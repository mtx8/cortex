"""Tests for Black-Scholes-Merton options pricing calculator."""

import math
import pytest

from cortex.calculators.options_pricing import (
    black_scholes,
    greeks,
    implied_volatility,
    profit_matrix,
    Greeks,
    OptionLeg,
)


# ─── Black-Scholes Pricing Tests ────────────────────────────────────

class TestBlackScholes:
    """Test BSM option pricing against known analytical values.

    Reference values computed independently using standard BSM formula:
    S=100, K=100, T=1, r=0.05, sigma=0.20
    Call ~ 10.4506, Put ~ 5.5735 (via put-call parity)
    """

    def test_atm_call_price(self):
        """ATM call: S=K=100, T=1yr, r=5%, vol=20%."""
        price = black_scholes(100, 100, 1.0, 0.05, 0.20, "call")
        assert abs(price - 10.4506) < 0.01

    def test_atm_put_price(self):
        """ATM put: S=K=100, T=1yr, r=5%, vol=20%."""
        price = black_scholes(100, 100, 1.0, 0.05, 0.20, "put")
        assert abs(price - 5.5735) < 0.01

    def test_put_call_parity(self):
        """Verify put-call parity: C - P = S - K*exp(-rT)."""
        S, K, T, r, sigma = 100, 100, 1.0, 0.05, 0.20
        call = black_scholes(S, K, T, r, sigma, "call")
        put = black_scholes(S, K, T, r, sigma, "put")
        parity = S - K * math.exp(-r * T)
        assert abs((call - put) - parity) < 1e-6

    def test_itm_call(self):
        """Deep ITM call should be close to intrinsic + time value."""
        price = black_scholes(150, 100, 1.0, 0.05, 0.20, "call")
        # Must be worth at least the intrinsic value
        assert price >= 50.0
        # Should have some time value above intrinsic
        assert price > 50.0

    def test_itm_put(self):
        """Deep ITM put should be close to intrinsic + time value."""
        price = black_scholes(50, 100, 1.0, 0.05, 0.20, "put")
        # Must be worth at least the discounted intrinsic
        assert price >= 45.0

    def test_otm_call(self):
        """Deep OTM call should be near zero but positive."""
        price = black_scholes(50, 100, 0.25, 0.05, 0.20, "call")
        assert price >= 0.0
        assert price < 1.0  # Very unlikely to cross 100 from 50 in 3 months

    def test_otm_put(self):
        """Deep OTM put should be near zero but positive."""
        price = black_scholes(150, 100, 0.25, 0.05, 0.20, "put")
        assert price >= 0.0
        assert price < 1.0

    def test_at_expiry_call_itm(self):
        """At expiry, call = max(S-K, 0)."""
        price = black_scholes(110, 100, 0.0, 0.05, 0.20, "call")
        assert abs(price - 10.0) < 1e-6

    def test_at_expiry_call_otm(self):
        """At expiry, OTM call = 0."""
        price = black_scholes(90, 100, 0.0, 0.05, 0.20, "call")
        assert abs(price) < 1e-6

    def test_at_expiry_put_itm(self):
        """At expiry, put = max(K-S, 0)."""
        price = black_scholes(90, 100, 0.0, 0.05, 0.20, "put")
        assert abs(price - 10.0) < 1e-6

    def test_at_expiry_put_otm(self):
        """At expiry, OTM put = 0."""
        price = black_scholes(110, 100, 0.0, 0.05, 0.20, "put")
        assert abs(price) < 1e-6

    def test_higher_vol_higher_price(self):
        """Higher volatility should increase option price."""
        low_vol = black_scholes(100, 100, 1.0, 0.05, 0.10, "call")
        high_vol = black_scholes(100, 100, 1.0, 0.05, 0.40, "call")
        assert high_vol > low_vol

    def test_longer_expiry_higher_price(self):
        """Longer time to expiry should increase call price (r > 0)."""
        short = black_scholes(100, 100, 0.25, 0.05, 0.20, "call")
        long = black_scholes(100, 100, 2.0, 0.05, 0.20, "call")
        assert long > short


# ─── Greeks Tests ────────────────────────────────────────────────────

