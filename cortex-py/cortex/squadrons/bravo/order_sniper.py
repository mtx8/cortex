"""BRAVO Order Sniper — autonomous order execution agent.

Receives sized position signals from ECHO Risk Guardian and executes orders
via Interactive Brokers. Enforces a hard $500 notional cap for initial live
testing safety.

Pipeline position: ECHO (POSITION_SIZE) -> BRAVO (Order Sniper) -> IBKR
"""

from dataclasses import dataclass
from datetime import datetime, timezone
from enum import Enum
from typing import Optional

import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent
from cortex.storage.audit import AuditTrail, AuditEventType

log = structlog.get_logger()

# ---------------------------------------------------------------------------
# Hard safety cap — non-negotiable for initial live testing
# ---------------------------------------------------------------------------
_HARD_MAX_NOTIONAL: float = 500.0


class OrderType(str, Enum):
    MARKET = "market"
    LIMIT = "limit"
    STOP = "stop"
    STOP_LIMIT = "stop_limit"


class OrderSide(str, Enum):
    BUY = "buy"
    SELL = "sell"


@dataclass
class OrderRequest:
    symbol: str
    side: OrderSide
    quantity: int
    order_type: OrderType
    limit_price: Optional[float] = None
    stop_price: Optional[float] = None
    time_in_force: str = "DAY"
    max_notional: float = _HARD_MAX_NOTIONAL

    def __post_init__(self) -> None:
        # Clamp max_notional — cannot exceed the hard cap regardless of caller
        if self.max_notional > _HARD_MAX_NOTIONAL:
            self.max_notional = _HARD_MAX_NOTIONAL


@dataclass
class OrderResult:
    order_id: str
    status: str  # submitted | filled | rejected | cancelled
    fill_price: Optional[float] = None
    fill_quantity: Optional[int] = None
    commission: Optional[float] = None
    filled_at: Optional[datetime] = None
    rejection_reason: Optional[str] = None


