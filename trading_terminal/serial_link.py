"""
serial_link.py — owns the persistent UART connection to the FPGA.

Design summary:
- A single serial.Serial connection is opened once and kept open for the
  life of the application, rather than reopened per-message (reopening
  repeatedly was observed to be unreliable on macOS during hardware bring-up
  — see docs/notes for the underlying investigation).
- Auto-detection tries to find the board's UART channel on its own; if that
  fails, the link starts in a DISCONNECTED state rather than crashing the
  application, and a caller (eventually the web UI) can supply an explicit
  port to retry with connect(port=...).
- Incoming bytes are read continuously by a background thread and handed
  off to consumers via a queue.Queue, decoupling the serial thread from
  whatever eventually processes reports (book reconstruction, stats, the
  web layer's push-to-client logic).
- The read thread resyncs on garbage the same way message_rx.v does: any
  byte that isn't a valid, checksummed frame starting with SENTINEL is
  dropped and scanning continues, rather than discarding large chunks of
  the stream or getting stuck.
"""

import re
import threading
import time
import queue

import serial
import serial.tools.list_ports

from protocol import (
    SENTINEL,
    FRAME_LENGTH,
    build_order,
    parse_report,
    ProtocolError,
)

CONNECTING = "connecting"
CONNECTED = "connected"
DISCONNECTED = "disconnected"

SETTLE_DELAY_SECONDS = 1.5  # empirically needed after opening the port on macOS
                             # before writes are reliably received


def find_tang_nano_port():
    """Locate the Tang Nano 9K's UART channel among connected usbserial
    devices.

    The board's bridge chip exposes two channels (JTAG and UART) that report
    identical description/manufacturer/vid:pid — metadata alone can't tell
    them apart. Empirically (verified across multiple reconnects), the UART
    channel is consistently the higher-numbered of the two consecutive
    device nodes. manufacturer == SIPEED is an additional sanity check that
    we're looking at this board at all, not some unrelated usbserial device.
    """
    candidates = [
        p for p in serial.tools.list_ports.comports()
        if "usbserial" in p.device.lower()
        and (p.manufacturer or "").upper() == "SIPEED"
    ]

    if not candidates:
        raise RuntimeError("No SIPEED usbserial device found — is the board connected?")

    if len(candidates) == 1:
        return candidates[0].device

    def trailing_number(device_path):
        match = re.search(r"(\d+)$", device_path)
        return int(match.group(1)) if match else -1

    candidates.sort(key=lambda p: trailing_number(p.device))
    return candidates[-1].device  # highest-numbered of the pair = UART channel


class SerialLink:
    def __init__(self, port=None, baudrate=115200, parity=serial.PARITY_EVEN):
        self.baudrate = baudrate
        self.parity = parity
        self.port = port  # None means "auto-detect on connect()"

        self.status = DISCONNECTED
        self.last_error = None

        self.reports = queue.Queue()

        self._serial = None
        self._reader_thread = None
        self._stop_event = threading.Event()
        self._write_lock = threading.Lock()

    # --- connection lifecycle ------------------------------------------

    def connect(self, port=None):
        """(Re)connect, optionally overriding the port. Never raises —
        failures are recorded in self.status / self.last_error so a caller
        (the web UI) can display them and let the user retry with a
        manually-supplied port, rather than crashing the application."""
        self.status = CONNECTING
        self.last_error = None

        self.disconnect()  # tear down any existing connection/thread first

        try:
            target_port = port or self.port or find_tang_nano_port()
            self._serial = serial.Serial(
                target_port, self.baudrate, parity=self.parity, timeout=1
            )
            self.port = target_port

            time.sleep(SETTLE_DELAY_SECONDS)
            self._serial.reset_input_buffer()

            self._stop_event.clear()
            self._reader_thread = threading.Thread(
                target=self._read_loop, daemon=True
            )
            self._reader_thread.start()

            self.status = CONNECTED
        except Exception as e:  # noqa: BLE001 - deliberately broad: any
            # failure here (port not found, permission denied, device busy,
            # etc.) should land the link in DISCONNECTED with a readable
            # message, not propagate and take the app down with it.
            self.status = DISCONNECTED
            self.last_error = str(e)
            self._serial = None

    def disconnect(self):
        self._stop_event.set()
        if self._reader_thread is not None:
            self._reader_thread.join(timeout=2)
            self._reader_thread = None

        if self._serial is not None:
            try:
                self._serial.close()
            except Exception:
                pass
            self._serial = None

        self.status = DISCONNECTED

    # --- sending ---------------------------------------------------------

    def send_order(self, order_id, side, price, quantity):
        """Build and transmit an order frame. Raises RuntimeError if not
        currently connected — callers should check self.status first if
        they want to avoid the exception path."""
        if self.status != CONNECTED or self._serial is None:
            raise RuntimeError("not connected")

        frame = build_order(order_id, side, price, quantity)
        with self._write_lock:
            print(f"[serial_link] writing order {order_id} at t={time.monotonic():.6f}", flush=True)
            self._serial.write(frame)
        return frame

    # --- background reading / resync -------------------------------------

    def _read_loop(self):
        while not self._stop_event.is_set():
            try:
                self._scan_for_frame()
            except serial.SerialException as e:
                self.status = DISCONNECTED
                self.last_error = str(e)
                return

    def _scan_for_frame(self):
        """Read one byte at a time until a SENTINEL is found, then attempt
        to read and parse a full frame. On any failure (short read/timeout,
        checksum mismatch, bad sentinel — shouldn't happen given the scan,
        but parse_report re-validates regardless), drop just that byte and
        resume scanning, mirroring message_rx.v's own resync behavior:
        every byte is a potential sentinel, so a single corrupted frame
        never derails reception of subsequent ones."""
        b = self._serial.read(1)
        if len(b) == 0:
            return  # read timeout, nothing arrived — loop again
        if b[0] != SENTINEL:
            print(f"[serial_link] non-sentinel byte while scanning: 0x{b[0]:02X}", flush=True)
            return  # not a frame start, keep scanning

        rest = self._serial.read(FRAME_LENGTH - 1)
        if len(rest) != FRAME_LENGTH - 1:
            print(f"[serial_link] incomplete frame: got {len(rest)}/{FRAME_LENGTH-1} bytes", flush=True)
            return  # incomplete frame (e.g. device disconnected mid-frame)

        frame = b + rest
        try:
            report = parse_report(frame)
            print(f"[serial_link] queued report for order_id={report.order_id}", flush=True)
            self.reports.put(report)
        except ProtocolError as e:
            # bad checksum or similar — drop this candidate frame and
            # resume scanning from the very next byte, not from wherever
            # this attempt left off, in case the real sentinel is buried
            # inside what we just consumed
            print(f"[serial_link] dropped candidate frame: {e}", flush=True)
            return