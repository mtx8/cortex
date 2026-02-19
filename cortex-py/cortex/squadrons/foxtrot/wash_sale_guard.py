"""FOXTROT Wash Sale Guard — enforces IRS wash sale rules to prevent tax violations.

IRS Wash Sale Rule: If you sell a security at a loss and buy a "substantially
identical" security within 30 days before or after the sale, the loss is
disallowed and added to the cost basis of the replacement shares.

This agent tracks tax lots (FIFO), detects wash sale triggers on both buy and
sell sides, and emits WASH_SALE_BLOCK signals to prevent BRAVO from executing
orders that would create wash sale violations.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from datetime import date, timedelta
import structlog

from cortex.orchestrator.bus import SignalBus, Signal
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class LotRecord:
    """A single tax lot representing a purchase (and optional sale) of shares."""

    symbol: str
    quantity: float
    cost_basis: float  # per-share cost basis
    acquired_date: date
    sold_date: date | None = None
    sold_price: float | None = None
    wash_sale_disallowed: float = 0.0
    adjusted_cost_basis: float | None = None

    @property
    def is_loss(self) -> bool:
        """True when the lot has been sold at a loss."""
        if self.sold_price is None:
            return False
        return self.sold_price < self.cost_basis

    @property
    def realized_gain(self) -> float:
        """Per-share realized gain (negative means loss). Zero if unsold."""
        if self.sold_price is None:
            return 0.0
        return (self.sold_price - self.cost_basis) * self.quantity

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "quantity": self.quantity,
            "cost_basis": self.cost_basis,
            "acquired_date": self.acquired_date.isoformat(),
            "sold_date": self.sold_date.isoformat() if self.sold_date else None,
            "sold_price": self.sold_price,
            "is_loss": self.is_loss,
            "wash_sale_disallowed": self.wash_sale_disallowed,
            "adjusted_cost_basis": self.adjusted_cost_basis,
            "realized_gain": self.realized_gain,
        }


@dataclass
class WashSaleCheck:
    """Result of a wash-sale analysis for a proposed trade."""

    symbol: str
    side: str  # "buy" or "sell"
    is_blocked: bool
    reason: str
    lookback_losses: list[LotRecord] = field(default_factory=list)
    adjusted_basis: float | None = None

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "side": self.side,
            "is_blocked": self.is_blocked,
            "reason": self.reason,
            "lookback_losses": [lr.to_dict() for lr in self.lookback_losses],
            "adjusted_basis": self.adjusted_basis,
        }


# ---------------------------------------------------------------------------
# Agent
# ---------------------------------------------------------------------------

class WashSaleGuard(BaseAgent):
    """Tracks tax lots and enforces IRS 30-day wash sale rules.

    Subscribes to ORDER_FILLED signals from BRAVO to automatically record
    buys and sells.  Exposes methods for pre-trade wash-sale checks so that
    the TradePipeline can query before order submission.
    """

    agent_id: str = "wash_sale_guard"
    squadron: str = "foxtrot"
    subscriptions: list[str] = [SignalTypes.ORDER_FILLED]

    def __init__(self, bus: SignalBus) -> None:
        super().__init__(bus)
        self._lot_ledger: dict[str, list[LotRecord]] = {}
        self._wash_sale_window: int = 30  # days

    # ------------------------------------------------------------------
    # Lot management
    # ------------------------------------------------------------------

    def record_buy(
        self,
        symbol: str,
        quantity: float,
        price: float,
        buy_date: date,
    ) -> LotRecord:
        """Record a purchase and return the new lot.

        If there are realized losses on *symbol* within the wash-sale window
        preceding *buy_date*, the disallowed loss is added to the new lot's
        adjusted cost basis.
        """
        lot = LotRecord(
            symbol=symbol,
            quantity=quantity,
            cost_basis=price,
            acquired_date=buy_date,
        )

        # Check for wash sale: losses realized in the preceding window
        window_start = buy_date - timedelta(days=self._wash_sale_window)
        loss_lots = self._find_loss_lots_in_window(symbol, window_start, buy_date)

        if loss_lots:
            total_disallowed = sum(
                abs(ll.realized_gain) for ll in loss_lots
            )
            per_share_adjustment = total_disallowed / quantity
            lot.adjusted_cost_basis = price + per_share_adjustment
            lot.wash_sale_disallowed = total_disallowed

            # Mark the loss lots as having their loss disallowed
            for ll in loss_lots:
                ll.wash_sale_disallowed = abs(ll.realized_gain)

            log.warning(
                "wash_sale.triggered_on_buy",
                symbol=symbol,
                disallowed=total_disallowed,
                adjusted_basis=lot.adjusted_cost_basis,
            )

        self._lot_ledger.setdefault(symbol, []).append(lot)
        return lot

    def record_sell(
        self,
        symbol: str,
        quantity: float,
        price: float,
        sell_date: date,
    ) -> list[LotRecord]:
        """Record a sale using FIFO lot matching. Returns the matched lots."""
        lots = self._lot_ledger.get(symbol, [])
        unsold = [lot for lot in lots if lot.sold_date is None]
        matched: list[LotRecord] = []
        remaining = quantity

        for lot in unsold:
            if remaining <= 0:
                break

            if lot.quantity <= remaining:
                # Fully consume this lot
                lot.sold_date = sell_date
                lot.sold_price = price
                remaining -= lot.quantity
                matched.append(lot)
            else:
                # Partial lot: split into sold portion and remainder
                sold_portion = LotRecord(
                    symbol=symbol,
                    quantity=remaining,
                    cost_basis=lot.cost_basis,
                    acquired_date=lot.acquired_date,
                    sold_date=sell_date,
                    sold_price=price,
                )
                lot.quantity -= remaining
                matched.append(sold_portion)

                # Insert the sold portion into the ledger right before
                # the original lot so the ledger remains ordered.
                idx = lots.index(lot)
                lots.insert(idx, sold_portion)
                remaining = 0

        return matched

    # ------------------------------------------------------------------
    # Wash-sale checks
    # ------------------------------------------------------------------

    def check_wash_sale(
        self,
        symbol: str,
        side: str,
        proposed_date: date,
    ) -> WashSaleCheck:
        """Analyze whether a proposed trade triggers or risks a wash sale.

        For BUYS:  Check if losses were realized on *symbol* in the past
                   30 days.  If so, the buy triggers a wash sale (loss is
                   disallowed and basis is adjusted).

        For SELLS: Check if there were buys in the past 30 days.  Also
                   warn that buys in the next 30 days would trigger a
                   wash sale if the sell is at a loss.
        """
        window_start = proposed_date - timedelta(days=self._wash_sale_window)

        if side == "buy":
            return self._check_wash_sale_buy(symbol, proposed_date, window_start)
        else:
            return self._check_wash_sale_sell(symbol, proposed_date, window_start)

    def _check_wash_sale_buy(
        self,
        symbol: str,
        proposed_date: date,
        window_start: date,
    ) -> WashSaleCheck:
        loss_lots = self._find_loss_lots_in_window(symbol, window_start, proposed_date)

        if loss_lots:
            total_disallowed = sum(abs(ll.realized_gain) for ll in loss_lots)
            return WashSaleCheck(
                symbol=symbol,
                side="buy",
                is_blocked=True,
                reason=(
                    f"Wash sale: {len(loss_lots)} loss lot(s) realized in the "
                    f"past {self._wash_sale_window} days. "
                    f"Total disallowed loss: ${total_disallowed:.2f}. "
                    f"Cost basis will be adjusted upward."
                ),
                lookback_losses=loss_lots,
                adjusted_basis=total_disallowed,
            )

        return WashSaleCheck(
            symbol=symbol,
            side="buy",
            is_blocked=False,
            reason="No recent losses on this symbol.",
        )

    def _check_wash_sale_sell(
        self,
        symbol: str,
        proposed_date: date,
        window_start: date,
    ) -> WashSaleCheck:
        # Check for buys in the past 30 days
        recent_buys = self._find_buy_lots_in_window(symbol, window_start, proposed_date)

        if recent_buys:
            return WashSaleCheck(
                symbol=symbol,
                side="sell",
                is_blocked=False,
                reason=(
                    f"Warning: {len(recent_buys)} buy(s) in the past "
                    f"{self._wash_sale_window} days. If this sell is at a loss, "
                    f"wash sale rules apply retroactively to those buys."
                ),
                lookback_losses=[],
            )

        return WashSaleCheck(
            symbol=symbol,
            side="sell",
            is_blocked=False,
            reason=(
                "No recent buys. Note: buying this symbol within "
                f"{self._wash_sale_window} days after a loss sale will "
                "trigger a wash sale."
            ),
        )

    def get_blocked_symbols(self, as_of: date) -> list[str]:
        """Return symbols that should not be bought due to recent loss sales."""
        window_start = as_of - timedelta(days=self._wash_sale_window)
        blocked: list[str] = []

        for symbol, lots in self._lot_ledger.items():
            loss_lots = self._find_loss_lots_in_window(symbol, window_start, as_of)
            if loss_lots:
                blocked.append(symbol)

        return sorted(blocked)

    # ------------------------------------------------------------------
    # Queries
    # ------------------------------------------------------------------

    def get_tax_lots(self, symbol: str) -> list[LotRecord]:
        """Return all lots (open and closed) for a symbol."""
        return list(self._lot_ledger.get(symbol, []))

    def get_realized_gains(self, symbol: str) -> float:
        """Total realized gains (positive) and losses (negative) for a symbol."""
        lots = self._lot_ledger.get(symbol, [])
        return sum(lot.realized_gain for lot in lots if lot.sold_date is not None)

    def get_unrealized_pnl(self, symbol: str, current_price: float) -> float:
        """Unrealized P&L across all open lots for a symbol at *current_price*."""
        lots = self._lot_ledger.get(symbol, [])
        return sum(
            (current_price - lot.cost_basis) * lot.quantity
            for lot in lots
            if lot.sold_date is None
        )

    # ------------------------------------------------------------------
    # Signal handler
    # ------------------------------------------------------------------

    async def handle_signal(self, signal: Signal) -> None:
        """Process ORDER_FILLED signals to automatically track lots."""
        if signal.signal_type != SignalTypes.ORDER_FILLED:
            return

        payload = signal.payload
        symbol = payload.get("symbol", "")
        side = payload.get("side", "")
        quantity = float(payload.get("quantity", 0))
        price = float(payload.get("price", 0))
        fill_date_str = payload.get("fill_date")

        if fill_date_str:
            fill_date = date.fromisoformat(fill_date_str)
        else:
            fill_date = date.today()

        if side == "buy":
            lot = self.record_buy(symbol, quantity, price, fill_date)
            if lot.wash_sale_disallowed > 0:
                await self.emit(
                    SignalTypes.WASH_SALE_BLOCK,
                    payload={
                        "symbol": symbol,
                        "disallowed_loss": lot.wash_sale_disallowed,
                        "adjusted_basis": lot.adjusted_cost_basis,
                        "reason": "Wash sale triggered on buy",
                    },
                )
        elif side == "sell":
            self.record_sell(symbol, quantity, price, fill_date)

        log.info(
            "wash_sale_guard.order_processed",
            symbol=symbol,
            side=side,
            quantity=quantity,
            price=price,
        )

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _find_loss_lots_in_window(
        self,
        symbol: str,
        window_start: date,
        window_end: date,
    ) -> list[LotRecord]:
        """Find lots sold at a loss within [window_start, window_end]."""
        lots = self._lot_ledger.get(symbol, [])
        return [
            lot
            for lot in lots
            if (
                lot.sold_date is not None
                and lot.is_loss
                and window_start <= lot.sold_date <= window_end
            )
        ]

    def _find_buy_lots_in_window(
        self,
        symbol: str,
        window_start: date,
        window_end: date,
    ) -> list[LotRecord]:
        """Find lots acquired within [window_start, window_end]."""
        lots = self._lot_ledger.get(symbol, [])
        return [
            lot
            for lot in lots
            if window_start <= lot.acquired_date <= window_end
        ]

    # ------------------------------------------------------------------
    # Serialisation
    # ------------------------------------------------------------------

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "wash_sale_window_days": self._wash_sale_window,
            "tracked_symbols": sorted(self._lot_ledger.keys()),
            "total_lots": sum(
                len(lots) for lots in self._lot_ledger.values()
            ),
            "lots_by_symbol": {
                sym: [lot.to_dict() for lot in lots]
                for sym, lots in self._lot_ledger.items()
            },
        })
        return base
