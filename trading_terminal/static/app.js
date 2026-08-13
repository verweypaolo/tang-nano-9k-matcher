/*
 * app.js — frontend logic for the tang-nano-matcher trading terminal.
 *
 * Two channels talk to the backend:
 *   - REST (POST /api/orders, POST /api/connect) for actions the user takes
 *   - WebSocket (/ws) for state the server pushes: book, stats, reports
 *
 * All rendering is driven by whole-state snapshots pushed over the socket
 * rather than by incrementally mutating the DOM from individual events, so
 * a freshly-opened tab and a long-running one always converge on the same
 * view.
 */

// --- outcome codes, mirroring protocol.py -----------------------------------

const OUTCOME_NAMES = {
  1: "FILLED",
  2: "RESTING",
  3: "REJECTED",
  4: "INVALID",
};

const OUTCOME_CLASSES = {
  1: "outcome-badge--filled",
  2: "outcome-badge--resting",
  3: "outcome-badge--rejected",
  4: "outcome-badge--invalid",
};

// --- element handles --------------------------------------------------------

const el = {
  linkDot: document.getElementById("linkDot"),
  linkPort: document.getElementById("linkPort"),
  reconnectBtn: document.getElementById("reconnectBtn"),

  statUptime: document.getElementById("statUptime"),
  statSent: document.getElementById("statSent"),
  statRecv: document.getElementById("statRecv"),
  statPending: document.getElementById("statPending"),
  statFilled: document.getElementById("statFilled"),
  statResting: document.getElementById("statResting"),
  statRejected: document.getElementById("statRejected"),
  statInvalid: document.getElementById("statInvalid"),

  orderForm: document.getElementById("orderForm"),
  priceInput: document.getElementById("priceInput"),
  qtyInput: document.getElementById("qtyInput"),
  sideButtons: document.querySelectorAll(".side-btn"),

  outgoingFeed: document.getElementById("outgoingFeed"),
  incomingFeed: document.getElementById("incomingFeed"),

  askTable: document.querySelector("#askTable tbody"),
  bidTable: document.querySelector("#bidTable tbody"),
  spreadValue: document.getElementById("spreadValue"),

  sentinelDot: document.getElementById("sentinelDot"),
  discrepancies: document.getElementById("discrepancies"),
  discrepancyText: document.getElementById("discrepancyText"),
};

let selectedSide = "BUY";
let pendingOrderIds = new Set();

// --- side toggle -------------------------------------------------------------

el.sideButtons.forEach((btn) => {
  btn.addEventListener("click", () => {
    el.sideButtons.forEach((b) => b.classList.remove("is-active"));
    btn.classList.add("is-active");
    selectedSide = btn.dataset.side;
  });
});

// --- order submission --------------------------------------------------------

el.orderForm.addEventListener("submit", async (event) => {
  event.preventDefault();

  const price = parseInt(el.priceInput.value, 10);
  const quantity = parseInt(el.qtyInput.value, 10);

  if (!Number.isFinite(price) || !Number.isFinite(quantity)) return;

  try {
    const response = await fetch("/api/orders", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ side: selectedSide, price, quantity }),
    });
    const result = await response.json();

    if (!result.ok) {
      showTransientError(result.error || "order rejected by backend");
      return;
    }
    pulseSentinel();
  } catch (err) {
    showTransientError("could not reach the backend");
  }
});

// --- reconnect ---------------------------------------------------------------

el.reconnectBtn.addEventListener("click", async () => {
  const manualPort = prompt(
    "Leave blank to retry auto-detection, or enter a port path:",
    el.linkPort.textContent.startsWith("/dev/") ? el.linkPort.textContent : ""
  );
  if (manualPort === null) return; // user cancelled

  el.reconnectBtn.disabled = true;
  el.reconnectBtn.textContent = "connecting…";

  try {
    const response = await fetch("/api/connect", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ port: manualPort.trim() || null }),
    });
    renderStatus(await response.json());
  } catch (err) {
    showTransientError("could not reach the backend");
  } finally {
    el.reconnectBtn.disabled = false;
    el.reconnectBtn.textContent = "reconnect";
  }
});

// --- websocket ---------------------------------------------------------------

let socket = null;

function connectSocket() {
  const protocol = location.protocol === "https:" ? "wss:" : "ws:";
  socket = new WebSocket(`${protocol}//${location.host}/ws`);

  socket.addEventListener("message", (event) => {
    const msg = JSON.parse(event.data);
    handleMessage(msg);
  });

  socket.addEventListener("close", () => {
    // the backend went away or the tab slept — retry shortly, so the page
    // recovers on its own rather than silently going stale
    setTimeout(connectSocket, 2000);
  });
}

function handleMessage(msg) {
  switch (msg.type) {
    case "status":
      renderStatus(msg.status);
      break;
    case "book":
      renderBook(msg.book);
      break;
    case "stats":
      renderStats(msg.stats);
      break;
    case "recent_sent":
      renderOutgoing(msg.orders);
      break;
    case "recent_reports":
      renderIncoming(msg.reports);
      break;
    case "order_sent":
      pendingOrderIds.add(msg.order.order_id);
      prependOutgoing(msg.order);
      pulseSentinel();
      break;
    case "report":
      pendingOrderIds.delete(msg.report.order_id);
      prependIncoming(msg.report);
      markOutgoingResolved(msg.report.order_id);
      pulseSentinel();
      break;
    case "unknown_report":
      prependIncoming(msg.report);
      showTransientError(msg.note);
      pulseSentinel();
      break;
  }
}

// --- rendering: status -------------------------------------------------------

