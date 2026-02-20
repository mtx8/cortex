"""IBKR API rate limiter.

Interactive Brokers has these rate limits:
- Market data: 50 lines (tickers) of streaming data
- Historical data: 60 requests per 10 minutes (pacing violations)
- Order submission: effectively unlimited but good practice to limit
- Account data: 1 request per second

Per CLAUDE.md: ALL IBKR API calls go through rate_limiter.py wrappers.
"""

import asyncio
import time
import structlog
from functools import wraps
from aiolimiter import AsyncLimiter

log = structlog.get_logger()


class IBKRRateLimiter:
    """Rate limiter for all IBKR API calls. Per CLAUDE.md, this is mandatory."""

    def __init__(self):
        # Historical data: max 6 per minute (conservative, IBKR allows ~6/min effectively)
        self.historical = AsyncLimiter(6, 60)

        # Market data subscriptions: max 50 concurrent
        self._active_market_data: set[str] = set()
        self._market_data_limit = 50

        # Order submissions: max 50 per second (very generous)
        self.orders = AsyncLimiter(50, 1)

        # Account/portfolio requests: 1 per second
        self.account = AsyncLimiter(1, 1)

        # General API calls: 50 per second
        self.general = AsyncLimiter(50, 1)

        self._stats = {
            "historical_requests": 0,
            "order_requests": 0,
            "account_requests": 0,
            "general_requests": 0,
            "rate_limited_waits": 0,
        }

    async def acquire_historical(self) -> None:
        """Acquire a slot for historical data request."""
        await self.historical.acquire()
        self._stats["historical_requests"] += 1

    async def acquire_order(self) -> None:
        """Acquire a slot for order submission."""
        await self.orders.acquire()
        self._stats["order_requests"] += 1

    async def acquire_account(self) -> None:
        """Acquire a slot for account data request."""
        await self.account.acquire()
        self._stats["account_requests"] += 1

    async def acquire_general(self) -> None:
        """Acquire a slot for general API call."""
        await self.general.acquire()
        self._stats["general_requests"] += 1

    def can_subscribe_market_data(self, symbol: str) -> bool:
        """Check if we can subscribe to another market data line."""
        return len(self._active_market_data) < self._market_data_limit or symbol in self._active_market_data

    def subscribe_market_data(self, symbol: str) -> bool:
        """Register a market data subscription."""
        if not self.can_subscribe_market_data(symbol):
            log.warning("ibkr.market_data_limit", current=len(self._active_market_data), limit=self._market_data_limit)
            return False
        self._active_market_data.add(symbol)
        return True

    def unsubscribe_market_data(self, symbol: str) -> None:
        """Unregister a market data subscription."""
        self._active_market_data.discard(symbol)

    @property
    def active_subscriptions(self) -> int:
        return len(self._active_market_data)

    def to_dict(self) -> dict:
        return {
            **self._stats,
            "active_market_data": self.active_subscriptions,
            "market_data_limit": self._market_data_limit,
        }
