"""Drawdown Analyzer — analyzes drawdown patterns and recovery times.

Tracks:
- Current drawdown depth from peak equity
- Historical drawdown events with duration and recovery
- Drawdown velocity (how fast equity is declining)
- Recovery patterns (what conditions precede recovery)

Feeds into risk management to adjust position sizing during drawdowns.
"""

import time
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class DrawdownEvent:
    """A single drawdown event from peak to recovery (or ongoing)."""

    __slots__ = (
        "peak_equity", "trough_equity", "start_time", "trough_time",
        "recovery_time", "max_depth_pct", "recovered",
    )

    def __init__(self, peak_equity: float, start_time: float):
        self.peak_equity = peak_equity
        self.trough_equity = peak_equity
        self.start_time = start_time
        self.trough_time = start_time
        self.recovery_time: float | None = None
        self.max_depth_pct = 0.0
        self.recovered = False

    def update(self, equity: float, ts: float) -> None:
        if equity < self.trough_equity:
            self.trough_equity = equity
            self.trough_time = ts
            self.max_depth_pct = (
                (self.peak_equity - self.trough_equity) / self.peak_equity * 100
                if self.peak_equity > 0 else 0.0
            )
        if equity >= self.peak_equity and not self.recovered:
            self.recovered = True
            self.recovery_time = ts

    @property
    def duration_seconds(self) -> float:
        end = self.recovery_time or time.time()
        return end - self.start_time

    def to_dict(self) -> dict:
        return {
            "peak_equity": round(self.peak_equity, 2),
            "trough_equity": round(self.trough_equity, 2),
            "max_depth_pct": round(self.max_depth_pct, 2),
            "duration_seconds": round(self.duration_seconds, 1),
            "recovered": self.recovered,
        }


class DrawdownAnalyzer(BaseAgent):
    """Analyzes drawdown patterns and recovery times."""

    agent_id = "drawdown_analyzer"
    squadron = "golf"
    subscriptions = [SignalTypes.TRADE_RECORDED, SignalTypes.DRAWDOWN_WARNING]

    def __init__(
        self,
        bus: SignalBus,
        alert_threshold_pct: float = 5.0,
        max_history: int = 100,
    ):
        super().__init__(bus)
        self._alert_threshold_pct = alert_threshold_pct
        self._max_history = max_history

        self._peak_equity = 0.0
        self._current_equity = 0.0
        self._current_drawdown: DrawdownEvent | None = None
        self._drawdown_history: list[DrawdownEvent] = []
        self._consecutive_losses = 0
        self._max_consecutive_losses = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type == SignalTypes.TRADE_RECORDED:
            await self._process_trade(signal.payload)
        elif signal.signal_type == SignalTypes.DRAWDOWN_WARNING:
            self._process_drawdown_warning(signal.payload)

    async def _process_trade(self, payload: dict) -> None:
        pnl = payload.get("pnl", 0.0)
        self._current_equity += pnl
        now = time.time()

        # Track consecutive losses
        if pnl <= 0:
            self._consecutive_losses += 1
            self._max_consecutive_losses = max(
                self._max_consecutive_losses, self._consecutive_losses
            )
        else:
            self._consecutive_losses = 0

        # New high-water mark
        if self._current_equity > self._peak_equity:
            self._peak_equity = self._current_equity

            # Close current drawdown if it exists
            if self._current_drawdown is not None:
                self._current_drawdown.recovered = True
                self._current_drawdown.recovery_time = now
                self._drawdown_history.append(self._current_drawdown)
                if len(self._drawdown_history) > self._max_history:
                    self._drawdown_history = self._drawdown_history[-self._max_history:]
                self._current_drawdown = None

        elif self._peak_equity > 0:
            # In drawdown
            dd_pct = (self._peak_equity - self._current_equity) / self._peak_equity * 100

            if self._current_drawdown is None and dd_pct > 0:
                self._current_drawdown = DrawdownEvent(
                    peak_equity=self._peak_equity, start_time=now
                )

            if self._current_drawdown is not None:
                self._current_drawdown.update(self._current_equity, now)

                if dd_pct >= self._alert_threshold_pct:
                    await self.emit(
                        SignalTypes.DRAWDOWN_ANALYSIS,
                        payload={
                            "current_drawdown_pct": round(dd_pct, 2),
                            "peak_equity": round(self._peak_equity, 2),
                            "current_equity": round(self._current_equity, 2),
                            "consecutive_losses": self._consecutive_losses,
                            "duration_seconds": round(
                                self._current_drawdown.duration_seconds, 1
                            ),
                            "avg_recovery_time": self._avg_recovery_time(),
                        },
                        priority=SignalPriority.NORMAL,
                    )

    def _process_drawdown_warning(self, payload: dict) -> None:
        """Ingest drawdown warnings from ECHO squadron for correlation."""
        dd_pct = payload.get("drawdown_pct", 0.0)
        if dd_pct > 0 and self._peak_equity == 0:
            # Seed equity from ECHO data
            nav = payload.get("nav", 0.0)
            if nav > 0:
                self._peak_equity = nav / (1 - dd_pct / 100)
                self._current_equity = nav

    def _avg_recovery_time(self) -> float:
        """Average recovery time from historical drawdowns."""
        recovered = [
            dd for dd in self._drawdown_history
            if dd.recovered and dd.recovery_time is not None
        ]
        if not recovered:
            return 0.0
        return sum(dd.duration_seconds for dd in recovered) / len(recovered)

    @property
    def current_drawdown_pct(self) -> float:
        if self._peak_equity <= 0:
            return 0.0
        return (
            (self._peak_equity - self._current_equity) / self._peak_equity * 100
        )

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "peak_equity": round(self._peak_equity, 2),
            "current_equity": round(self._current_equity, 2),
            "current_drawdown_pct": round(self.current_drawdown_pct, 2),
            "consecutive_losses": self._consecutive_losses,
            "max_consecutive_losses": self._max_consecutive_losses,
            "historical_drawdowns": len(self._drawdown_history),
            "avg_recovery_time": round(self._avg_recovery_time(), 1),
        })
        return base
