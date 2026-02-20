"""Correlation Tracker — monitors cross-asset correlations.

Tracks rolling correlations between:
- Individual stocks (cross-correlation matrix)
- Stocks vs sector ETFs
- Stocks vs VIX (inverse correlation as risk indicator)
- Stocks vs bond proxies (TLT)

Emits alerts when correlations break down or shift significantly,
which signals regime changes or diversification opportunities.
"""

import math
from collections import deque
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class CorrelationTracker(BaseAgent):
    """Monitors cross-asset correlations and emits shift alerts."""

    agent_id = "correlation_tracker"
    squadron = "golf"
    subscriptions = [SignalTypes.MARKET_SIGNAL]

    def __init__(
        self,
        bus: SignalBus,
        lookback: int = 30,
        shift_threshold: float = 0.3,
        benchmark_symbols: tuple[str, ...] = ("SPY", "QQQ", "VIX", "TLT"),
    ):
        super().__init__(bus)
        self._lookback = lookback
        self._shift_threshold = shift_threshold
        self._benchmark_symbols = set(benchmark_symbols)

        # Price return history per symbol
        self._returns: dict[str, deque[float]] = {}
        self._prev_prices: dict[str, float] = {}
        self._correlations: dict[tuple[str, str], float] = {}
        self._prev_correlations: dict[tuple[str, str], float] = {}
        self._shift_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type != SignalTypes.MARKET_SIGNAL:
            return

        payload = signal.payload
        symbol = payload.get("symbol", "")
        close = payload.get("close", 0.0)

        if not symbol or close <= 0:
            return

        # Compute return from previous price
        if symbol in self._prev_prices and self._prev_prices[symbol] > 0:
            ret = (close - self._prev_prices[symbol]) / self._prev_prices[symbol]
            if symbol not in self._returns:
                self._returns[symbol] = deque(maxlen=self._lookback)
            self._returns[symbol].append(ret)
        self._prev_prices[symbol] = close

        # Only recompute correlations periodically (when benchmark data updates)
        if symbol in self._benchmark_symbols:
            await self._update_correlations()

    async def _update_correlations(self) -> None:
        """Recompute correlations between tracked symbols and benchmarks."""
        symbols_with_data = [
            s for s, rets in self._returns.items() if len(rets) >= 10
        ]

        if len(symbols_with_data) < 2:
            return

        self._prev_correlations = dict(self._correlations)
        new_correlations: dict[tuple[str, str], float] = {}

        # Compute correlation of each non-benchmark with each benchmark
        benchmarks = [s for s in symbols_with_data if s in self._benchmark_symbols]
        non_benchmarks = [s for s in symbols_with_data if s not in self._benchmark_symbols]

        for sym in non_benchmarks:
            for bench in benchmarks:
                corr = self._pearson_correlation(
                    list(self._returns[sym]),
                    list(self._returns[bench]),
                )
                if corr is not None:
                    pair = (sym, bench)
                    new_correlations[pair] = corr

        self._correlations = new_correlations

        # Detect significant shifts
        for pair, new_corr in new_correlations.items():
            old_corr = self._prev_correlations.get(pair)
            if old_corr is not None:
                shift = abs(new_corr - old_corr)
                if shift >= self._shift_threshold:
                    self._shift_count += 1
                    await self.emit(
                        SignalTypes.CORRELATION_SHIFT,
                        payload={
                            "symbol": pair[0],
                            "benchmark": pair[1],
                            "old_correlation": round(old_corr, 3),
                            "new_correlation": round(new_corr, 3),
                            "shift": round(shift, 3),
                        },
                        priority=SignalPriority.NORMAL,
                    )

    @staticmethod
    def _pearson_correlation(x: list[float], y: list[float]) -> float | None:
        """Compute Pearson correlation between two return series."""
        n = min(len(x), len(y))
        if n < 5:
            return None

        # Align to same length (most recent)
        x = x[-n:]
        y = y[-n:]

        mean_x = sum(x) / n
        mean_y = sum(y) / n

        cov = sum((x[i] - mean_x) * (y[i] - mean_y) for i in range(n)) / n
        std_x = math.sqrt(sum((xi - mean_x) ** 2 for xi in x) / n)
        std_y = math.sqrt(sum((yi - mean_y) ** 2 for yi in y) / n)

        if std_x == 0 or std_y == 0:
            return None

        return cov / (std_x * std_y)

    def get_correlation(self, symbol: str, benchmark: str) -> float | None:
        return self._correlations.get((symbol, benchmark))

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "tracked_symbols": len(self._returns),
            "correlation_pairs": len(self._correlations),
            "correlation_shifts": self._shift_count,
        })
        return base
