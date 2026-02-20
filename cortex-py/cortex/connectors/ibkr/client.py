"""IBKR Connection Manager — handles TWS API connection lifecycle.
Uses ib_async for async compatibility. Reconnects automatically.
Position reconciliation on every reconnect.

Per CLAUDE.md: ALL IBKR API calls go through rate_limiter.py wrappers."""

from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

import structlog

if TYPE_CHECKING:
    from cortex.connectors.ibkr.rate_limiter import IBKRRateLimiter

log = structlog.get_logger()


@dataclass
class IBKRConfig:
    host: str = "127.0.0.1"
    port: int = 4001  # IB Gateway paper: 4002, live: 4001
    client_id: int = 1
    max_reconnect_attempts: int = 10
    reconnect_delay_seconds: float = 5.0
    paper_trading: bool = True


class IBKRConnectionManager:
    def __init__(self, config: IBKRConfig, rate_limiter: IBKRRateLimiter | None = None):
        self._config = config
        self._connected = False
        self._reconnect_count = 0
        self._ib = None  # Will be ib_async.IB instance
        self._rate_limiter = rate_limiter

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def reconnect_count(self) -> int:
        return self._reconnect_count

    async def connect(self) -> bool:
        try:
            if self._rate_limiter:
                await self._rate_limiter.acquire_general()
            from ib_async import IB
            self._ib = IB()
            await self._ib.connectAsync(
                host=self._config.host,
                port=self._config.port,
                clientId=self._config.client_id,
            )
            self._connected = True
            log.info("ibkr.connected", port=self._config.port, client_id=self._config.client_id)
            return True
        except Exception as e:
            log.error("ibkr.connect_failed", error=str(e))
            self._connected = False
            return False

    async def disconnect(self) -> None:
        if self._ib:
            self._ib.disconnect()
            self._connected = False
            log.info("ibkr.disconnected")

    async def reconnect(self) -> bool:
        self._reconnect_count += 1
        log.warning("ibkr.reconnecting", attempt=self._reconnect_count)
        await self.disconnect()
        success = await self.connect()
        if success:
            await self._reconcile_positions()
        return success

    async def place_order(self, contract, order):
        """Submit an order through IBKR. Rate-limited per CLAUDE.md."""
        if self._rate_limiter:
            await self._rate_limiter.acquire_order()
        if not self._ib:
            raise RuntimeError("IBKR not connected")
        return self._ib.placeOrder(contract, order)

    async def get_positions(self):
        """Fetch current positions. Rate-limited per CLAUDE.md."""
        if self._rate_limiter:
            await self._rate_limiter.acquire_account()
        if not self._ib:
            raise RuntimeError("IBKR not connected")
        return self._ib.positions()

    async def get_account_summary(self):
        """Fetch account summary. Rate-limited per CLAUDE.md."""
        if self._rate_limiter:
            await self._rate_limiter.acquire_account()
        if not self._ib:
            raise RuntimeError("IBKR not connected")
        return self._ib.accountSummary()

    async def get_historical_data(self, contract, **kwargs):
        """Fetch historical bar data. Rate-limited per CLAUDE.md."""
        if self._rate_limiter:
            await self._rate_limiter.acquire_historical()
        if not self._ib:
            raise RuntimeError("IBKR not connected")
        return await self._ib.reqHistoricalDataAsync(contract, **kwargs)

    def subscribe_market_data(self, contract, symbol: str):
        """Subscribe to streaming market data. Checks market data limit per CLAUDE.md."""
        if self._rate_limiter:
            if not self._rate_limiter.subscribe_market_data(symbol):
                raise RuntimeError(
                    f"Market data limit reached ({self._rate_limiter.active_subscriptions} "
                    f"active). Cannot subscribe to {symbol}."
                )
        if not self._ib:
            raise RuntimeError("IBKR not connected")
        return self._ib.reqMktData(contract)

    def unsubscribe_market_data(self, contract, symbol: str):
        """Cancel streaming market data subscription."""
        if self._rate_limiter:
            self._rate_limiter.unsubscribe_market_data(symbol)
        if self._ib:
            self._ib.cancelMktData(contract)

    async def _reconcile_positions(self) -> None:
        """Fetch true positions from IBKR and reconcile with local state.
        Called on every reconnect to prevent phantom positions."""
        if not self._ib:
            return
        try:
            if self._rate_limiter:
                await self._rate_limiter.acquire_account()
            positions = self._ib.positions()
            log.info("ibkr.positions_reconciled", count=len(positions))
        except Exception as e:
            log.error("ibkr.reconcile_failed", error=str(e))
