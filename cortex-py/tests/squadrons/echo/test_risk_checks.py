import pytest
from cortex.squadrons.echo.risk_checks import (
    PreTradeCheck,
    CheckResult,
    OrderRequest,
    PortfolioState,
)


def make_portfolio(nav: float = 50000.0, daily_drawdown_pct: float = 0.0) -> PortfolioState:
    return PortfolioState(
        nav=nav,
        daily_drawdown_pct=daily_drawdown_pct,
        weekly_drawdown_pct=0.0,
        total_drawdown_pct=0.0,
        position_count=5,
        daily_trade_count=10,
    )


def make_order(
    symbol: str = "AAPL",
    quantity: float = 10,
    price: float = 150.0,
    asset_class: str = "equity",
    is_closing: bool = False,
) -> OrderRequest:
    return OrderRequest(
        symbol=symbol,
        quantity=quantity,
        estimated_price=price,
        asset_class=asset_class,
        side="buy",
        is_closing=is_closing,
    )


def test_order_within_limits_passes():
    checker = PreTradeCheck(max_position_pct=5.0, max_concurrent=15, max_daily_trades=50)
    portfolio = make_portfolio()
    order = make_order()  # $1500 order on $50K portfolio = 3%
    result = checker.run(order, portfolio, is_halted=False)
    assert result.approved is True


def test_kill_switch_blocks_all():
    checker = PreTradeCheck(max_position_pct=5.0, max_concurrent=15, max_daily_trades=50)
    portfolio = make_portfolio()
    order = make_order()
    result = checker.run(order, portfolio, is_halted=True)
    assert result.approved is False
    assert "HALTED" in result.rejections[0]


def test_oversized_position_rejected():
    checker = PreTradeCheck(max_position_pct=5.0, max_concurrent=15, max_daily_trades=50)
    portfolio = make_portfolio(nav=50000.0)
    order = make_order(quantity=100, price=150.0)  # $15,000 = 30% of $50K
    result = checker.run(order, portfolio, is_halted=False)
    assert result.approved is False
    assert any("position size" in r.lower() for r in result.rejections)


def test_drawdown_halt_blocks_new_positions():
    checker = PreTradeCheck(
        max_position_pct=5.0, max_concurrent=15, max_daily_trades=50,
        daily_drawdown_halt_pct=7.0,
    )
    portfolio = make_portfolio(daily_drawdown_pct=8.0)
    order = make_order()
    result = checker.run(order, portfolio, is_halted=False)
    assert result.approved is False


def test_closing_positions_allowed_during_drawdown():
    checker = PreTradeCheck(
        max_position_pct=5.0, max_concurrent=15, max_daily_trades=50,
        daily_drawdown_halt_pct=7.0,
    )
    portfolio = make_portfolio(daily_drawdown_pct=8.0)
    order = make_order(is_closing=True)
    result = checker.run(order, portfolio, is_halted=False)
    assert result.approved is True


def test_max_positions_blocks_new():
    checker = PreTradeCheck(max_position_pct=5.0, max_concurrent=5, max_daily_trades=50)
    portfolio = make_portfolio()
    portfolio.position_count = 5  # At limit
    order = make_order()
    result = checker.run(order, portfolio, is_halted=False)
    assert result.approved is False
