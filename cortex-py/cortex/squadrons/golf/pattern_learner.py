"""Pattern Learner — statistical pattern analysis on completed trades.

Analyzes trade outcomes to find statistically significant patterns:
- Win rate by strategy, sector, time-of-day, regime
- Feature importance (which entry reasons correlate with wins)
- Holding period optimization
- Confidence calibration (are 80% confidence trades winning 80%?)

Runs analysis every N trades and emits learned patterns via SignalBus.
"""

import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class PatternLearner(BaseAgent):
    """Analyzes trade outcomes to find statistically significant patterns."""

    agent_id = "pattern_learner"
    squadron = "golf"
    subscriptions = [SignalTypes.TRADE_RECORDED]

    def __init__(
        self,
        bus: SignalBus,
        trade_historian=None,
        analysis_interval: int = 100,
        min_sample_size: int = 20,
        min_win_rate: float = 0.60,
    ):
        super().__init__(bus)
        self._historian = trade_historian
        self._trade_count = 0
        self._analysis_interval = analysis_interval
        self._min_sample_size = min_sample_size
        self._min_win_rate = min_win_rate
        self._patterns: list[dict] = []
        self._last_analysis_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type != SignalTypes.TRADE_RECORDED:
            return

        self._trade_count += 1

        if self._trade_count % self._analysis_interval == 0:
            await self._analyze_patterns()

    async def _analyze_patterns(self) -> None:
        """Run statistical analysis on recorded trades."""
        if self._historian is None:
            log.warning("pattern_learner.no_historian")
            return

        trades = self._historian.trades
        if len(trades) < self._min_sample_size:
            return

        new_patterns: list[dict] = []

        # Analyze by strategy
        strategy_patterns = self._analyze_by_group(
            trades, key_fn=lambda t: t.strategy, group_name="strategy"
        )
        new_patterns.extend(strategy_patterns)

        # Analyze by sector
        sector_patterns = self._analyze_by_group(
            trades, key_fn=lambda t: t.sector, group_name="sector"
        )
        new_patterns.extend(sector_patterns)

        # Analyze by direction
        direction_patterns = self._analyze_by_group(
            trades, key_fn=lambda t: t.direction, group_name="direction"
        )
        new_patterns.extend(direction_patterns)

        # Analyze by entry reason frequency
        reason_patterns = self._analyze_entry_reasons(trades)
        new_patterns.extend(reason_patterns)

        # Analyze holding period sweet spots
        holding_patterns = self._analyze_holding_periods(trades)
        new_patterns.extend(holding_patterns)

        self._patterns = new_patterns
        self._last_analysis_count = self._trade_count

        if new_patterns:
            log.info(
                "pattern_learner.analysis_complete",
                patterns_found=len(new_patterns),
                trade_count=self._trade_count,
            )

            await self.emit(
                SignalTypes.PATTERN_LEARNED,
                payload={"patterns": new_patterns, "trade_count": self._trade_count},
                priority=SignalPriority.LOW,
            )

    def _analyze_by_group(self, trades, key_fn, group_name: str) -> list[dict]:
        """Group trades by a key function and find high win-rate groups."""
        groups: dict[str, list] = {}
        for trade in trades:
            key = key_fn(trade)
            if key not in groups:
                groups[key] = []
            groups[key].append(trade)

        patterns = []
        for key, group_trades in groups.items():
            if len(group_trades) < self._min_sample_size:
                continue

            wins = sum(1 for t in group_trades if t.pnl > 0)
            win_rate = wins / len(group_trades)
            avg_pnl = sum(t.pnl for t in group_trades) / len(group_trades)

            if win_rate >= self._min_win_rate:
                patterns.append({
                    "type": f"{group_name}_edge",
                    "key": key,
                    "win_rate": round(win_rate, 3),
                    "sample_size": len(group_trades),
                    "avg_pnl": round(avg_pnl, 2),
                    "significance": "high" if len(group_trades) >= 50 else "moderate",
                })

        return patterns

    def _analyze_entry_reasons(self, trades) -> list[dict]:
        """Find which entry reasons correlate with winning trades."""
        reason_stats: dict[str, dict] = {}

        for trade in trades:
            for reason in trade.entry_reasons:
                # Normalize reason to a feature tag (e.g., "RSI reversal..." -> "rsi_reversal")
                tag = reason.split("(")[0].strip().lower().replace(" ", "_")
                if tag not in reason_stats:
                    reason_stats[tag] = {"wins": 0, "total": 0, "total_pnl": 0.0}
                reason_stats[tag]["total"] += 1
                reason_stats[tag]["total_pnl"] += trade.pnl
                if trade.pnl > 0:
                    reason_stats[tag]["wins"] += 1

        patterns = []
        for tag, stats in reason_stats.items():
            if stats["total"] < self._min_sample_size:
                continue

            win_rate = stats["wins"] / stats["total"]
            if win_rate >= self._min_win_rate:
                patterns.append({
                    "type": "entry_reason_edge",
                    "key": tag,
                    "win_rate": round(win_rate, 3),
                    "sample_size": stats["total"],
                    "avg_pnl": round(stats["total_pnl"] / stats["total"], 2),
                })

        return patterns

    def _analyze_holding_periods(self, trades) -> list[dict]:
        """Find optimal holding period ranges."""
        if not trades:
            return []

        # Bucket trades by holding period
        buckets = {
            "scalp_0_5m": (0, 300),
            "short_5_30m": (300, 1800),
            "medium_30m_2h": (1800, 7200),
            "swing_2h_1d": (7200, 86400),
            "multi_day": (86400, float("inf")),
        }

        patterns = []
        for bucket_name, (low, high) in buckets.items():
            bucket_trades = [
                t for t in trades if low <= t.holding_period_seconds < high
            ]
            if len(bucket_trades) < self._min_sample_size:
                continue

            wins = sum(1 for t in bucket_trades if t.pnl > 0)
            win_rate = wins / len(bucket_trades)

            if win_rate >= self._min_win_rate:
                patterns.append({
                    "type": "holding_period_edge",
                    "key": bucket_name,
                    "win_rate": round(win_rate, 3),
                    "sample_size": len(bucket_trades),
                    "avg_pnl": round(
                        sum(t.pnl for t in bucket_trades) / len(bucket_trades), 2
                    ),
                })

        return patterns

    @property
    def patterns(self) -> list[dict]:
        return list(self._patterns)

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "trade_count": self._trade_count,
            "analysis_interval": self._analysis_interval,
            "patterns_found": len(self._patterns),
            "last_analysis_at": self._last_analysis_count,
        })
        return base
