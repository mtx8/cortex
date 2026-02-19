"""Position Sizer — calculates optimal position sizes using Kelly criterion
with fixed-fractional fallback and volatility adjustment.

Uses quarter-Kelly to be conservative:
  f* = 0.25 * (p*b - q) / b
  where p=win_prob, b=avg_win/avg_loss, q=1-p

Falls back to fixed-fractional (1% of NAV) when:
  - Insufficient trade history for Kelly
  - Kelly suggests >5% of NAV
  - Kelly suggests negative (don't trade)
"""

import math
from dataclasses import dataclass
import structlog

log = structlog.get_logger()


@dataclass
class SizingRequest:
    symbol: str
    asset_class: str  # "equity" | "option" | "crypto"
    entry_price: float
    stop_loss_price: float
    nav: float
    win_rate: float | None = None  # historical win probability
    avg_win: float | None = None  # average win amount
    avg_loss: float | None = None  # average loss amount
    volatility: float | None = None  # annualized volatility (e.g. 0.30 = 30%)


@dataclass
class SizingResult:
    recommended_quantity: int
    recommended_dollar_amount: float
    position_pct_of_nav: float
    method_used: str  # "quarter_kelly" | "fixed_fractional" | "vol_adjusted"
    kelly_fraction: float | None = None
    risk_per_share: float = 0.0
    max_loss_estimate: float = 0.0


class PositionSizer:
    def __init__(
        self,
        max_position_pct: float = 5.0,
        fixed_fractional_pct: float = 1.0,
        min_trade_history: int = 30,
        target_volatility: float = 0.20,
        max_single_loss_usd: float = 500.0,
    ):
        self._max_position_pct = max_position_pct
        self._fixed_fractional_pct = fixed_fractional_pct
        self._min_history = min_trade_history
        self._target_vol = target_volatility
        self._max_loss = max_single_loss_usd

    def calculate(self, request: SizingRequest) -> SizingResult:
        if request.nav <= 0 or request.entry_price <= 0:
            return self._zero_result("invalid_input")

        risk_per_share = abs(request.entry_price - request.stop_loss_price)
        if risk_per_share <= 0:
            return self._zero_result("no_stop_loss")

        # Try Kelly first
        kelly_result = self._try_kelly(request, risk_per_share)
        if kelly_result is not None:
            return kelly_result

        # Try vol-adjusted sizing for crypto
        if request.asset_class == "crypto" and request.volatility is not None:
            vol_result = self._vol_adjusted(request, risk_per_share)
            if vol_result is not None:
                return vol_result

        # Fallback: fixed fractional
        return self._fixed_fractional(request, risk_per_share)

    def _try_kelly(
        self, request: SizingRequest, risk_per_share: float
    ) -> SizingResult | None:
        if (
            request.win_rate is None
            or request.avg_win is None
            or request.avg_loss is None
        ):
            return None

        if request.avg_loss <= 0:
            return None

        p = request.win_rate
        q = 1.0 - p
        b = request.avg_win / request.avg_loss

        kelly_full = (p * b - q) / b if b > 0 else 0.0

        # Negative Kelly = don't trade
        if kelly_full <= 0:
            return self._zero_result("kelly_negative")

        kelly_quarter = kelly_full * 0.25

        # Cap at max position %
        max_fraction = self._max_position_pct / 100.0
        capped = min(kelly_quarter, max_fraction)

        dollar_amount = request.nav * capped
        # Also cap by max single loss
        max_qty_by_loss = self._max_loss / risk_per_share if risk_per_share > 0 else 0
        qty_by_kelly = dollar_amount / request.entry_price
        quantity = min(qty_by_kelly, max_qty_by_loss)
        quantity = max(1, int(quantity))

        actual_dollar = quantity * request.entry_price
        actual_pct = (actual_dollar / request.nav) * 100

        return SizingResult(
            recommended_quantity=quantity,
            recommended_dollar_amount=actual_dollar,
            position_pct_of_nav=actual_pct,
            method_used="quarter_kelly",
            kelly_fraction=kelly_quarter,
            risk_per_share=risk_per_share,
            max_loss_estimate=quantity * risk_per_share,
        )

    def _vol_adjusted(
        self, request: SizingRequest, risk_per_share: float
    ) -> SizingResult | None:
        if request.volatility is None or request.volatility <= 0:
            return None

        # Scale position inversely to volatility
        vol_scalar = self._target_vol / request.volatility
        vol_scalar = min(vol_scalar, 2.0)  # Never more than 2x leverage
        vol_scalar = max(vol_scalar, 0.1)  # Never less than 10% of normal

        base_dollar = request.nav * (self._fixed_fractional_pct / 100.0)
        adjusted_dollar = base_dollar * vol_scalar

        # Cap at max position %
        max_dollar = request.nav * (self._max_position_pct / 100.0)
        adjusted_dollar = min(adjusted_dollar, max_dollar)

        # Cap by max single loss
        max_qty_by_loss = self._max_loss / risk_per_share if risk_per_share > 0 else 0
        qty = adjusted_dollar / request.entry_price
        quantity = min(qty, max_qty_by_loss)
        quantity = max(1, int(quantity))

        actual_dollar = quantity * request.entry_price
        actual_pct = (actual_dollar / request.nav) * 100

        return SizingResult(
            recommended_quantity=quantity,
            recommended_dollar_amount=actual_dollar,
            position_pct_of_nav=actual_pct,
            method_used="vol_adjusted",
            risk_per_share=risk_per_share,
            max_loss_estimate=quantity * risk_per_share,
        )

    def _fixed_fractional(
        self, request: SizingRequest, risk_per_share: float
    ) -> SizingResult:
        dollar_amount = request.nav * (self._fixed_fractional_pct / 100.0)

        # Cap at max position %
        max_dollar = request.nav * (self._max_position_pct / 100.0)
        dollar_amount = min(dollar_amount, max_dollar)

        # Cap by max single loss
        max_qty_by_loss = self._max_loss / risk_per_share if risk_per_share > 0 else 0
        qty = dollar_amount / request.entry_price
        quantity = min(qty, max_qty_by_loss)
        quantity = max(1, int(quantity))

        actual_dollar = quantity * request.entry_price
        actual_pct = (actual_dollar / request.nav) * 100

        return SizingResult(
            recommended_quantity=quantity,
            recommended_dollar_amount=actual_dollar,
            position_pct_of_nav=actual_pct,
            method_used="fixed_fractional",
            risk_per_share=risk_per_share,
            max_loss_estimate=quantity * risk_per_share,
        )

    @staticmethod
    def _zero_result(reason: str) -> SizingResult:
        return SizingResult(
            recommended_quantity=0,
            recommended_dollar_amount=0.0,
            position_pct_of_nav=0.0,
            method_used=reason,
        )
