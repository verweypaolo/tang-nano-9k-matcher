"""
book.py — host-side reconstruction of the FPGA's order book state.

This is not just a display cache: it's a from-scratch reimplementation of
order_book_side.v's sorted insert/consume logic and matching_engine.v's
match-walk, built so it can be compared against the FPGA's real behavior as
a verification tool, not only a UI convenience.

This works because the terminal is currently the sole source of orders:
every resting entry that could exist on the real FPGA book originated from
an order this terminal sent. A report only tells us the outcome of the
INCOMING order, never which resting order(s) it matched against — so this
module reconstructs that missing information by replaying the same
price-time-priority walk the FPGA itself performs, using our own copy of
the opposite side's book.

If reconstruction is ever internally inconsistent (e.g. a FILLED report
implies consuming more than the reconstructed book actually holds), that is
recorded as a Discrepancy rather than silently ignored. The whole point of
building this as a reference model is that disagreement is a signal worth
surfacing — it should never happen if both sides implement the same
matching semantics correctly, so if it does, something is wrong (in the
reconstruction, or genuinely in the FPGA) and is worth knowing about.
"""

from dataclasses import dataclass
from typing import List, Optional

from protocol import (
    SIDE_BUY,
    OUTCOME_FILLED,
    OUTCOME_RESTING,
    OUTCOME_REJECTED,
    OUTCOME_INVALID,
    SentOrder,
    Report,
)


@dataclass
class BookEntry:
    order_id: int
    price: int
    quantity: int
    seq: int  # local monotonic sequence, used only for tie-breaking


@dataclass
class Discrepancy:
    seq: int
    order_id: int
    description: str


class SideBook:
    """Mirrors order_book_side.v: a sorted list of resting entries, best
    price at index 0. descending=True for bids (highest price first),
    False for asks (lowest price first) — same DESCENDING convention as
    the RTL parameter of the same name."""

    def __init__(self, descending: bool):
        self.descending = descending
        self.entries: List[BookEntry] = []

    def _better(self, price_a: int, price_b: int) -> bool:
        """True if price_a should sort ahead of (be considered strictly
        better than) price_b — mirrors order_book_side.v's priority
        encoder comparison exactly, including that it's a strict
        inequality, so equal prices fall through and never displace an
        existing entry at the same price (arrival order decides instead,
        via insertion position)."""
        return price_a > price_b if self.descending else price_a < price_b

    def insert(self, order_id: int, price: int, quantity: int, seq: int):
        entry = BookEntry(order_id=order_id, price=price, quantity=quantity, seq=seq)
        index = len(self.entries)
        for i, existing in enumerate(self.entries):
            if self._better(price, existing.price):
                index = i
                break
        self.entries.insert(index, entry)

    def top(self) -> Optional[BookEntry]:
        return self.entries[0] if self.entries else None

    def crosses(self, price: int) -> bool:
        """Does an incoming order at `price` cross this side's top entry?
        Mirrors matching_engine.v's `crosses` wire. Only meaningful when
        called on the side OPPOSITE the incoming order's own side."""
        top = self.top()
        if top is None:
            return False
        return price >= top.price if self.descending else price <= top.price

    def consume(self, quantity: int) -> int:
        """Walk and consume up to `quantity` from the top entries,
        mirroring MATCH_LOOP: fully consume entries smaller than the
        remaining amount and continue to the next; reduce (not remove) an
        entry larger than the remaining amount; stop exactly on an exact
        match. Returns the leftover quantity that could NOT be satisfied
        (0 if fully satisfied, >0 if the book ran out before `quantity`
        was fully accounted for — the caller should treat any nonzero
        leftover as a discrepancy)."""
        remaining = quantity
        while remaining > 0:
            top = self.top()
            if top is None:
                break
            if top.quantity < remaining:
                remaining -= top.quantity
                self.entries.pop(0)
            elif top.quantity == remaining:
                self.entries.pop(0)
                remaining = 0
            else:
                top.quantity -= remaining
                remaining = 0
        return remaining

    def snapshot(self):
        """Plain list of dicts, convenient for JSON serialization to the UI."""
        return [
            {"order_id": e.order_id, "price": e.price, "quantity": e.quantity}
            for e in self.entries
        ]


class OrderBook:
    """Top-level reconstruction, mirroring matching_engine.v's routing:
    own-side inserts, opposite-side consumption, driven by (SentOrder,
    Report) pairs rather than raw bytes."""

    def __init__(self):
        self.bids = SideBook(descending=True)
        self.asks = SideBook(descending=False)
        self.discrepancies: List[Discrepancy] = []
        self._seq_counter = 0

    def _next_seq(self) -> int:
        self._seq_counter += 1
        return self._seq_counter

    def _sides_for(self, side: int):
        """Returns (own_book, opposite_book) for the given incoming side,
        matching matching_engine.v's routing: a BUY matches against asks
        and rests on bids; a SELL matches against bids and rests on asks."""
        if side == SIDE_BUY:
            return self.bids, self.asks
        return self.asks, self.bids

    def on_report(self, order: SentOrder, report: Report):
        """order is the originally-sent order this report corresponds to
        (looked up by order_id by the caller); report is the parsed
        Report received back from the FPGA."""
        own_book, opposite_book = self._sides_for(order.side)

        if report.outcome in (OUTCOME_REJECTED, OUTCOME_INVALID):
            return  # no book change either way

        if report.outcome == OUTCOME_FILLED:
            self._consume_and_check(opposite_book, order.quantity, order.order_id)
            return

        if report.outcome == OUTCOME_RESTING:
            # report.quantity is the REMAINING resting quantity; any
            # difference from the original was matched away before the
            # remainder rested, and must be walked off the opposite book
            # first, exactly as matching_engine.v's MATCH_LOOP would have
            # done before falling through to REST.
            matched_amount = order.quantity - report.quantity
            if matched_amount > 0:
                self._consume_and_check(opposite_book, matched_amount, order.order_id)
            own_book.insert(
                order_id=order.order_id,
                price=order.price,
                quantity=report.quantity,
                seq=self._next_seq(),
            )
            return

        self.discrepancies.append(Discrepancy(
            seq=self._next_seq(),
            order_id=order.order_id,
            description=f"unrecognized outcome code 0x{report.outcome:02X}",
        ))

    def _consume_and_check(self, opposite_book: SideBook, amount: int, order_id: int):
        leftover = opposite_book.consume(amount)
        if leftover > 0:
            self.discrepancies.append(Discrepancy(
                seq=self._next_seq(),
                order_id=order_id,
                description=(
                    f"report implied consuming {amount} units, but the "
                    f"reconstructed opposite book only had "
                    f"{amount - leftover} available ({leftover} unaccounted for)"
                ),
            ))

    def snapshot(self):
        return {
            "bids": self.bids.snapshot(),
            "asks": self.asks.snapshot(),
            "discrepancies": [
                {"order_id": d.order_id, "description": d.description}
                for d in self.discrepancies
            ],
        }