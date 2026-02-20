"""Tests for PaperPortfolio and related dataclasses."""

import pytest

from cortex.simulation.paper_portfolio import PaperPortfolio, PaperPosition, PaperTrade


# ── PaperPosition tests ─────────────────────────────────────────────


def test_position_market_value():
    pos = PaperPosition(symbol="AAPL", quantity=10, avg_price=150.0, current_price=160.0)
    assert pos.market_value == 1600.0


def test_position_unrealized_pnl():
    pos = PaperPosition(symbol="AAPL", quantity=10, avg_price=150.0, current_price=160.0)
    assert pos.unrealized_pnl == 100.0  # 10 * (160 - 150)


def test_position_pnl_pct():
    pos = PaperPosition(symbol="AAPL", quantity=10, avg_price=100.0, current_price=110.0)
    assert pos.pnl_pct == pytest.approx(10.0)


def test_position_pnl_pct_zero_avg():
    pos = PaperPosition(symbol="AAPL", quantity=10, avg_price=0.0, current_price=110.0)
    assert pos.pnl_pct == 0.0


def test_position_to_dict():
    pos = PaperPosition(symbol="AAPL", quantity=5, avg_price=100.0, current_price=105.0)
    d = pos.to_dict()
    assert d["symbol"] == "AAPL"
    assert d["quantity"] == 5
    assert d["market_value"] == 525.0
    assert d["unrealized_pnl"] == 25.0


# ── PaperTrade tests ────────────────────────────────────────────────


def test_trade_to_dict():
    trade = PaperTrade(symbol="AAPL", side="buy", quantity=10, price=150.0)
    d = trade.to_dict()
    assert d["symbol"] == "AAPL"
    assert d["side"] == "buy"
    assert d["quantity"] == 10
    assert d["price"] == 150.0
    assert d["pnl"] == 0.0


# ── PaperPortfolio tests ────────────────────────────────────────────


def test_initial_state():
    p = PaperPortfolio(starting_capital=50_000.0)
    assert p.cash == 50_000.0
    assert p.nav == 50_000.0
    assert p.total_pnl == 0.0
    assert p.total_return_pct == 0.0
    assert p.max_drawdown == 0.0
    assert p.win_rate == 0.0
    assert len(p.positions) == 0
    assert len(p.trades) == 0


def test_buy_creates_position():
    p = PaperPortfolio(starting_capital=100_000.0)
    trade = p.buy("AAPL", 10, 150.0)

    assert trade.side == "buy"
    assert trade.symbol == "AAPL"
    assert trade.quantity == 10
    assert "AAPL" in p.positions
    assert p.positions["AAPL"].quantity == 10
    assert p.positions["AAPL"].avg_price == 150.0
    assert p.cash == pytest.approx(98_500.0)  # 100k - 10*150


def test_buy_with_commission():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 10, 150.0, commission=5.0)
    assert p.cash == pytest.approx(98_495.0)  # 100k - 10*150 - 5


def test_buy_adds_to_existing_position():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 10, 100.0)
    p.buy("AAPL", 10, 120.0)

    pos = p.positions["AAPL"]
    assert pos.quantity == 20
    assert pos.avg_price == pytest.approx(110.0)  # (10*100 + 10*120) / 20


def test_buy_insufficient_cash():
    p = PaperPortfolio(starting_capital=1_000.0)
    with pytest.raises(ValueError, match="Insufficient cash"):
        p.buy("AAPL", 100, 150.0)  # needs $15,000


def test_sell_reduces_position():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 20, 100.0)
    trade = p.sell("AAPL", 10, 110.0)

    assert trade.side == "sell"
    assert trade.pnl == pytest.approx(100.0)  # 10 * (110 - 100)
    assert p.positions["AAPL"].quantity == 10


def test_sell_closes_position():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 10, 100.0)
    p.sell("AAPL", 10, 110.0)

    assert "AAPL" not in p.positions


