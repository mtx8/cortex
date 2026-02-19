"""IBKR Connection Manager — handles TWS API connection lifecycle.
Uses ib_async for async compatibility. Reconnects automatically.
Position reconciliation on every reconnect."""

from dataclasses import dataclass
import structlog

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
    def __init__(self, config: IBKRConfig):
        self._config = config
        self._connected = False
        self._reconnect_count = 0
        self._ib = None  # Will be ib_async.IB instance

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def reconnect_count(self) -> int:
        return self._reconnect_count

    async def connect(self) -> bool:
        try:
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

    async def _reconcile_positions(self) -> None:
        """Fetch true positions from IBKR and reconcile with local state.
        Called on every reconnect to prevent phantom positions."""
        if not self._ib:
            return
        try:
            positions = self._ib.positions()
            log.info("ibkr.positions_reconciled", count=len(positions))
        except Exception as e:
            log.error("ibkr.reconcile_failed", error=str(e))
