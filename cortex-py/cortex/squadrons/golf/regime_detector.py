"""Regime Detector — detects market regime changes using volatility and trend analysis.

Tracks four market regimes:
- trending: Strong directional movement with low pullbacks
- mean_reverting: Range-bound with frequent reversals
- volatile: High ATR and wide swings
- quiet: Low volatility, narrow ranges

Uses a rolling window of market data to classify regime and emits
regime change signals when transitions occur.
"""

import math
from collections import deque
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class RegimeDetector(BaseAgent):
    """Detects market regime changes using volatility and trend analysis."""

    agent_id = "regime_detector"
    squadron = "golf"
    subscriptions = [SignalTypes.MARKET_SIGNAL]

    REGIME_TRENDING = "trending"
    REGIME_MEAN_REVERTING = "mean_reverting"
    REGIME_VOLATILE = "volatile"
    REGIME_QUIET = "quiet"

    def __init__(
        self,
        bus: SignalBus,
        lookback: int = 50,
        volatility_high_threshold: float = 2.0,
        volatility_low_threshold: float = 0.5,
        trend_strength_threshold: float = 0.6,
    ):
        super().__init__(bus)
        self._lookback = lookback
        self._volatility_high = volatility_high_threshold
        self._volatility_low = volatility_low_threshold
        self._trend_threshold = trend_strength_threshold

        # Per-symbol price history and regime tracking
        self._prices: dict[str, deque[float]] = {}
        self._current_regime: dict[str, str] = {}
        self._regime_duration: dict[str, int] = {}
        self._regime_change_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type != SignalTypes.MARKET_SIGNAL:
            return

        payload = signal.payload
        symbol = payload.get("symbol", "")
        close = payload.get("close", 0.0)

        if not symbol or close <= 0:
            return

        if symbol not in self._prices:
            self._prices[symbol] = deque(maxlen=self._lookback)
            self._current_regime[symbol] = self.REGIME_QUIET
            self._regime_duration[symbol] = 0

        self._prices[symbol].append(close)

        if len(self._prices[symbol]) < 20:
            return

        new_regime = self._classify_regime(list(self._prices[symbol]))
        old_regime = self._current_regime[symbol]

        if new_regime != old_regime:
            self._current_regime[symbol] = new_regime
            self._regime_duration[symbol] = 1
            self._regime_change_count += 1

            log.info(
                "regime.change",
                symbol=symbol,
                old=old_regime,
                new=new_regime,
            )

            await self.emit(
                SignalTypes.REGIME_CHANGE,
                payload={
                    "symbol": symbol,
                    "old_regime": old_regime,
                    "new_regime": new_regime,
                    "confidence": self._regime_confidence(list(self._prices[symbol]), new_regime),
                },
                priority=SignalPriority.NORMAL,
            )
        else:
            self._regime_duration[symbol] += 1

    def _classify_regime(self, prices: list[float]) -> str:
        """Classify the current market regime from price history."""
        returns = [
            (prices[i] - prices[i - 1]) / prices[i - 1]
            for i in range(1, len(prices))
        ]

        if not returns:
            return self.REGIME_QUIET

        # Volatility: standard deviation of returns (annualized proxy)
        mean_return = sum(returns) / len(returns)
        variance = sum((r - mean_return) ** 2 for r in returns) / len(returns)
        volatility = math.sqrt(variance) * math.sqrt(252) if variance > 0 else 0.0

        # Trend strength: ratio of net move to total absolute moves
        net_move = abs(prices[-1] - prices[0])
        total_move = sum(abs(prices[i] - prices[i - 1]) for i in range(1, len(prices)))
        trend_strength = net_move / total_move if total_move > 0 else 0.0

        # Classification logic
        if volatility > self._volatility_high:
            return self.REGIME_VOLATILE
        elif volatility < self._volatility_low:
            return self.REGIME_QUIET
        elif trend_strength > self._trend_threshold:
            return self.REGIME_TRENDING
        else:
            return self.REGIME_MEAN_REVERTING

    def _regime_confidence(self, prices: list[float], regime: str) -> float:
        """Estimate confidence in the regime classification."""
        if len(prices) < 10:
            return 0.3

        # More data = more confidence, capped at 0.9
        data_factor = min(len(prices) / self._lookback, 1.0)
        base_confidence = 0.5 + 0.4 * data_factor
        return round(base_confidence, 2)

    def get_regime(self, symbol: str) -> str:
        """Get the current regime for a symbol."""
        return self._current_regime.get(symbol, self.REGIME_QUIET)

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "tracked_symbols": len(self._prices),
            "regime_changes": self._regime_change_count,
            "current_regimes": dict(self._current_regime),
        })
        return base
