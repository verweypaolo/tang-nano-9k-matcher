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
uart_rx.v          bits -> bytes         (byteReady, dataIn, uartFrameError, parityError)
message_rx.v        bytes -> messages    (messageReady, sentinelError, timeOutError,
                                          checksumError, decoded order fields)
order_book_side.v   sorted resting orders per side (insert/remove, N=8, parameterized
                                          by sort direction for bid vs. ask)
matching engine     messages + book state -> book updates / executions   (planned)
```

- **`uart_rx.v`** — RX-only port of the UART core from `tang-nano-uart`,
  producing one `byteReady` pulse per received byte.
- **`message_rx.v`** *(complete, tested)* — a state machine that consumes
  UART bytes and assembles them into a fixed-length order message, validating
  framing and checksum before asserting `messageReady`.
- **`order_book_side.v`** *(complete, tested)* — maintains a sorted,
  fixed-depth (N=8) list of resting orders for one side of the book (bid or
  ask, selected via a `DESCENDING` parameter), implemented as combinationally
  shifted register arrays rather than BRAM, so that finding the best price is
  a direct read rather than a search. Two instances of this module (one per
  side) will be instantiated by the matching engine.
- **matching engine** *(planned)* — consumes `message_rx`'s decoded fields on
  `messageReady`, matches incoming orders against the resting book, and
  issues insert/remove commands to the appropriate `order_book_side` instance.

### Why registers instead of BRAM for the order book

The Tang Nano 9K's block RAM (BSRAM) only exposes one or two addressable
ports per cycle, which would force "find the best price" into a serial
search. Since matching latency is the entire point of doing this on an FPGA,
`order_book_side.v` instead stores its N=8 slots as plain registers and
computes insertion position via a fully parallel, combinational priority
encoder, and shifts on insert/remove in a single clock cycle — trading some
LUT/flip-flop budget for a book where "what is the best price" is always a
direct read, never a scan.

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

## Order Book Design

`order_book_side.v` maintains a fixed depth of N=8 resting orders, always
kept sorted (best price at index 0) via combinational insert/remove — no
scanning is ever needed to find the best resting price. A single module,
parameterized by `DESCENDING` (1 = bid side, highest price on top; 0 = ask
side, lowest price on top), is instantiated once per side.

Each slot stores: a valid bit, order ID, price, quantity, and a sequence
number for time-priority tie-breaking at equal prices — the sequence number
itself is generated externally (this module only stores whatever value it's
given), since it represents a single global arrival order shared across both
sides of the book.

Three distinct error conditions are exposed, kept separate for the same
debuggability reasons as `message_rx.v`'s error signals:

- **`insertFullError`** — an insert was attempted while all N slots were occupied.
- **`removeEmptyError`** — a remove was attempted while the book was empty.
- **`simultaneousOpError`** — insert and remove were both requested in the
  same cycle; neither operation is performed, since silently picking a
  winner could mask a bug in whatever module is driving this one.

Any successful insert or remove clears all three error flags; a failed
operation only asserts its own specific flag, leaving the others untouched.

## Testing

### `message_rx.v`

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

Coverage, all passing:

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

### `order_book_side.v`

Two testbenches exercise this module — `order_book_side_bid_tb.v`
(`DESCENDING=1`, bid side) and `order_book_side_ask_tb.v` (`DESCENDING=0`,
ask side) — sharing
the same overall structure: `do_insert`/`do_remove` tasks drive the module's
insert/remove pulses directly (no UART or message framing involved, since
this module's interface is already at the clean-signal level), and a
`print_book` task dumps every slot's valid bit and field values for visual
inspection after each test step.

Both testbenches build up a shared scenario sequentially rather than
resetting between tests, so later tests also implicitly verify the module's
state (sorted order, error flags) carries over correctly from whatever the
previous test left behind:

- **Simultaneous insert + remove** — both pulsed in the same cycle asserts
  `simultaneousOpError`, and neither operation is performed.
- **Remove from an empty book** — asserts `removeEmptyError`, book state
  unchanged.
- **Insert into an empty book** — lands correctly in slot 0.
- **Insert appended / inserted mid-array** — a second insert correctly sorts
  relative to the first, and a third insert lands strictly between two
  existing entries, forcing a genuine multi-slot shift (checked field-by-field,
  not just via the `valid` mask).
- **Duplicate price** — an insert at a price equal to an existing entry lands
  *after* it, confirming arrival order (not just price) determines priority
  at equal prices.
- **Fill to full, then insert-when-full** — asserts `insertFullError`, book
  contents unchanged.
- **Remove from a full book** — correctly removes slot 0 and shifts the
  remaining entries, verified at both ends of the shifted range.
- **Interleaved insert/remove** — alternating growth and shrinkage (rather
  than a monolithic fill-then-drain), confirming the book stays correctly
  sorted and that transitioning out of the full-book state doesn't leave any
  stale condition behind.
- **Drain to empty, then remove again** — re-confirms `removeEmptyError`
  fires correctly once the book is genuinely empty after real use, not just
  in its untouched startup state.

A known, low-risk testbench-authoring hazard worth documenting: setting a
`reg` input in the same simulation instant as the `@(posedge clk)` that's
meant to register it races against the DUT's own nonblocking assignments to
that same edge. Every input change in both testbenches is followed by a small
`#1` delay before being modified, specifically to avoid this.

## Status

- [x] `uart_rx.v` ported from `tang-nano-uart`
- [x] `message_rx.v` — message FSM, checksum validation, resync handling
- [x] `message_rx.v` testbench — all scenarios passing
- [x] `order_book_side.v` — sorted N=8 register-array book, parameterized bid/ask
- [x] `order_book_side.v` testbenches (bid + ask) — all scenarios passing
- [ ] Matching engine — consumes messages, drives both book instances
- [ ] TX-side execution reports
- [ ] Formal verification (SymbiYosys)

## Toolchain

- [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) (Yosys, nextpnr, Icarus Verilog)
- VS Code with the [Lushay Code](https://lushaylabs.com/) extension
- [VaporView](https://github.com/Lramseyer/vaporview) for waveform inspection
- CoolTerm / pyserial for serial-level testing