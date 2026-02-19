"""Integration tests: full trade lifecycle from signal to fill."""
import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus
from cortex.orchestrator.trade_pipeline import TradePipeline, PipelineStage
from cortex.squadrons.echo.risk_guardian import RiskGuardian


@pytest.mark.asyncio
async def test_full_trade_lifecycle():
    """Signal -> Risk Check -> Size -> Submit -> Fill."""
    bus = SignalBus()
    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: False)
    pipeline = TradePipeline(bus=bus, risk_guardian=guardian)

    order = await pipeline.process_entry_signal(
        symbol="MSFT", asset_class="equity", side="buy",
        entry_price=400.0, stop_loss=395.0,
        source_signal_id="sig_lifecycle", source_agent="test",
        nav=50000.0,
    )

    assert order.stage == PipelineStage.SUBMITTED
    assert order.quantity > 0
    # $500 cap: at $400/share, max 1 share
    assert order.quantity == 1
    assert order.quantity * 400.0 <= 500.0

    pipeline.mark_filled(order.order_id, fill_price=400.05)
    assert order.stage == PipelineStage.FILLED


@pytest.mark.asyncio
async def test_drawdown_blocks_trade():
    """High drawdown should reject the trade."""
    bus = SignalBus()
    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: False)
    pipeline = TradePipeline(bus=bus, risk_guardian=guardian)

    order = await pipeline.process_entry_signal(
        symbol="AAPL", asset_class="equity", side="buy",
        entry_price=150.0, stop_loss=145.0,
        source_signal_id="sig_dd", source_agent="test",
        nav=50000.0,
        daily_drawdown_pct=8.0,
    )

    assert order.stage == PipelineStage.REJECTED


@pytest.mark.asyncio
async def test_expensive_stock_rejected():
    """Stock priced above $500 should be rejected by notional cap."""
    bus = SignalBus()
    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: False)
    pipeline = TradePipeline(bus=bus, risk_guardian=guardian)

    order = await pipeline.process_entry_signal(
        symbol="BRK.A", asset_class="equity", side="buy",
        entry_price=600.0, stop_loss=590.0,
        source_signal_id="sig_exp", source_agent="test",
        nav=100000.0,
    )

    assert order.stage == PipelineStage.REJECTED
