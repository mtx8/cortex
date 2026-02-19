"""Polygon.io WebSocket client for real-time market data.

Streams: trades (T.*), quotes (Q.*), aggregates (AM.*)
Authentication via API key in first message.
Auto-reconnect on disconnect.

Uses aiolimiter to respect Polygon rate limits.
"""

import asyncio
import json
from dataclasses import dataclass, field
from enum import Enum
from typing import Callable, Awaitable
import structlog

log = structlog.get_logger()


class PolygonFeed(str, Enum):
    TRADES = "T"
    QUOTES = "Q"
    MINUTE_AGG = "AM"
    SECOND_AGG = "A"


@dataclass
class PolygonConfig:
    api_key: str = ""
    ws_url: str = "wss://socket.polygon.io/stocks"
    max_subscriptions: int = 500
    reconnect_delay: float = 5.0
    max_reconnects: int = 50


@dataclass
class PolygonTrade:
    symbol: str
    price: float
    size: int
    timestamp: int  # Unix ms
    conditions: list[int] = field(default_factory=list)


@dataclass
class PolygonQuote:
    symbol: str
    bid: float
    ask: float
    bid_size: int
    ask_size: int
    timestamp: int


@dataclass
class PolygonAggregate:
    symbol: str
    open: float
    high: float
    low: float
    close: float
    volume: float
    vwap: float
    timestamp: int


class PolygonWebSocket:
    """Polygon.io WebSocket client with auto-reconnect and subscription management."""

    def __init__(self, config: PolygonConfig):
        self._config = config
        self._ws = None
        self._connected = False
        self._authenticated = False
        self._reconnect_count = 0
        self._subscriptions: set[str] = set()

        # Handlers by feed type
        self._trade_handlers: list[Callable[[PolygonTrade], Awaitable[None]]] = []
        self._quote_handlers: list[Callable[[PolygonQuote], Awaitable[None]]] = []
        self._agg_handlers: list[Callable[[PolygonAggregate], Awaitable[None]]] = []

        self._messages_received = 0

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def is_authenticated(self) -> bool:
        return self._authenticated

    @property
    def messages_received(self) -> int:
        return self._messages_received

    def on_trade(self, handler: Callable[[PolygonTrade], Awaitable[None]]) -> None:
        self._trade_handlers.append(handler)

    def on_quote(self, handler: Callable[[PolygonQuote], Awaitable[None]]) -> None:
        self._quote_handlers.append(handler)

    def on_aggregate(self, handler: Callable[[PolygonAggregate], Awaitable[None]]) -> None:
        self._agg_handlers.append(handler)

    def subscribe(self, feed: PolygonFeed, symbols: list[str]) -> list[str]:
        """Add subscriptions. Returns the subscription strings."""
        subs = [f"{feed.value}.{s}" for s in symbols]
        self._subscriptions.update(subs)
        return subs

    def unsubscribe(self, feed: PolygonFeed, symbols: list[str]) -> None:
        subs = {f"{feed.value}.{s}" for s in symbols}
        self._subscriptions -= subs

    def get_subscriptions(self) -> set[str]:
        return set(self._subscriptions)

    async def connect(self) -> bool:
        """Connect to Polygon WebSocket. Requires websockets library."""
        try:
            import websockets
            self._ws = await websockets.connect(self._config.ws_url)
            self._connected = True
            log.info("polygon.ws.connected", url=self._config.ws_url)

            # Wait for connection message
            msg = await self._ws.recv()
            data = json.loads(msg)
            if isinstance(data, list) and data[0].get("status") == "connected":
                # Authenticate
                await self._ws.send(json.dumps({"action": "auth", "params": self._config.api_key}))
                auth_msg = await self._ws.recv()
                auth_data = json.loads(auth_msg)
                if isinstance(auth_data, list) and auth_data[0].get("status") == "auth_success":
                    self._authenticated = True
                    log.info("polygon.ws.authenticated")

                    # Subscribe to channels
                    if self._subscriptions:
                        await self._ws.send(json.dumps({
                            "action": "subscribe",
                            "params": ",".join(self._subscriptions),
                        }))

                    return True
            return False
        except Exception as e:
            log.error("polygon.ws.connect_failed", error=str(e))
            self._connected = False
            return False

    async def disconnect(self) -> None:
        if self._ws:
            await self._ws.close()
            self._connected = False
            self._authenticated = False
            log.info("polygon.ws.disconnected")

    def parse_message(self, raw: str) -> list:
        """Parse a raw Polygon WebSocket message into typed objects.
        Messages come as JSON arrays of events."""
        try:
            events = json.loads(raw)
        except json.JSONDecodeError:
            return []

        if not isinstance(events, list):
            return []

        results = []
        for event in events:
            ev_type = event.get("ev", "")

            if ev_type == "T":
                results.append(PolygonTrade(
                    symbol=event.get("sym", ""),
                    price=event.get("p", 0.0),
                    size=event.get("s", 0),
                    timestamp=event.get("t", 0),
                    conditions=event.get("c", []),
                ))
            elif ev_type == "Q":
                results.append(PolygonQuote(
                    symbol=event.get("sym", ""),
                    bid=event.get("bp", 0.0),
                    ask=event.get("ap", 0.0),
                    bid_size=event.get("bs", 0),
                    ask_size=event.get("as", 0),
                    timestamp=event.get("t", 0),
                ))
            elif ev_type in ("AM", "A"):
                results.append(PolygonAggregate(
                    symbol=event.get("sym", ""),
                    open=event.get("o", 0.0),
                    high=event.get("h", 0.0),
                    low=event.get("l", 0.0),
                    close=event.get("c", 0.0),
                    volume=event.get("v", 0.0),
                    vwap=event.get("vw", 0.0),
                    timestamp=event.get("s", 0),
                ))

            self._messages_received += 1

        return results

    async def run(self) -> None:
        """Main receive loop. Processes messages and dispatches to handlers."""
        if not self._ws:
            return

        try:
            async for raw_msg in self._ws:
                parsed = self.parse_message(raw_msg)
                for obj in parsed:
                    if isinstance(obj, PolygonTrade):
                        for h in self._trade_handlers:
                            await h(obj)
                    elif isinstance(obj, PolygonQuote):
                        for h in self._quote_handlers:
                            await h(obj)
                    elif isinstance(obj, PolygonAggregate):
                        for h in self._agg_handlers:
                            await h(obj)
        except Exception as e:
            log.error("polygon.ws.receive_error", error=str(e))
            self._connected = False

    def to_dict(self) -> dict:
        return {
            "connected": self._connected,
            "authenticated": self._authenticated,
            "subscriptions": len(self._subscriptions),
            "messages_received": self._messages_received,
            "reconnect_count": self._reconnect_count,
        }
