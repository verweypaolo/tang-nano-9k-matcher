"""
protocol.py — byte-level frame format for the tang-nano-matcher UART protocol.

This is the single source of truth, on the Python side, for how orders are
encoded and how execution reports are decoded. It is a hand-maintained mirror
of the RTL frame formats implemented in message_rx.v (inbound orders) and
message_tx.v (outbound reports) — see the "Message Format" and "TX Reporting
Design" sections of the top-level README for the authoritative field layout.

There is no automatic mechanism keeping this file and the RTL in sync. If the
frame format ever changes on the FPGA side (field widths, field order, the
outcome enum, etc.), this file must be updated to match by hand.

Both frame types share the same shape: a fixed 10-byte frame, big-endian for
multi-byte fields, terminated by an XOR checksum over every preceding byte.
"""

from dataclasses import dataclass, field

# --- Framing ---------------------------------------------------------------

SENTINEL = 0xAA
FRAME_LENGTH = 10

# --- Inbound (order) message types ------------------------------------------

MSG_TYPE_NEW_ORDER = 0x01
# MSG_TYPE_CANCEL is not yet implemented on the FPGA side.
# MSG_TYPE_CANCEL = 0x02

# --- Side ---------------------------------------------------------------

SIDE_BUY = 0x00
SIDE_SELL = 0x01

SIDE_NAMES = {
    SIDE_BUY: "BUY",
    SIDE_SELL: "SELL",
}

# --- Outbound (report) outcome codes ----------------------------------------

OUTCOME_FILLED = 0x01
OUTCOME_RESTING = 0x02
OUTCOME_REJECTED = 0x03
OUTCOME_INVALID = 0x04

OUTCOME_NAMES = {
    OUTCOME_FILLED: "FILLED",
    OUTCOME_RESTING: "RESTING",
    OUTCOME_REJECTED: "REJECTED",
    OUTCOME_INVALID: "INVALID",
}


class ProtocolError(ValueError):
    """Raised when a frame fails to parse or validate."""


def _checksum(payload_bytes):
    """XOR-reduce every byte in payload_bytes (does not include the checksum
    byte itself)."""
    checksum = 0
    for b in payload_bytes:
        checksum ^= b
    return checksum


@dataclass
class SentOrder:
    """A record of an order this terminal sent, kept around so a later
    Report (which only carries order_id, outcome, price, quantity) can be
    correlated back to the full original order — needed by book.py's
    reconstruction, which requires knowing the original side and quantity,
    neither of which round-trips through a report on its own."""
    order_id: int
    side: int
    price: int
    quantity: int


def build_order(order_id: int, side: int, price: int, quantity: int,
                 msg_type: int = MSG_TYPE_NEW_ORDER) -> bytes:
    """Build a 10-byte order frame ready to write to the serial port.

    order_id, price, quantity are each 16-bit, big-endian on the wire.
    side must be SIDE_BUY or SIDE_SELL.
    """
    if not (0 <= order_id <= 0xFFFF):
        raise ProtocolError(f"order_id out of range: {order_id}")
    if not (0 <= price <= 0xFFFF):
        raise ProtocolError(f"price out of range: {price}")
    if not (0 <= quantity <= 0xFFFF):
        raise ProtocolError(f"quantity out of range: {quantity}")
    if side not in (SIDE_BUY, SIDE_SELL):
        raise ProtocolError(f"invalid side: {side}")

    payload = bytes([
        SENTINEL,
        msg_type,
        (order_id >> 8) & 0xFF, order_id & 0xFF,
        side,
        (price >> 8) & 0xFF, price & 0xFF,
        (quantity >> 8) & 0xFF, quantity & 0xFF,
    ])
    return payload + bytes([_checksum(payload)])


@dataclass
class Report:
    msg_type: int
    order_id: int
    outcome: int
    price: int
    quantity: int
    outcome_name: str = field(init=False)

    def __post_init__(self):
        self.outcome_name = OUTCOME_NAMES.get(
            self.outcome, f"UNKNOWN(0x{self.outcome:02X})"
        )


def parse_report(data: bytes) -> Report:
    """Decode a 10-byte execution report. Raises ProtocolError on any framing,
    length, or checksum failure — never returns a partially-valid Report."""
    if len(data) != FRAME_LENGTH:
        raise ProtocolError(f"expected {FRAME_LENGTH} bytes, got {len(data)}")

    if data[0] != SENTINEL:
        raise ProtocolError(f"bad sentinel: 0x{data[0]:02X}")

    computed = _checksum(data[:9])
    if computed != data[9]:
        raise ProtocolError(
            f"checksum mismatch: computed 0x{computed:02X}, "
            f"received 0x{data[9]:02X}"
        )

    return Report(
        msg_type=data[1],
        order_id=(data[2] << 8) | data[3],
        outcome=data[4],
        price=(data[5] << 8) | data[6],
        quantity=(data[7] << 8) | data[8],
    )