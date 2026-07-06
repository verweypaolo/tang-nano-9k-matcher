# tang-nano-matcher

A UART-based order matching engine implemented in hand-coded Verilog for the
[Sipeed Tang Nano 9K](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html)
(Gowin GW1NR-9C, 27 MHz).

This project builds an application layer on top of a separate, standalone UART
implementation ([tang-nano-uart](#) — link to that repo). Where that repo is a
showcase of the UART protocol itself (fractional baud generation, parity,
framing-error detection), this repo is a showcase of *using* UART as a
transport for something more interesting: a reactive market-matching engine
that receives buy/sell orders as multi-byte messages, matches them against a
resting order book, and reports back the outcome — all inside FPGA fabric,
with no soft CPU involved.

## Scope

This project is intentionally scoped as a **reactive matching engine**, not an
autonomous market maker. The FPGA does not generate its own quotes, manage its
own inventory, or make independent trading decisions — it only evaluates
orders that arrive over UART against the current book. Autonomous
market-making (independent quoting, inventory-aware pricing, cancel/replace of
the FPGA's own resting orders) is a natural extension of this design, but is
explicitly deferred to a possible future phase.

## Architecture

Each layer only understands the handshake contract of the layer below it —
the same pattern used by the underlying UART core (bit-level sampling below,
byte-level `byteReady` handshake above):

```
uart_rx.v        bits -> bytes        (byteReady, dataIn, uartFrameError, parityError)
message_rx.v      bytes -> messages   (messageReady, msgFrameError, decoded order fields)
matching engine   messages -> book updates / executions   (in progress)
```

- **`uart_rx.v`** — RX-only port of the UART core from `tang-nano-uart`,
  producing one `byteReady` pulse per received byte.
- **`message_rx.v`** — a state machine that consumes UART bytes and assembles
  them into a fixed-length order message, validating framing and checksum
  before asserting `messageReady`.
- **matching engine** *(planned)* — maintains a resting order book and
  matches incoming orders against it on a `messageReady` pulse.

## Message Format

Orders are sent as a fixed-length, 10-byte frame:

| Field      | Bytes | Description                                      |
|------------|:-----:|---------------------------------------------------|
| Sentinel   |   1   | Fixed marker byte (`0xAA`), used to detect/regain frame sync |
| Msg Type   |   1   | e.g. `NEW_ORDER`, `CANCEL`                          |
| Order ID   |   2   | Unique identifier for the order                    |
| Side       |   1   | `0` = BUY, `1` = SELL                               |
| Price      |   2   | Fixed-point price, in ticks                        |
| Quantity   |   2   | Order size                                         |
| Checksum   |   1   | XOR of all preceding bytes in the frame            |

Fixed-length framing was chosen over length-prefixed or delimiter-based
framing for simplicity: every field lives at a known byte offset, so the
receiving FSM can be a straightforward byte counter rather than needing
escape-byte or variable-length handling.

### Framing and error detection

Two distinct error signals exist at two distinct layers, and are not conflated:

- **`uartFrameError`** (from `uart_rx.v`) — a UART-level framing error (e.g.
  missing stop bit), detected per byte.
- **`msgFrameError`** (from `message_rx.v`) — a message-level error, raised
  when the checksum fails or the sentinel is not found where expected.

If a message fails validation, it is dropped rather than acted on. Given the
domain (financial orders), never acting on a corrupted or malformed message is
treated as a hard invariant, not an optional refinement.

## Status

- [x] `uart_rx.v` ported from `tang-nano-uart`
- [ ] `message_rx.v` — message FSM, checksum validation, resync handling
- [ ] Order book storage
- [ ] Matching logic
- [ ] TX-side execution reports
- [ ] Formal verification (SymbiYosys)

## Toolchain

- [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) (Yosys, nextpnr, Icarus Verilog)
- VS Code with the [Lushay Code](https://lushaylabs.com/) extension
- [VaporView](https://github.com/Lramseyer/vaporview) for waveform inspection
- CoolTerm / pyserial for serial-level testing
