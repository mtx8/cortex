import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus
from cortex.orchestrator.trade_pipeline import (
    TradePipeline,
    PipelineOrder,
    PipelineStage,
)
from cortex.squadrons.echo.risk_guardian import RiskGuardian
from cortex.squadrons.echo.risk_checks import PreTradeCheck
from cortex.squadrons.echo.position_sizer import PositionSizer
from cortex.squadrons.echo.drawdown_shield import DrawdownShield


def make_pipeline(is_halted: bool = False) -> TradePipeline:
    bus = SignalBus()
    guardian = RiskGuardian(
        bus=bus,
        kill_switch_check=lambda: is_halted,
        pre_trade=PreTradeCheck(
            max_position_pct=5.0,
            max_concurrent=15,
            max_daily_trades=50,
        ),
        position_sizer=PositionSizer(
            max_position_pct=5.0,
            max_single_loss_usd=500.0,
        ),
        drawdown_shield=DrawdownShield(),
    )
    return TradePipeline(bus=bus, risk_guardian=guardian)


@pytest.mark.asyncio
async def test_pipeline_approves_valid_order():
    pipeline = make_pipeline()
    order = await pipeline.process_entry_signal(
        symbol="AAPL",
        asset_class="equity",
        side="buy",
        entry_price=150.0,
        stop_loss=145.0,
        source_signal_id="sig_001",
        source_agent="signal_hunter",
        nav=50000.0,
    )
    assert order.stage == PipelineStage.SUBMITTED
    assert order.quantity > 0
    assert order.order_id.startswith("ORD-")


@pytest.mark.asyncio
async def test_pipeline_rejects_when_halted():
    pipeline = make_pipeline(is_halted=True)
    order = await pipeline.process_entry_signal(
        symbol="AAPL",
        asset_class="equity",
        side="buy",
        entry_price=150.0,
        stop_loss=145.0,
        source_signal_id="sig_002",
        source_agent="signal_hunter",
        nav=50000.0,
    )
    assert order.stage == PipelineStage.REJECTED
    assert len(order.rejections) > 0


@pytest.mark.asyncio
async def test_pipeline_tracks_counts():
    pipeline = make_pipeline()
    await pipeline.process_entry_signal(
        symbol="AAPL", asset_class="equity", side="buy",
        entry_price=150.0, stop_loss=145.0,
        source_signal_id="sig_003", source_agent="test",
        nav=50000.0,
    )
    assert pipeline.orders_submitted == 1
    assert pipeline.orders_rejected == 0


@pytest.mark.asyncio
async def test_pipeline_rejects_over_drawdown():
    pipeline = make_pipeline()
    order = await pipeline.process_entry_signal(
        symbol="AAPL", asset_class="equity", side="buy",
        entry_price=150.0, stop_loss=145.0,
        source_signal_id="sig_004", source_agent="test",
        nav=50000.0,
        daily_drawdown_pct=8.0,  # Over 7% halt
    )
    assert order.stage == PipelineStage.REJECTED


@pytest.mark.asyncio
async def test_pipeline_order_retrieval():
    pipeline = make_pipeline()
    order = await pipeline.process_entry_signal(
        symbol="TSLA", asset_class="equity", side="buy",
        entry_price=200.0, stop_loss=195.0,
        source_signal_id="sig_005", source_agent="test",
        nav=50000.0,
    )
    retrieved = pipeline.get_order(order.order_id)
    assert retrieved is not None
    assert retrieved.symbol == "TSLA"


@pytest.mark.asyncio
async def test_pipeline_mark_filled():
    pipeline = make_pipeline()
    order = await pipeline.process_entry_signal(
        symbol="MSFT", asset_class="equity", side="buy",
        entry_price=400.0, stop_loss=395.0,
        source_signal_id="sig_006", source_agent="test",
        nav=50000.0,
    )
    pipeline.mark_filled(order.order_id, fill_price=400.05)
    assert order.stage == PipelineStage.FILLED
    assert order.completed_at is not None


@pytest.mark.asyncio
async def test_pipeline_mark_cancelled():
    pipeline = make_pipeline()
    order = await pipeline.process_entry_signal(
        symbol="NVDA", asset_class="equity", side="buy",
        entry_price=800.0, stop_loss=790.0,
        source_signal_id="sig_007", source_agent="test",
        nav=50000.0,
    )
    pipeline.mark_cancelled(order.order_id, "timeout")
    assert order.stage == PipelineStage.CANCELLED


@pytest.mark.asyncio
async def test_pipeline_sequential_order_ids():
    pipeline = make_pipeline()
    o1 = await pipeline.process_entry_signal(
        symbol="A", asset_class="equity", side="buy",
        entry_price=100.0, stop_loss=98.0,
        source_signal_id="s1", source_agent="test", nav=50000.0,
    )
    o2 = await pipeline.process_entry_signal(
        symbol="B", asset_class="equity", side="buy",
        entry_price=100.0, stop_loss=98.0,
        source_signal_id="s2", source_agent="test", nav=50000.0,
    )
    assert o1.order_id == "ORD-000001"
    assert o2.order_id == "ORD-000002"


@pytest.mark.asyncio
async def test_pipeline_emits_submit_signal():
    """Pipeline should publish order_submit signal to bus."""
    bus = SignalBus()
    guardian = RiskGuardian(
        bus=bus, kill_switch_check=lambda: False,
    )
    pipeline = TradePipeline(bus=bus, risk_guardian=guardian)

    submitted = []
    bus.subscribe("bravo.order_submit", lambda s: submitted.append(s))

    task = asyncio.create_task(bus.run())

    await pipeline.process_entry_signal(
        symbol="AAPL", asset_class="equity", side="buy",
        entry_price=150.0, stop_loss=145.0,
        source_signal_id="sig_bus", source_agent="test",
        nav=50000.0,
    )

    await asyncio.sleep(0.05)
    task.cancel()

    assert len(submitted) == 1
    assert submitted[0].payload["symbol"] == "AAPL"
    assert submitted[0].payload["quantity"] > 0


@pytest.mark.asyncio
async def test_pipeline_to_dict():
    pipeline = make_pipeline()
    await pipeline.process_entry_signal(
        symbol="X", asset_class="equity", side="buy",
        entry_price=50.0, stop_loss=48.0,
        source_signal_id="s", source_agent="t", nav=50000.0,
    )
    d = pipeline.to_dict()
    assert d["orders_submitted"] == 1
    assert d["total_orders"] == 1
