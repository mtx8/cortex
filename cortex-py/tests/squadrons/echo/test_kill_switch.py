import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.echo.kill_switch import KillSwitchCommander, KillSwitchState


@pytest.mark.asyncio
async def test_kill_switch_starts_inactive():
    bus = SignalBus()
    ks = KillSwitchCommander(bus)
    assert ks.state == KillSwitchState.ARMED


@pytest.mark.asyncio
async def test_kill_switch_engages():
    bus = SignalBus()
    ks = KillSwitchCommander(bus)
    ks.register()

    killed_signals = []

    async def capture(s):
        killed_signals.append(s)

    bus.subscribe(SignalTypes.KILL_SWITCH, capture)

    task = asyncio.create_task(bus.run())
    await ks.engage(reason="manual", triggered_by="user")
    await asyncio.sleep(0.05)
    task.cancel()

    assert ks.state == KillSwitchState.ENGAGED
    assert len(killed_signals) == 1
    assert killed_signals[0].payload["reason"] == "manual"


@pytest.mark.asyncio
async def test_kill_switch_blocks_when_engaged():
    bus = SignalBus()
    ks = KillSwitchCommander(bus)
    await ks.engage(reason="test", triggered_by="test")
    assert ks.is_halted is True


@pytest.mark.asyncio
async def test_kill_switch_disengage_requires_manual():
    bus = SignalBus()
    ks = KillSwitchCommander(bus)
    await ks.engage(reason="drawdown", triggered_by="drawdown_shield")

    ks.disengage(operator="user")
    assert ks.state == KillSwitchState.ARMED
    assert ks.is_halted is False
