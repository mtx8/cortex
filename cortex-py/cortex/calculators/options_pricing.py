"""Black-Scholes-Merton options pricing calculator.

Provides analytical pricing, Greeks computation, implied volatility
solving, and multi-leg profit/loss matrix generation for the Options
Calculator view in the Swift client.

Uses math + scipy.stats.norm for the standard normal distribution.
"""

import math
from dataclasses import dataclass
from typing import Literal

from scipy.stats import norm

import structlog

log = structlog.get_logger()

OptionType = Literal["call", "put"]

# Minimum time-to-expiry to avoid division by zero (roughly 1 minute)
_MIN_T = 1e-10
# IV solver limits
_IV_MAX_ITERATIONS = 100
_IV_TOLERANCE = 1e-6
_IV_INITIAL_GUESS = 0.25
_IV_LOWER = 0.001
_IV_UPPER = 5.0


def _d1(S: float, K: float, T: float, r: float, sigma: float) -> float:
    """Compute d1 in the Black-Scholes formula."""
    T = max(T, _MIN_T)
    return (math.log(S / K) + (r + 0.5 * sigma**2) * T) / (sigma * math.sqrt(T))


def _d2(S: float, K: float, T: float, r: float, sigma: float) -> float:
    """Compute d2 in the Black-Scholes formula."""
    T = max(T, _MIN_T)
    return _d1(S, K, T, r, sigma) - sigma * math.sqrt(T)


def black_scholes(
    S: float,
    K: float,
    T: float,
    r: float,
    sigma: float,
    option_type: OptionType = "call",
) -> float:
    """Calculate the Black-Scholes option price.

    Args:
        S: Current underlying price.
        K: Strike price.
        T: Time to expiration in years (e.g., 0.25 = 3 months).
        r: Risk-free interest rate (annualized, e.g., 0.05 = 5%).
        sigma: Volatility (annualized, e.g., 0.20 = 20%).
        option_type: "call" or "put".

    Returns:
        Theoretical option price.
    """
    if T <= 0:
        # At expiry — intrinsic value only
        if option_type == "call":
            return max(S - K, 0.0)
        return max(K - S, 0.0)

    d1 = _d1(S, K, T, r, sigma)
    d2 = _d2(S, K, T, r, sigma)

    if option_type == "call":
        return S * norm.cdf(d1) - K * math.exp(-r * T) * norm.cdf(d2)
    else:
        return K * math.exp(-r * T) * norm.cdf(-d2) - S * norm.cdf(-d1)


@dataclass
class Greeks:
    """Option Greeks — sensitivity measures."""

    delta: float
    gamma: float
    theta: float  # per day
    vega: float  # per 1% vol move
    rho: float  # per 1% rate move


def greeks(
    S: float,
    K: float,
    T: float,
    r: float,
    sigma: float,
    option_type: OptionType = "call",
) -> Greeks:
    """Calculate the Black-Scholes Greeks.

    Args:
        S: Current underlying price.
        K: Strike price.
        T: Time to expiration in years.
        r: Risk-free interest rate (annualized).
        sigma: Volatility (annualized).
        option_type: "call" or "put".

    Returns:
        Greeks dataclass with delta, gamma, theta (per day), vega (per 1% vol),
        and rho (per 1% rate).
    """
    T = max(T, _MIN_T)
    d1 = _d1(S, K, T, r, sigma)
    d2 = _d2(S, K, T, r, sigma)
    sqrt_T = math.sqrt(T)

    # Gamma is the same for calls and puts
    gamma = norm.pdf(d1) / (S * sigma * sqrt_T)

    # Vega is the same for calls and puts (per 1% vol move = / 100)
    vega = S * norm.pdf(d1) * sqrt_T / 100.0

    if option_type == "call":
        delta = norm.cdf(d1)
        theta = (
            -S * norm.pdf(d1) * sigma / (2 * sqrt_T)
            - r * K * math.exp(-r * T) * norm.cdf(d2)
        ) / 365.0  # Convert to per-day
        rho = K * T * math.exp(-r * T) * norm.cdf(d2) / 100.0
    else:
        delta = norm.cdf(d1) - 1.0
        theta = (
            -S * norm.pdf(d1) * sigma / (2 * sqrt_T)
            + r * K * math.exp(-r * T) * norm.cdf(-d2)
        ) / 365.0
        rho = -K * T * math.exp(-r * T) * norm.cdf(-d2) / 100.0

    return Greeks(
        delta=delta,
        gamma=gamma,
        theta=theta,
        vega=vega,
        rho=rho,
    )


def implied_volatility(
    market_price: float,
    S: float,
    K: float,
    T: float,
    r: float,
    option_type: OptionType = "call",
) -> float | None:
    """Solve for implied volatility using Newton's method.

    Args:
        market_price: Observed market price of the option.
        S: Current underlying price.
        K: Strike price.
        T: Time to expiration in years.
        r: Risk-free interest rate (annualized).
        option_type: "call" or "put".

    Returns:
        Implied volatility (annualized), or None if solver fails to converge.
    """
    if T <= 0 or market_price <= 0:
        return None

    sigma = _IV_INITIAL_GUESS

    for _ in range(_IV_MAX_ITERATIONS):
        price = black_scholes(S, K, T, r, sigma, option_type)
        diff = price - market_price

        if abs(diff) < _IV_TOLERANCE:
            return sigma

        # Vega for Newton step (raw vega, not per-1%-move)
        d1 = _d1(S, K, T, r, sigma)
        raw_vega = S * norm.pdf(d1) * math.sqrt(T)

        if raw_vega < 1e-12:
            # Vega too small for reliable Newton step — fall back to bisection
            return _iv_bisection(market_price, S, K, T, r, option_type)

        sigma -= diff / raw_vega
        sigma = max(_IV_LOWER, min(_IV_UPPER, sigma))

    log.warning(
        "iv_solver.no_convergence",
        market_price=market_price,
        S=S,
        K=K,
        T=T,
        last_sigma=sigma,
    )
    return None


