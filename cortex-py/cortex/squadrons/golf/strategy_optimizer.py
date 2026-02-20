"""Strategy Optimizer — adjusts strategy parameters based on learned patterns.

Consumes output from PatternLearner and adjusts:
- Position sizing multipliers per strategy
- Entry confidence thresholds
- Stop-loss widths
- Maximum concurrent positions per strategy

Changes are conservative: small incremental adjustments to avoid overfitting.
"""

import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class StrategyOptimizer(BaseAgent):
    """Adjusts strategy params based on pattern learning output."""

    agent_id = "strategy_optimizer"
    squadron = "golf"
    subscriptions = [SignalTypes.PATTERN_LEARNED, SignalTypes.PERFORMANCE_UPDATE]

    def __init__(
        self,
        bus: SignalBus,
        max_adjustment_pct: float = 10.0,
        learning_rate: float = 0.05,
    ):
        super().__init__(bus)
        self._max_adjustment_pct = max_adjustment_pct
        self._learning_rate = learning_rate
        self._strategy_params: dict[str, dict] = {}
        self._optimization_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type == SignalTypes.PATTERN_LEARNED:
            await self._optimize_from_patterns(signal.payload)
        elif signal.signal_type == SignalTypes.PERFORMANCE_UPDATE:
            self._update_strategy_metrics(signal.payload)

    async def _optimize_from_patterns(self, payload: dict) -> None:
        patterns = payload.get("patterns", [])
        if not patterns:
            return

        adjustments: list[dict] = []

        for pattern in patterns:
            pattern_type = pattern.get("type", "")
            key = pattern.get("key", "")
            win_rate = pattern.get("win_rate", 0.5)
            sample_size = pattern.get("sample_size", 0)

            if pattern_type == "strategy_edge":
                adj = self._compute_strategy_adjustment(key, win_rate, sample_size)
                if adj:
                    adjustments.append(adj)
            elif pattern_type == "holding_period_edge":
                adj = self._compute_holding_adjustment(key, win_rate, sample_size)
                if adj:
                    adjustments.append(adj)

        if adjustments:
            self._optimization_count += 1
            log.info(
                "strategy_optimizer.optimized",
                adjustments=len(adjustments),
                total_optimizations=self._optimization_count,
            )

            await self.emit(
                SignalTypes.STRATEGY_OPTIMIZED,
                payload={
                    "adjustments": adjustments,
                    "optimization_count": self._optimization_count,
                },
                priority=SignalPriority.LOW,
            )

    def _compute_strategy_adjustment(
        self, strategy: str, win_rate: float, sample_size: int
    ) -> dict | None:
        """Compute conservative size adjustment for a strategy."""
        if sample_size < 30:
            return None

        # How far above baseline (50%) is the win rate?
        edge = win_rate - 0.5

        # Scale by learning rate and cap at max_adjustment_pct
        size_delta = edge * self._learning_rate * 100
        size_delta = max(-self._max_adjustment_pct, min(self._max_adjustment_pct, size_delta))

        if abs(size_delta) < 0.5:
            return None

        # Update internal state
        if strategy not in self._strategy_params:
            self._strategy_params[strategy] = {
                "size_multiplier": 1.0,
                "confidence_threshold": 0.5,
            }

        params = self._strategy_params[strategy]
        params["size_multiplier"] = max(
            0.5, min(2.0, params["size_multiplier"] + size_delta / 100)
        )

        return {
            "strategy": strategy,
            "adjustment_type": "position_size",
            "delta_pct": round(size_delta, 2),
            "new_multiplier": round(params["size_multiplier"], 3),
            "based_on_win_rate": win_rate,
            "sample_size": sample_size,
        }

    def _compute_holding_adjustment(
        self, bucket: str, win_rate: float, sample_size: int
    ) -> dict | None:
        """Suggest holding period preference adjustments."""
        if sample_size < 30:
            return None

        return {
            "strategy": "all",
            "adjustment_type": "holding_preference",
            "preferred_bucket": bucket,
            "win_rate": win_rate,
            "sample_size": sample_size,
        }

    def _update_strategy_metrics(self, payload: dict) -> None:
        """Track live performance data for ongoing optimization."""
        strategy = payload.get("strategy", "")
        if strategy and strategy not in self._strategy_params:
            self._strategy_params[strategy] = {
                "size_multiplier": 1.0,
                "confidence_threshold": 0.5,
            }

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "optimization_count": self._optimization_count,
            "tracked_strategies": len(self._strategy_params),
            "strategy_params": dict(self._strategy_params),
            "learning_rate": self._learning_rate,
            "max_adjustment_pct": self._max_adjustment_pct,
        })
        return base
