"""TradePipeline — enforced execution sequence for all trades.

Pipeline: Entry Signal → Risk Guardian → Position Size → Pre-Trade Check
→ FOXTROT Wash Sale → Order Submission → Fill Confirmation

NO trade bypasses this pipeline. ECHO has absolute override authority.
"""

import asyncio
import time
from dataclasses import dataclass, field
from enum import Enum
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.echo.risk_guardian import RiskGuardian, RiskDecision

log = structlog.get_logger()


class PipelineStage(str, Enum):
    RECEIVED = "received"
    RISK_CHECK = "risk_check"
    SIZED = "sized"
    WASH_SALE_CHECK = "wash_sale_check"
    SUBMITTED = "submitted"
    FILLED = "filled"
    REJECTED = "rejected"
    CANCELLED = "cancelled"


@dataclass
class PipelineOrder:
    order_id: str
    symbol: str
    asset_class: str
    side: str
    entry_price: float
    stop_loss: float
    source_signal_id: str
    source_agent: str
    stage: PipelineStage = PipelineStage.RECEIVED
    quantity: int = 0
    sizing_method: str = ""
    risk_decision: RiskDecision | None = None
    rejections: list[str] = field(default_factory=list)
    created_at: float = field(default_factory=time.time)
    completed_at: float | None = None


class TradePipeline:
    """Enforced execution sequence. Every order flows through here.
    The pipeline is synchronous in decision-making (fast path),
    async only for I/O operations (order submission)."""

    # Hard safety cap — non-negotiable for initial live testing.
    # This is the absolute maximum notional value per trade.
    HARD_MAX_NOTIONAL: float = 500.0

    def __init__(
        self,
        bus: SignalBus,
        risk_guardian: RiskGuardian,
    ):
        self._bus = bus
        self._risk_guardian = risk_guardian
        self._orders: dict[str, PipelineOrder] = {}
        self._order_seq = 0
        self._orders_submitted = 0
        self._orders_rejected = 0

    async def process_entry_signal(
        self,
        symbol: str,
        asset_class: str,
        side: str,
        entry_price: float,
        stop_loss: float,
        source_signal_id: str,
        source_agent: str,
        nav: float,
        daily_drawdown_pct: float = 0.0,
        weekly_drawdown_pct: float = 0.0,
        total_drawdown_pct: float = 0.0,
        position_count: int = 0,
        daily_trade_count: int = 0,
        win_rate: float | None = None,
        avg_win: float | None = None,
        avg_loss: float | None = None,
        volatility: float | None = None,
    ) -> PipelineOrder:
        """Process an entry signal through the full pipeline."""
        self._order_seq += 1
        order_id = f"ORD-{self._order_seq:06d}"

        order = PipelineOrder(
            order_id=order_id,
            symbol=symbol,
            asset_class=asset_class,
            side=side,
            entry_price=entry_price,
            stop_loss=stop_loss,
            source_signal_id=source_signal_id,
            source_agent=source_agent,
        )
        self._orders[order_id] = order

        # Stage 1: Risk Guardian evaluation
        order.stage = PipelineStage.RISK_CHECK
        decision = self._risk_guardian.evaluate(
            symbol=symbol,
            asset_class=asset_class,
            entry_price=entry_price,
            stop_loss_price=stop_loss,
            side=side,
            nav=nav,
            daily_drawdown_pct=daily_drawdown_pct,
            weekly_drawdown_pct=weekly_drawdown_pct,
            total_drawdown_pct=total_drawdown_pct,
            position_count=position_count,
            daily_trade_count=daily_trade_count,
            win_rate=win_rate,
            avg_win=avg_win,
            avg_loss=avg_loss,
            volatility=volatility,
        )

        order.risk_decision = decision

        if not decision.approved:
            order.stage = PipelineStage.REJECTED
            order.rejections = decision.rejections
            order.completed_at = time.time()
            self._orders_rejected += 1

            log.warning(
                "pipeline.rejected",
                order_id=order_id,
                symbol=symbol,
                rejections=decision.rejections,
            )
            return order

        # Stage 2: Apply sizing
        order.stage = PipelineStage.SIZED
        if decision.sizing:
            order.quantity = decision.sizing.recommended_quantity
            order.sizing_method = decision.sizing.method_used

        # Stage 2b: Hard notional cap — $500 max per trade (non-negotiable)
        notional = order.quantity * entry_price
        if notional > self.HARD_MAX_NOTIONAL:
            # Reduce quantity to fit within cap
            capped_qty = int(self.HARD_MAX_NOTIONAL / entry_price)
            if capped_qty < 1:
                order.stage = PipelineStage.REJECTED
                order.rejections.append(
                    f"Single share ${entry_price:.2f} exceeds "
                    f"hard cap ${self.HARD_MAX_NOTIONAL:.2f}"
                )
                order.completed_at = time.time()
                self._orders_rejected += 1
                log.warning(
                    "pipeline.notional_cap_reject",
                    order_id=order_id, symbol=symbol,
                    notional=notional, cap=self.HARD_MAX_NOTIONAL,
                )
                return order
            log.info(
                "pipeline.notional_cap_reduced",
                order_id=order_id, symbol=symbol,
                original_qty=order.quantity, capped_qty=capped_qty,
                notional=capped_qty * entry_price,
                cap=self.HARD_MAX_NOTIONAL,
            )
            order.quantity = capped_qty

        # Stage 3: Wash sale check placeholder (FOXTROT will implement)
        order.stage = PipelineStage.WASH_SALE_CHECK
        # TODO: Check FOXTROT wash sale guard when implemented
        # For now, pass through

        # Stage 4: Submit order
        order.stage = PipelineStage.SUBMITTED
        self._orders_submitted += 1

        log.info(
            "pipeline.submitted",
            order_id=order_id,
            symbol=symbol,
            quantity=order.quantity,
            side=side,
            sizing_method=order.sizing_method,
        )

        # Emit order submission signal
        await self._bus.publish(Signal(
            signal_id=f"pipeline_{order_id}",
            source_agent="trade_pipeline",
            source_squadron="orchestrator",
            signal_type=SignalTypes.ORDER_SUBMITTED,
            payload={
                "order_id": order_id,
                "symbol": symbol,
                "asset_class": asset_class,
                "side": side,
                "quantity": order.quantity,
                "entry_price": entry_price,
                "stop_loss": stop_loss,
                "sizing_method": order.sizing_method,
            },
            priority=SignalPriority.HIGH,
        ))

        return order

    def get_order(self, order_id: str) -> PipelineOrder | None:
        return self._orders.get(order_id)

    def mark_filled(self, order_id: str, fill_price: float) -> None:
        order = self._orders.get(order_id)
        if order:
            order.stage = PipelineStage.FILLED
            order.completed_at = time.time()
            log.info("pipeline.filled", order_id=order_id, fill_price=fill_price)

    def mark_cancelled(self, order_id: str, reason: str) -> None:
        order = self._orders.get(order_id)
        if order:
            order.stage = PipelineStage.CANCELLED
            order.completed_at = time.time()
            order.rejections.append(f"Cancelled: {reason}")

    @property
    def orders_submitted(self) -> int:
        return self._orders_submitted

    @property
    def orders_rejected(self) -> int:
        return self._orders_rejected

    @property
    def pending_orders(self) -> list[PipelineOrder]:
        return [o for o in self._orders.values() if o.stage == PipelineStage.SUBMITTED]

    def to_dict(self) -> dict:
        return {
            "orders_submitted": self._orders_submitted,
            "orders_rejected": self._orders_rejected,
            "pending_count": len(self.pending_orders),
            "total_orders": len(self._orders),
        }