function renderStatus(status) {
  const isUp = status.status === "connected";
  el.linkDot.classList.toggle("link__dot--up", isUp);
  el.linkDot.classList.toggle("link__dot--down", !isUp);
  el.linkPort.textContent = status.port || status.last_error || "no device";
  el.linkPort.title = status.last_error || "";
}

// --- rendering: stats --------------------------------------------------------

function renderStats(stats) {
  el.statUptime.textContent = formatDuration(stats.running_time_seconds);
  el.statSent.textContent = stats.orders_sent;
  el.statRecv.textContent = stats.reports_received;
  el.statPending.textContent = stats.outstanding;
  el.statFilled.textContent = stats.outcome_counts.filled;
  el.statResting.textContent = stats.outcome_counts.resting;
  el.statRejected.textContent = stats.outcome_counts.rejected;
  el.statInvalid.textContent = stats.outcome_counts.invalid;
}

function formatDuration(totalSeconds) {
  const s = Math.floor(totalSeconds);
  const hh = String(Math.floor(s / 3600)).padStart(2, "0");
  const mm = String(Math.floor((s % 3600) / 60)).padStart(2, "0");
  const ss = String(s % 60).padStart(2, "0");
  return `${hh}:${mm}:${ss}`;
}

// --- rendering: book ---------------------------------------------------------

function renderBook(book) {
  // book.py returns both sides already sorted best-first (index 0), which is
  // exactly the order we render top-to-bottom, so no re-sorting is needed
  el.askTable.innerHTML = book.asks.map(bookRow).join("");
  el.bidTable.innerHTML = book.bids.map(bookRow).join("");

  const bestAsk = book.asks.length ? book.asks[0].price : null;
  const bestBid = book.bids.length ? book.bids[0].price : null;
  el.spreadValue.textContent =
    bestAsk !== null && bestBid !== null ? bestAsk - bestBid : "—";

  if (book.discrepancies && book.discrepancies.length) {
    const latest = book.discrepancies[book.discrepancies.length - 1];
    el.discrepancyText.textContent = `#${pad4(latest.order_id)} — ${latest.description}`;
    el.discrepancies.hidden = false;
  } else {
    el.discrepancies.hidden = true;
  }
}

function bookRow(entry) {
  return `<tr>
    <td class="book__oid">#${pad4(entry.order_id)}</td>
    <td class="book__qty">${entry.quantity}</td>
    <td class="book__price">${entry.price}</td>
  </tr>`;
}

// --- rendering: feeds --------------------------------------------------------

function renderOutgoing(orders) {
  el.outgoingFeed.innerHTML = orders.map(outgoingRow).join("");
}

function prependOutgoing(order) {
  el.outgoingFeed.insertAdjacentHTML("afterbegin", outgoingRow(order));
  trimFeed(el.outgoingFeed);
}

function outgoingRow(order) {
  const isPending = pendingOrderIds.has(order.order_id);
  const sideClass = order.side === "BUY" ? "feed__side--buy" : "feed__side--sell";
  return `<li class="feed__row ${isPending ? "feed__row--pending" : ""}" data-order-id="${order.order_id}">
    <span class="feed__id">#${pad4(order.order_id)}</span>
    <span class="feed__side ${sideClass}">${order.side}</span>
    <span class="feed__price">${order.price}</span>
    <span class="feed__qty">×${order.quantity}</span>
    ${isPending ? '<span class="feed__flag" title="awaiting report">…</span>' : ""}
  </li>`;
}

function markOutgoingResolved(orderId) {
  const row = el.outgoingFeed.querySelector(`[data-order-id="${orderId}"]`);
  if (!row) return;
  row.classList.remove("feed__row--pending");
  const flag = row.querySelector(".feed__flag");
  if (flag) flag.remove();
}

function renderIncoming(reports) {
  el.incomingFeed.innerHTML = reports.map(incomingRow).join("");
}

function prependIncoming(report) {
  el.incomingFeed.insertAdjacentHTML("afterbegin", incomingRow(report));
  trimFeed(el.incomingFeed);
}

function incomingRow(report) {
  const name = OUTCOME_NAMES[report.outcome] || `0x${report.outcome.toString(16)}`;
  const cls = OUTCOME_CLASSES[report.outcome] || "outcome-badge--invalid";
  return `<li class="feed__row">
    <span class="feed__id">#${pad4(report.order_id)}</span>
    <span class="outcome-badge ${cls}">${name}</span>
    <span class="feed__price">${report.price}</span>
    <span class="feed__qty">×${report.quantity}</span>
  </li>`;
}

function trimFeed(feedEl, max = 100) {
  while (feedEl.children.length > max) {
    feedEl.removeChild(feedEl.lastChild);
  }
}

// --- misc --------------------------------------------------------------------

function pad4(n) {
  return String(n).padStart(4, "0");
}

let sentinelTimer = null;
function pulseSentinel() {
  el.sentinelDot.classList.remove("is-active");
  // force reflow so the animation restarts even on rapid consecutive frames
  void el.sentinelDot.offsetWidth;
  el.sentinelDot.classList.add("is-active");

  clearTimeout(sentinelTimer);
  sentinelTimer = setTimeout(() => {
    el.sentinelDot.classList.remove("is-active");
  }, 400);
}

function showTransientError(message) {
  el.discrepancyText.textContent = message;
  el.discrepancies.hidden = false;
  setTimeout(() => {
    if (el.discrepancyText.textContent === message) {
      el.discrepancies.hidden = true;
    }
  }, 5000);
}

// --- boot --------------------------------------------------------------------

connectSocket();