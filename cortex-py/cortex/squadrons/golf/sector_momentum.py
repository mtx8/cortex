"""Sector Momentum — tracks sector rotation and relative strength.

Monitors sector ETF prices to determine:
- Relative strength ranking (which sectors are leading/lagging)
- Sector rotation signals (momentum shifting between sectors)
- Correlation of trade outcomes with sector momentum

Sector ETFs tracked: XLK, XLF, XLV, XLE, XLI, XLC, XLY, XLP, XLU, XLRE, XLB
"""

from collections import deque
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()

# Standard SPDR sector ETFs
SECTOR_ETFS = {
    "XLK": "Technology",
    "XLF": "Financials",
    "XLV": "Healthcare",
    "XLE": "Energy",
    "XLI": "Industrials",
    "XLC": "Communication Services",
    "XLY": "Consumer Discretionary",
    "XLP": "Consumer Staples",
    "XLU": "Utilities",
    "XLRE": "Real Estate",
    "XLB": "Materials",
}


class SectorMomentum(BaseAgent):
    """Tracks sector rotation and momentum via sector ETF relative strength."""

    agent_id = "sector_momentum"
    squadron = "golf"
    subscriptions = [SignalTypes.MARKET_SIGNAL]

    def __init__(
        self,
        bus: SignalBus,
        lookback: int = 20,
        rotation_threshold: float = 0.02,
    ):
        super().__init__(bus)
        self._lookback = lookback
        self._rotation_threshold = rotation_threshold

        # Price history per sector ETF
        self._prices: dict[str, deque[float]] = {}
        self._rankings: list[tuple[str, float]] = []
        self._prev_rankings: list[tuple[str, float]] = []
        self._update_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type != SignalTypes.MARKET_SIGNAL:
            return

        payload = signal.payload
        symbol = payload.get("symbol", "")
        close = payload.get("close", 0.0)

        if symbol not in SECTOR_ETFS or close <= 0:
            return

        if symbol not in self._prices:
            self._prices[symbol] = deque(maxlen=self._lookback)

        self._prices[symbol].append(close)
        self._update_count += 1

        # Only re-rank when we have data for at least 3 sectors
        sectors_with_data = sum(
            1 for p in self._prices.values() if len(p) >= 5
        )
        if sectors_with_data < 3:
            return

        # Re-rank every time a sector ETF updates
        new_rankings = self._compute_rankings()
        if new_rankings and self._rankings:
            rotation = self._detect_rotation(self._rankings, new_rankings)
            if rotation:
                await self.emit(
                    SignalTypes.SECTOR_MOMENTUM,
                    payload={
                        "rankings": [
                            {"symbol": s, "sector": SECTOR_ETFS.get(s, s), "momentum": round(m, 4)}
                            for s, m in new_rankings
                        ],
                        "rotation": rotation,
                    },
                    priority=SignalPriority.LOW,
                )

        self._prev_rankings = self._rankings
        self._rankings = new_rankings

    def _compute_rankings(self) -> list[tuple[str, float]]:
        """Rank sectors by recent return (momentum)."""
        momentum: list[tuple[str, float]] = []

        for symbol, prices in self._prices.items():
            if len(prices) < 5:
                continue
            price_list = list(prices)
            ret = (price_list[-1] - price_list[0]) / price_list[0]
            momentum.append((symbol, ret))

        momentum.sort(key=lambda x: x[1], reverse=True)
        return momentum

    def _detect_rotation(
        self,
        old_rankings: list[tuple[str, float]],
        new_rankings: list[tuple[str, float]],
    ) -> dict | None:
        """Detect if sector leadership has rotated significantly."""
        if not old_rankings or not new_rankings:
            return None

        old_leader = old_rankings[0][0]
        new_leader = new_rankings[0][0]

        if old_leader != new_leader:
            old_leader_momentum = dict(new_rankings).get(old_leader, 0.0)
            new_leader_momentum = new_rankings[0][1]

            if abs(new_leader_momentum - old_leader_momentum) >= self._rotation_threshold:
                return {
                    "type": "leadership_change",
                    "old_leader": old_leader,
                    "old_leader_sector": SECTOR_ETFS.get(old_leader, old_leader),
                    "new_leader": new_leader,
                    "new_leader_sector": SECTOR_ETFS.get(new_leader, new_leader),
                    "momentum_spread": round(
                        new_leader_momentum - old_leader_momentum, 4
                    ),
                }

        return None

    @property
    def current_rankings(self) -> list[tuple[str, float]]:
        return list(self._rankings)

    def get_sector_momentum(self, symbol: str) -> float | None:
        """Get momentum for a specific sector ETF."""
        for s, m in self._rankings:
            if s == symbol:
                return m
        return None

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "tracked_sectors": len(self._prices),
            "update_count": self._update_count,
            "top_sector": self._rankings[0][0] if self._rankings else None,
            "bottom_sector": self._rankings[-1][0] if self._rankings else None,
        })
        return base
