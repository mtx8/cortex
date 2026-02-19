import pytest
from cortex.squadrons.echo.position_sizer import (
    PositionSizer,
    SizingRequest,
    SizingResult,
)


def make_request(
    symbol: str = "AAPL",
    entry_price: float = 150.0,
    stop_loss: float = 145.0,
    nav: float = 50000.0,
    asset_class: str = "equity",
    win_rate: float | None = None,
    avg_win: float | None = None,
    avg_loss: float | None = None,
    volatility: float | None = None,
) -> SizingRequest:
    return SizingRequest(
        symbol=symbol,
        asset_class=asset_class,
        entry_price=entry_price,
        stop_loss_price=stop_loss,
        nav=nav,
        win_rate=win_rate,
        avg_win=avg_win,
        avg_loss=avg_loss,
        volatility=volatility,
    )


def test_fixed_fractional_default():
    """Without Kelly data, falls back to fixed fractional."""
    sizer = PositionSizer(fixed_fractional_pct=1.0, max_single_loss_usd=500.0)
    req = make_request(nav=50000.0, entry_price=150.0, stop_loss=145.0)
    result = sizer.calculate(req)
    assert result.method_used == "fixed_fractional"
    assert result.recommended_quantity >= 1
    assert result.position_pct_of_nav <= 5.0  # Under max


def test_kelly_with_good_history():
    """With sufficient trade history, uses quarter-Kelly."""
    sizer = PositionSizer(max_position_pct=5.0, max_single_loss_usd=500.0)
    req = make_request(
        nav=50000.0,
        entry_price=150.0,
        stop_loss=145.0,
        win_rate=0.55,
        avg_win=200.0,
        avg_loss=100.0,
    )
    result = sizer.calculate(req)
    assert result.method_used == "quarter_kelly"
    assert result.kelly_fraction is not None
    assert result.kelly_fraction > 0
    assert result.recommended_quantity >= 1


def test_kelly_negative_returns_zero():
    """Negative Kelly (losing strategy) returns zero."""
    sizer = PositionSizer()
    req = make_request(
        win_rate=0.30,  # Very low win rate
        avg_win=100.0,
        avg_loss=200.0,  # Losses twice as large
    )
    result = sizer.calculate(req)
    assert result.recommended_quantity == 0
    assert result.method_used == "kelly_negative"


def test_position_capped_at_max_pct():
    """Position size never exceeds max_position_pct."""
    sizer = PositionSizer(max_position_pct=2.0, max_single_loss_usd=5000.0)
    req = make_request(
        nav=50000.0,
        entry_price=10.0,  # Cheap stock
        stop_loss=9.0,
        win_rate=0.70,
        avg_win=500.0,
        avg_loss=100.0,  # Great stats
    )
    result = sizer.calculate(req)
    assert result.position_pct_of_nav <= 2.1  # Small float tolerance


def test_max_loss_cap():
    """Position is capped so max loss doesn't exceed max_single_loss_usd."""
    sizer = PositionSizer(max_single_loss_usd=250.0)
    req = make_request(
        nav=100000.0,
        entry_price=100.0,
        stop_loss=90.0,  # $10 risk per share
    )
    result = sizer.calculate(req)
    # Max 250/10 = 25 shares
    assert result.recommended_quantity <= 25
    assert result.max_loss_estimate <= 250.0


def test_vol_adjusted_for_crypto():
    """Crypto positions use volatility adjustment."""
    sizer = PositionSizer(
        fixed_fractional_pct=1.0,
        target_volatility=0.20,
        max_single_loss_usd=500.0,
    )
    req = make_request(
        symbol="BTC-USD",
        asset_class="crypto",
        entry_price=50000.0,
        stop_loss=48000.0,  # $2000 risk per unit
        nav=100000.0,
        volatility=0.60,  # 60% vol — 3x target
    )
    result = sizer.calculate(req)
    assert result.method_used == "vol_adjusted"
    # With 60% vol vs 20% target, scalar = 0.333
    # So position should be smaller than fixed fractional


def test_zero_nav_returns_zero():
    """Zero NAV returns zero sizing."""
    sizer = PositionSizer()
    req = make_request(nav=0.0)
    result = sizer.calculate(req)
    assert result.recommended_quantity == 0


def test_zero_stop_loss_returns_zero():
    """Same price as stop loss means no risk definition."""
    sizer = PositionSizer()
    req = make_request(entry_price=150.0, stop_loss=150.0)
    result = sizer.calculate(req)
    assert result.recommended_quantity == 0
    assert result.method_used == "no_stop_loss"
