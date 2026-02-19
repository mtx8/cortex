"""Market data feed — polls Polygon snapshots and broadcasts to Swift clients.

Runs as a background asyncio task. Every poll_interval seconds it:
1. Fetches snapshots for the watchlist from PolygonRESTClient
2. Broadcasts MARKET_QUOTE messages to connected Swift clients via WSBroadcaster
3. Publishes price signals to the SignalBus for ALPHA squadron agents
"""

import asyncio
import structlog

from cortex.api.protocol import MessageType, CortexMessage
from cortex.api.ws_broadcaster import WSBroadcaster
from cortex.connectors.polygon.rest_client import PolygonRESTClient
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority

log = structlog.get_logger()

DEFAULT_WATCHLIST: list[str] = [
    "AAPL", "NVDA", "MSFT", "TSLA", "META", "AMZN", "GOOG", "SPY", "QQQ",
]


class MarketDataFeed:
    """Polls Polygon snapshots and fans out market quotes to WebSocket clients
    and the internal SignalBus."""

    def __init__(
        self,
        polygon_client: PolygonRESTClient,
        broadcaster: WSBroadcaster,
        bus: SignalBus,
        watchlist: list[str] | None = None,
        poll_interval: float = 15.0,
    ):
        self._polygon = polygon_client
        self._broadcaster = broadcaster
        self._bus = bus
        self._watchlist: list[str] = list(watchlist or DEFAULT_WATCHLIST)
        self._poll_interval = poll_interval
        self._running = False
        self._poll_count = 0
        self._last_quotes: dict[str, dict] = {}
        self._task: asyncio.Task | None = None

    @property
    def watchlist(self) -> list[str]:
        return list(self._watchlist)

    @property
    def poll_count(self) -> int:
        return self._poll_count

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def last_quotes(self) -> dict[str, dict]:
        return dict(self._last_quotes)

    def add_ticker(self, ticker: str) -> None:
        ticker = ticker.upper()
        if ticker not in self._watchlist:
            self._watchlist.append(ticker)
            log.info("feed.ticker_added", ticker=ticker, watchlist_size=len(self._watchlist))

    def remove_ticker(self, ticker: str) -> None:
        ticker = ticker.upper()
        if ticker in self._watchlist:
            self._watchlist.remove(ticker)
            self._last_quotes.pop(ticker, None)
            log.info("feed.ticker_removed", ticker=ticker, watchlist_size=len(self._watchlist))

    async def _poll_once(self) -> list[dict]:
        """Fetch snapshots, broadcast to WS clients, publish to bus. Returns snapshots."""
        if not self._watchlist:
            return []

        try:
            snapshots = await self._polygon.get_snapshots(self._watchlist)
        except Exception as e:
            log.error("feed.poll_error", error=str(e))
            return []

        self._poll_count += 1

        for quote in snapshots:
            ticker = quote.get("ticker", "")
            self._last_quotes[ticker] = quote

            # Broadcast to Swift clients
            msg = CortexMessage(
                type=MessageType.MARKET_QUOTE,
                payload=quote,
            )
            await self._broadcaster.broadcast(msg)

            # Publish to SignalBus for ALPHA squadron agents
            await self._bus.publish(Signal(
                signal_id=f"market_quote_{ticker}_{self._poll_count}",
                source_agent="market_data_feed",
                source_squadron="feeds",
                signal_type="feeds.market_quote",
                payload=quote,
                priority=SignalPriority.LOW,
            ))

        log.debug(
            "feed.poll_complete",
            poll=self._poll_count,
            tickers=len(snapshots),
        )
        return snapshots

    async def start(self) -> None:
        """Start the polling loop. Call this as an asyncio task."""
        self._running = True
        log.info(
            "feed.starting",
            watchlist=self._watchlist,
            interval=self._poll_interval,
        )

        while self._running:
            await self._poll_once()
            try:
                await asyncio.sleep(self._poll_interval)
            except asyncio.CancelledError:
                break

        log.info("feed.stopped", polls=self._poll_count)

    async def stop(self) -> None:
        """Signal the polling loop to stop."""
        self._running = False
        log.info("feed.stop_requested")

    def to_dict(self) -> dict:
        return {
            "running": self._running,
            "poll_count": self._poll_count,
            "watchlist": self._watchlist,
            "poll_interval": self._poll_interval,
            "tracked_tickers": len(self._last_quotes),
        }
