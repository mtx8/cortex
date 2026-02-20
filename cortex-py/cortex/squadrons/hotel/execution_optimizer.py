"""Execution Optimizer — optimizes order execution strategy.

Suggests optimal order types based on market conditions:
- LIMIT: For wide spreads or illiquid names
- MARKET: For urgent entries in liquid names
- TWAP: For large orders to minimize impact
- VWAP: For benchmark-tracking execution

Considers:
- Current spread width
- Order book depth
- Recent volatility
- Order size relative to ADV
"""

import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class ExecutionOptimizer(BaseAgent):
    """Suggests optimal order execution based on market microstructure."""

    agent_id = "execution_optimizer"
    squadron = "hotel"
    subscriptions = [
        SignalTypes.ENTRY_SIGNAL,
        SignalTypes.SPREAD_ALERT,
        SignalTypes.DEPTH_IMBALANCE,
    ]

    def __init__(
        self,
        bus: SignalBus,
        large_order_threshold_pct: float = 1.0,  # % of ADV
        wide_spread_threshold: float = 0.003,  # 0.3%
    ):
        super().__init__(bus)
        self._large_order_threshold = large_order_threshold_pct
        self._wide_spread_threshold = wide_spread_threshold

        # Market condition cache per symbol
        self._spread_data: dict[str, dict] = {}
        self._depth_data: dict[str, dict] = {}
        self._recommendation_count = 0

    async def handle_signal(self, signal: Signal) -> None:
        payload = signal.payload

        if signal.signal_type == SignalTypes.SPREAD_ALERT:
            self._update_spread_data(payload)
        elif signal.signal_type == SignalTypes.DEPTH_IMBALANCE:
            self._update_depth_data(payload)
        elif signal.signal_type == SignalTypes.ENTRY_SIGNAL:
            await self._generate_recommendation(payload)

    def _update_spread_data(self, payload: dict) -> None:
        symbol = payload.get("symbol", "")
        if symbol:
            self._spread_data[symbol] = {
                "spread_pct": payload.get("spread_pct", 0.0),
                "severity": payload.get("severity", "low"),
            }

    def _update_depth_data(self, payload: dict) -> None:
        symbol = payload.get("symbol", "")
        if symbol:
            self._depth_data[symbol] = {
                "imbalance": payload.get("imbalance", 0.0),
                "direction": payload.get("direction", "balanced"),
                "bid_depth": payload.get("bid_depth", 0),
                "ask_depth": payload.get("ask_depth", 0),
            }

    async def _generate_recommendation(self, payload: dict) -> None:
        """Generate execution recommendation for an entry signal."""
        symbol = payload.get("symbol", "")
        if not symbol:
            return

        spread_info = self._spread_data.get(symbol, {})
        depth_info = self._depth_data.get(symbol, {})
        confidence = payload.get("confidence", 0.5)

        # Determine order type
        order_type, reasoning = self._select_order_type(
            spread_info, depth_info, confidence
        )

        # Determine urgency
        urgency = self._assess_urgency(confidence, depth_info)

        self._recommendation_count += 1

        await self.emit(
            SignalTypes.EXECUTION_RECOMMENDATION,
            payload={
                "symbol": symbol,
                "order_type": order_type,
                "urgency": urgency,
                "reasoning": reasoning,
                "spread_context": spread_info,
                "depth_context": depth_info,
            },
            priority=SignalPriority.HIGH,
        )

        log.info(
            "execution.recommendation",
            symbol=symbol,
            order_type=order_type,
            urgency=urgency,
        )

    def _select_order_type(
        self,
        spread_info: dict,
        depth_info: dict,
        confidence: float,
    ) -> tuple[str, str]:
        """Select optimal order type based on conditions."""
        spread_pct = spread_info.get("spread_pct", 0.0) / 100  # Convert from percentage
        imbalance = depth_info.get("imbalance", 0.0)

        # Wide spread -> use limit order
        if spread_pct > self._wide_spread_threshold:
            return "limit", f"Wide spread ({spread_pct:.3%}) — use limit to avoid slippage"

        # Strong depth imbalance in our favor -> market is fine
        if abs(imbalance) > 0.3 and imbalance > 0:
            return "market", f"Favorable depth imbalance ({imbalance:.2f}) — market order OK"

        # High confidence + liquid -> market
        if confidence >= 0.8 and spread_pct < 0.001:
            return "market", f"High confidence ({confidence:.0%}) + tight spread — market order"

        # Default to limit
        return "limit", "Default to limit order for price protection"

    def _assess_urgency(self, confidence: float, depth_info: dict) -> str:
        """Assess how urgent the execution is."""
        if confidence >= 0.85:
            return "high"
        elif confidence >= 0.65:
            return "medium"
        return "low"

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "recommendations": self._recommendation_count,
            "tracked_spreads": len(self._spread_data),
            "tracked_depth": len(self._depth_data),
        })
        return base
