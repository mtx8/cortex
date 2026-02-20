"""Tracks trading patterns and generates learning insights."""

import time
from collections import defaultdict
from dataclasses import dataclass, field

import structlog

log = structlog.get_logger()


@dataclass
class LearningInsight:
    pattern_type: str
    description: str
    win_rate: float
    sample_size: int
    confidence: str  # "low", "medium", "high"
    timestamp: float = field(default_factory=time.time)

    def to_dict(self) -> dict:
        return {
            "pattern_type": self.pattern_type,
            "description": self.description,
            "win_rate": self.win_rate,
            "sample_size": self.sample_size,
            "confidence": self.confidence,
            "timestamp": self.timestamp,
        }


class LearningTracker:
    def __init__(self, analysis_interval: int = 50, broadcaster=None):
        self._trades: list[dict] = []
        self._insights: list[LearningInsight] = []
        self._analysis_interval = analysis_interval
        self._broadcaster = broadcaster

    def record_trade(self, trade_data: dict) -> None:
        self._trades.append({**trade_data, "recorded_at": time.time()})
        if len(self._trades) % self._analysis_interval == 0:
            self._analyze()

    def _analyze(self) -> None:
        if len(self._trades) < 10:
            return

        # Group by signal type
        by_signal: dict[str, list[dict]] = defaultdict(list)
        for t in self._trades:
            sig = t.get("signal_type", "unknown")
            by_signal[sig].append(t)

        for sig_type, trades in by_signal.items():
            if len(trades) < 5:
                continue
            winners = sum(1 for t in trades if t.get("pnl", 0) > 0)
            win_rate = winners / len(trades)

            confidence = "low"
            if len(trades) >= 30:
                confidence = "high"
            elif len(trades) >= 15:
                confidence = "medium"

            if win_rate > 0.55:
                insight = LearningInsight(
                    pattern_type=sig_type,
                    description=(
                        f"{sig_type} signals show {win_rate:.0%} win rate "
                        f"over {len(trades)} trades"
                    ),
                    win_rate=win_rate,
                    sample_size=len(trades),
                    confidence=confidence,
                )
                self._insights.append(insight)
                log.info(
                    "learning.insight_found",
                    pattern=sig_type,
                    win_rate=win_rate,
                    sample=len(trades),
                )

    @property
    def insights(self) -> list[LearningInsight]:
        return self._insights

    async def broadcast_insights(self) -> None:
        if self._broadcaster and self._insights:
            from cortex.api.protocol import CortexMessage, MessageType

            msg = CortexMessage(
                type=MessageType.LEARNING_INSIGHT,
                payload={
                    "insights": [i.to_dict() for i in self._insights[-10:]],
                    "total_trades": len(self._trades),
                },
            )
            await self._broadcaster.broadcast(msg)

    def to_dict(self) -> dict:
        return {
            "total_trades": len(self._trades),
            "insights_count": len(self._insights),
            "analysis_interval": self._analysis_interval,
        }
