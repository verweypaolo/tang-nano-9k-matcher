# tang-nano-matcher

A UART-based order matching engine implemented in hand-coded Verilog for the
[Sipeed Tang Nano 9K](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html)
(Gowin GW1NR-9C, 27 MHz).

This project builds an application layer on top of a separate, standalone UART
implementation ([tang-nano-uart](https://github.com/verweypaolo/tang-nano-9k-uart) — link to that repo). Where that repo is a
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
message_rx.v      bytes -> messages   (messageReady, sentinelError, timeOutError,
                                       checksumError, decoded order fields)
matching engine   messages -> book updates / executions   (planned)
```

- **`uart_rx.v`** — RX-only port of the UART core from `tang-nano-uart`,
  producing one `byteReady` pulse per received byte.
- **`message_rx.v`** *(complete, tested)* — a state machine that consumes
  UART bytes and assembles them into a fixed-length order message, validating
  framing and checksum before asserting `messageReady`.
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
| Checksum   |   1   | XOR of all preceding bytes in the frame (sentinel through quantity, inclusive) |

Multi-byte fields (Order ID, Price, Quantity) are transmitted **big-endian
(high byte first)** — the first byte received for a given field occupies its
most-significant byte. This is a protocol-level convention chosen for this
project; it is independent of the UART core's own bit ordering (UART
transmits each byte LSB-first at the bit level, which is standard and
unrelated to this byte-level ordering decision).

Fixed-length framing was chosen over length-prefixed or delimiter-based
framing for simplicity: every field lives at a known byte offset, so the
receiving FSM can be a straightforward byte counter rather than needing
escape-byte or variable-length handling.

### Framing and error detection

Distinct error signals exist at two distinct layers, and are not conflated:

- **`uartFrameError`** / **`parityError`** (from `uart_rx.v`) — UART-level
  framing/parity errors, detected per byte.
- **`sentinelError`**, **`timeOutError`**, **`checksumError`** (from
  `message_rx.v`) — message-level errors, kept as separate signals rather
  than a single collapsed flag so a downstream consumer (or a testbench) can
  distinguish which failure mode occurred:
  - `sentinelError` — the expected sentinel byte was not found where a new
    message should start.
  - `timeOutError` — more than a configured number of cycles elapsed while
    waiting for the next byte of an in-progress message.
  - `checksumError` — the received checksum byte did not match the
    accumulated XOR of the frame.

If a message fails validation, it is dropped rather than acted on. Given the
domain (financial orders), never acting on a corrupted or malformed message is
treated as a hard invariant, not an optional refinement.

`message_rx.v`'s `IDLE` state treats every incoming byte as a potential
sentinel, so the FSM naturally regains frame sync after any corruption or
stray byte without needing special-case recovery logic.

## Testing

`message_rx_tb.v` is a self-checking Icarus Verilog testbench (module `test`)
that instantiates `message_rx` (which in turn instantiates `uart_rx`) and
drives it bit-serially via a `send_byte` task, built up into full order frames
via `send_order`. The fractional baud accumulator (`ACC_INCREMENT`) is
disabled in simulation to keep bit timing exactly deterministic, since it
exists to approximate a real-world fractional baud rate that has no meaning
at the simulated clock speed used for fast testing.

All test cases run in a single sequential `initial` block, deliberately with
no gap between most of them, so that each test also implicitly verifies
`message_rx` correctly resets its internal state (checksum accumulator, byte
counter, error flags) and is ready for the next message immediately —
catching exactly the class of stale-state bug that's easy to introduce when
building up a multi-state FSM incrementally.

Current coverage, all passing:

- **Valid order** — correct sentinel, fields, and checksum decode correctly
  and assert `messageReady`.
- **Bad sentinel** — an incorrect first byte asserts `sentinelError` without
  asserting `messageReady`.
- **Bad checksum** — a correctly-framed message with a deliberately wrong
  checksum byte asserts `checksumError` without asserting `messageReady`.
- **Timeout** — a partial message followed by prolonged silence asserts
  `timeOutError`, with no other error/ready flag incorrectly set.
- **Resync after garbage** — a single stray non-sentinel byte followed
  immediately by a valid order confirms the FSM recovers and decodes the
  valid message with no special-case handling needed.
- **Back-to-back valid messages** — two consecutive, distinct valid orders
  with no gap between them, checked independently, confirming per-message
  state is fully reset between messages rather than leaking forward.

## Status

- [x] `uart_rx.v` ported from `tang-nano-uart`
- [x] `message_rx.v` — message FSM, checksum validation, resync handling
- [x] `message_rx.v` testbench — all scenarios passing
- [ ] Order book storage
- [ ] Matching logic
- [ ] TX-side execution reports
- [ ] Formal verification (SymbiYosys)

## Toolchain

- [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) (Yosys, nextpnr, Icarus Verilog)
- VS Code with the [Lushay Code](https://lushaylabs.com/) extension
- [VaporView](https://github.com/Lramseyer/vaporview) for waveform inspection
- CoolTerm / pyserial for serial-level testing