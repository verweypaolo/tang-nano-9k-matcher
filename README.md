# FPGA Order Matching Engine over UART

A UART-based order matching engine implemented in hand-coded Verilog for the
[Sipeed Tang Nano 9K](https://wiki.sipeed.com/hardware/en/tang/Tang-Nano-9K/Nano-9K.html)
(Gowin GW1NR-9C, 27 MHz).

This project builds an application layer on top of a separate, standalone UART
implementation ([tang-nano-9k-uart](https://github.com/verweypaolo/tang-nano-9k-uart)).
Where that repo is a showcase of the UART protocol itself (fractional baud
generation, parity, framing-error detection), this repo is a showcase of
*using* UART as a transport for something more interesting: a reactive
market-matching engine that receives buy/sell orders as multi-byte messages,
matches them against a resting order book — including partial fills — and
reports back the outcome over the same serial link, all inside FPGA fabric,
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
byte-level `byteReady`/`txByteConsumed` handshakes above):

```
uart_rx.v          bits -> bytes         (byteReady, dataIn, uartFrameError, parityError)
message_rx.v        bytes -> messages    (messageReady, sentinelError, timeOutError,
                                          checksumError, decoded order fields)
order_book_side.v   sorted resting orders per side (insert/remove/reduce, N=8,
                                          parameterized by sort direction for bid vs. ask)
matching_engine.v   messages + book state -> book updates / executions -> reports
                                          (orderFilled, orderResting, orderRejected,
                                          wrongMsgType, wrongMsgSide)
message_tx.v         report fields -> bytes   (sendMessageValid -> messageSent)
uart_tx.v           bytes -> bits         (txByteValid/txByteData -> txByteConsumed)
```

- **`uart_rx.v`** — RX-only port of the UART core from `tang-nano-9k-uart`,
  producing one `byteReady` pulse per received byte.
- **`message_rx.v`** *(complete, tested)* — a state machine that consumes
  UART bytes and assembles them into a fixed-length order message, validating
  framing and checksum before asserting `messageReady`.
- **`order_book_side.v`** *(complete, tested)* — maintains a sorted,
  fixed-depth (N=8) list of resting orders for one side of the book (bid or
  ask, selected via a `DESCENDING` parameter), implemented as combinationally
  shifted register arrays rather than BRAM, so that finding the best price is
  a direct read rather than a search. Supports insert, remove (of the top
  order), and reduce (partial consumption of the top order's quantity, for
  partial fills). Two instances of this module (one per side) are
  instantiated by the matching engine.
- **`matching_engine.v`** *(complete, tested, fully wired end-to-end)* —
  instantiates `message_rx`, `message_tx`, and both `order_book_side`
  instances. On each `messageReady` pulse, routes the order to the correct
  side, walks the opposite side's book to resolve full or partial fills
  against one or more resting orders, rests any unfilled remainder as a new
  order (or rejects it if that side's book is full), and transmits an
  execution report for every outcome via `message_tx` — including malformed
  messages, which are reported back rather than silently dropped.
- **`uart_tx.v`** *(complete, tested)* — a byte-mover for the transmit
  direction, the mirror image of `uart_rx.v`: accepts one byte at a time via
  a `txByteValid`/`txByteData`/`txByteConsumed` handshake and serializes it
  onto the line (start bit, 8 data bits, parity, stop bit), using the same
  fractional-baud accumulator as the RX side. Ported down from an earlier,
  more general showcase UART project.
- **`message_tx.v`** *(complete, tested)* — the transmit-side mirror of
  `message_rx.v`: given an order ID, outcome, price, and quantity, latches
  them on a `sendMessageValid` pulse, computes a checksum, and streams the
  resulting fixed-length report out through its own `uart_tx` instance one
  byte at a time, asserting `messageSent` once the full frame has gone out.

### Why registers instead of BRAM for the order book

The Tang Nano 9K's block RAM (BSRAM) only exposes one or two addressable
ports per cycle, which would force "find the best price" into a serial
search. Since matching latency is the entire point of doing this on an FPGA,
`order_book_side.v` instead stores its N=8 slots as plain registers and
computes insertion position via a fully parallel, combinational priority
encoder, and shifts on insert/remove in a single clock cycle — trading some
LUT/flip-flop budget for a book where "what is the best price" is always a
direct read, never a scan.

### Resource utilization

Synthesized for the GW1NR-9C via Yosys (`synth_gowin`), the complete pipeline
— UART RX, message framing, both order book sides with partial-fill support,
the full matching FSM, and TX-side execution reporting — uses:

| Resource   | Used  | Available | Utilization |
|------------|------:|----------:|-------------:|
| Flip-flops |   966 |     6,480 |        ~15% |
| LUTs       | 3,838 |     8,640 |        ~44% |

Comfortable headroom remains for future extensions (e.g. a deeper book, a
`CANCEL` message type, or a multi-entry TX report queue).

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

Three operations are supported, each triggered by an edge-detected pulse:

- **Insert** — combinationally finds the correct sorted position and shifts
  existing entries to make room, in a single clock cycle.
- **Remove** — removes the top (slot 0) order and shifts the remaining
  entries up to close the gap, also in a single cycle.
- **Reduce** — decrements the top order's quantity in place, without
  shifting or invalidating it, to support partial fills. An exact-match
  reduce (`reduceAmount == quantity`) is treated as a usage error rather than
  silently handled: full consumption of the top order is `remove`'s
  responsibility, not `reduce`'s, so a caller sending the two operations
  should never be able to blur that line.

Five distinct error conditions are exposed, kept separate for the same
debuggability reasons as `message_rx.v`'s error signals:

- **`insertFullError`** — an insert was attempted while all N slots were occupied.
- **`removeEmptyError`** — a remove was attempted while the book was empty.
- **`reduceEmptyError`** — a reduce was attempted while the book was empty.
- **`overReduceError`** — a reduce amount was greater than or equal to the
  top order's current quantity.
- **`simultaneousOpError`** — more than one of insert/remove/reduce were
  requested in the same cycle; no operation is performed, since silently
  picking a winner could mask a bug in whatever module is driving this one.

Any successful operation clears all five error flags; a failed operation only
asserts its own specific flag, leaving the others untouched.

## Matching Engine Design

`matching_engine.v` ties the whole pipeline together. It instantiates
`message_rx`, `message_tx`, and one `order_book_side` instance per side, and
drives a state machine off `message_rx`'s `messageReady` pulse:

1. **Validate** the message type and side; malformed values are flagged
   (`wrongMsgType`, `wrongMsgSide`) and reported back as an `RPT_INVALID`
   outcome rather than acted on.
2. **Walk the opposite side's book**, comparing the incoming order's
   remaining quantity against each crossing resting order's quantity in turn:
   - if the resting order is smaller, it's fully consumed (`remove`) and the
     walk continues against the new top of book;
   - if it's an exact match, it's fully consumed and the incoming order is
     completely filled;
   - if it's larger, it's partially consumed (`reduce`) and the incoming
     order is completely filled.
3. **Rest** any unfilled remainder as a new order on the incoming order's own
   side, or **reject** it if that side's book is full.
4. **Report**: every resolved order — filled, resting, rejected, or invalid —
   triggers an execution report via `message_tx`. If a report can't be sent
   immediately (a previous report is still transmitting), it's latched into a
   single-entry pending buffer and automatically drained the instant
   `message_tx` frees up, rather than being dropped.

The walk is bounded by the book's fixed depth (`matchLoopOverrunError` is a
defensive flag that should be structurally unreachable in normal operation,
since `order_book_side` never holds more than N resting orders — guarding
against a loop that somehow never terminates).

Because `order_book_side` needs a full clock cycle to detect an
insert/remove/reduce pulse's edge and update its own error/state outputs,
the matching FSM includes explicit one-cycle wait states between issuing an
operation and reading back its result.

Three outcome flags report the result of each processed message internally:
`orderFilled`, `orderResting`, `orderRejected`.

## TX Reporting Design

`message_tx.v` is the transmit-side mirror of `message_rx.v`, producing a
fixed-length, 10-byte execution report:

| Field      | Bytes | Description                                      |
|------------|:-----:|---------------------------------------------------|
| Sentinel   |   1   | Same `0xAA` framing convention as the inbound format |
| Msg Type   |   1   | Report-type identifier                            |
| Order ID   |   2   | Which original order this report is about         |
| Outcome    |   1   | Filled / Resting / Rejected / Invalid (small enum, extensible) |
| Price      |   2   | Echoed back so a downstream consumer needn't track it separately |
| Quantity   |   2   | Meaning depends on outcome — see below             |
| Checksum   |   1   | Same XOR convention as the inbound format          |

`Quantity`'s meaning is outcome-dependent by design: for a fill, it's the
(always-complete, given this project's current matching semantics) filled
quantity; for a rest, it's the *remaining* resting quantity, which may be
smaller than the original order if part of it matched before the remainder
rested; for a reject or an invalid message, it's the original incoming
quantity, since nothing happened. This distinction — remaining vs. original —
matters for a downstream consumer (a planned Python dashboard, driven over
the same serial link) that wants to track how much of an order is actually
still live in the book.

Unlike `message_rx.v`, which must incrementally accumulate a checksum as
untrusted bytes arrive one at a time, `message_tx.v` already has every field
available the instant a send is requested — its checksum is a single
combinational expression over the latched field registers, computed once and
stable for the whole transmission.

`message_tx.v` itself exposes a simple busy/reject contract: a
`sendMessageValid` pulse received while a previous report is still
transmitting asserts `sendWhileBusyError` and is otherwise ignored. The
one-entry pending buffer that smooths this out for realistic back-to-back
order flow lives one layer up, in `matching_engine.v` (see above) — a small,
targeted addition rather than a full multi-entry queue, since RX and TX
frames are the same length at the same baud rate and only ever overlap by
one report deep under sustained load in practice.

## Testing

### `message_rx.v`

`message_rx_tb.v` is a self-checking Icarus Verilog testbench (module `test`)
that instantiates `message_rx` (which in turn instantiates `uart_rx`) and
drives it bit-serially via a `send_byte` task, built up into full order frames
via `send_order`.

Coverage, all passing: valid order decode, bad sentinel, bad checksum,
timeout, resync after a stray garbage byte, and back-to-back valid messages
with no gap (confirming per-message state is fully reset between messages).

### `order_book_side.v`

Two testbenches — `order_book_side_bid_tb.v` (`DESCENDING=1`) and
`order_book_side_ask_tb.v` (`DESCENDING=0`) — drive the module's
insert/remove/reduce pulses directly and build up a shared scenario
sequentially, so later tests also implicitly verify state carries over
correctly between operations.

Coverage, all passing: simultaneous-operation rejection, insert/remove on
empty and full books, mid-array insertion forcing a genuine shift,
duplicate-price time-priority ordering, interleaved insert/remove, partial
reduce, over-reduce and exact-match-reduce boundary rejection, and state
persistence across unrelated operations.

### `matching_engine.v`

`matching_engine_tb.v` drives the engine at its real, external interface —
raw UART bytes via `send_order` — and, for TX verification, instantiates a
second `message_rx`/`uart_rx` pair as a "known-good reference receiver"
wired to the engine's serial output, decoding and checking every execution
report the DUT actually transmits.

Coverage, all passing:

- The four single-order outcome paths (rest, exact-match fill, match-then-
  rest, reduce-only fill) and reject-on-full-book, each verified against
  both the outcome flags/book contents and the corresponding execution
  report — including the outcome-dependent quantity semantics (remaining vs.
  original) described above.
- `wrongMsgType` / `wrongMsgSide`, confirming both the correct drop behavior
  and the `RPT_INVALID` report sent back for each.
- A full multi-iteration match walk draining an entire 8-entry book in one
  incoming order.
- `matchLoopOverrunError`, an structurally-unreachable defensive guard,
  verified via `force`/`release` on the internal loop counter.
- Sequence-number correctness across resolved and dropped messages.
- Back-to-back and back-to-back-to-back messages with zero gaps, confirming
  `matching_engine`'s one-entry pending report buffer correctly holds and
  drains overlapping reports without loss, including the case where three
  reports genuinely do overlap under sustained zero-gap load.

## Status

- [x] `uart_rx.v` ported from `tang-nano-9k-uart`
- [x] `message_rx.v` — message FSM, checksum validation, resync handling
- [x] `message_rx.v` testbench — all scenarios passing
- [x] `order_book_side.v` — sorted N=8 register-array book, parameterized
      bid/ask, insert/remove/reduce
- [x] `order_book_side.v` testbenches (bid + ask) — all scenarios passing,
      including partial-fill (reduce) support
- [x] `matching_engine.v` — full/partial-fill matching FSM
- [x] `uart_tx.v` — ported and adapted TX byte-mover
- [x] `message_tx.v` — TX-side execution report framing
- [x] `message_tx.v` testbench — all scenarios passing
- [x] `matching_engine.v` wired end-to-end with TX reporting, including a
      pending-report buffer for overlapping back-to-back orders
- [x] `matching_engine.v` testbench — all scenarios passing, including full
      round-trip TX report verification
- [ ] Python dashboard (order entry + live report display over serial)
- [ ] Formal verification (SymbiYosys)

## Toolchain

- [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build) (Yosys, nextpnr, Icarus Verilog)
- VS Code with the [Lushay Code](https://lushaylabs.com/) extension
- [VaporView](https://github.com/Lramseyer/vaporview) for waveform inspection
- CoolTerm / pyserial for serial-level testing