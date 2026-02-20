"""Tick Analyzer — tick-by-tick pattern analysis.

Analyzes individual trade ticks to detect:
- Momentum bursts (rapid succession of same-direction ticks)
- Exhaustion patterns (decelerating tick frequency at extremes)
- Block trades (large single-tick volume)
- Tick direction ratios (uptick vs downtick)

Useful for high-frequency entry timing.
"""

from collections import deque
import time
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class TickAnalyzer(BaseAgent):
    """Analyzes tick-by-tick patterns for microstructure signals."""

    agent_id = "tick_analyzer"
    squadron = "hotel"
    subscriptions = [SignalTypes.MARKET_SIGNAL]

    def __init__(
        self,
        bus: SignalBus,
        lookback: int = 100,
        momentum_threshold: int = 7,  # N consecutive same-direction ticks
        block_trade_multiplier: float = 5.0,
    ):
        super().__init__(bus)
        self._lookback = lookback
        self._momentum_threshold = momentum_threshold
        self._block_trade_multiplier = block_trade_multiplier

        # Per-symbol tick history
        self._ticks: dict[str, deque[dict]] = {}
        self._prev_price: dict[str, float] = {}
        self._pattern_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type != SignalTypes.MARKET_SIGNAL:
            return

        payload = signal.payload
        symbol = payload.get("symbol", "")
        price = payload.get("close", payload.get("last", 0.0))
        volume = payload.get("volume", payload.get("tick_volume", 0))

        if not symbol or price <= 0:
            return

        # Determine tick direction
        prev = self._prev_price.get(symbol, price)
        direction = 1 if price > prev else (-1 if price < prev else 0)
        self._prev_price[symbol] = price

        if symbol not in self._ticks:
            self._ticks[symbol] = deque(maxlen=self._lookback)

        tick = {
            "price": price,
            "volume": volume,
            "direction": direction,
            "ts": time.time(),
        }
        self._ticks[symbol].append(tick)

        # Check for patterns
        ticks = list(self._ticks[symbol])
        if len(ticks) < 5:
            return

        # Momentum burst detection
        momentum = self._detect_momentum_burst(ticks)
        if momentum:
            self._pattern_count += 1
            await self.emit(
                SignalTypes.TICK_PATTERN,
                payload={
                    "symbol": symbol,
                    "pattern": "momentum_burst",
                    "direction": "up" if momentum > 0 else "down",
                    "consecutive_ticks": abs(momentum),
                    "current_price": price,
                },
                priority=SignalPriority.NORMAL,
            )

        # Block trade detection
        if self._is_block_trade(ticks, volume):
            self._pattern_count += 1
            await self.emit(
                SignalTypes.TICK_PATTERN,
                payload={
                    "symbol": symbol,
                    "pattern": "block_trade",
                    "volume": volume,
                    "price": price,
                    "direction": "up" if direction > 0 else "down" if direction < 0 else "flat",
                },
                priority=SignalPriority.NORMAL,
            )

    def _detect_momentum_burst(self, ticks: list[dict]) -> int:
        """Detect consecutive same-direction ticks.

        Returns:
            Positive int for uptick burst, negative for downtick, 0 for none.
        """
        if len(ticks) < self._momentum_threshold:
            return 0

        recent = ticks[-self._momentum_threshold:]
        directions = [t["direction"] for t in recent]

        if all(d == 1 for d in directions):
            return self._momentum_threshold
        elif all(d == -1 for d in directions):
            return -self._momentum_threshold

        return 0

    def _is_block_trade(self, ticks: list[dict], current_volume: int) -> bool:
        """Detect if current tick volume is a block trade."""
        if len(ticks) < 10 or current_volume <= 0:
            return False

        avg_volume = sum(t["volume"] for t in ticks[:-1] if t["volume"] > 0)
        count = sum(1 for t in ticks[:-1] if t["volume"] > 0)
        if count == 0:
            return False

        avg_volume /= count
        return current_volume >= avg_volume * self._block_trade_multiplier

    def get_tick_ratio(self, symbol: str) -> dict | None:
        """Get uptick/downtick ratio for a symbol."""
        ticks = self._ticks.get(symbol)
        if not ticks:
            return None

        ups = sum(1 for t in ticks if t["direction"] == 1)
        downs = sum(1 for t in ticks if t["direction"] == -1)
        total = ups + downs
        return {
            "upticks": ups,
            "downticks": downs,
            "ratio": round(ups / total, 3) if total > 0 else 0.5,
        }

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "tracked_symbols": len(self._ticks),
            "patterns_detected": self._pattern_count,
            "momentum_threshold": self._momentum_threshold,
        })
        return base