def _iv_bisection(
    market_price: float,
    S: float,
    K: float,
    T: float,
    r: float,
    option_type: OptionType,
) -> float | None:
    """Bisection fallback for IV when Newton's method fails."""
    lo, hi = _IV_LOWER, _IV_UPPER

    for _ in range(_IV_MAX_ITERATIONS):
        mid = (lo + hi) / 2.0
        price = black_scholes(S, K, T, r, mid, option_type)

        if abs(price - market_price) < _IV_TOLERANCE:
            return mid

        if price > market_price:
            hi = mid
        else:
            lo = mid

    return None


@dataclass
class OptionLeg:
    """A single leg in a multi-leg options strategy."""

    strike: float
    option_type: OptionType
    quantity: int  # positive = long, negative = short
    premium: float  # price paid/received per contract
    expiry_years: float  # time to expiry in years


def profit_matrix(
    legs: list[OptionLeg],
    price_range: tuple[float, float],
    price_steps: int = 50,
    date_range: tuple[float, float] | None = None,
    date_steps: int = 10,
    r: float = 0.05,
    sigma: float = 0.25,
) -> dict:
    """Calculate a P&L surface for a multi-leg options strategy.

    Returns a dict with:
        - prices: list of underlying price points
        - dates: list of time-to-expiry values (years)
        - matrix: 2D list [date_idx][price_idx] of P&L values
        - max_profit: maximum P&L in the matrix
        - max_loss: minimum P&L in the matrix
        - breakevens: list of approximate breakeven prices at expiry

    Args:
        legs: List of OptionLeg defining the strategy.
        price_range: (min_price, max_price) for the underlying.
        price_steps: Number of price points to compute.
        date_range: (max_T, min_T) time range in years. Defaults to
                    (max leg expiry, 0).
        date_steps: Number of time steps.
        r: Risk-free rate for BSM pricing of pre-expiry values.
        sigma: Volatility assumption for pre-expiry values.
    """
    if not legs:
        return {
            "prices": [],
            "dates": [],
            "matrix": [],
            "max_profit": 0.0,
            "max_loss": 0.0,
            "breakevens": [],
        }

    min_price, max_price = price_range
    prices = [
        min_price + i * (max_price - min_price) / max(price_steps - 1, 1)
        for i in range(price_steps)
    ]

    # Time range defaults to max leg expiry down to 0
    if date_range is None:
        max_T = max(leg.expiry_years for leg in legs)
        date_range = (max_T, 0.0)

    t_start, t_end = date_range
    dates = [
        t_start - i * (t_start - t_end) / max(date_steps - 1, 1)
        for i in range(date_steps)
    ]

    # Net premium paid (debit = positive cost, credit = negative cost)
    net_debit = sum(leg.premium * leg.quantity for leg in legs)

    matrix: list[list[float]] = []

    for t in dates:
        row: list[float] = []
        for price in prices:
            total_value = 0.0
            for leg in legs:
                # Time remaining for this leg at this date step
                leg_T = max(leg.expiry_years - (t_start - t), 0.0)

                if leg_T <= 0:
                    # At or past expiry — intrinsic value
                    if leg.option_type == "call":
                        intrinsic = max(price - leg.strike, 0.0)
                    else:
                        intrinsic = max(leg.strike - price, 0.0)
                    total_value += intrinsic * leg.quantity
                else:
                    # Pre-expiry — use BSM theoretical value
                    theoretical = black_scholes(
                        price, leg.strike, leg_T, r, sigma, leg.option_type,
                    )
                    total_value += theoretical * leg.quantity

            # P&L = current value - cost basis
            pnl = total_value - net_debit
            row.append(round(pnl, 2))
        matrix.append(row)

    # Find breakevens at expiry (last row, where T ~ 0)
    expiry_row = matrix[-1] if matrix else []
    breakevens = _find_breakevens(prices, expiry_row)

    flat = [v for row in matrix for v in row]

    return {
        "prices": [round(p, 2) for p in prices],
        "dates": [round(d, 6) for d in dates],
        "matrix": matrix,
        "max_profit": max(flat) if flat else 0.0,
        "max_loss": min(flat) if flat else 0.0,
        "breakevens": breakevens,
    }


def _find_breakevens(prices: list[float], pnl_row: list[float]) -> list[float]:
    """Find approximate breakeven points by linear interpolation."""
    breakevens = []
    for i in range(len(pnl_row) - 1):
        if pnl_row[i] * pnl_row[i + 1] < 0:
            # Sign change — interpolate
            frac = abs(pnl_row[i]) / (abs(pnl_row[i]) + abs(pnl_row[i + 1]))
            be = prices[i] + frac * (prices[i + 1] - prices[i])
            breakevens.append(round(be, 2))
    return breakevens
