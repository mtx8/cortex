"""Volume Profiler — monitors relative volume vs 20-day average.
Detects volume surges that confirm momentum moves.

Publishes VOLUME_SURGE signals when:
- Current volume > 2x 20-day average (significant surge)
- Volume acceleration detected (increasing volume over 3+ bars)
"""

from dataclasses import dataclass, field
from collections import deque
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


@dataclass
class VolumeSurge:
    symbol: str
    relative_volume: float  # Current / 20-day avg
    current_volume: float
    avg_volume: float
    price_change_pct: float
    acceleration: bool  # True if 3+ bars of increasing volume
    surge_level: str  # "moderate" (1.5-2x), "significant" (2-3x), "extreme" (>3x)


class VolumeProfiler(BaseAgent):
    agent_id = "volume_profiler"
    squadron = "alpha"
    subscriptions = [SignalTypes.MARKET_SIGNAL]

    def __init__(
        self,
        bus: SignalBus,
        lookback: int = 20,
        moderate_threshold: float = 1.5,
        significant_threshold: float = 2.0,
        extreme_threshold: float = 3.0,
        acceleration_bars: int = 3,
    ):
        super().__init__(bus)
        self._lookback = lookback
        self._moderate = moderate_threshold
        self._significant = significant_threshold
        self._extreme = extreme_threshold
        self._accel_bars = acceleration_bars

        self._volumes: dict[str, deque[float]] = {}
        self._prices: dict[str, deque[float]] = {}
        self._surges_detected = 0

    async def handle_signal(self, signal: Signal) -> None:
        payload = signal.payload
        symbol = payload.get("symbol")
        volume = payload.get("volume", 0.0)
        close = payload.get("close", 0.0)

        if not symbol or volume <= 0 or close <= 0:
            return

        if symbol not in self._volumes:
            self._volumes[symbol] = deque(maxlen=self._lookback + 1)
            self._prices[symbol] = deque(maxlen=self._lookback + 1)

        self._volumes[symbol].append(volume)
        self._prices[symbol].append(close)

        surge = self.analyze(symbol)
        if surge:
            self._surges_detected += 1
            await self.emit(
                SignalTypes.VOLUME_SURGE,
                payload={
                    "symbol": surge.symbol,
                    "relative_volume": surge.relative_volume,
                    "current_volume": surge.current_volume,
                    "avg_volume": surge.avg_volume,
                    "price_change_pct": surge.price_change_pct,
                    "acceleration": surge.acceleration,
                    "surge_level": surge.surge_level,
                },
                priority=SignalPriority.NORMAL,
            )

    def analyze(self, symbol: str) -> VolumeSurge | None:
        """Analyze volume for a symbol. Returns VolumeSurge if detected."""
        volumes = list(self._volumes.get(symbol, []))
        prices = list(self._prices.get(symbol, []))

        if len(volumes) < 2:
            return None

        current_vol = volumes[-1]

        # Calculate 20-day average (exclude current bar)
        historical = volumes[:-1]
        if not historical:
            return None
        avg_vol = sum(historical) / len(historical)

        if avg_vol <= 0:
            return None

        rel_vol = current_vol / avg_vol

        # Classify surge level
        if rel_vol >= self._extreme:
            level = "extreme"
        elif rel_vol >= self._significant:
            level = "significant"
        elif rel_vol >= self._moderate:
            level = "moderate"
        else:
            return None  # Below threshold

        # Price change
        price_change = 0.0
        if len(prices) >= 2 and prices[-2] > 0:
            price_change = ((prices[-1] - prices[-2]) / prices[-2]) * 100.0

        # Volume acceleration (3+ consecutive bars of increasing volume)
        acceleration = False
        if len(volumes) >= self._accel_bars:
            recent = volumes[-self._accel_bars:]
            acceleration = all(
                recent[i] > recent[i - 1] for i in range(1, len(recent))
            )

        return VolumeSurge(
            symbol=symbol,
            relative_volume=rel_vol,
            current_volume=current_vol,
            avg_volume=avg_vol,
            price_change_pct=price_change,
            acceleration=acceleration,
            surge_level=level,
        )

    @property
    def surges_detected(self) -> int:
        return self._surges_detected

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "tracked_symbols": len(self._volumes),
            "surges_detected": self._surges_detected,
        })
        return base
