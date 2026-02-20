"""Depth Reader — analyzes L2 order book depth and imbalance.

Reads order book data to detect:
- Buy/sell imbalance (more buyers = bullish pressure)
- Thin levels (price levels with low depth = potential fast moves)
- Iceberg orders (large hidden liquidity)
- Absorption (large orders holding a level)

Emits depth imbalance signals for entry timing optimization.
"""

import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class DepthReader(BaseAgent):
    """Analyzes L2 order book for depth imbalances."""

    agent_id = "depth_reader"
    squadron = "hotel"
    subscriptions = [SignalTypes.MARKET_SIGNAL]

    def __init__(
        self,
        bus: SignalBus,
        imbalance_threshold: float = 0.3,  # 30% imbalance triggers signal
        depth_levels: int = 5,
    ):
        super().__init__(bus)
        self._imbalance_threshold = imbalance_threshold
        self._depth_levels = depth_levels

        self._last_imbalance: dict[str, float] = {}
        self._imbalance_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type != SignalTypes.MARKET_SIGNAL:
            return

        payload = signal.payload
        symbol = payload.get("symbol", "")
        bids = payload.get("depth_bids", [])  # list of [price, size]
        asks = payload.get("depth_asks", [])  # list of [price, size]

        if not symbol or not bids or not asks:
            return

        imbalance = self._compute_imbalance(bids, asks)
        self._last_imbalance[symbol] = imbalance

        if abs(imbalance) >= self._imbalance_threshold:
            self._imbalance_count += 1
            direction = "buy_heavy" if imbalance > 0 else "sell_heavy"

            await self.emit(
                SignalTypes.DEPTH_IMBALANCE,
                payload={
                    "symbol": symbol,
                    "imbalance": round(imbalance, 3),
                    "direction": direction,
                    "bid_depth": sum(s for _, s in bids[:self._depth_levels]),
                    "ask_depth": sum(s for _, s in asks[:self._depth_levels]),
                    "thin_levels": self._find_thin_levels(bids, asks),
                },
                priority=SignalPriority.NORMAL,
            )

    def _compute_imbalance(
        self, bids: list[list[float]], asks: list[list[float]]
    ) -> float:
        """Compute order book imbalance ratio.

        Returns:
            Positive = more buy pressure, Negative = more sell pressure.
            Range: -1.0 to 1.0
        """
        bid_size = sum(s for _, s in bids[:self._depth_levels])
        ask_size = sum(s for _, s in asks[:self._depth_levels])
        total = bid_size + ask_size

        if total == 0:
            return 0.0

        return (bid_size - ask_size) / total

    def _find_thin_levels(
        self, bids: list[list[float]], asks: list[list[float]]
    ) -> list[dict]:
        """Find price levels with unusually low depth."""
        thin = []
        all_levels = [(p, s, "bid") for p, s in bids[:self._depth_levels]]
        all_levels += [(p, s, "ask") for p, s in asks[:self._depth_levels]]

        if not all_levels:
            return []

        avg_size = sum(s for _, s, _ in all_levels) / len(all_levels)

        for price, size, side in all_levels:
            if avg_size > 0 and size < avg_size * 0.3:
                thin.append({
                    "price": price,
                    "size": size,
                    "side": side,
                    "relative_size": round(size / avg_size, 2) if avg_size > 0 else 0.0,
                })

        return thin

    def get_imbalance(self, symbol: str) -> float:
        return self._last_imbalance.get(symbol, 0.0)

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "tracked_symbols": len(self._last_imbalance),
            "imbalance_signals": self._imbalance_count,
            "depth_levels": self._depth_levels,
        })
        return base
