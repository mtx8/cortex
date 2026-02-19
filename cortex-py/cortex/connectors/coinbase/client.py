"""Coinbase Advanced Trade connector — crypto order management.

Sandbox-only for Phase 1. The $500 notional cap mirrors
the equity pipeline's pre-trade risk check.  All secrets
come from config/env, never hardcoded.
"""

from __future__ import annotations

import time
import uuid
from dataclasses import dataclass, field

import structlog

log = structlog.get_logger()

# ---------------------------------------------------------------------------
# Data models
# ---------------------------------------------------------------------------


@dataclass
class CryptoBalance:
    currency: str
    available: float
    hold: float

    @property
    def total(self) -> float:
        return self.available + self.hold


@dataclass
class CryptoOrder:
    symbol: str
    side: str  # "buy" | "sell"
    quantity: float
    order_type: str  # "market" | "limit"
    status: str  # "pending" | "submitted" | "filled" | "rejected" | "cancelled"
    estimated_price: float = 0.0
    fill_price: float = 0.0
    order_id: str = ""
    rejection_reason: str | None = None
    created_at: float = field(default_factory=time.time)


# ---------------------------------------------------------------------------
# Supported trading pairs
# ---------------------------------------------------------------------------

_SUPPORTED_PAIRS: list[str] = [
    "BTC-USD",
    "ETH-USD",
    "SOL-USD",
    "DOGE-USD",
    "AVAX-USD",
    "LINK-USD",
    "ADA-USD",
    "DOT-USD",
]

# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------


class CoinbaseClient:
    """Thin wrapper around Coinbase Advanced Trade API.

    Phase 1 runs in sandbox mode only — no real money.
    """

    def __init__(
        self,
        api_key: str,
        private_key: str,
        *,
        sandbox: bool = True,
        max_notional: float = 500.0,
    ) -> None:
        self._api_key = api_key
        self._private_key = private_key
        self._sandbox = sandbox
        self._max_notional = max_notional
        self._connected = False
        log.info(
            "coinbase.client_init",
            sandbox=sandbox,
            max_notional=max_notional,
        )

    # -- properties ---------------------------------------------------------

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def supported_pairs(self) -> list[str]:
        return list(_SUPPORTED_PAIRS)

    # -- balances -----------------------------------------------------------

    async def get_balances(self) -> list[CryptoBalance]:
        """Return account balances.

        In sandbox mode returns mock data. In real mode would call
        the Coinbase Advanced Trade ``/accounts`` endpoint.
        """
        if self._sandbox:
            log.debug("coinbase.get_balances.sandbox")
            return [
                CryptoBalance(currency="BTC", available=0.5, hold=0.0),
                CryptoBalance(currency="ETH", available=5.0, hold=0.0),
                CryptoBalance(currency="USD", available=10_000.0, hold=0.0),
            ]
        # Real implementation would go here
        log.warning("coinbase.get_balances.live_not_implemented")
        return []

    # -- orders -------------------------------------------------------------

    async def submit_order(self, order: CryptoOrder) -> CryptoOrder:
        """Submit an order with pre-trade notional cap enforcement.

        Returns the order with updated status and metadata.
        """
        # --- notional cap check ---
        if order.estimated_price > 0:
            notional = order.quantity * order.estimated_price
            if notional > self._max_notional:
                log.warning(
                    "coinbase.order_rejected.notional_cap",
                    notional=notional,
                    max_notional=self._max_notional,
                    symbol=order.symbol,
                )
                order.status = "rejected"
                order.rejection_reason = (
                    f"Notional value ${notional:,.2f} exceeds "
                    f"cap ${self._max_notional:,.2f}"
                )
                return order

        if self._sandbox:
            return self._simulate_fill(order)

        # Real implementation would go here
        log.warning("coinbase.submit_order.live_not_implemented")
        order.status = "rejected"
        order.rejection_reason = "Live trading not implemented"
        return order

    def _simulate_fill(self, order: CryptoOrder) -> CryptoOrder:
        """Sandbox: simulate an immediate fill with mock pricing."""
        order.order_id = str(uuid.uuid4())
        order.status = "filled"
        order.fill_price = order.estimated_price if order.estimated_price > 0 else 50_000.0
        log.info(
            "coinbase.order_filled.sandbox",
            order_id=order.order_id,
            symbol=order.symbol,
            side=order.side,
            quantity=order.quantity,
            fill_price=order.fill_price,
        )
        return order

    async def cancel_order(self, order_id: str) -> bool:
        """Cancel an open order. Sandbox always returns True."""
        if self._sandbox:
            log.info("coinbase.order_cancelled.sandbox", order_id=order_id)
            return True
        # Real implementation would go here
        log.warning("coinbase.cancel_order.live_not_implemented")
        return False

    # -- serialisation ------------------------------------------------------

    def to_dict(self) -> dict:
        return {
            "connected": self.is_connected,
            "sandbox": self._sandbox,
            "max_notional": self._max_notional,
            "supported_pairs": len(self.supported_pairs),
        }