class TestGreeks:
    """Test Greek values for reasonableness and known properties."""

    def test_atm_call_delta(self):
        """ATM call delta should be approximately 0.5 (slightly above due to drift)."""
        g = greeks(100, 100, 1.0, 0.05, 0.20, "call")
        assert 0.50 < g.delta < 0.70

    def test_atm_put_delta(self):
        """ATM put delta should be negative and near -0.5 (shifted by drift)."""
        g = greeks(100, 100, 1.0, 0.05, 0.20, "put")
        assert -0.30 > g.delta > -0.70

    def test_call_put_delta_relationship(self):
        """Call delta - Put delta = 1."""
        call_g = greeks(100, 100, 1.0, 0.05, 0.20, "call")
        put_g = greeks(100, 100, 1.0, 0.05, 0.20, "put")
        assert abs((call_g.delta - put_g.delta) - 1.0) < 1e-6

    def test_gamma_positive(self):
        """Gamma should always be positive for long options."""
        g = greeks(100, 100, 1.0, 0.05, 0.20, "call")
        assert g.gamma > 0

    def test_gamma_same_call_put(self):
        """Gamma is the same for calls and puts with same parameters."""
        call_g = greeks(100, 100, 1.0, 0.05, 0.20, "call")
        put_g = greeks(100, 100, 1.0, 0.05, 0.20, "put")
        assert abs(call_g.gamma - put_g.gamma) < 1e-10

    def test_theta_negative_for_long(self):
        """Theta should be negative (time decay hurts long options)."""
        g = greeks(100, 100, 1.0, 0.05, 0.20, "call")
        assert g.theta < 0

    def test_vega_positive(self):
        """Vega should be positive (higher vol = higher option price)."""
        g = greeks(100, 100, 1.0, 0.05, 0.20, "call")
        assert g.vega > 0

    def test_vega_same_call_put(self):
        """Vega is the same for calls and puts with same parameters."""
        call_g = greeks(100, 100, 1.0, 0.05, 0.20, "call")
        put_g = greeks(100, 100, 1.0, 0.05, 0.20, "put")
        assert abs(call_g.vega - put_g.vega) < 1e-10

    def test_call_rho_positive(self):
        """Call rho should be positive (higher rates help call holders)."""
        g = greeks(100, 100, 1.0, 0.05, 0.20, "call")
        assert g.rho > 0

    def test_put_rho_negative(self):
        """Put rho should be negative (higher rates hurt put holders)."""
        g = greeks(100, 100, 1.0, 0.05, 0.20, "put")
        assert g.rho < 0

    def test_deep_itm_call_delta_near_one(self):
        """Deep ITM call delta should approach 1."""
        g = greeks(200, 100, 1.0, 0.05, 0.20, "call")
        assert g.delta > 0.95

    def test_deep_otm_call_delta_near_zero(self):
        """Deep OTM call delta should approach 0."""
        g = greeks(50, 100, 0.25, 0.05, 0.20, "call")
        assert g.delta < 0.05

    def test_greeks_returns_dataclass(self):
        """Verify Greeks returns a proper dataclass."""
        g = greeks(100, 100, 1.0, 0.05, 0.20, "call")
        assert isinstance(g, Greeks)
        assert hasattr(g, "delta")
        assert hasattr(g, "gamma")
        assert hasattr(g, "theta")
        assert hasattr(g, "vega")
        assert hasattr(g, "rho")


# ─── Implied Volatility Tests ───────────────────────────────────────

class TestImpliedVolatility:
    """Test IV solver against known prices."""

    def test_iv_round_trip_call(self):
        """Price a call with known vol, then recover vol from IV solver."""
        S, K, T, r, sigma = 100, 100, 1.0, 0.05, 0.25
        price = black_scholes(S, K, T, r, sigma, "call")
        recovered = implied_volatility(price, S, K, T, r, "call")
        assert recovered is not None
        assert abs(recovered - sigma) < 0.001

    def test_iv_round_trip_put(self):
        """Price a put with known vol, then recover vol from IV solver."""
        S, K, T, r, sigma = 100, 100, 0.5, 0.05, 0.30
        price = black_scholes(S, K, T, r, sigma, "put")
        recovered = implied_volatility(price, S, K, T, r, "put")
        assert recovered is not None
        assert abs(recovered - sigma) < 0.001

    def test_iv_itm_call(self):
        """IV solver with ITM call."""
        S, K, T, r, sigma = 110, 100, 1.0, 0.05, 0.20
        price = black_scholes(S, K, T, r, sigma, "call")
        recovered = implied_volatility(price, S, K, T, r, "call")
        assert recovered is not None
        assert abs(recovered - sigma) < 0.001

    def test_iv_otm_put(self):
        """IV solver with OTM put."""
        S, K, T, r, sigma = 110, 100, 0.5, 0.05, 0.35
        price = black_scholes(S, K, T, r, sigma, "put")
        recovered = implied_volatility(price, S, K, T, r, "put")
        assert recovered is not None
        assert abs(recovered - sigma) < 0.001

    def test_iv_high_vol(self):
        """IV solver with high volatility (meme stock style)."""
        S, K, T, r, sigma = 100, 100, 0.25, 0.05, 1.50
        price = black_scholes(S, K, T, r, sigma, "call")
        recovered = implied_volatility(price, S, K, T, r, "call")
        assert recovered is not None
        assert abs(recovered - sigma) < 0.01

    def test_iv_low_vol(self):
        """IV solver with low volatility."""
        S, K, T, r, sigma = 100, 100, 1.0, 0.05, 0.05
        price = black_scholes(S, K, T, r, sigma, "call")
        recovered = implied_volatility(price, S, K, T, r, "call")
        assert recovered is not None
        assert abs(recovered - sigma) < 0.001

    def test_iv_expired_returns_none(self):
        """IV solver should return None for expired options."""
        result = implied_volatility(5.0, 100, 100, 0.0, 0.05, "call")
        assert result is None

    def test_iv_zero_price_returns_none(self):
        """IV solver should return None for zero market price."""
        result = implied_volatility(0.0, 100, 100, 1.0, 0.05, "call")
        assert result is None


