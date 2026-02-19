"""Drawdown Shield — monitors portfolio drawdown on 3 independent clocks
(daily, weekly, total). Applies linear throttle ramp, halt, and kill switch.

Throttle logic:
  - Daily DD < throttle_pct: throttle_factor = 1.0 (full trading)
  - Daily DD >= throttle_pct and < halt_pct: linear ramp from 1.0 -> 0.0
  - Daily DD >= halt_pct: throttle_factor = 0.0 (no new positions)
  - Weekly DD >= weekly_halt_pct: throttle_factor = 0.0
  - Total DD >= kill_pct: trigger kill switch
"""

import time
from dataclasses import dataclass, field
from enum import Enum
import structlog

log = structlog.get_logger()


class DrawdownLevel(str, Enum):
    NORMAL = "normal"          # Full trading
    THROTTLED = "throttled"    # Reduced position sizes
    HALTED = "halted"          # No new positions
    KILL = "kill"              # Trigger kill switch


@dataclass
class DrawdownState:
    level: DrawdownLevel
    throttle_factor: float  # 0.0 = no trading, 1.0 = full trading
    daily_drawdown_pct: float
    weekly_drawdown_pct: float
    total_drawdown_pct: float
    should_engage_kill_switch: bool = False
    message: str = ""


class DrawdownShield:
    def __init__(
        self,
        daily_throttle_pct: float = 5.0,
        daily_halt_pct: float = 7.0,
        weekly_halt_pct: float = 10.0,
        total_kill_pct: float = 20.0,
    ):
        self._daily_throttle = daily_throttle_pct
        self._daily_halt = daily_halt_pct
        self._weekly_halt = weekly_halt_pct
        self._total_kill = total_kill_pct

        # High-water marks for drawdown calculation
        self._daily_hwm: float = 0.0
        self._weekly_hwm: float = 0.0
        self._total_hwm: float = 0.0

        # Current drawdowns
        self._daily_dd: float = 0.0
        self._weekly_dd: float = 0.0
        self._total_dd: float = 0.0

        self._last_reset_day: str = ""
        self._last_reset_week: str = ""

    def update(self, current_nav: float, timestamp: float | None = None) -> DrawdownState:
        """Update drawdown calculations with current NAV.
        Call this on every portfolio valuation tick."""
        ts = timestamp or time.time()

        # Update high-water marks
        if current_nav > self._daily_hwm:
            self._daily_hwm = current_nav
        if current_nav > self._weekly_hwm:
            self._weekly_hwm = current_nav
        if current_nav > self._total_hwm:
            self._total_hwm = current_nav

        # Calculate drawdowns (percentage from HWM)
        self._daily_dd = self._calc_dd(current_nav, self._daily_hwm)
        self._weekly_dd = self._calc_dd(current_nav, self._weekly_hwm)
        self._total_dd = self._calc_dd(current_nav, self._total_hwm)

        return self._evaluate()

    def reset_daily(self, current_nav: float) -> None:
        """Call at market open to reset daily high-water mark."""
        self._daily_hwm = current_nav
        self._daily_dd = 0.0
        log.info("drawdown.daily_reset", nav=current_nav)

    def reset_weekly(self, current_nav: float) -> None:
        """Call on Monday market open to reset weekly high-water mark."""
        self._weekly_hwm = current_nav
        self._weekly_dd = 0.0
        log.info("drawdown.weekly_reset", nav=current_nav)

    def get_state(self) -> DrawdownState:
        """Return current state without updating."""
        return self._evaluate()

    @property
    def daily_drawdown_pct(self) -> float:
        return self._daily_dd

    @property
    def weekly_drawdown_pct(self) -> float:
        return self._weekly_dd

    @property
    def total_drawdown_pct(self) -> float:
        return self._total_dd

    def _evaluate(self) -> DrawdownState:
        # Priority: kill > halt > throttle > normal
        # Check total drawdown kill
        if self._total_dd >= self._total_kill:
            return DrawdownState(
                level=DrawdownLevel.KILL,
                throttle_factor=0.0,
                daily_drawdown_pct=self._daily_dd,
                weekly_drawdown_pct=self._weekly_dd,
                total_drawdown_pct=self._total_dd,
                should_engage_kill_switch=True,
                message=f"Total drawdown {self._total_dd:.1f}% >= kill threshold {self._total_kill}%",
            )

        # Check weekly halt
        if self._weekly_dd >= self._weekly_halt:
            return DrawdownState(
                level=DrawdownLevel.HALTED,
                throttle_factor=0.0,
                daily_drawdown_pct=self._daily_dd,
                weekly_drawdown_pct=self._weekly_dd,
                total_drawdown_pct=self._total_dd,
                message=f"Weekly drawdown {self._weekly_dd:.1f}% >= halt {self._weekly_halt}%",
            )

        # Check daily halt
        if self._daily_dd >= self._daily_halt:
            return DrawdownState(
                level=DrawdownLevel.HALTED,
                throttle_factor=0.0,
                daily_drawdown_pct=self._daily_dd,
                weekly_drawdown_pct=self._weekly_dd,
                total_drawdown_pct=self._total_dd,
                message=f"Daily drawdown {self._daily_dd:.1f}% >= halt {self._daily_halt}%",
            )

        # Check daily throttle (linear ramp)
        if self._daily_dd >= self._daily_throttle:
            # Linear interpolation: at throttle_pct -> 1.0, at halt_pct -> 0.0
            range_pct = self._daily_halt - self._daily_throttle
            if range_pct > 0:
                progress = (self._daily_dd - self._daily_throttle) / range_pct
                throttle = max(0.0, 1.0 - progress)
            else:
                throttle = 0.0

            return DrawdownState(
                level=DrawdownLevel.THROTTLED,
                throttle_factor=throttle,
                daily_drawdown_pct=self._daily_dd,
                weekly_drawdown_pct=self._weekly_dd,
                total_drawdown_pct=self._total_dd,
                message=f"Daily drawdown {self._daily_dd:.1f}% — throttle factor {throttle:.2f}",
            )

        # Normal
        return DrawdownState(
            level=DrawdownLevel.NORMAL,
            throttle_factor=1.0,
            daily_drawdown_pct=self._daily_dd,
            weekly_drawdown_pct=self._weekly_dd,
            total_drawdown_pct=self._total_dd,
        )

    @staticmethod
    def _calc_dd(current: float, hwm: float) -> float:
        if hwm <= 0:
            return 0.0
        return max(0.0, ((hwm - current) / hwm) * 100.0)
