"""Price Level Mapper — maps support/resistance from order flow.

Builds a volume-at-price profile to identify:
- High-volume nodes (HVN): Support/resistance levels
- Low-volume nodes (LVN): Areas where price moves quickly
- Point of control (POC): Price with highest volume
- Value area (VA): Range containing 70% of volume

Emits price level maps for entry/exit optimization.
"""

from collections import defaultdict, deque
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class PriceLevelMapper(BaseAgent):
    """Maps support/resistance levels from volume-at-price data."""

    agent_id = "price_level_mapper"
    squadron = "hotel"
    subscriptions = [SignalTypes.MARKET_SIGNAL]

    def __init__(
        self,
        bus: SignalBus,
        tick_size: float = 0.01,
        lookback: int = 500,
        update_interval: int = 50,
        value_area_pct: float = 0.70,
    ):
        super().__init__(bus)
        self._tick_size = tick_size
        self._lookback = lookback
        self._update_interval = update_interval
        self._value_area_pct = value_area_pct

        # Per-symbol volume profile
        self._volume_profile: dict[str, dict[float, float]] = {}
        self._price_history: dict[str, deque[tuple[float, float]]] = {}  # (price, volume)
        self._tick_count: dict[str, int] = {}
        self._levels: dict[str, dict] = {}

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type != SignalTypes.MARKET_SIGNAL:
            return

        payload = signal.payload
        symbol = payload.get("symbol", "")
        price = payload.get("close", 0.0)
        volume = payload.get("volume", 0.0)

        if not symbol or price <= 0:
            return

        # Round price to tick size
        rounded = round(price / self._tick_size) * self._tick_size

        if symbol not in self._volume_profile:
            self._volume_profile[symbol] = defaultdict(float)
            self._price_history[symbol] = deque(maxlen=self._lookback)
            self._tick_count[symbol] = 0

        self._volume_profile[symbol][rounded] += volume
        self._price_history[symbol].append((price, volume))
        self._tick_count[symbol] += 1

        if self._tick_count[symbol] % self._update_interval == 0:
            levels = self._compute_levels(symbol)
            if levels:
                self._levels[symbol] = levels
                await self.emit(
                    SignalTypes.PRICE_LEVEL_MAP,
                    payload={
                        "symbol": symbol,
                        "poc": levels["poc"],
                        "value_area_high": levels["va_high"],
                        "value_area_low": levels["va_low"],
                        "support_levels": levels["support"],
                        "resistance_levels": levels["resistance"],
                    },
                    priority=SignalPriority.LOW,
                )

    def _compute_levels(self, symbol: str) -> dict | None:
        """Compute POC, value area, and support/resistance."""
        profile = self._volume_profile.get(symbol, {})
        if not profile:
            return None

        # Point of control — highest volume price
        poc_price = max(profile, key=profile.get)  # type: ignore[arg-type]
        total_volume = sum(profile.values())

        if total_volume == 0:
            return None

        # Value area — expand from POC until 70% of volume captured
        sorted_levels = sorted(profile.items(), key=lambda x: x[1], reverse=True)
        va_volume = 0.0
        va_prices: list[float] = []

        for price, vol in sorted_levels:
            va_volume += vol
            va_prices.append(price)
            if va_volume / total_volume >= self._value_area_pct:
                break

        va_high = max(va_prices) if va_prices else poc_price
        va_low = min(va_prices) if va_prices else poc_price

        # High-volume nodes (top 20% by volume) = support/resistance
        threshold = sorted_levels[0][1] * 0.5 if sorted_levels else 0
        hvn = [p for p, v in sorted_levels if v >= threshold]

        # Current price determines which are support vs resistance
        history = self._price_history.get(symbol)
        current_price = history[-1][0] if history else poc_price

        support = sorted([p for p in hvn if p < current_price], reverse=True)[:3]
        resistance = sorted([p for p in hvn if p > current_price])[:3]

        return {
            "poc": round(poc_price, 2),
            "va_high": round(va_high, 2),
            "va_low": round(va_low, 2),
            "support": [round(p, 2) for p in support],
            "resistance": [round(p, 2) for p in resistance],
        }

    def get_levels(self, symbol: str) -> dict | None:
        return self._levels.get(symbol)

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "tracked_symbols": len(self._volume_profile),
            "symbols_with_levels": len(self._levels),
        })
        return base
