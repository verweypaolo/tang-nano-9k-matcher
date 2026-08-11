"""
app.py — ties serial_link, book, and stats together and serves the UI.

Ownership model:
- This module is the ONE place that correlates order_id -> SentOrder
  (the "pending orders" table). book.py and stats.py both need that
  correlation but deliberately don't keep their own copies of it — app.py
  looks up the SentOrder once per incoming report and feeds both.
- serial_link.SerialLink's background thread only ever writes decoded
  Report objects onto link.reports (a queue.Queue). A second background
  thread here drains that queue and, for each report, does the
  correlation + updates book/stats, then hands the result to the asyncio
  event loop (via call_soon_threadsafe) so it can be pushed to connected
  WebSocket clients. Two different concurrency models (threading +
  asyncio) meet at exactly that one handoff point.
"""

import asyncio
import itertools
import threading

from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel
from typing import Optional

from protocol import SentOrder, SIDE_BUY, SIDE_SELL
from serial_link import SerialLink
from book import OrderBook
from stats import Stats

app = FastAPI()

link = SerialLink()
book = OrderBook()
stats = Stats()

_order_id_counter = itertools.count(1)
_pending_orders = {}  # order_id -> SentOrder, entries removed once a report arrives
_pending_lock = threading.Lock()

_recent_sent = []    # most-recent-first, capped, for the UI's outgoing queue panel
_recent_reports = [] # most-recent-first, capped, for the UI's incoming reports panel
_RECENT_CAP = 100

_ws_clients = set()
_event_loop = None  # captured at startup, needed for the background thread's handoff


# --- connection lifecycle ---------------------------------------------------

@app.on_event("startup")
async def startup():
    global _event_loop
    _event_loop = asyncio.get_running_loop()
    link.connect()  # tries auto-detect; never raises, just sets status/last_error
    _start_report_drain_thread()


class ConnectRequest(BaseModel):
    port: Optional[str] = None  # None retries auto-detect; a string overrides it


@app.post("/api/connect")
async def api_connect(req: ConnectRequest):
    link.connect(port=req.port)
    return _connection_status()


@app.get("/api/status")
async def api_status():
    return _connection_status()


def _connection_status():
    return {
        "status": link.status,
        "port": link.port,
        "last_error": link.last_error,
    }


# --- sending orders ----------------------------------------------------------

class OrderRequest(BaseModel):
    side: str  # "BUY" or "SELL"
    price: int
    quantity: int


@app.post("/api/orders")
async def api_send_order(req: OrderRequest):
    side = SIDE_BUY if req.side.upper() == "BUY" else SIDE_SELL
    order_id = next(_order_id_counter)

    sent_order = SentOrder(order_id=order_id, side=side, price=req.price, quantity=req.quantity)

    with _pending_lock:
        _pending_orders[order_id] = sent_order

    try:
        link.send_order(order_id, side, req.price, req.quantity)
    except RuntimeError as e:
        with _pending_lock:
            _pending_orders.pop(order_id, None)
        return {"ok": False, "error": str(e)}

    stats.on_order_sent(order_id)
    _push_recent(_recent_sent, {
        "order_id": order_id, "side": req.side.upper(),
        "price": req.price, "quantity": req.quantity,
    })
    await _broadcast({"type": "order_sent", "order": _recent_sent[0]})
    await _broadcast({"type": "stats", "stats": stats.snapshot()})

    return {"ok": True, "order_id": order_id}


# --- background report draining (thread) -> asyncio handoff ------------------

def _start_report_drain_thread():
    t = threading.Thread(target=_drain_reports_loop, daemon=True)
    t.start()


def _drain_reports_loop():
    while True:
        report = link.reports.get()  # blocks until a report is available

        with _pending_lock:
            order = _pending_orders.pop(report.order_id, None)

        if order is None:
            # a report arrived for an order_id we have no record of sending —
            # itself worth surfacing rather than silently dropping
            note = f"report for unknown order_id {report.order_id}"
            payload = {"type": "unknown_report", "report": report.__dict__, "note": note}
        else:
            book.on_report(order, report)
            payload = {"type": "report", "report": report.__dict__}

        stats.on_report_received(report.order_id, report.outcome)
        _push_recent(_recent_reports, report.__dict__)

        if _event_loop is not None:
            asyncio.run_coroutine_threadsafe(_broadcast_report_update(payload), _event_loop)


async def _broadcast_report_update(payload):
    await _broadcast(payload)
    await _broadcast({"type": "book", "book": book.snapshot()})
    await _broadcast({"type": "stats", "stats": stats.snapshot()})


def _push_recent(target_list, item):
    target_list.insert(0, item)
    del target_list[_RECENT_CAP:]


# --- websocket ----------------------------------------------------------------

@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    _ws_clients.add(ws)
    try:
        # send full current state on connect, so a freshly-opened browser
        # tab isn't stuck waiting for the next event to populate anything
        await ws.send_json({"type": "status", "status": _connection_status()})
        await ws.send_json({"type": "book", "book": book.snapshot()})
        await ws.send_json({"type": "stats", "stats": stats.snapshot()})
        await ws.send_json({"type": "recent_sent", "orders": _recent_sent})
        await ws.send_json({"type": "recent_reports", "reports": _recent_reports})

        while True:
            await ws.receive_text()  # unused for now; keeps the connection alive
    except WebSocketDisconnect:
        pass
    finally:
        _ws_clients.discard(ws)


async def _broadcast(payload):
    dead = []
    for ws in _ws_clients:
        try:
            await ws.send_json(payload)
        except Exception:
            dead.append(ws)
    for ws in dead:
        _ws_clients.discard(ws)


# --- static frontend -----------------------------------------------------------

app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/")
async def index():
    return FileResponse("static/index.html")