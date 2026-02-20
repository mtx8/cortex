"""Spread Analyzer — monitors bid-ask spreads for execution quality signals.

Tracks:
- Current spread as percentage of mid-price
- Rolling average spread
- Spread widening/narrowing trends
- Unusual spread events (market stress indicator)

Wide spreads signal low liquidity or high uncertainty.
Emits alerts when spreads exceed thresholds.
"""

from collections import deque
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class SpreadAnalyzer(BaseAgent):
    """Monitors bid-ask spreads and emits alerts on anomalies."""

    agent_id = "spread_analyzer"
    squadron = "hotel"
    subscriptions = [SignalTypes.MARKET_SIGNAL]

    def __init__(
        self,
        bus: SignalBus,
        lookback: int = 50,
        wide_spread_threshold: float = 0.005,  # 0.5% of mid-price
        alert_multiplier: float = 2.0,
    ):
        super().__init__(bus)
        self._lookback = lookback
        self._wide_spread_threshold = wide_spread_threshold
        self._alert_multiplier = alert_multiplier

        # Per-symbol spread history
        self._spreads: dict[str, deque[float]] = {}
        self._last_spread: dict[str, float] = {}
        self._alert_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type != SignalTypes.MARKET_SIGNAL:
            return

        payload = signal.payload
        symbol = payload.get("symbol", "")
        bid = payload.get("bid", 0.0)
        ask = payload.get("ask", 0.0)

        if not symbol or bid <= 0 or ask <= 0 or ask <= bid:
            return

        mid = (bid + ask) / 2.0
        spread_pct = (ask - bid) / mid

        if symbol not in self._spreads:
            self._spreads[symbol] = deque(maxlen=self._lookback)

        self._spreads[symbol].append(spread_pct)
        self._last_spread[symbol] = spread_pct

        # Check for anomalous spread
        avg_spread = self._avg_spread(symbol)
        if avg_spread > 0 and spread_pct > avg_spread * self._alert_multiplier:
            self._alert_count += 1
            await self.emit(
                SignalTypes.SPREAD_ALERT,
                payload={
                    "symbol": symbol,
                    "spread_pct": round(spread_pct * 100, 4),
                    "avg_spread_pct": round(avg_spread * 100, 4),
                    "multiplier": round(spread_pct / avg_spread, 2),
                    "bid": bid,
                    "ask": ask,
                    "severity": "high" if spread_pct > self._wide_spread_threshold else "moderate",
                },
                priority=SignalPriority.NORMAL,
            )

    def _avg_spread(self, symbol: str) -> float:
        spreads = self._spreads.get(symbol)
        if not spreads or len(spreads) < 3:
            return 0.0
        return sum(spreads) / len(spreads)

    def get_spread(self, symbol: str) -> float | None:
        return self._last_spread.get(symbol)

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "tracked_symbols": len(self._spreads),
            "alert_count": self._alert_count,
        })
        return base
