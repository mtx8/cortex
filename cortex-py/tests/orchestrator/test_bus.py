import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority


@pytest.mark.asyncio
async def test_bus_publishes_and_delivers():
    bus = SignalBus()
    received = []

    async def handler(signal: Signal):
        received.append(signal)

    bus.subscribe("test.signal", handler)

    task = asyncio.create_task(bus.run())

    await bus.publish(Signal(
        signal_id="s1",
        source_agent="test_agent",
        source_squadron="alpha",
        signal_type="test.signal",
        payload={"ticker": "AAPL"},
        priority=SignalPriority.NORMAL,
    ))

    await asyncio.sleep(0.05)
    task.cancel()

    assert len(received) == 1
    assert received[0].payload["ticker"] == "AAPL"


@pytest.mark.asyncio
async def test_bus_priority_ordering():
    bus = SignalBus()
    received = []

    async def handler(signal: Signal):
        received.append(signal.signal_id)

    bus.subscribe_all(handler)

    # Publish low priority first, then critical
    await bus.publish(Signal(
        signal_id="low",
        source_agent="a", source_squadron="a",
        signal_type="x", payload={},
        priority=SignalPriority.LOW,
    ))
    await bus.publish(Signal(
        signal_id="critical",
        source_agent="a", source_squadron="a",
        signal_type="x", payload={},
        priority=SignalPriority.CRITICAL,
    ))

    task = asyncio.create_task(bus.run())
    await asyncio.sleep(0.05)
    task.cancel()

    assert received[0] == "critical"
    assert received[1] == "low"


@pytest.mark.asyncio
async def test_bus_wildcard_subscriber():
    bus = SignalBus()
    received = []

    async def handler(signal: Signal):
        received.append(signal.signal_type)

    bus.subscribe_all(handler)

    task = asyncio.create_task(bus.run())

    await bus.publish(Signal(
        signal_id="s1", source_agent="a", source_squadron="a",
        signal_type="alpha.signal", payload={},
        priority=SignalPriority.NORMAL,
    ))
    await bus.publish(Signal(
        signal_id="s2", source_agent="a", source_squadron="a",
        signal_type="echo.risk_breach", payload={},
        priority=SignalPriority.CRITICAL,
    ))

    await asyncio.sleep(0.05)
    task.cancel()

    assert "alpha.signal" in received
    assert "echo.risk_breach" in received