def test_sell_no_position():
    p = PaperPortfolio(starting_capital=100_000.0)
    with pytest.raises(ValueError, match="No position"):
        p.sell("AAPL", 10, 110.0)


def test_sell_excess_quantity():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 10, 100.0)
    with pytest.raises(ValueError, match="Cannot sell"):
        p.sell("AAPL", 20, 110.0)


def test_sell_with_commission():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 10, 100.0)
    trade = p.sell("AAPL", 10, 110.0, commission=5.0)

    # pnl = 10 * (110 - 100) - 5 = 95
    assert trade.pnl == pytest.approx(95.0)
    # cash = 100k - 10*100 + 10*110 - 5 = 100_095
    assert p.cash == pytest.approx(100_095.0)


def test_nav_includes_positions():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 10, 100.0)  # cash = 99,000; pos = 10*100 = 1,000
    assert p.nav == pytest.approx(100_000.0)  # position current_price == avg_price at buy

    p.update_price("AAPL", 110.0)
    # cash = 99,000; pos = 10*110 = 1,100
    assert p.nav == pytest.approx(100_100.0)


def test_total_return_pct():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 10, 100.0)
    p.update_price("AAPL", 200.0)  # double
    # nav = 99,000 + 10*200 = 101,000
    assert p.total_return_pct == pytest.approx(1.0)


def test_total_return_pct_zero_capital():
    p = PaperPortfolio(starting_capital=0.0)
    assert p.total_return_pct == 0.0


def test_max_drawdown():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 100, 100.0)  # cash = 90,000; pos = 10,000
    p.update_price("AAPL", 110.0)  # NAV = 90,000 + 11,000 = 101,000 (new peak)
    p.update_price("AAPL", 90.0)   # NAV = 90,000 + 9,000 = 99,000

    # drawdown = (101,000 - 99,000) / 101,000 * 100
    expected_dd = (101_000.0 - 99_000.0) / 101_000.0 * 100
    assert p.max_drawdown == pytest.approx(expected_dd)


def test_win_rate():
    p = PaperPortfolio(starting_capital=100_000.0)
    # Winning trade
    p.buy("AAPL", 10, 100.0)
    p.sell("AAPL", 10, 110.0)  # pnl = +100

    # Losing trade
    p.buy("MSFT", 10, 200.0)
    p.sell("MSFT", 10, 190.0)  # pnl = -100

    assert p.win_rate == pytest.approx(0.5)


def test_win_rate_all_winners():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 10, 100.0)
    p.sell("AAPL", 10, 110.0)
    p.buy("MSFT", 10, 100.0)
    p.sell("MSFT", 10, 120.0)

    assert p.win_rate == pytest.approx(1.0)


def test_win_rate_no_sells():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 10, 100.0)
    assert p.win_rate == 0.0


def test_update_price_nonexistent():
    """Updating price for a symbol we don't hold should be a no-op."""
    p = PaperPortfolio(starting_capital=100_000.0)
    p.update_price("AAPL", 150.0)  # no error
    assert "AAPL" not in p.positions


def test_snapshot():
    p = PaperPortfolio(starting_capital=100_000.0)
    p.buy("AAPL", 10, 100.0)
    snap = p.snapshot()

    assert snap["cash"] == pytest.approx(99_000.0)
    assert snap["nav"] == pytest.approx(100_000.0)
    assert snap["num_trades"] == 1
    assert snap["num_positions"] == 1
    assert "AAPL" in snap["positions"]
    assert isinstance(snap["equity_curve"], list)


def test_equity_curve_capped():
    """Equity curve should not exceed 100 entries in snapshot."""
    p = PaperPortfolio(starting_capital=100_000.0)
    # Generate >100 entries by buying and updating price repeatedly
    p.buy("AAPL", 1, 100.0)
    for i in range(120):
        p.update_price("AAPL", 100.0 + i)

    snap = p.snapshot()
    assert len(snap["equity_curve"]) <= 100
