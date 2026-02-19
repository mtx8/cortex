"""Risk Guardian — master controller that aggregates all risk subsystems.
Every order proposal flows through the Risk Guardian before execution.

Pipeline: Signal → Risk Guardian → [Position Sizer + PreTradeCheck + Drawdown Shield] → approved/rejected

The Risk Guardian is the single entry point for all risk decisions.
It coordinates the KillSwitch, DrawdownShield, PositionSizer, and PreTradeCheck."""

import time
from dataclasses import dataclass, field
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent
from cortex.squadrons.echo.risk_checks import PreTradeCheck, OrderRequest, PortfolioState, CheckResult
from cortex.squadrons.echo.position_sizer import PositionSizer, SizingRequest, SizingResult
from cortex.squadrons.echo.drawdown_shield import DrawdownShield, DrawdownState, DrawdownLevel

log = structlog.get_logger()


@dataclass
class RiskDecision:
    approved: bool
    sizing: SizingResult | None = None
    pre_trade: CheckResult | None = None
    drawdown: DrawdownState | None = None
    throttle_factor: float = 1.0
    rejections: list[str] = field(default_factory=list)
    decision_time_ms: float = 0.0


class RiskGuardian(BaseAgent):
    agent_id = "risk_guardian"
    squadron = "echo"
    subscriptions = [
        SignalTypes.ENTRY_SIGNAL,
        SignalTypes.ORDER_FILLED,
    ]

    def __init__(
        self,
        bus: SignalBus,
        kill_switch_check: callable,  # () -> bool
        pre_trade: PreTradeCheck | None = None,
        position_sizer: PositionSizer | None = None,
        drawdown_shield: DrawdownShield | None = None,
    ):
        super().__init__(bus)
        self._is_kill_switch_engaged = kill_switch_check
        self._pre_trade = pre_trade or PreTradeCheck()
        self._sizer = position_sizer or PositionSizer()
        self._drawdown = drawdown_shield or DrawdownShield()
        self._decisions_approved = 0
        self._decisions_rejected = 0

    async def handle_signal(self, signal: Signal) -> None:
        if signal.signal_type == SignalTypes.ENTRY_SIGNAL:
            await self._handle_entry_signal(signal)
        elif signal.signal_type == SignalTypes.ORDER_FILLED:
            # Track fills for drawdown calculation
            pass

    async def _handle_entry_signal(self, signal: Signal) -> None:
        """Process an entry signal through the full risk pipeline."""
        payload = signal.payload
        decision = self.evaluate(
            symbol=payload.get("symbol", ""),
            asset_class=payload.get("asset_class", "equity"),
            entry_price=payload.get("entry_price", 0.0),
            stop_loss_price=payload.get("stop_loss", 0.0),
            side=payload.get("side", "buy"),
            nav=payload.get("nav", 0.0),
            daily_drawdown_pct=payload.get("daily_drawdown_pct", 0.0),
            weekly_drawdown_pct=payload.get("weekly_drawdown_pct", 0.0),
            total_drawdown_pct=payload.get("total_drawdown_pct", 0.0),
            position_count=payload.get("position_count", 0),
            daily_trade_count=payload.get("daily_trade_count", 0),
            win_rate=payload.get("win_rate"),
            avg_win=payload.get("avg_win"),
            avg_loss=payload.get("avg_loss"),
            volatility=payload.get("volatility"),
        )

        if decision.approved:
            await self.emit(
                SignalTypes.POSITION_SIZE,
                payload={
                    "symbol": payload.get("symbol"),
                    "quantity": decision.sizing.recommended_quantity if decision.sizing else 0,
                    "dollar_amount": decision.sizing.recommended_dollar_amount if decision.sizing else 0,
                    "method": decision.sizing.method_used if decision.sizing else "none",
                    "throttle_factor": decision.throttle_factor,
                    "source_signal_id": signal.signal_id,
                },
                priority=SignalPriority.HIGH,
            )
        else:
            await self.emit(
                SignalTypes.RISK_BREACH,
                payload={
                    "symbol": payload.get("symbol"),
                    "rejections": decision.rejections,
                    "source_signal_id": signal.signal_id,
                },
                priority=SignalPriority.HIGH,
            )

    def evaluate(
        self,
        symbol: str,
        asset_class: str,
        entry_price: float,
        stop_loss_price: float,
        side: str,
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
    ) -> RiskDecision:
        """Synchronous evaluation of a trade proposal through all risk subsystems.
        This is the core method — must be fast (<10ms target)."""
        start = time.perf_counter()
        rejections: list[str] = []

        # 1. Check kill switch (instant, in-memory)
        is_halted = self._is_kill_switch_engaged()

        # 2. Get drawdown state
        drawdown_state = self._drawdown.get_state()
        if drawdown_state.should_engage_kill_switch:
            rejections.append(f"Kill switch triggered by drawdown: {drawdown_state.message}")
            return RiskDecision(
                approved=False,
                drawdown=drawdown_state,
                rejections=rejections,
                decision_time_ms=(time.perf_counter() - start) * 1000,
            )

        # 3. Run pre-trade checks
        order = OrderRequest(
            symbol=symbol,
            quantity=1,  # Will be sized by PositionSizer
            estimated_price=entry_price,
            asset_class=asset_class,
            side=side,
        )
        portfolio = PortfolioState(
            nav=nav,
            daily_drawdown_pct=daily_drawdown_pct,
            weekly_drawdown_pct=weekly_drawdown_pct,
            total_drawdown_pct=total_drawdown_pct,
            position_count=position_count,
            daily_trade_count=daily_trade_count,
        )
        pre_trade_result = self._pre_trade.run(order, portfolio, is_halted)

        if not pre_trade_result.approved:
            self._decisions_rejected += 1
            return RiskDecision(
                approved=False,
                pre_trade=pre_trade_result,
                drawdown=drawdown_state,
                rejections=pre_trade_result.rejections,
                decision_time_ms=(time.perf_counter() - start) * 1000,
            )

        # 4. Calculate position size
        sizing_request = SizingRequest(
            symbol=symbol,
            asset_class=asset_class,
            entry_price=entry_price,
            stop_loss_price=stop_loss_price,
            nav=nav,
            win_rate=win_rate,
            avg_win=avg_win,
            avg_loss=avg_loss,
            volatility=volatility,
        )
        sizing = self._sizer.calculate(sizing_request)

        if sizing.recommended_quantity <= 0:
            self._decisions_rejected += 1
            rejections.append(f"Position sizer returned 0 quantity ({sizing.method_used})")
            return RiskDecision(
                approved=False,
                sizing=sizing,
                pre_trade=pre_trade_result,
                drawdown=drawdown_state,
                rejections=rejections,
                decision_time_ms=(time.perf_counter() - start) * 1000,
            )

        # 5. Apply throttle factor from drawdown shield
        throttle = drawdown_state.throttle_factor
        if throttle < 1.0:
            original_qty = sizing.recommended_quantity
            sizing.recommended_quantity = max(1, int(sizing.recommended_quantity * throttle))
            sizing.recommended_dollar_amount = sizing.recommended_quantity * entry_price
            sizing.position_pct_of_nav = (sizing.recommended_dollar_amount / nav) * 100 if nav > 0 else 0
            log.info(
                "risk.throttled",
                symbol=symbol,
                original_qty=original_qty,
                throttled_qty=sizing.recommended_quantity,
                factor=throttle,
            )

        self._decisions_approved += 1
        duration = (time.perf_counter() - start) * 1000

        log.info(
            "risk.approved",
            symbol=symbol,
            quantity=sizing.recommended_quantity,
            method=sizing.method_used,
            duration_ms=f"{duration:.2f}",
        )

        return RiskDecision(
            approved=True,
            sizing=sizing,
            pre_trade=pre_trade_result,
            drawdown=drawdown_state,
            throttle_factor=throttle,
            decision_time_ms=duration,
        )

    @property
    def decisions_approved(self) -> int:
        return self._decisions_approved

    @property
    def decisions_rejected(self) -> int:
        return self._decisions_rejected

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "decisions_approved": self._decisions_approved,
            "decisions_rejected": self._decisions_rejected,
        })
        return base
