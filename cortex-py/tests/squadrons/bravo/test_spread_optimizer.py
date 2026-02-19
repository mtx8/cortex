"""Tests for BRAVO Spread Optimizer agent.

Covers spread construction (verticals, iron condors, calendars),
risk/reward analysis, leg ordering, simulated execution, ID uniqueness,
and active spread tracking.
"""

import pytest

from cortex.orchestrator.bus import SignalBus
from cortex.squadrons.bravo.spread_optimizer import (
    SpreadOptimizer,
    SpreadLeg,
    SpreadOrder,
    SpreadResult,
    SpreadType,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def make_optimizer(simulation: bool = True) -> tuple[SpreadOptimizer, SignalBus]:
    """Create a SpreadOptimizer with a fresh SignalBus."""
    bus = SignalBus()
    optimizer = SpreadOptimizer(bus=bus, simulation=simulation)
    return optimizer, bus


# ---------------------------------------------------------------------------
# 1. Build vertical call — correct legs for bull call spread
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_build_vertical_call():
    """Bull call spread: buy lower strike call, sell higher strike call."""
    optimizer, _ = make_optimizer()

    order = optimizer.build_vertical(
        symbol="AAPL",
        option_type="call",
        long_strike=150.0,
        short_strike=160.0,
        expiry="2026-03-20",
        quantity=1,
    )

    assert order.spread_type == SpreadType.VERTICAL_CALL
    assert len(order.legs) == 2
    assert order.status == "pending"

    buy_leg = next(l for l in order.legs if l.side == "buy")
    sell_leg = next(l for l in order.legs if l.side == "sell")

    assert buy_leg.strike == 150.0
    assert buy_leg.option_type == "call"
    assert buy_leg.side == "buy"
    assert buy_leg.symbol == "AAPL"
    assert buy_leg.expiry == "2026-03-20"
    assert buy_leg.quantity == 1

    assert sell_leg.strike == 160.0
    assert sell_leg.option_type == "call"
    assert sell_leg.side == "sell"


# ---------------------------------------------------------------------------
# 2. Build vertical put — correct legs for bear put spread
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_build_vertical_put():
    """Bear put spread: buy higher strike put, sell lower strike put."""
    optimizer, _ = make_optimizer()

    order = optimizer.build_vertical(
        symbol="SPY",
        option_type="put",
        long_strike=450.0,
        short_strike=440.0,
        expiry="2026-04-17",
        quantity=2,
    )

    assert order.spread_type == SpreadType.VERTICAL_PUT
    assert len(order.legs) == 2

    buy_leg = next(l for l in order.legs if l.side == "buy")
    sell_leg = next(l for l in order.legs if l.side == "sell")

    assert buy_leg.strike == 450.0
    assert buy_leg.option_type == "put"
    assert buy_leg.quantity == 2

    assert sell_leg.strike == 440.0
    assert sell_leg.option_type == "put"
    assert sell_leg.quantity == 2


# ---------------------------------------------------------------------------
# 3. Build iron condor — 4 legs with correct strikes
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_build_iron_condor():
    """Iron condor has 4 legs: buy put, sell put, sell call, buy call."""
    optimizer, _ = make_optimizer()

    order = optimizer.build_iron_condor(
        symbol="SPY",
        put_long=420.0,
        put_short=430.0,
        call_short=470.0,
        call_long=480.0,
        expiry="2026-03-20",
        quantity=1,
    )

    assert order.spread_type == SpreadType.IRON_CONDOR
    assert len(order.legs) == 4

    # Verify all four legs exist with correct properties
    put_legs = [l for l in order.legs if l.option_type == "put"]
    call_legs = [l for l in order.legs if l.option_type == "call"]

    assert len(put_legs) == 2
    assert len(call_legs) == 2

    put_buy = next(l for l in put_legs if l.side == "buy")
    put_sell = next(l for l in put_legs if l.side == "sell")
    call_sell = next(l for l in call_legs if l.side == "sell")
    call_buy = next(l for l in call_legs if l.side == "buy")

    assert put_buy.strike == 420.0
    assert put_sell.strike == 430.0
    assert call_sell.strike == 470.0
    assert call_buy.strike == 480.0

    # All legs should have the same symbol, expiry, and quantity
    for leg in order.legs:
        assert leg.symbol == "SPY"
        assert leg.expiry == "2026-03-20"
        assert leg.quantity == 1


# ---------------------------------------------------------------------------
# 4. Build calendar — same strike, different expiries
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_build_calendar():
    """Calendar spread: same strike, sell near-term, buy far-term."""
    optimizer, _ = make_optimizer()

    order = optimizer.build_calendar(
        symbol="MSFT",
        option_type="call",
        strike=400.0,
        near_expiry="2026-03-20",
        far_expiry="2026-06-19",
        quantity=3,
    )

    assert order.spread_type == SpreadType.CALENDAR
    assert len(order.legs) == 2

    sell_leg = next(l for l in order.legs if l.side == "sell")
    buy_leg = next(l for l in order.legs if l.side == "buy")

    # Same strike
    assert sell_leg.strike == 400.0
    assert buy_leg.strike == 400.0

    # Different expiries: near-term is sold, far-term is bought
    assert sell_leg.expiry == "2026-03-20"
    assert buy_leg.expiry == "2026-06-19"

    assert sell_leg.option_type == "call"
    assert buy_leg.option_type == "call"

    assert sell_leg.quantity == 3
    assert buy_leg.quantity == 3


# ---------------------------------------------------------------------------
# 5. Analyze vertical spread — max risk = debit, max reward = width - debit
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_analyze_vertical_spread():
    """Vertical spread analysis: max_risk = net_debit, max_reward = width - debit."""
    optimizer, _ = make_optimizer()

    order = optimizer.build_vertical(
        symbol="AAPL",
        option_type="call",
        long_strike=150.0,
        short_strike=160.0,
        expiry="2026-03-20",
        quantity=1,
    )

    # Set limit prices: buy the 150 call for $5, sell the 160 call for $2
    buy_leg = next(l for l in order.legs if l.side == "buy")
    sell_leg = next(l for l in order.legs if l.side == "sell")
    buy_leg.limit_price = 5.0
    sell_leg.limit_price = 2.0

    analysis = optimizer.analyze_spread(order)

    # net_debit = 5.0 - 2.0 = 3.0
    assert analysis["net_debit"] == 3.0
    # strike_width = |150 - 160| = 10.0
    assert analysis["strike_width"] == 10.0
    # max_risk = net_debit * quantity * 100 = 3.0 * 1 * 100 = $300
    assert analysis["max_risk"] == 300.0
    # max_reward = (width - debit) * quantity * 100 = 7.0 * 1 * 100 = $700
    assert analysis["max_reward"] == 700.0
    # breakeven = long_strike + net_debit = 153.0
    assert analysis["breakeven"] == [153.0]


# ---------------------------------------------------------------------------
# 6. Analyze iron condor — max risk = width - credit, max reward = credit
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_analyze_iron_condor():
    """Iron condor analysis: max_reward = net_credit, max_risk = width - credit."""
    optimizer, _ = make_optimizer()

    order = optimizer.build_iron_condor(
        symbol="SPY",
        put_long=420.0,
        put_short=430.0,
        call_short=470.0,
        call_long=480.0,
        expiry="2026-03-20",
        quantity=1,
    )

    # Set premiums: sell puts/calls at higher price, buy wings cheaper
    for leg in order.legs:
        if leg.option_type == "put" and leg.side == "buy":
            leg.limit_price = 1.0   # buy 420 put @ $1
        elif leg.option_type == "put" and leg.side == "sell":
            leg.limit_price = 2.5   # sell 430 put @ $2.50
        elif leg.option_type == "call" and leg.side == "sell":
            leg.limit_price = 2.5   # sell 470 call @ $2.50
        elif leg.option_type == "call" and leg.side == "buy":
            leg.limit_price = 1.0   # buy 480 call @ $1

    analysis = optimizer.analyze_spread(order)

    # net_credit = (2.5 + 2.5) - (1.0 + 1.0) = 3.0
    assert analysis["net_credit"] == 3.0
    # put_width = 430 - 420 = 10, call_width = 480 - 470 = 10
    assert analysis["put_width"] == 10.0
    assert analysis["call_width"] == 10.0
    # max_reward = net_credit * 1 * 100 = $300
    assert analysis["max_reward"] == 300.0
    # max_risk = (wing_width - net_credit) * 1 * 100 = (10 - 3) * 100 = $700
    assert analysis["max_risk"] == 700.0
    # breakevens
    assert analysis["breakeven"] == [427.0, 473.0]


# ---------------------------------------------------------------------------
# 7. Optimal leg order — sell legs before buy legs
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_optimal_leg_order():
    """Sell legs must be ordered before buy legs for capital efficiency."""
    optimizer, _ = make_optimizer()

    legs = [
        SpreadLeg("AAPL", "call", 150.0, "2026-03-20", "buy", 1, 5.0),
        SpreadLeg("AAPL", "call", 160.0, "2026-03-20", "sell", 1, 2.0),
        SpreadLeg("AAPL", "put", 140.0, "2026-03-20", "buy", 1, 3.0),
        SpreadLeg("AAPL", "put", 130.0, "2026-03-20", "sell", 1, 1.0),
    ]

    ordered = optimizer._optimal_leg_order(legs)

    # First two legs should be sells, last two should be buys
    assert ordered[0].side == "sell"
    assert ordered[1].side == "sell"
    assert ordered[2].side == "buy"
    assert ordered[3].side == "buy"

    # All original legs present
    assert len(ordered) == 4


# ---------------------------------------------------------------------------
# 8. Submit spread simulated — all legs fill in simulation
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_submit_spread_simulated():
    """All legs fill in simulation mode; result is 'filled'."""
    optimizer, _ = make_optimizer(simulation=True)

    order = optimizer.build_vertical(
        symbol="AAPL",
        option_type="call",
        long_strike=150.0,
        short_strike=160.0,
        expiry="2026-03-20",
        quantity=1,
    )

    # Set limit prices for simulation
    for leg in order.legs:
        if leg.side == "buy":
            leg.limit_price = 5.0
        else:
            leg.limit_price = 2.0

    result = await optimizer.submit_spread(order)

    assert result.status == "filled"
    assert result.spread_id == order.spread_id
    assert len(result.legs_filled) == 2

    # Verify each leg was filled
    for leg_fill in result.legs_filled:
        assert "fill_price" in leg_fill
        assert "filled_at" in leg_fill
        assert leg_fill["symbol"] == "AAPL"
        assert leg_fill["quantity"] == 1

    # net_premium: sell 160c @ $2 = +$200, buy 150c @ $5 = -$500 => net = -$300
    assert result.net_premium == pytest.approx(-300.0)

    # Spread should no longer be active after fill
    assert len(optimizer.active_spreads) == 0


# ---------------------------------------------------------------------------
# 9. Spread ID uniqueness — each spread gets unique ID
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_spread_id_uniqueness():
    """Every constructed spread receives a unique spread_id."""
    optimizer, _ = make_optimizer()

    ids = set()
    for _ in range(50):
        order = optimizer.build_vertical(
            symbol="AAPL",
            option_type="call",
            long_strike=150.0,
            short_strike=160.0,
            expiry="2026-03-20",
            quantity=1,
        )
        ids.add(order.spread_id)

    assert len(ids) == 50, "All 50 spread IDs must be unique"

    # All IDs should follow the SPR- prefix convention
    for spread_id in ids:
        assert spread_id.startswith("SPR-")


# ---------------------------------------------------------------------------
# 10. Active spreads tracking
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_active_spreads_tracking():
    """Active spreads are tracked during submission and cleared after fill."""
    optimizer, _ = make_optimizer(simulation=False)

    assert len(optimizer.active_spreads) == 0

    # Submit two spreads in non-simulation mode (they stay as 'submitted')
    order1 = optimizer.build_vertical(
        symbol="AAPL",
        option_type="call",
        long_strike=150.0,
        short_strike=160.0,
        expiry="2026-03-20",
        quantity=1,
    )
    order2 = optimizer.build_vertical(
        symbol="MSFT",
        option_type="put",
        long_strike=400.0,
        short_strike=390.0,
        expiry="2026-04-17",
        quantity=2,
    )

    await optimizer.submit_spread(order1)
    assert len(optimizer.active_spreads) == 1

    await optimizer.submit_spread(order2)
    assert len(optimizer.active_spreads) == 2

    # Verify the correct spread IDs are tracked
    active_ids = {s.spread_id for s in optimizer.active_spreads}
    assert order1.spread_id in active_ids
    assert order2.spread_id in active_ids

    # Verify the active_spreads property returns a copy (not the internal list)
    active_copy = optimizer.active_spreads
    active_copy.clear()
    assert len(optimizer.active_spreads) == 2, "Clearing copy must not affect internals"


# ---------------------------------------------------------------------------
# Additional: active spreads clear after simulated fill
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_active_spreads_clear_after_sim_fill():
    """In simulation mode, filled spreads are removed from active tracking."""
    optimizer, _ = make_optimizer(simulation=True)

    order = optimizer.build_vertical(
        symbol="AAPL",
        option_type="call",
        long_strike=150.0,
        short_strike=160.0,
        expiry="2026-03-20",
        quantity=1,
    )
    for leg in order.legs:
        leg.limit_price = 3.0

    result = await optimizer.submit_spread(order)
    assert result.status == "filled"
    assert len(optimizer.active_spreads) == 0


# ---------------------------------------------------------------------------
# Additional: to_dict includes spread-specific fields
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_to_dict():
    """to_dict() includes base agent fields and spread-specific counters."""
    optimizer, _ = make_optimizer()

    d = optimizer.to_dict()
    assert d["agent_id"] == "spread_optimizer"
    assert d["squadron"] == "bravo"
    assert d["simulation"] is True
    assert d["active_spread_count"] == 0
    assert d["completed_spread_count"] == 0
    assert "active_spread_ids" in d


# ---------------------------------------------------------------------------
# Additional: SpreadType enum values
# ---------------------------------------------------------------------------

def test_spread_type_values():
    """SpreadType enum contains all expected spread types."""
    assert SpreadType.VERTICAL_CALL.value == "vertical_call"
    assert SpreadType.VERTICAL_PUT.value == "vertical_put"
    assert SpreadType.IRON_CONDOR.value == "iron_condor"
    assert SpreadType.CALENDAR.value == "calendar"
    assert SpreadType.STRADDLE.value == "straddle"
    assert SpreadType.STRANGLE.value == "strangle"
