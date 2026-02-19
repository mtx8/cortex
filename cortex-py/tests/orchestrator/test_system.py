import pytest
import asyncio
from cortex.orchestrator.system import SystemOrchestrator, AgentHealth
from cortex.orchestrator.bus import SignalBus
from cortex.orchestrator.autonomy import AutonomyDial


def test_orchestrator_creation():
    bus = SignalBus()
    dial = AutonomyDial()
    orch = SystemOrchestrator(bus=bus, autonomy=dial)
    assert orch.agent_count == 0
    assert orch.is_running is False


def test_register_agent():
    bus = SignalBus()
    orch = SystemOrchestrator(bus=bus, autonomy=AutonomyDial())
    from cortex.squadrons.echo.kill_switch import KillSwitchCommander
    agent = KillSwitchCommander(bus=bus)
    orch.register_agent(agent)
    assert orch.agent_count == 1


def test_health_check():
    health = AgentHealth(
        agent_id="test", squadron="alpha",
        status="active", signal_count=10, error_count=0,
        last_signal_ts=1000.0,
    )
    assert health.is_healthy is True


def test_health_check_error_threshold():
    health = AgentHealth(
        agent_id="test", squadron="alpha",
        status="active", signal_count=10, error_count=8,
        last_signal_ts=1000.0,
    )
    assert health.is_healthy is False


def test_get_squadron_health():
    bus = SignalBus()
    orch = SystemOrchestrator(bus=bus, autonomy=AutonomyDial())
    from cortex.squadrons.alpha.signal_hunter import SignalHunter
    agent = SignalHunter(bus=bus)
    orch.register_agent(agent)
    health = orch.get_squadron_health("alpha")
    assert len(health) == 1


def test_to_dict():
    bus = SignalBus()
    orch = SystemOrchestrator(bus=bus, autonomy=AutonomyDial())
    d = orch.to_dict()
    assert "agent_count" in d
    assert "is_running" in d
    assert "autonomy" in d


@pytest.mark.asyncio
async def test_orchestrator_start_stop():
    bus = SignalBus()
    orch = SystemOrchestrator(bus=bus, autonomy=AutonomyDial())
    task = asyncio.create_task(orch.start())
    await asyncio.sleep(0.05)
    assert orch.is_running is True
    await orch.stop()
    task.cancel()
