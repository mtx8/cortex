"""Tests for SimulationEngine."""

import asyncio

import pytest
from unittest.mock import AsyncMock, MagicMock

from cortex.simulation.engine import SimulationEngine
from cortex.simulation.paper_portfolio import PaperPortfolio


@pytest.fixture
def bus():
    return MagicMock()


@pytest.fixture
def broadcaster():
    b = MagicMock()
    b.broadcast = AsyncMock()
    return b


@pytest.fixture
def engine(bus, broadcaster):
    return SimulationEngine(bus=bus, broadcaster=broadcaster)


def test_initial_state(engine):
    assert engine.running is False
    assert engine.portfolio is not None
    assert engine.portfolio.nav == 100_000.0


def test_to_dict(engine):
    d = engine.to_dict()
    assert d["running"] is False
    assert d["portfolio_nav"] == 100_000.0
    assert d["num_trades"] == 0


def test_stats_before_start(engine):
    stats = engine.stats
    assert stats["running"] is False
    assert stats["elapsed_seconds"] == 0
    assert stats["nav"] == 100_000.0


@pytest.mark.asyncio
async def test_start(engine):
    await engine.start(starting_capital=50_000.0)
    assert engine.running is True
    assert engine.portfolio.starting_capital == 50_000.0
    assert engine.portfolio.cash == 50_000.0

    # Clean up
    await engine.stop()


@pytest.mark.asyncio
async def test_start_idempotent(engine):
    """Calling start twice should be a no-op on the second call."""
    await engine.start(starting_capital=50_000.0)
    first_portfolio = engine.portfolio
    await engine.start(starting_capital=75_000.0)  # should be ignored
    assert engine.portfolio is first_portfolio
    assert engine.portfolio.starting_capital == 50_000.0

    await engine.stop()


@pytest.mark.asyncio
async def test_stop_returns_stats(engine):
    await engine.start(starting_capital=100_000.0)
    stats = await engine.stop()
    assert engine.running is False
    assert "nav" in stats
    assert "running" in stats
    assert stats["running"] is False


@pytest.mark.asyncio
async def test_stop_when_not_running(engine):
    """Stopping when never started should not raise."""
    stats = await engine.stop()
    assert stats["running"] is False


@pytest.mark.asyncio
async def test_stats_include_elapsed(engine):
    await engine.start()
    await asyncio.sleep(0.05)
    stats = engine.stats
    assert stats["elapsed_seconds"] > 0
    assert stats["running"] is True

    await engine.stop()


@pytest.mark.asyncio
async def test_broadcast_loop_calls_broadcaster(engine, broadcaster):
    """Verify the broadcast loop sends simulation updates."""
    await engine.start()
    # Let the broadcast loop fire at least once
    await asyncio.sleep(0.1)

    # Manually trigger a broadcast instead of waiting for the 2s loop
    await engine._broadcast_update()
    assert broadcaster.broadcast.called

    call_args = broadcaster.broadcast.call_args[0][0]
    assert call_args.type.value == "simulation_update"
    assert "nav" in call_args.payload
    assert "running" in call_args.payload

    await engine.stop()


@pytest.mark.asyncio
async def test_no_broadcaster(bus):
    """Engine works without a broadcaster."""
    engine = SimulationEngine(bus=bus, broadcaster=None)
    await engine.start()
    await engine._broadcast_update()  # should not raise
    await engine.stop()


@pytest.mark.asyncio
async def test_custom_portfolio(bus, broadcaster):
    """Engine can be initialized with a custom portfolio."""
    portfolio = PaperPortfolio(starting_capital=25_000.0)
    engine = SimulationEngine(bus=bus, portfolio=portfolio, broadcaster=broadcaster)
    assert engine.portfolio.starting_capital == 25_000.0

    # Starting resets portfolio
    await engine.start(starting_capital=50_000.0)
    assert engine.portfolio.starting_capital == 50_000.0
    await engine.stop()


@pytest.mark.asyncio
async def test_portfolio_trades_reflected_in_stats(engine):
    await engine.start(starting_capital=100_000.0)
    engine.portfolio.buy("AAPL", 10, 150.0)
    stats = engine.stats
    assert stats["num_trades"] == 1
    assert stats["num_positions"] == 1
    assert "AAPL" in stats["positions"]

    await engine.stop()
