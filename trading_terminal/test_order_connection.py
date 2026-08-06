import serial
import time

SENTINEL = 0xAA
MSG_TYPE_NEW_ORDER = 0x01
SIDE_BUY = 0x00
SIDE_SELL = 0x01

def build_order(msg_type, order_id, side, price, quantity):
    """Build the 10-byte order frame, big-endian for multi-byte fields."""
    payload = [
        SENTINEL,
        msg_type,
        (order_id >> 8) & 0xFF, order_id & 0xFF,
        side,
        (price >> 8) & 0xFF, price & 0xFF,
        (quantity >> 8) & 0xFF, quantity & 0xFF,
    ]
    checksum = 0
    for b in payload:
        checksum ^= b
    payload.append(checksum)
    return bytes(payload)

def parse_report(data):
    """Parse a 10-byte execution report."""
    if len(data) != 10:
        return None, f"expected 10 bytes, got {len(data)}"
    if data[0] != SENTINEL:
        return None, f"bad sentinel: 0x{data[0]:02X}"
    checksum = 0
    for b in data[:9]:
        checksum ^= b
    if checksum != data[9]:
        return None, f"checksum mismatch: computed 0x{checksum:02X}, received 0x{data[9]:02X}"
    return {
        "msg_type": data[1],
        "order_id": (data[2] << 8) | data[3],
        "outcome": data[4],
        "price": (data[5] << 8) | data[6],
        "quantity": (data[7] << 8) | data[8],
    }, None

OUTCOME_NAMES = {0x01: "FILLED", 0x02: "RESTING", 0x03: "REJECTED", 0x04: "INVALID"}

# --- adjust these two for your setup ---
PORT = "/dev/tty.usbserial-101"  # find with: ls /dev/tty.*
BAUD = 115200                      # must match BAUD_DIVISOR=234 at 27MHz

with serial.Serial(PORT, BAUD, parity=serial.PARITY_EVEN,  timeout=2) as ser:
    time.sleep(2)  # let the port settle before writing
    ser.reset_input_buffer()  # clear any garbage accumulated during settling
    
    order = build_order(MSG_TYPE_NEW_ORDER, 0x0001, SIDE_BUY, 100, 10)
    print(f"Sending: {order.hex(' ')}")
    ser.write(order)

    response = ser.read(10)
    print(f"Received: {response.hex(' ')}")

    report, err = parse_report(response)
    if err:
        print(f"Parse error: {err}")
    else:
        print(f"  order_id = {report['order_id']}")
        outcome_name = OUTCOME_NAMES.get(report['outcome'], f"unknown (0x{report['outcome']:02X})")
        print(f"  outcome  = {outcome_name}")
        print(f"  price    = {report['price']}")
        print(f"  quantity = {report['quantity']}")