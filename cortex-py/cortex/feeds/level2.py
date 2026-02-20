"""Level 2 (Market Depth) data feed for IBKR integration.

Streams order book data (bids/asks at multiple price levels) from IBKR
and broadcasts L2_UPDATE messages to connected Swift clients.

Per CLAUDE.md: ALL IBKR API calls go through rate_limiter.py wrappers.
"""

import asyncio
import time
from dataclasses import dataclass, field

import structlog

from cortex.api.protocol import MessageType, CortexMessage

log = structlog.get_logger()


@dataclass
class L2Row:
    """A single price level in the order book."""

    price: float
    size: int
    num_orders: int = 0


@dataclass
class L2BookSnapshot:
    """Point-in-time snapshot of the Level 2 order book."""

    symbol: str
    bids: list[L2Row] = field(default_factory=list)
    asks: list[L2Row] = field(default_factory=list)
    timestamp: float = 0.0

    def to_dict(self) -> dict:
        return {
            "symbol": self.symbol,
            "bids": [
                {"price": r.price, "size": r.size, "orders": r.num_orders}
                for r in self.bids
            ],
            "asks": [
                {"price": r.price, "size": r.size, "orders": r.num_orders}
                for r in self.asks
            ],
            "timestamp": self.timestamp,
        }


class Level2Feed:
    """Streams Level 2 order book data from IBKR.

    Usage:
        feed = Level2Feed(ibkr_manager, broadcaster, rate_limiter)
        await feed.subscribe("AAPL", num_rows=20)
        # ... data arrives via push_update() callbacks ...
        await feed.unsubscribe()
    """

    def __init__(self, ibkr_manager, broadcaster, rate_limiter=None):
        self._ibkr = ibkr_manager
        self._broadcaster = broadcaster
        self._rate_limiter = rate_limiter
        self._active_symbol: str | None = None
        self._book = L2BookSnapshot(symbol="")
        self._running = False
        self._num_rows = 20

    async def subscribe(self, symbol: str, num_rows: int = 20) -> None:
        """Subscribe to Level 2 data for a symbol.

        Unsubscribes from any existing symbol first. Per CLAUDE.md,
        IBKR calls go through the rate limiter.
        """
        if self._active_symbol:
            await self.unsubscribe()

        # Rate limit the IBKR subscription request
        if self._rate_limiter is not None:
            await self._rate_limiter.acquire_general()

        self._active_symbol = symbol
        self._num_rows = num_rows
        self._book = L2BookSnapshot(symbol=symbol)
        self._running = True
        log.info("level2.subscribed", symbol=symbol, rows=num_rows)

    async def unsubscribe(self) -> None:
        """Unsubscribe from Level 2 data for the active symbol."""
        if not self._active_symbol:
            return

        # Rate limit the IBKR unsubscription request
        if self._rate_limiter is not None:
            await self._rate_limiter.acquire_general()

        symbol = self._active_symbol
        self._running = False
        self._active_symbol = None
        self._book = L2BookSnapshot(symbol="")
        log.info("level2.unsubscribed", symbol=symbol)

    async def push_update(self, bids: list[dict], asks: list[dict]) -> None:
        """Push a new order book update from IBKR callback.

        Called by the IBKR connection manager when depth-of-market data
        changes. Converts raw dicts to L2Row objects and broadcasts to
        connected WebSocket clients.

        Args:
            bids: List of dicts with keys: price, size, num_orders.
            asks: List of dicts with keys: price, size, num_orders.
        """
        if not self._active_symbol:
            return

        self._book.bids = [L2Row(**b) for b in bids]
        self._book.asks = [L2Row(**a) for a in asks]
        self._book.timestamp = time.time()

        msg = CortexMessage(
            type=MessageType.L2_UPDATE,
            payload=self._book.to_dict(),
        )
        await self._broadcaster.broadcast(msg)

    @property
    def active_symbol(self) -> str | None:
        return self._active_symbol

    @property
    def book(self) -> L2BookSnapshot:
        return self._book

    @property
    def is_running(self) -> bool:
        return self._running

    def to_dict(self) -> dict:
        return {
            "active_symbol": self._active_symbol,
            "running": self._running,
            "num_rows": self._num_rows,
        }