class OrderSniper(BaseAgent):
    """BRAVO squadron order execution agent.

    Subscribes to POSITION_SIZE signals from ECHO Risk Guardian,
    validates orders against the hard notional cap, and submits them.
    In simulation mode (default), orders are filled locally with mock prices.
    """

    agent_id = "order_sniper"
    squadron = "bravo"
    subscriptions = [SignalTypes.POSITION_SIZE]

    def __init__(
        self,
        bus: SignalBus,
        audit: AuditTrail | None = None,
        simulation: bool = True,
        default_market_price: float = 100.0,
    ):
        super().__init__(bus)
        self._audit = audit or AuditTrail()
        self._simulation = simulation
        self._default_market_price = default_market_price

        # Order tracking
        self._pending_orders: dict[str, OrderRequest] = {}
        self._filled_today: int = 0
        self._submitted_today: int = 0
        self._order_seq: int = 0

    # ------------------------------------------------------------------
    # Properties
    # ------------------------------------------------------------------

    @property
    def pending_count(self) -> int:
        return len(self._pending_orders)

    @property
    def filled_today(self) -> int:
        return self._filled_today

    # ------------------------------------------------------------------
    # Signal handling
    # ------------------------------------------------------------------

    async def handle_signal(self, signal: Signal) -> None:
        """Route incoming signals to appropriate handlers."""
        if signal.signal_type == SignalTypes.POSITION_SIZE:
            await self._handle_position_size(signal)

    async def _handle_position_size(self, signal: Signal) -> None:
        """Extract order details from POSITION_SIZE signal and submit."""
        payload = signal.payload
        symbol = payload.get("symbol", "")
        quantity = payload.get("quantity", 0)
        side_str = payload.get("side", "buy").lower()
        side = OrderSide.BUY if side_str == "buy" else OrderSide.SELL
        entry_price = payload.get("entry_price")

        request = OrderRequest(
            symbol=symbol,
            side=side,
            quantity=quantity,
            order_type=OrderType.MARKET if entry_price is None else OrderType.LIMIT,
            limit_price=entry_price,
        )

        await self.submit_order(request)

    # ------------------------------------------------------------------
    # Order submission
    # ------------------------------------------------------------------

    async def submit_order(self, request: OrderRequest) -> OrderResult:
        """Submit an order after notional cap validation.

        Returns an OrderResult immediately. In simulation mode the order
        is filled at the limit price or a default simulated market price.
        """
        self._order_seq += 1
        order_id = f"BRV-{self._order_seq:06d}"

        # --- Notional cap validation ---
        reference_price = self._estimate_price(request)
        notional = request.quantity * reference_price

        if notional > request.max_notional:
            reason = (
                f"Notional ${notional:.2f} exceeds hard cap "
                f"${request.max_notional:.2f} "
                f"({request.quantity} x ${reference_price:.2f})"
            )
            log.warning(
                "order.rejected_notional",
                order_id=order_id,
                symbol=request.symbol,
                notional=notional,
                cap=request.max_notional,
            )
            self._audit.log_order(
                event_type=AuditEventType.ORDER_REJECTED,
                source_agent=self.agent_id,
                order_id=order_id,
                symbol=request.symbol,
                message=reason,
            )
            await self.emit(
                SignalTypes.ORDER_REJECTED,
                payload={
                    "order_id": order_id,
                    "symbol": request.symbol,
                    "reason": reason,
                },
                priority=SignalPriority.HIGH,
            )
            return OrderResult(
                order_id=order_id,
                status="rejected",
                rejection_reason=reason,
            )

        # --- Track as pending ---
        self._pending_orders[order_id] = request
        self._submitted_today += 1

        self._audit.log_order(
            event_type=AuditEventType.ORDER_SUBMITTED,
            source_agent=self.agent_id,
            order_id=order_id,
            symbol=request.symbol,
            message=(
                f"{request.side.value.upper()} {request.quantity} "
                f"{request.symbol} @ {request.order_type.value}"
            ),
        )

        await self.emit(
            SignalTypes.ORDER_SUBMITTED,
            payload={
                "order_id": order_id,
                "symbol": request.symbol,
                "side": request.side.value,
                "quantity": request.quantity,
                "order_type": request.order_type.value,
                "limit_price": request.limit_price,
                "stop_price": request.stop_price,
            },
            priority=SignalPriority.HIGH,
        )

        log.info(
            "order.submitted",
            order_id=order_id,
            symbol=request.symbol,
            side=request.side.value,
            quantity=request.quantity,
            order_type=request.order_type.value,
        )

        # --- Execute (simulation or live) ---
        if self._simulation:
            return self._simulate_fill(order_id, request, reference_price)

        # Live execution placeholder — will route through IBKRConnectionManager
        return OrderResult(order_id=order_id, status="submitted")

    # ------------------------------------------------------------------
    # Cancellation
    # ------------------------------------------------------------------

    async def cancel_order(self, order_id: str) -> bool:
        """Cancel a pending order. Returns True if successfully cancelled."""
        if order_id not in self._pending_orders:
            log.warning("order.cancel_not_found", order_id=order_id)
            return False

        request = self._pending_orders.pop(order_id)
        self._audit.log_order(
            event_type=AuditEventType.ORDER_CANCELLED,
            source_agent=self.agent_id,
            order_id=order_id,
            symbol=request.symbol,
            message=f"Cancelled pending {request.order_type.value} order",
        )
        log.info("order.cancelled", order_id=order_id, symbol=request.symbol)
        return True

    # ------------------------------------------------------------------
    # Daily reset
    # ------------------------------------------------------------------

    def reset_daily(self) -> None:
        """Clear daily counters. Called at market open by orchestrator."""
        self._filled_today = 0
        self._submitted_today = 0
        self._pending_orders.clear()
        log.info("order_sniper.daily_reset")

    # ------------------------------------------------------------------
    # Internal helpers
    # ------------------------------------------------------------------

    def _estimate_price(self, request: OrderRequest) -> float:
        """Return the best reference price for notional calculation."""
        if request.order_type == OrderType.LIMIT and request.limit_price is not None:
            return request.limit_price
        if request.order_type == OrderType.STOP and request.stop_price is not None:
            return request.stop_price
        if request.order_type == OrderType.STOP_LIMIT:
            if request.limit_price is not None:
                return request.limit_price
            if request.stop_price is not None:
                return request.stop_price
        # Market orders or missing prices: use default simulated price
        return self._default_market_price

    def _simulate_fill(
        self, order_id: str, request: OrderRequest, reference_price: float
    ) -> OrderResult:
        """Produce a simulated fill for paper-trading / testing."""
        fill_price = reference_price
        now = datetime.now(timezone.utc)

        # Remove from pending
        self._pending_orders.pop(order_id, None)
        self._filled_today += 1

        self._audit.log_order(
            event_type=AuditEventType.ORDER_FILLED,
            source_agent=self.agent_id,
            order_id=order_id,
            symbol=request.symbol,
            message=(
                f"SIM FILL {request.side.value.upper()} {request.quantity} "
                f"{request.symbol} @ ${fill_price:.2f}"
            ),
        )

        log.info(
            "order.sim_filled",
            order_id=order_id,
            symbol=request.symbol,
            fill_price=fill_price,
            quantity=request.quantity,
        )

        return OrderResult(
            order_id=order_id,
            status="filled",
            fill_price=fill_price,
            fill_quantity=request.quantity,
            commission=0.0,
            filled_at=now,
        )

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "pending_count": self.pending_count,
            "filled_today": self._filled_today,
            "submitted_today": self._submitted_today,
            "simulation": self._simulation,
        })
        return base
