import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.squadrons.base import BaseAgent


class MockAgent(BaseAgent):
    agent_id = "mock_agent"
    squadron = "test"
    subscriptions = ["test.signal"]

    def __init__(self, bus: SignalBus):
        super().__init__(bus)
        self.received: list[Signal] = []

    async def handle_signal(self, signal: Signal) -> None:
        self.received.append(signal)


@pytest.mark.asyncio
async def test_agent_receives_subscribed_signals():
    bus = SignalBus()
    agent = MockAgent(bus)
    agent.register()

    task = asyncio.create_task(bus.run())

    await bus.publish(Signal(
        signal_id="s1", source_agent="test", source_squadron="test",
        signal_type="test.signal", payload={"data": 1},
        priority=SignalPriority.NORMAL,
    ))
    await asyncio.sleep(0.05)
    task.cancel()

    assert len(agent.received) == 1
    assert agent.received[0].payload["data"] == 1


@pytest.mark.asyncio
async def test_agent_ignores_unsubscribed_signals():
    bus = SignalBus()
    agent = MockAgent(bus)
    agent.register()

    task = asyncio.create_task(bus.run())

    await bus.publish(Signal(
        signal_id="s1", source_agent="test", source_squadron="test",
        signal_type="other.signal", payload={},
        priority=SignalPriority.NORMAL,
    ))
    await asyncio.sleep(0.05)
    task.cancel()

    assert len(agent.received) == 0


@pytest.mark.asyncio
async def test_agent_status_tracking():
    bus = SignalBus()
    agent = MockAgent(bus)
    assert agent.status == "idle"

    agent.register()
    assert agent.status == "active"
