"""Tests for BRAVO Order Sniper agent.

Covers order submission, notional cap enforcement, signal integration,
daily counters, and audit trail logging.
"""

import asyncio

import pytest

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.storage.audit import AuditTrail, AuditEventType
from cortex.squadrons.bravo.order_sniper import (
    OrderSniper,
    OrderRequest,
    OrderResult,
    OrderType,
    OrderSide,
    _HARD_MAX_NOTIONAL,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_sniper(
    simulation: bool = True,
    default_market_price: float = 100.0,
    audit: AuditTrail | None = None,
) -> tuple[OrderSniper, SignalBus, AuditTrail]:
    """Create an OrderSniper with fresh bus and audit trail."""
    bus = SignalBus()
    audit = audit or AuditTrail()
    sniper = OrderSniper(
        bus=bus,
        audit=audit,
        simulation=simulation,
        default_market_price=default_market_price,
    )
    return sniper, bus, audit


# ---------------------------------------------------------------------------
# 1. Basic market order fill (simulated)
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_submit_market_order_simulated():
    """A market order in simulation mode fills at the default market price."""
    sniper, bus, _ = make_sniper(default_market_price=50.0)

    request = OrderRequest(
        symbol="AAPL",
        side=OrderSide.BUY,
        quantity=5,
        order_type=OrderType.MARKET,
    )
    result = await sniper.submit_order(request)

    assert result.status == "filled"
    assert result.fill_price == 50.0
    assert result.fill_quantity == 5
    assert result.commission == 0.0
    assert result.filled_at is not None
    assert result.order_id.startswith("BRV-")


# ---------------------------------------------------------------------------
# 2. Limit order fill at limit price (simulated)
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_submit_limit_order_simulated():
    """A limit order in simulation mode fills at the limit price."""
    sniper, bus, _ = make_sniper()

    request = OrderRequest(
        symbol="MSFT",
        side=OrderSide.BUY,
        quantity=2,
        order_type=OrderType.LIMIT,
        limit_price=150.0,
    )
    result = await sniper.submit_order(request)

    assert result.status == "filled"
    assert result.fill_price == 150.0
    assert result.fill_quantity == 2


# ---------------------------------------------------------------------------
# 3. Notional cap rejection — exceeds $500
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_notional_cap_rejection():
    """Order with notional exceeding $500 is immediately rejected."""
    sniper, bus, _ = make_sniper()

    # 10 shares * $60 = $600 > $500
    request = OrderRequest(
        symbol="TSLA",
        side=OrderSide.BUY,
        quantity=10,
        order_type=OrderType.LIMIT,
        limit_price=60.0,
    )
    result = await sniper.submit_order(request)

    assert result.status == "rejected"
    assert result.rejection_reason is not None
    assert "500" in result.rejection_reason
    assert result.fill_price is None
    assert sniper.pending_count == 0
    assert sniper.filled_today == 0


# ---------------------------------------------------------------------------
# 4. Notional cap exact boundary — exactly $500 passes
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_notional_cap_exact_boundary():
    """Order with notional exactly $500 should pass (not exceed)."""
    sniper, bus, _ = make_sniper()

    # 5 shares * $100 = $500 exactly
    request = OrderRequest(
        symbol="AMZN",
        side=OrderSide.BUY,
        quantity=5,
        order_type=OrderType.LIMIT,
        limit_price=100.0,
    )
    result = await sniper.submit_order(request)

    assert result.status == "filled"
    assert result.fill_price == 100.0
    assert result.fill_quantity == 5


# ---------------------------------------------------------------------------
# 5. Cancel pending order
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_cancel_pending_order():
    """A pending order can be successfully cancelled."""
    sniper, bus, _ = make_sniper(simulation=False)

    # In non-simulation mode, order stays as 'submitted' (pending)
    request = OrderRequest(
        symbol="GOOG",
        side=OrderSide.BUY,
        quantity=1,
        order_type=OrderType.LIMIT,
        limit_price=150.0,
    )
    result = await sniper.submit_order(request)
    assert result.status == "submitted"
    assert sniper.pending_count == 1

    cancelled = await sniper.cancel_order(result.order_id)
    assert cancelled is True
    assert sniper.pending_count == 0

    # Cancelling same order again fails
    cancelled_again = await sniper.cancel_order(result.order_id)
    assert cancelled_again is False


# ---------------------------------------------------------------------------
# 6. Handle POSITION_SIZE signal — signal bus integration
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_handle_position_size_signal():
    """OrderSniper processes POSITION_SIZE signals into filled orders."""
    bus = SignalBus()
    audit = AuditTrail()
    sniper = OrderSniper(bus=bus, audit=audit, simulation=True, default_market_price=50.0)
    sniper.register()

    # Capture emitted ORDER_SUBMITTED signals
    submitted_signals: list[Signal] = []

    async def capture_submitted(s: Signal) -> None:
        submitted_signals.append(s)

    bus.subscribe(SignalTypes.ORDER_SUBMITTED, capture_submitted)

    task = asyncio.create_task(bus.run())

    # Simulate POSITION_SIZE signal from ECHO risk guardian
    await bus.publish(Signal(
        signal_id="test_pos_size_1",
        source_agent="risk_guardian",
        source_squadron="echo",
        signal_type=SignalTypes.POSITION_SIZE,
        payload={
            "symbol": "AAPL",
            "quantity": 3,
            "side": "buy",
            "entry_price": 150.0,
            "dollar_amount": 450.0,
            "method": "fixed_fractional",
            "throttle_factor": 1.0,
            "source_signal_id": "entry_1",
        },
        priority=SignalPriority.HIGH,
    ))

    await asyncio.sleep(0.1)
    task.cancel()

    # Should have processed the signal and emitted ORDER_SUBMITTED
    assert len(submitted_signals) >= 1
    assert submitted_signals[0].payload["symbol"] == "AAPL"
    assert submitted_signals[0].payload["quantity"] == 3
    assert sniper.filled_today == 1


# ---------------------------------------------------------------------------
# 7. Daily counter tracking — filled_today increments
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_daily_counter_tracking():
    """Each filled order increments the filled_today counter."""
    sniper, bus, _ = make_sniper(default_market_price=50.0)

    assert sniper.filled_today == 0

    for i in range(3):
        request = OrderRequest(
            symbol=f"SYM{i}",
            side=OrderSide.BUY,
            quantity=1,
            order_type=OrderType.MARKET,
        )
        result = await sniper.submit_order(request)
        assert result.status == "filled"

    assert sniper.filled_today == 3


# ---------------------------------------------------------------------------
# 8. Daily reset clears counters
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_daily_reset():
    """reset_daily() clears filled counter and pending orders."""
    sniper, bus, _ = make_sniper(default_market_price=50.0)

    # Fill some orders
    for _ in range(2):
        await sniper.submit_order(OrderRequest(
            symbol="SPY",
            side=OrderSide.BUY,
            quantity=1,
            order_type=OrderType.MARKET,
        ))
    assert sniper.filled_today == 2

    sniper.reset_daily()

    assert sniper.filled_today == 0
    assert sniper.pending_count == 0


# ---------------------------------------------------------------------------
# 9. Stop order submission
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_stop_order_submission():
    """Stop order uses stop_price for notional calculation and fills."""
    sniper, bus, _ = make_sniper()

    request = OrderRequest(
        symbol="META",
        side=OrderSide.SELL,
        quantity=2,
        order_type=OrderType.STOP,
        stop_price=200.0,
    )
    result = await sniper.submit_order(request)

    assert result.status == "filled"
    assert result.fill_price == 200.0
    assert result.fill_quantity == 2


# ---------------------------------------------------------------------------
# 10. Order audit logging — verify audit trail entries
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_order_audit_logging():
    """Submitted and filled orders create audit trail entries."""
    sniper, bus, audit = make_sniper(default_market_price=50.0)

    request = OrderRequest(
        symbol="NVDA",
        side=OrderSide.BUY,
        quantity=3,
        order_type=OrderType.MARKET,
    )
    result = await sniper.submit_order(request)
    assert result.status == "filled"

    # Check audit entries were created
    entries = audit.get_recent(50)
    assert len(entries) >= 2  # At least SUBMITTED + FILLED

    event_types = [e.event_type for e in entries]
    assert AuditEventType.ORDER_SUBMITTED in event_types
    assert AuditEventType.ORDER_FILLED in event_types

    # All entries should reference the correct symbol
    for entry in entries:
        assert entry.symbol == "NVDA"
        assert entry.source_agent == "order_sniper"

    # Verify trade IDs match
    order_ids = {e.trade_id for e in entries}
    assert result.order_id in order_ids


# ---------------------------------------------------------------------------
# Additional edge case: max_notional cannot exceed hard cap
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_max_notional_clamp():
    """OrderRequest.max_notional is clamped to the hard cap of $500."""
    request = OrderRequest(
        symbol="SPY",
        side=OrderSide.BUY,
        quantity=1,
        order_type=OrderType.MARKET,
        max_notional=99999.0,  # Attempt to override
    )
    assert request.max_notional == _HARD_MAX_NOTIONAL


# ---------------------------------------------------------------------------
# Additional: rejected order audit logging
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_rejected_order_audit_logging():
    """Rejected orders log to the audit trail with the rejection reason."""
    sniper, bus, audit = make_sniper()

    request = OrderRequest(
        symbol="TSLA",
        side=OrderSide.BUY,
        quantity=100,
        order_type=OrderType.LIMIT,
        limit_price=50.0,  # 100 * $50 = $5000 >> $500
    )
    result = await sniper.submit_order(request)
    assert result.status == "rejected"

    entries = audit.get_recent(50)
    rejected_entries = [
        e for e in entries if e.event_type == AuditEventType.ORDER_REJECTED
    ]
    assert len(rejected_entries) == 1
    assert "TSLA" == rejected_entries[0].symbol


# ---------------------------------------------------------------------------
# Additional: stop_limit order type
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_stop_limit_order_submission():
    """Stop-limit order uses limit_price for notional and fills."""
    sniper, bus, _ = make_sniper()

    request = OrderRequest(
        symbol="AMZN",
        side=OrderSide.BUY,
        quantity=2,
        order_type=OrderType.STOP_LIMIT,
        limit_price=200.0,
        stop_price=195.0,
    )
    result = await sniper.submit_order(request)

    assert result.status == "filled"
    assert result.fill_price == 200.0  # Uses limit_price


# ---------------------------------------------------------------------------
# Additional: to_dict returns expected keys
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_to_dict():
    """to_dict() includes agent state and sniper-specific fields."""
    sniper, bus, _ = make_sniper()

    d = sniper.to_dict()
    assert d["agent_id"] == "order_sniper"
    assert d["squadron"] == "bravo"
    assert d["pending_count"] == 0
    assert d["filled_today"] == 0
    assert d["simulation"] is True
