"""Comprehensive tests for CHARLIE Greeks Engine + IV Surface Mapper.

All tests are deterministic with fixed inputs and use only the ``math``
standard-library module (no numpy / scipy).
"""

import math
import pytest

from cortex.squadrons.charlie.greeks_engine import (
    GreeksEngine,
    GreeksResult,
    IVPoint,
    IVSurface,
    OptionType,
)

# ---------------------------------------------------------------------------
# Shared fixtures
# ---------------------------------------------------------------------------

@pytest.fixture
def engine() -> GreeksEngine:
    return GreeksEngine()


# Common parameters: ATM option, 1-year expiry, 5% rate, 20% vol
SPOT = 100.0
STRIKE_ATM = 100.0
EXPIRY = 1.0        # 1 year
RATE = 0.05
IV = 0.20


# ---------------------------------------------------------------------------
# Delta tests
# ---------------------------------------------------------------------------

class TestDelta:

    def test_call_delta_atm(self, engine: GreeksEngine) -> None:
        """ATM call delta should be approximately 0.5 (slightly above due to drift)."""
        result = engine.calculate_greeks(SPOT, STRIKE_ATM, EXPIRY, RATE, IV, OptionType.CALL)
        assert 0.45 < result.delta < 0.65, f"ATM call delta = {result.delta}"

    def test_put_delta_atm(self, engine: GreeksEngine) -> None:
        """ATM put delta should be approximately -0.5."""
        result = engine.calculate_greeks(SPOT, STRIKE_ATM, EXPIRY, RATE, IV, OptionType.PUT)
        assert -0.65 < result.delta < -0.35, f"ATM put delta = {result.delta}"

    def test_greeks_deep_itm_call(self, engine: GreeksEngine) -> None:
        """Deep ITM call (spot >> strike) should have delta near 1.0."""
        result = engine.calculate_greeks(200.0, 100.0, EXPIRY, RATE, IV, OptionType.CALL)
        assert result.delta > 0.95, f"Deep ITM call delta = {result.delta}"

    def test_greeks_deep_otm_call(self, engine: GreeksEngine) -> None:
        """Deep OTM call (spot << strike) should have delta near 0.0."""
        result = engine.calculate_greeks(50.0, 100.0, EXPIRY, RATE, IV, OptionType.CALL)
        assert result.delta < 0.05, f"Deep OTM call delta = {result.delta}"


# ---------------------------------------------------------------------------
# Price bounds & parity
# ---------------------------------------------------------------------------

class TestPriceBounds:

    def test_call_price_bounds(self, engine: GreeksEngine) -> None:
        """BS call price must be in (0, spot)."""
        price = engine._bs_price(SPOT, STRIKE_ATM, EXPIRY, RATE, IV, OptionType.CALL)
        assert 0 < price < SPOT, f"Call price = {price}"

    def test_put_call_parity(self, engine: GreeksEngine) -> None:
        """Put-call parity: C - P = S - K * exp(-rT)."""
        call = engine._bs_price(SPOT, STRIKE_ATM, EXPIRY, RATE, IV, OptionType.CALL)
        put = engine._bs_price(SPOT, STRIKE_ATM, EXPIRY, RATE, IV, OptionType.PUT)
        parity_rhs = SPOT - STRIKE_ATM * math.exp(-RATE * EXPIRY)
        assert abs((call - put) - parity_rhs) < 1e-10, (
            f"Parity violation: C-P={call - put}, S-Ke^(-rT)={parity_rhs}"
        )


# ---------------------------------------------------------------------------
# Gamma / Vega / Theta
# ---------------------------------------------------------------------------

class TestGreeksSign:

    def test_gamma_positive(self, engine: GreeksEngine) -> None:
        """Gamma is always positive for long options."""
        for ot in (OptionType.CALL, OptionType.PUT):
            result = engine.calculate_greeks(SPOT, STRIKE_ATM, EXPIRY, RATE, IV, ot)
            assert result.gamma > 0, f"Gamma should be positive, got {result.gamma}"

    def test_vega_positive(self, engine: GreeksEngine) -> None:
        """Vega is always positive for long options."""
        for ot in (OptionType.CALL, OptionType.PUT):
            result = engine.calculate_greeks(SPOT, STRIKE_ATM, EXPIRY, RATE, IV, ot)
            assert result.vega > 0, f"Vega should be positive, got {result.vega}"

    def test_theta_negative_call(self, engine: GreeksEngine) -> None:
        """Theta is typically negative for a long call (time decay)."""
        result = engine.calculate_greeks(SPOT, STRIKE_ATM, EXPIRY, RATE, IV, OptionType.CALL)
        assert result.theta < 0, f"Call theta should be negative, got {result.theta}"


