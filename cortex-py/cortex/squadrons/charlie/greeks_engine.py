"""CHARLIE Greeks Engine + IV Surface Mapper.

Black-Scholes Greeks calculator and implied-volatility surface built from
scratch using only the Python ``math`` module.  No scipy / numpy required.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from enum import Enum

from cortex.orchestrator.bus import SignalBus, Signal
from cortex.squadrons.base import BaseAgent


# ---------------------------------------------------------------------------
# Enums & data classes
# ---------------------------------------------------------------------------

class OptionType(Enum):
    CALL = "call"
    PUT = "put"


@dataclass
class GreeksResult:
    delta: float
    gamma: float
    theta: float
    vega: float
    rho: float
    iv: float


@dataclass
class IVPoint:
    strike: float
    expiry_days: int
    iv: float
    option_type: OptionType


# ---------------------------------------------------------------------------
# IV Surface
# ---------------------------------------------------------------------------

class IVSurface:
    """Grid of :class:`IVPoint` objects with convenience lookups."""

    def __init__(self) -> None:
        self._points: list[IVPoint] = []

    # -- mutators -----------------------------------------------------------

    def add_point(self, point: IVPoint) -> None:
        self._points.append(point)

    # -- queries ------------------------------------------------------------

    def get_iv(
        self,
        strike: float,
        expiry_days: int,
        option_type: OptionType,
    ) -> float | None:
        """Nearest-neighbour lookup across strike and expiry_days."""
        candidates = [p for p in self._points if p.option_type == option_type]
        if not candidates:
            return None
        best = min(
            candidates,
            key=lambda p: (abs(p.strike - strike) + abs(p.expiry_days - expiry_days)),
        )
        return best.iv

    def get_smile(self, expiry_days: int) -> list[IVPoint]:
        """All strikes for a given expiry, sorted by strike."""
        return sorted(
            [p for p in self._points if p.expiry_days == expiry_days],
            key=lambda p: p.strike,
        )

    def get_term_structure(self, strike: float) -> list[IVPoint]:
        """All expiries for a given strike, sorted by expiry_days."""
        return sorted(
            [p for p in self._points if p.strike == strike],
            key=lambda p: p.expiry_days,
        )

    def get_skew(self, expiry_days: int) -> float | None:
        """25-delta put IV minus 25-delta call IV approximation.

        We approximate by selecting the OTM put with the highest strike
        (closest to 25-delta put) and the OTM call with the lowest strike
        (closest to 25-delta call) within the given expiry slice.
        """
        smile = self.get_smile(expiry_days)
        if not smile:
            return None

        puts = [p for p in smile if p.option_type == OptionType.PUT]
        calls = [p for p in smile if p.option_type == OptionType.CALL]

        if not puts or not calls:
            return None

        # 25-delta put ~= highest-strike OTM put, 25-delta call ~= lowest-strike OTM call
        put_iv = max(puts, key=lambda p: p.strike).iv
        call_iv = min(calls, key=lambda p: p.strike).iv
        return put_iv - call_iv


# ---------------------------------------------------------------------------
# Greeks Engine — pure Black-Scholes computation
# ---------------------------------------------------------------------------

class GreeksEngine:
    """Black-Scholes option pricing and Greeks from first principles."""

    # -- Normal distribution helpers ----------------------------------------

    @staticmethod
    def _norm_cdf(x: float) -> float:
        """Standard normal CDF via ``math.erf``."""
        return 0.5 * (1.0 + math.erf(x / math.sqrt(2.0)))

    @staticmethod
    def _norm_pdf(x: float) -> float:
        """Standard normal PDF."""
        return math.exp(-0.5 * x * x) / math.sqrt(2.0 * math.pi)

    # -- Black-Scholes d1 / d2 ---------------------------------------------

    @staticmethod
    def _d1(
        spot: float,
        strike: float,
        expiry_years: float,
        rate: float,
        iv: float,
    ) -> float:
        return (
            math.log(spot / strike) + (rate + 0.5 * iv * iv) * expiry_years
        ) / (iv * math.sqrt(expiry_years))

    @staticmethod
    def _d2(d1: float, iv: float, expiry_years: float) -> float:
        return d1 - iv * math.sqrt(expiry_years)

    # -- Option price (internal) -------------------------------------------

    def _bs_price(
        self,
        spot: float,
        strike: float,
        expiry_years: float,
        rate: float,
        iv: float,
        option_type: OptionType,
    ) -> float:
        d1 = self._d1(spot, strike, expiry_years, rate, iv)
        d2 = self._d2(d1, iv, expiry_years)
        discount = math.exp(-rate * expiry_years)

        if option_type == OptionType.CALL:
            return spot * self._norm_cdf(d1) - strike * discount * self._norm_cdf(d2)
        else:
            return strike * discount * self._norm_cdf(-d2) - spot * self._norm_cdf(-d1)

    # -- Public API ---------------------------------------------------------

    def calculate_greeks(
        self,
        spot: float,
        strike: float,
        expiry_years: float,
        rate: float,
        iv: float,
        option_type: OptionType,
    ) -> GreeksResult:
        """Compute all Black-Scholes Greeks for a European option."""
        sqrt_t = math.sqrt(expiry_years)
        d1 = self._d1(spot, strike, expiry_years, rate, iv)
        d2 = self._d2(d1, iv, expiry_years)
        discount = math.exp(-rate * expiry_years)
        pdf_d1 = self._norm_pdf(d1)

        # Delta
        if option_type == OptionType.CALL:
            delta = self._norm_cdf(d1)
        else:
            delta = self._norm_cdf(d1) - 1.0

        # Gamma (same for call and put)
        gamma = pdf_d1 / (spot * iv * sqrt_t)

        # Vega (same for call and put) — per 1 unit (not per 1%)
        vega = spot * pdf_d1 * sqrt_t

        # Theta
        common_theta = -(spot * pdf_d1 * iv) / (2.0 * sqrt_t)
        if option_type == OptionType.CALL:
            theta = common_theta - rate * strike * discount * self._norm_cdf(d2)
        else:
            theta = common_theta + rate * strike * discount * self._norm_cdf(-d2)

        # Rho
        if option_type == OptionType.CALL:
            rho = strike * expiry_years * discount * self._norm_cdf(d2)
        else:
            rho = -strike * expiry_years * discount * self._norm_cdf(-d2)

        return GreeksResult(
            delta=delta,
            gamma=gamma,
            theta=theta,
            vega=vega,
            rho=rho,
            iv=iv,
        )

    def implied_volatility(
        self,
        spot: float,
        strike: float,
        expiry_years: float,
        rate: float,
        market_price: float,
        option_type: OptionType,
        tol: float = 1e-8,
        max_iter: int = 200,
    ) -> float:
        """Newton-Raphson solver for Black-Scholes implied volatility."""
        # Initial guess via Brenner-Subrahmanyam approximation
        iv_guess = math.sqrt(2.0 * math.pi / expiry_years) * (market_price / spot)
        iv_guess = max(iv_guess, 0.01)  # floor at 1%

        iv = iv_guess
        for _ in range(max_iter):
            price = self._bs_price(spot, strike, expiry_years, rate, iv, option_type)
            diff = price - market_price

            # Vega as derivative of price w.r.t. iv
            d1 = self._d1(spot, strike, expiry_years, rate, iv)
            vega = spot * self._norm_pdf(d1) * math.sqrt(expiry_years)

            if abs(vega) < 1e-15:
                break

            iv -= diff / vega

            # Keep iv positive
            if iv <= 0:
                iv = 0.001

            if abs(diff) < tol:
                break

        return iv


# ---------------------------------------------------------------------------
# GreeksAgent — thin BaseAgent wrapper
# ---------------------------------------------------------------------------

class GreeksAgent(BaseAgent):
    """Signal-bus agent exposing :class:`GreeksEngine` and :class:`IVSurface`."""

    agent_id: str = "greeks_engine"
    squadron: str = "charlie"
    subscriptions: list[str] = []

    def __init__(self, bus: SignalBus) -> None:
        super().__init__(bus)
        self.engine = GreeksEngine()
        self.surface = IVSurface()

    async def handle_signal(self, signal: Signal) -> None:
        """No-op for now; the agent is query-driven via ``compute_for_chain``."""

    async def compute_for_chain(
        self,
        spot: float,
        strikes: list[float],
        expiries: list[float],
        rate: float,
        option_type: OptionType,
    ) -> list[GreeksResult]:
        """Batch-compute Greeks for every (strike, expiry) combination."""
        results: list[GreeksResult] = []
        for strike in strikes:
            for expiry in expiries:
                # Try to use IV from the surface; fall back to 0.20 (20%)
                iv = self.surface.get_iv(
                    strike,
                    int(expiry * 365),
                    option_type,
                )
                if iv is None:
                    iv = 0.20
                greeks = self.engine.calculate_greeks(
                    spot, strike, expiry, rate, iv, option_type,
                )
                results.append(greeks)
        return results
