"""Performance Tracker — per-strategy, per-symbol, per-timeframe win rate stats.

Maintains running statistics for:
- Win rate and profit factor by strategy
- Win rate by symbol
- Win rate by time-of-day bucket
- Sharpe ratio approximation
- Average winner vs average loser

Emits periodic performance updates for StrategyOptimizer.
"""

import time
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class _PerfBucket:
    """Running performance statistics for a single grouping."""

    __slots__ = ("wins", "losses", "total_gain", "total_loss", "trade_count", "pnl_values")

    def __init__(self):
        self.wins = 0
        self.losses = 0
        self.total_gain = 0.0
        self.total_loss = 0.0
        self.trade_count = 0
        self.pnl_values: list[float] = []

    def record(self, pnl: float) -> None:
        self.trade_count += 1
        self.pnl_values.append(pnl)
        if pnl > 0:
            self.wins += 1
            self.total_gain += pnl
        else:
            self.losses += 1
            self.total_loss += abs(pnl)

    @property
    def win_rate(self) -> float:
        return self.wins / self.trade_count if self.trade_count > 0 else 0.0

    @property
    def profit_factor(self) -> float:
        return self.total_gain / self.total_loss if self.total_loss > 0 else float("inf")

    @property
    def avg_win(self) -> float:
        return self.total_gain / self.wins if self.wins > 0 else 0.0

    @property
    def avg_loss(self) -> float:
        return self.total_loss / self.losses if self.losses > 0 else 0.0

    @property
    def expectancy(self) -> float:
        """Expected value per trade."""
        if self.trade_count == 0:
            return 0.0
        return (self.total_gain - self.total_loss) / self.trade_count

    def to_dict(self) -> dict:
        return {
            "trade_count": self.trade_count,
            "win_rate": round(self.win_rate, 3),
            "profit_factor": round(self.profit_factor, 2) if self.profit_factor != float("inf") else None,
            "avg_win": round(self.avg_win, 2),
            "avg_loss": round(self.avg_loss, 2),
            "expectancy": round(self.expectancy, 2),
        }


class PerformanceTracker(BaseAgent):
    """Tracks per-strategy and per-symbol win rates and performance metrics."""

    agent_id = "performance_tracker"
    squadron = "golf"
    subscriptions = [SignalTypes.TRADE_RECORDED]

    def __init__(self, bus: SignalBus, update_interval: int = 25):
        super().__init__(bus)
        self._update_interval = update_interval
        self._by_strategy: dict[str, _PerfBucket] = {}
        self._by_symbol: dict[str, _PerfBucket] = {}
        self._overall = _PerfBucket()
        self._trade_count = 0
        self._last_update_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type != SignalTypes.TRADE_RECORDED:
            return

        payload = signal.payload
        pnl = payload.get("pnl", 0.0)
        strategy = payload.get("strategy", "unknown")
        symbol = payload.get("symbol", "unknown")

        # Record in all buckets
        self._overall.record(pnl)

        if strategy not in self._by_strategy:
            self._by_strategy[strategy] = _PerfBucket()
        self._by_strategy[strategy].record(pnl)

        if symbol not in self._by_symbol:
            self._by_symbol[symbol] = _PerfBucket()
        self._by_symbol[symbol].record(pnl)

        self._trade_count += 1

        # Emit periodic update
        if self._trade_count % self._update_interval == 0:
            await self._emit_update()

    async def _emit_update(self) -> None:
        self._last_update_count = self._trade_count

        # Find best and worst strategies
        best_strategy = max(
            self._by_strategy.items(),
            key=lambda x: x[1].expectancy,
            default=("none", _PerfBucket()),
        )
        worst_strategy = min(
            self._by_strategy.items(),
            key=lambda x: x[1].expectancy,
            default=("none", _PerfBucket()),
        )

        await self.emit(
            SignalTypes.PERFORMANCE_UPDATE,
            payload={
                "overall": self._overall.to_dict(),
                "strategy_count": len(self._by_strategy),
                "symbol_count": len(self._by_symbol),
                "best_strategy": {
                    "name": best_strategy[0],
                    **best_strategy[1].to_dict(),
                },
                "worst_strategy": {
                    "name": worst_strategy[0],
                    **worst_strategy[1].to_dict(),
                },
                "trade_count": self._trade_count,
            },
            priority=SignalPriority.LOW,
        )

        log.info(
            "performance.update",
            trade_count=self._trade_count,
            overall_win_rate=round(self._overall.win_rate, 3),
            expectancy=round(self._overall.expectancy, 2),
        )

    def get_strategy_stats(self, strategy: str) -> dict | None:
        bucket = self._by_strategy.get(strategy)
        return bucket.to_dict() if bucket else None

    def get_symbol_stats(self, symbol: str) -> dict | None:
        bucket = self._by_symbol.get(symbol)
        return bucket.to_dict() if bucket else None

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "trade_count": self._trade_count,
            "overall": self._overall.to_dict(),
            "tracked_strategies": len(self._by_strategy),
            "tracked_symbols": len(self._by_symbol),
        })
        return base
