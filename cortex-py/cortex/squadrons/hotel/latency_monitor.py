"""Latency Monitor — monitors execution and data feed latency.

Tracks:
- Order submission to fill latency
- Market data tick-to-processing latency
- WebSocket round-trip time
- Running percentiles (p50, p95, p99)

Emits alerts when latency exceeds thresholds, signaling
potential infrastructure issues or market conditions.
"""

import time
from collections import deque
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class LatencyMonitor(BaseAgent):
    """Monitors execution latency and emits alerts on degradation."""

    agent_id = "latency_monitor"
    squadron = "hotel"
    subscriptions = [
        SignalTypes.ORDER_SUBMITTED,
        SignalTypes.ORDER_FILLED,
        SignalTypes.MARKET_SIGNAL,
    ]

    def __init__(
        self,
        bus: SignalBus,
        lookback: int = 200,
        alert_threshold_ms: float = 500.0,
        critical_threshold_ms: float = 2000.0,
    ):
        super().__init__(bus)
        self._lookback = lookback
        self._alert_threshold_ms = alert_threshold_ms
        self._critical_threshold_ms = critical_threshold_ms

        # Latency measurements
        self._order_latencies: deque[float] = deque(maxlen=lookback)
        self._data_latencies: deque[float] = deque(maxlen=lookback)
        self._pending_orders: dict[str, float] = {}  # order_id -> submit_time
        self._alert_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        payload = signal.payload

        if signal.signal_type == SignalTypes.ORDER_SUBMITTED:
            order_id = payload.get("order_id", "")
            if order_id:
                self._pending_orders[order_id] = time.time()

        elif signal.signal_type == SignalTypes.ORDER_FILLED:
            order_id = payload.get("order_id", "")
            submit_time = self._pending_orders.pop(order_id, None)
            if submit_time is not None:
                latency_ms = (time.time() - submit_time) * 1000
                self._order_latencies.append(latency_ms)
                await self._check_latency(latency_ms, "order_execution")

        elif signal.signal_type == SignalTypes.MARKET_SIGNAL:
            # Measure data processing latency from signal timestamp
            data_ts = payload.get("timestamp", 0.0)
            if data_ts > 0:
                latency_ms = (time.time() - data_ts) * 1000
                if 0 < latency_ms < 60000:  # Ignore unreasonable values
                    self._data_latencies.append(latency_ms)

    async def _check_latency(self, latency_ms: float, category: str) -> None:
        """Check if latency exceeds thresholds and emit alerts."""
        if latency_ms >= self._critical_threshold_ms:
            self._alert_count += 1
            await self.emit(
                SignalTypes.LATENCY_ALERT,
                payload={
                    "category": category,
                    "latency_ms": round(latency_ms, 1),
                    "severity": "critical",
                    "p50": round(self._percentile(self._order_latencies, 50), 1),
                    "p95": round(self._percentile(self._order_latencies, 95), 1),
                    "p99": round(self._percentile(self._order_latencies, 99), 1),
                },
                priority=SignalPriority.HIGH,
            )
        elif latency_ms >= self._alert_threshold_ms:
            self._alert_count += 1
            await self.emit(
                SignalTypes.LATENCY_ALERT,
                payload={
                    "category": category,
                    "latency_ms": round(latency_ms, 1),
                    "severity": "warning",
                    "p50": round(self._percentile(self._order_latencies, 50), 1),
                    "p95": round(self._percentile(self._order_latencies, 95), 1),
                },
                priority=SignalPriority.NORMAL,
            )

    @staticmethod
    def _percentile(data: deque[float], pct: int) -> float:
        """Compute percentile from a deque of values."""
        if not data:
            return 0.0
        sorted_data = sorted(data)
        idx = int(len(sorted_data) * pct / 100)
        idx = min(idx, len(sorted_data) - 1)
        return sorted_data[idx]

    @property
    def order_p50(self) -> float:
        return self._percentile(self._order_latencies, 50)

    @property
    def order_p95(self) -> float:
        return self._percentile(self._order_latencies, 95)

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "order_latency_p50_ms": round(self._percentile(self._order_latencies, 50), 1),
            "order_latency_p95_ms": round(self._percentile(self._order_latencies, 95), 1),
            "data_latency_p50_ms": round(self._percentile(self._data_latencies, 50), 1),
            "pending_orders": len(self._pending_orders),
            "alert_count": self._alert_count,
            "samples": len(self._order_latencies),
        })
        return base