# ─── Profit Matrix Tests ────────────────────────────────────────────

class TestProfitMatrix:
    """Test P&L surface generation for multi-leg strategies."""

    def test_long_call_profit_matrix(self):
        """Simple long call — profit above breakeven at expiry."""
        legs = [OptionLeg(strike=100, option_type="call", quantity=1, premium=5.0, expiry_years=0.25)]
        result = profit_matrix(legs, price_range=(80, 120), price_steps=20)

        assert "prices" in result
        assert "dates" in result
        assert "matrix" in result
        assert "max_profit" in result
        assert "max_loss" in result
        assert "breakevens" in result

        assert len(result["prices"]) == 20
        assert len(result["matrix"]) > 0
        assert len(result["matrix"][0]) == 20

        # At expiry, max loss should be approximately the premium paid
        expiry_pnl = result["matrix"][-1]
        assert min(expiry_pnl) == pytest.approx(-5.0, abs=0.5)

        # At high prices, should be profitable
        assert max(expiry_pnl) > 0

    def test_long_put_profit_matrix(self):
        """Long put — profit below breakeven at expiry."""
        legs = [OptionLeg(strike=100, option_type="put", quantity=1, premium=5.0, expiry_years=0.25)]
        result = profit_matrix(legs, price_range=(80, 120), price_steps=20)

        expiry_pnl = result["matrix"][-1]
        # At low prices (80), should be profitable
        assert expiry_pnl[0] > 0
        # At high prices (120), max loss = premium
        assert expiry_pnl[-1] == pytest.approx(-5.0, abs=0.5)

    def test_bull_call_spread(self):
        """Bull call spread: long 100C, short 110C."""
        legs = [
            OptionLeg(strike=100, option_type="call", quantity=1, premium=5.0, expiry_years=0.25),
            OptionLeg(strike=110, option_type="call", quantity=-1, premium=2.0, expiry_years=0.25),
        ]
        result = profit_matrix(legs, price_range=(80, 130), price_steps=30)

        expiry_pnl = result["matrix"][-1]
        # Max loss = net debit (5 - 2 = 3)
        assert min(expiry_pnl) == pytest.approx(-3.0, abs=0.5)
        # Max profit = spread width - net debit = 10 - 3 = 7
        assert max(expiry_pnl) == pytest.approx(7.0, abs=0.5)

    def test_iron_condor(self):
        """Iron condor: short 95P, long 90P, short 105C, long 110C."""
        legs = [
            OptionLeg(strike=95, option_type="put", quantity=-1, premium=3.0, expiry_years=0.25),
            OptionLeg(strike=90, option_type="put", quantity=1, premium=1.0, expiry_years=0.25),
            OptionLeg(strike=105, option_type="call", quantity=-1, premium=3.0, expiry_years=0.25),
            OptionLeg(strike=110, option_type="call", quantity=1, premium=1.0, expiry_years=0.25),
        ]
        result = profit_matrix(legs, price_range=(80, 120), price_steps=40)

        expiry_pnl = result["matrix"][-1]
        # Max profit = net credit = -3 + 1 - 3 + 1 = -4 (net credit of 4)
        assert max(expiry_pnl) > 0
        # Max loss = spread width - net credit = 5 - 4 = 1 (negative)
        assert min(expiry_pnl) < 0

    def test_breakevens(self):
        """Breakeven detection for a long call."""
        legs = [OptionLeg(strike=100, option_type="call", quantity=1, premium=5.0, expiry_years=0.25)]
        result = profit_matrix(legs, price_range=(90, 120), price_steps=100)

        # Should find a breakeven near 105 (strike + premium)
        assert len(result["breakevens"]) >= 1
        be = result["breakevens"][0]
        assert abs(be - 105.0) < 1.0

    def test_empty_legs(self):
        """Empty legs should return empty result."""
        result = profit_matrix([], price_range=(80, 120))
        assert result["prices"] == []
        assert result["matrix"] == []
        assert result["max_profit"] == 0.0
        assert result["max_loss"] == 0.0

    def test_matrix_dimensions(self):
        """Verify matrix dimensions match price_steps and date_steps."""
        legs = [OptionLeg(strike=100, option_type="call", quantity=1, premium=5.0, expiry_years=0.5)]
        result = profit_matrix(
            legs,
            price_range=(80, 120),
            price_steps=25,
            date_steps=8,
        )
        assert len(result["prices"]) == 25
        assert len(result["dates"]) == 8
        assert len(result["matrix"]) == 8
        for row in result["matrix"]:
            assert len(row) == 25
