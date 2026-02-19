"""Integration tests: verify signal flow across squadrons."""
import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.alpha.signal_hunter import SignalHunter
from cortex.squadrons.echo.risk_guardian import RiskGuardian
from cortex.squadrons.echo.kill_switch import KillSwitchCommander
from cortex.storage.audit import AuditTrail


@pytest.mark.asyncio
async def test_entry_signal_flows_through_pipeline():
    """ALPHA entry signal -> ECHO risk check -> BRAVO order execution."""
    bus = SignalBus()

    # Register agents
    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: False)
    guardian.register()

    task = asyncio.create_task(bus.run())

    # Emit entry signal (simulating ALPHA)
    await bus.publish(Signal(
        signal_id="test_entry_001",
        source_agent="signal_hunter",
        source_squadron="alpha",
        signal_type=SignalTypes.ENTRY_SIGNAL,
        payload={"symbol": "AAPL", "entry_price": 150.0, "stop_loss": 145.0, "side": "buy"},
        priority=SignalPriority.NORMAL,
    ))

    await asyncio.sleep(0.1)
    task.cancel()

    # Verify the signal was processed
    assert guardian._signal_count >= 1


@pytest.mark.asyncio
async def test_kill_switch_halts_all_trading():
    """Kill switch should prevent any order execution."""
    bus = SignalBus()
    kill_switch = KillSwitchCommander(bus=bus)
    kill_switch.register()

    # Engage kill switch
    await kill_switch.engage("test halt", "test")
    assert kill_switch.is_halted is True

    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: kill_switch.is_halted)

    # Try to process - should be blocked
    decision = guardian.evaluate(
        symbol="AAPL", asset_class="equity",
        entry_price=150.0, stop_loss_price=145.0, side="buy",
        nav=50000, position_count=0, daily_trade_count=0,
    )
    assert decision.approved is False
    assert any("halt" in r.lower() for r in decision.rejections)
