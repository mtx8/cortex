"""Gap Scanner — detects pre-market price gaps from prior close.
A gap is significant when price opens >2% away from yesterday's close.

Gap types:
- Gap Up: open > prior_close * 1.02
- Gap Down: open < prior_close * 0.98
- Full Gap: gap hasn't been filled (price stays on gap side)
- Partial Gap: gap partially filled during session

Publishes GAP_DETECTED signals with gap metadata.
"""

from dataclasses import dataclass, field
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


@dataclass
class GapEvent:
    symbol: str
    gap_pct: float
    direction: str  # "up" | "down"
    prior_close: float
    open_price: float
    current_price: float
    volume_ratio: float
    gap_filled: bool


class GapScanner(BaseAgent):
    agent_id = "gap_scanner"
    squadron = "alpha"
    subscriptions = [SignalTypes.MARKET_SIGNAL]

    def __init__(
        self,
        bus: SignalBus,
        min_gap_pct: float = 2.0,
        volume_confirm_threshold: float = 1.5,
    ):
        super().__init__(bus)
        self._min_gap_pct = min_gap_pct
        self._volume_confirm = volume_confirm_threshold

        # Track prior close and today's open per symbol
        self._prior_close: dict[str, float] = {}
        self._today_open: dict[str, float] = {}
        self._active_gaps: dict[str, GapEvent] = {}
        self._gaps_detected = 0

    async def handle_signal(self, signal: Signal) -> None:
        payload = signal.payload
        symbol = payload.get("symbol")
        if not symbol:
            return

        close = payload.get("close", 0.0)
        open_price = payload.get("open", 0.0)
        volume = payload.get("volume", 0.0)
        avg_volume = payload.get("avg_volume", 0.0)
        is_market_open = payload.get("is_market_open", False)

        if close <= 0:
            return

        # Track prior close (end of day update)
        if not is_market_open:
            self._prior_close[symbol] = close
            return

        # Market is open — check for gap
        if symbol not in self._prior_close:
            return

        if open_price > 0 and symbol not in self._today_open:
            self._today_open[symbol] = open_price

        vol_ratio = volume / avg_volume if avg_volume > 0 else 0.0

        gap = self.detect_gap(
            symbol=symbol,
            prior_close=self._prior_close[symbol],
            open_price=self._today_open.get(symbol, open_price),
            current_price=close,
            volume_ratio=vol_ratio,
        )

        if gap and symbol not in self._active_gaps:
            self._active_gaps[symbol] = gap
            self._gaps_detected += 1
            await self.emit(
                SignalTypes.GAP_DETECTED,
                payload={
                    "symbol": gap.symbol,
                    "gap_pct": gap.gap_pct,
                    "direction": gap.direction,
                    "prior_close": gap.prior_close,
                    "open_price": gap.open_price,
                    "current_price": gap.current_price,
                    "volume_ratio": gap.volume_ratio,
                    "gap_filled": gap.gap_filled,
                },
                priority=SignalPriority.NORMAL,
            )

    def detect_gap(
        self,
        symbol: str,
        prior_close: float,
        open_price: float,
        current_price: float,
        volume_ratio: float,
    ) -> GapEvent | None:
        """Detect gap from prior close. Returns GapEvent or None."""
        if prior_close <= 0 or open_price <= 0:
            return None

        gap_pct = ((open_price - prior_close) / prior_close) * 100.0

        if abs(gap_pct) < self._min_gap_pct:
            return None

        direction = "up" if gap_pct > 0 else "down"

        # Check if gap has been filled
        if direction == "up":
            gap_filled = current_price <= prior_close
        else:
            gap_filled = current_price >= prior_close

        return GapEvent(
            symbol=symbol,
            gap_pct=gap_pct,
            direction=direction,
            prior_close=prior_close,
            open_price=open_price,
            current_price=current_price,
            volume_ratio=volume_ratio,
            gap_filled=gap_filled,
        )

    def reset_daily(self) -> None:
        """Call at end of day to prepare for next session."""
        self._today_open.clear()
        self._active_gaps.clear()

    @property
    def gaps_detected(self) -> int:
        return self._gaps_detected

    @property
    def active_gaps(self) -> dict[str, GapEvent]:
        return dict(self._active_gaps)

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "gaps_detected": self._gaps_detected,
            "active_gaps": len(self._active_gaps),
        })
        return base
