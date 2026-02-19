import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.echo.risk_guardian import RiskGuardian, RiskDecision
from cortex.squadrons.echo.risk_checks import PreTradeCheck
from cortex.squadrons.echo.position_sizer import PositionSizer
from cortex.squadrons.echo.drawdown_shield import DrawdownShield


def make_guardian(
    is_halted: bool = False,
    daily_throttle: float = 5.0,
    daily_halt: float = 7.0,
) -> RiskGuardian:
    bus = SignalBus()
    return RiskGuardian(
        bus=bus,
        kill_switch_check=lambda: is_halted,
        pre_trade=PreTradeCheck(
            max_position_pct=5.0,
            max_concurrent=15,
            max_daily_trades=50,
            daily_drawdown_halt_pct=daily_halt,
        ),
        position_sizer=PositionSizer(
            max_position_pct=5.0,
            fixed_fractional_pct=1.0,
            max_single_loss_usd=500.0,
        ),
        drawdown_shield=DrawdownShield(
            daily_throttle_pct=daily_throttle,
            daily_halt_pct=daily_halt,
        ),
    )


def test_guardian_approves_valid_trade():
    """Valid trade within all limits gets approved."""
    guardian = make_guardian()
    decision = guardian.evaluate(
        symbol="AAPL",
        asset_class="equity",
        entry_price=150.0,
        stop_loss_price=145.0,
        side="buy",
        nav=50000.0,
        position_count=5,
        daily_trade_count=10,
    )
    assert decision.approved is True
    assert decision.sizing is not None
    assert decision.sizing.recommended_quantity >= 1
    assert decision.decision_time_ms < 100  # Fast


def test_guardian_rejects_when_halted():
    """Kill switch engaged blocks all trades."""
    guardian = make_guardian(is_halted=True)
    decision = guardian.evaluate(
        symbol="AAPL",
        asset_class="equity",
        entry_price=150.0,
        stop_loss_price=145.0,
        side="buy",
        nav=50000.0,
    )
    assert decision.approved is False
    assert any("HALTED" in r for r in decision.rejections)


def test_guardian_rejects_drawdown_breach():
    """High daily drawdown blocks new trades."""
    guardian = make_guardian(daily_halt=7.0)
    decision = guardian.evaluate(
        symbol="AAPL",
        asset_class="equity",
        entry_price=150.0,
        stop_loss_price=145.0,
        side="buy",
        nav=50000.0,
        daily_drawdown_pct=8.0,  # Over 7% halt
    )
    assert decision.approved is False


def test_guardian_uses_kelly_when_available():
    """With trade history, Kelly sizing is used."""
    guardian = make_guardian()
    decision = guardian.evaluate(
        symbol="AAPL",
        asset_class="equity",
        entry_price=150.0,
        stop_loss_price=145.0,
        side="buy",
        nav=50000.0,
        win_rate=0.55,
        avg_win=200.0,
        avg_loss=100.0,
    )
    assert decision.approved is True
    assert decision.sizing is not None
    assert decision.sizing.method_used == "quarter_kelly"


def test_guardian_tracks_decisions():
    """Guardian tracks approved/rejected counts."""
    guardian = make_guardian()

    # Approved trade
    guardian.evaluate(
        symbol="AAPL", asset_class="equity",
        entry_price=150.0, stop_loss_price=145.0,
        side="buy", nav=50000.0,
    )
    assert guardian.decisions_approved == 1
    assert guardian.decisions_rejected == 0

    # Rejected trade (halted)
    guardian._is_kill_switch_engaged = lambda: True
    guardian.evaluate(
        symbol="MSFT", asset_class="equity",
        entry_price=400.0, stop_loss_price=390.0,
        side="buy", nav=50000.0,
    )
    assert guardian.decisions_rejected == 1


@pytest.mark.asyncio
async def test_guardian_emits_position_size_signal():
    """Approved trade emits POSITION_SIZE signal on the bus."""
    bus = SignalBus()
    guardian = RiskGuardian(
        bus=bus,
        kill_switch_check=lambda: False,
    )
    guardian.register()

    emitted = []
    bus.subscribe(SignalTypes.POSITION_SIZE, lambda s: emitted.append(s))

    task = asyncio.create_task(bus.run())

    # Simulate an entry signal
    await bus.publish(Signal(
        signal_id="test_entry",
        source_agent="signal_hunter",
        source_squadron="alpha",
        signal_type=SignalTypes.ENTRY_SIGNAL,
        payload={
            "symbol": "AAPL",
            "asset_class": "equity",
            "entry_price": 150.0,
            "stop_loss": 145.0,
            "side": "buy",
            "nav": 50000.0,
            "daily_drawdown_pct": 0.0,
            "weekly_drawdown_pct": 0.0,
            "total_drawdown_pct": 0.0,
            "position_count": 5,
            "daily_trade_count": 10,
        },
        priority=SignalPriority.NORMAL,
    ))

    await asyncio.sleep(0.1)
    task.cancel()

    assert len(emitted) == 1
    assert emitted[0].payload["symbol"] == "AAPL"
    assert emitted[0].payload["quantity"] > 0


@pytest.mark.asyncio
async def test_guardian_emits_risk_breach_when_halted():
    """Rejected trade emits RISK_BREACH signal."""
    bus = SignalBus()
    guardian = RiskGuardian(
        bus=bus,
        kill_switch_check=lambda: True,  # Halted
    )
    guardian.register()

    breaches = []
    bus.subscribe(SignalTypes.RISK_BREACH, lambda s: breaches.append(s))

    task = asyncio.create_task(bus.run())

    await bus.publish(Signal(
        signal_id="test_entry_halted",
        source_agent="signal_hunter",
        source_squadron="alpha",
        signal_type=SignalTypes.ENTRY_SIGNAL,
        payload={
            "symbol": "MSFT",
            "asset_class": "equity",
            "entry_price": 400.0,
            "stop_loss": 390.0,
            "side": "buy",
            "nav": 50000.0,
        },
        priority=SignalPriority.NORMAL,
    ))

    await asyncio.sleep(0.1)
    task.cancel()

    assert len(breaches) == 1
    assert "MSFT" in breaches[0].payload["symbol"]
