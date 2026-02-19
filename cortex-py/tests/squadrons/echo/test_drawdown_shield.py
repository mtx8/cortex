import pytest
from cortex.squadrons.echo.drawdown_shield import (
    DrawdownShield,
    DrawdownState,
    DrawdownLevel,
)


def test_normal_state_no_drawdown():
    """Fresh shield with no drawdown returns normal."""
    shield = DrawdownShield()
    state = shield.update(50000.0)
    assert state.level == DrawdownLevel.NORMAL
    assert state.throttle_factor == 1.0
    assert state.daily_drawdown_pct == 0.0


def test_daily_throttle_kicks_in():
    """Past 5% daily drawdown, throttle reduces position sizing."""
    shield = DrawdownShield(
        daily_throttle_pct=5.0,
        daily_halt_pct=7.0,
    )
    # Set HWM at 50000
    shield.update(50000.0)
    # Drop to 47000 = 6% drawdown (past throttle threshold)
    state = shield.update(47000.0)
    assert state.level == DrawdownLevel.THROTTLED
    assert state.throttle_factor < 1.0
    assert state.throttle_factor >= 0.0


def test_daily_throttle_linear_ramp():
    """Throttle factor decreases linearly between throttle and halt."""
    shield = DrawdownShield(
        daily_throttle_pct=5.0,
        daily_halt_pct=7.0,
    )
    shield.update(100000.0)  # HWM

    # At 6% drawdown (midpoint between 5% and 7%)
    state = shield.update(94000.0)
    assert state.level == DrawdownLevel.THROTTLED
    assert 0.4 <= state.throttle_factor <= 0.6  # ~0.5


def test_daily_halt_blocks_trading():
    """At 7% daily drawdown, trading halted."""
    shield = DrawdownShield(
        daily_throttle_pct=5.0,
        daily_halt_pct=7.0,
    )
    shield.update(50000.0)
    # Drop to 46500 = 7% drawdown
    state = shield.update(46500.0)
    assert state.level == DrawdownLevel.HALTED
    assert state.throttle_factor == 0.0


def test_weekly_halt():
    """Weekly drawdown >= halt triggers halt."""
    shield = DrawdownShield(weekly_halt_pct=10.0)
    shield.update(50000.0)
    # Drop 10% = to 45000
    state = shield.update(45000.0)
    assert state.level == DrawdownLevel.HALTED
    assert "Weekly" in state.message or "weekly" in state.message.lower()


def test_total_kill_switch():
    """Total drawdown >= kill threshold triggers kill switch."""
    shield = DrawdownShield(total_kill_pct=20.0)
    shield.update(50000.0)
    # Drop 20% = to 40000
    state = shield.update(40000.0)
    assert state.level == DrawdownLevel.KILL
    assert state.should_engage_kill_switch is True
    assert state.throttle_factor == 0.0


def test_reset_daily():
    """Daily reset clears daily drawdown."""
    shield = DrawdownShield(daily_throttle_pct=5.0, daily_halt_pct=7.0)
    shield.update(50000.0)
    shield.update(47000.0)  # 6% drawdown
    assert shield.daily_drawdown_pct > 5.0

    # Reset (market open)
    shield.reset_daily(47000.0)
    assert shield.daily_drawdown_pct == 0.0
    state = shield.get_state()
    assert state.level != DrawdownLevel.HALTED  # Daily halt cleared


def test_reset_weekly():
    """Weekly reset clears weekly drawdown."""
    shield = DrawdownShield(weekly_halt_pct=10.0)
    shield.update(50000.0)
    shield.update(44000.0)  # 12% drawdown
    assert shield.weekly_drawdown_pct > 10.0

    shield.reset_weekly(44000.0)
    assert shield.weekly_drawdown_pct == 0.0


def test_hwm_only_goes_up():
    """High-water mark should only increase, never decrease."""
    shield = DrawdownShield()
    shield.update(50000.0)
    shield.update(48000.0)
    shield.update(49000.0)  # Recovery, but still below 50000

    # Total DD should be calculated from 50000, not 49000
    assert shield.total_drawdown_pct > 0.0
    assert shield.total_drawdown_pct == pytest.approx(2.0, abs=0.1)