# ---------------------------------------------------------------------------
# Implied-volatility solver
# ---------------------------------------------------------------------------

class TestIVSolver:

    def test_iv_solver_roundtrip(self, engine: GreeksEngine) -> None:
        """Compute a BS price from known IV, then recover IV via Newton-Raphson."""
        known_iv = 0.30
        price = engine._bs_price(SPOT, STRIKE_ATM, EXPIRY, RATE, known_iv, OptionType.CALL)
        recovered_iv = engine.implied_volatility(
            SPOT, STRIKE_ATM, EXPIRY, RATE, price, OptionType.CALL,
        )
        assert abs(recovered_iv - known_iv) < 1e-6, (
            f"IV roundtrip failed: expected {known_iv}, got {recovered_iv}"
        )

    def test_iv_solver_roundtrip_put(self, engine: GreeksEngine) -> None:
        """Same roundtrip for a put option."""
        known_iv = 0.25
        price = engine._bs_price(SPOT, 110.0, EXPIRY, RATE, known_iv, OptionType.PUT)
        recovered_iv = engine.implied_volatility(
            SPOT, 110.0, EXPIRY, RATE, price, OptionType.PUT,
        )
        assert abs(recovered_iv - known_iv) < 1e-6, (
            f"IV roundtrip (put) failed: expected {known_iv}, got {recovered_iv}"
        )


# ---------------------------------------------------------------------------
# IV Surface
# ---------------------------------------------------------------------------

class TestIVSurface:

    @pytest.fixture
    def surface(self) -> IVSurface:
        s = IVSurface()
        # Build a small surface: 2 expiries x 3 strikes x 2 option types
        for expiry_days in (30, 60):
            for strike, call_iv, put_iv in [
                (95.0, 0.22, 0.28),
                (100.0, 0.20, 0.20),
                (105.0, 0.18, 0.24),
            ]:
                s.add_point(IVPoint(strike, expiry_days, call_iv, OptionType.CALL))
                s.add_point(IVPoint(strike, expiry_days, put_iv, OptionType.PUT))
        return s

    def test_iv_surface_add_and_retrieve(self, surface: IVSurface) -> None:
        """Exact match retrieval returns the stored IV."""
        iv = surface.get_iv(100.0, 30, OptionType.CALL)
        assert iv == 0.20

    def test_iv_surface_nearest_neighbour(self, surface: IVSurface) -> None:
        """When no exact match exists, nearest-neighbour returns closest point."""
        iv = surface.get_iv(101.0, 31, OptionType.CALL)
        # Closest is (100, 30) -> 0.20
        assert iv == 0.20

    def test_iv_surface_smile(self, surface: IVSurface) -> None:
        """get_smile returns all points for the given expiry, sorted by strike."""
        smile = surface.get_smile(30)
        expiry_set = {p.expiry_days for p in smile}
        assert expiry_set == {30}
        strikes = [p.strike for p in smile]
        assert strikes == sorted(strikes)
        # 3 strikes x 2 types = 6 points
        assert len(smile) == 6

    def test_iv_surface_term_structure(self, surface: IVSurface) -> None:
        """get_term_structure returns all expiries for a given strike."""
        ts = surface.get_term_structure(100.0)
        strikes = {p.strike for p in ts}
        assert strikes == {100.0}
        expiries = [p.expiry_days for p in ts]
        assert expiries == sorted(expiries)
        # 2 expiries x 2 types = 4 points
        assert len(ts) == 4

    def test_iv_surface_skew(self, surface: IVSurface) -> None:
        """get_skew returns put_iv - call_iv for the given expiry."""
        skew = surface.get_skew(30)
        assert skew is not None
        # highest-strike put IV (105, 0.24) - lowest-strike call IV (95, 0.22)
        assert abs(skew - (0.24 - 0.22)) < 1e-10

    def test_iv_surface_empty(self) -> None:
        """Queries on an empty surface return None / empty."""
        s = IVSurface()
        assert s.get_iv(100.0, 30, OptionType.CALL) is None
        assert s.get_smile(30) == []
        assert s.get_term_structure(100.0) == []
        assert s.get_skew(30) is None
