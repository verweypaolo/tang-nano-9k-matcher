"""
stats.py — session-level counters and derived metrics.

Deliberately has no knowledge of order/report correlation (which order_id
maps to which SentOrder) — that lookup lives in app.py, which owns the
pending-orders table and feeds events here and to book.py from the same
source, rather than each module keeping its own independent copy.
"""

import time
from dataclasses import dataclass, field
from typing import Dict

from protocol import (
    OUTCOME_FILLED,
    OUTCOME_RESTING,
    OUTCOME_REJECTED,
    OUTCOME_INVALID,
)

OUTCOME_LABELS = {
    OUTCOME_FILLED: "filled",
    OUTCOME_RESTING: "resting",
    OUTCOME_REJECTED: "rejected",
    OUTCOME_INVALID: "invalid",
}


class Stats:
    def __init__(self):
        self.start_time = time.monotonic()
        self.orders_sent = 0
        self.reports_received = 0
        self.outcome_counts: Dict[str, int] = {label: 0 for label in OUTCOME_LABELS.values()}
        self._pending_send_times: Dict[int, float] = {}  # order_id -> send timestamp
        self._latencies_ms = []  # completed round-trip latencies, for an average/last-N view

    def on_order_sent(self, order_id: int):
        self.orders_sent += 1
        self._pending_send_times[order_id] = time.monotonic()

    def on_report_received(self, order_id: int, outcome: int):
        self.reports_received += 1

        label = OUTCOME_LABELS.get(outcome)
        if label is not None:
            self.outcome_counts[label] += 1

        sent_at = self._pending_send_times.pop(order_id, None)
        if sent_at is not None:
            latency_ms = (time.monotonic() - sent_at) * 1000
            self._latencies_ms.append(latency_ms)

    @property
    def outstanding_count(self) -> int:
        """Orders sent with no report yet received — a persistently
        nonzero value here is itself worth surfacing, given reports were
        observed to occasionally not arrive during hardware bring-up."""
        return len(self._pending_send_times)

    @property
    def running_time_seconds(self) -> float:
        return time.monotonic() - self.start_time

    @property
    def average_latency_ms(self) -> float:
        if not self._latencies_ms:
            return 0.0
        return sum(self._latencies_ms) / len(self._latencies_ms)

    @property
    def last_latency_ms(self) -> float:
        return self._latencies_ms[-1] if self._latencies_ms else 0.0

    def snapshot(self):
        return {
            "running_time_seconds": round(self.running_time_seconds, 1),
            "orders_sent": self.orders_sent,
            "reports_received": self.reports_received,
            "outstanding": self.outstanding_count,
            "outcome_counts": dict(self.outcome_counts),
            "average_latency_ms": round(self.average_latency_ms, 1),
            "last_latency_ms": round(self.last_latency_ms, 1),
        }