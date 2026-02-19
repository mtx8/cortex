# Production-Ready Core Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Transform CORTEX from mock demo to live trading platform with real Polygon/Claude APIs, professional UI with collapsible sidebar, searchable charts, Perplexity-style AI chat, and an overhauled War Room.

**Architecture:** Python backend is the single secure data gateway. Swift never calls external APIs directly. TradingView widget handles its own chart rendering. Claude chat flows through Python for server-side context injection. All mock data eliminated.

**Tech Stack:** Swift 5.9/SwiftUI (macOS 14+), Python 3.12/FastAPI/httpx/anthropic, Rust/PyO3 (scanner), Polygon.io REST, Claude API (claude-opus-4-6), Redis for caching.

**Critical Fix:** The Swift WebSocket client sends JSON, but Python protocol.py uses msgpack. Task 1 resolves this mismatch.

---

## Task 1: Fix Protocol Mismatch — Switch Python to JSON

The Swift `WebSocketClient` sends/receives JSON. The Python `protocol.py` uses `msgpack`. They cannot communicate. Switch Python to JSON to match the working Swift client.

**Files:**
- Modify: `cortex-py/cortex/api/protocol.py`
- Modify: `cortex-py/cortex/main.py` (lines 63-66: change `receive_bytes`/msgpack to `receive_json`)
- Test: `cortex-py/tests/test_protocol.py`

**Step 1: Write test for JSON protocol**

```python
# cortex-py/tests/test_protocol.py
import json
import pytest
from cortex.api.protocol import MessageType, CortexMessage, encode_message, decode_message

def test_encode_message_returns_json_string():
    msg = CortexMessage(type=MessageType.PORTFOLIO_UPDATE, payload={"nav": 50000.0})
    encoded = encode_message(msg)
    assert isinstance(encoded, str)
    parsed = json.loads(encoded)
    assert parsed["type"] == "portfolio_update"
    assert parsed["payload"]["nav"] == 50000.0

def test_decode_message_from_json_dict():
    data = {"type": "cmd_kill_switch", "payload": {"reason": "manual"}}
    msg = decode_message(data)
    assert msg.type == MessageType.CMD_KILL_SWITCH
    assert msg.payload["reason"] == "manual"

def test_roundtrip():
    original = CortexMessage(type=MessageType.SIGNAL_FIRED, payload={"symbol": "AAPL", "score": 87.5})
    encoded = encode_message(original)
    decoded = decode_message(json.loads(encoded))
    assert decoded.type == original.type
    assert decoded.payload == original.payload
```

**Step 2: Run test to verify it fails**

Run: `cd cortex-py && python -m pytest tests/test_protocol.py -v`
Expected: FAIL (current encode returns bytes via msgpack, not JSON string)

**Step 3: Rewrite protocol.py to use JSON**

Replace `cortex-py/cortex/api/protocol.py` entirely:

```python
"""JSON-based WebSocket protocol for Swift <-> Python communication."""

from dataclasses import dataclass
from enum import Enum
import time
import orjson


class MessageType(str, Enum):
    # Server -> Client
    PORTFOLIO_UPDATE = "portfolio_update"
    AGENT_UPDATE = "agent_update"
    SIGNAL_FIRED = "signal_fired"
    SCANNER_RESULT = "scanner_result"
    ACTIVITY_EVENT = "activity_event"
    OPPORTUNITY = "opportunity"
    CHAT_RESPONSE = "chat_response"
    CHAT_CHUNK = "chat_chunk"
    KILL_SWITCH_STATUS = "kill_switch_status"
    TICKER_SEARCH_RESULTS = "ticker_search_results"
    MARKET_QUOTE = "market_quote"

    # Client -> Server
    CMD_KILL_SWITCH = "cmd_kill_switch"
    CMD_DISENGAGE_KILL = "cmd_disengage_kill"
    CMD_SET_AUTONOMY = "cmd_set_autonomy"
    CMD_TOGGLE_AGENT = "cmd_toggle_agent"
    CMD_QUICK_TRADE = "cmd_quick_trade"
    CMD_CHAT_MESSAGE = "cmd_chat_message"
    CMD_SUBSCRIBE_SCANNER = "cmd_subscribe_scanner"
    CMD_SEARCH_TICKER = "cmd_search_ticker"
    CMD_REQUEST_QUOTES = "cmd_request_quotes"


@dataclass
class CortexMessage:
    type: MessageType
    payload: dict
    timestamp: float | None = None

    def __post_init__(self):
        if self.timestamp is None:
            self.timestamp = time.time()


def encode_message(msg: CortexMessage) -> str:
    """Encode a CortexMessage to a JSON string for WebSocket transmission."""
    return orjson.dumps({
        "type": msg.type.value,
        "payload": msg.payload,
        "ts": msg.timestamp,
    }).decode("utf-8")


def decode_message(data: dict) -> CortexMessage:
    """Decode a JSON dict (already parsed by FastAPI) into a CortexMessage."""
    type_str = data.get("type", "")
    try:
        msg_type = MessageType(type_str)
    except ValueError:
        msg_type = MessageType.PORTFOLIO_UPDATE  # fallback
    return CortexMessage(
        type=msg_type,
        payload=data.get("payload", data),
        timestamp=data.get("ts"),
    )
```

**Step 4: Update main.py WebSocket handler to use JSON**

In `cortex-py/cortex/main.py`, change the WebSocket endpoint:
- Replace `data = await ws.receive_bytes()` with `data = await ws.receive_json()`
- Replace `decode_message(data)` call to pass the JSON dict directly
- Replace `msg.type == MessageType.CMD_KILL_SWITCH` to use string enum comparison
- In `ws_broadcaster.py`, change `send_bytes(data)` to `send_text(data)` since encode_message now returns a string

**Step 5: Update ws_broadcaster.py broadcast method**

Change `await client.send_bytes(data)` to `await client.send_text(data)` in the broadcast method.

**Step 6: Update MessageRouter.swift to handle new format**

The Swift `MessageRouter` already expects JSON with a `"type"` string key — it routes on `"portfolio_update"`, `"agent_update"`, etc. The new Python string enum values match exactly. No Swift changes needed.

**Step 7: Run tests and verify**

Run: `cd cortex-py && python -m pytest tests/test_protocol.py -v`
Expected: PASS

**Step 8: Commit**

```bash
git add cortex-py/cortex/api/protocol.py cortex-py/cortex/main.py cortex-py/cortex/api/ws_broadcaster.py cortex-py/tests/test_protocol.py
git commit -m "fix: switch protocol from msgpack to JSON — matches Swift WebSocket client"
```

---

## Task 2: Polygon REST Client with Caching

**Files:**
- Create: `cortex-py/cortex/connectors/polygon/rest_client.py`
- Test: `cortex-py/tests/test_polygon_rest.py`

**Step 1: Write tests**

```python
# cortex-py/tests/test_polygon_rest.py
import pytest
from unittest.mock import AsyncMock, patch
from cortex.connectors.polygon.rest_client import PolygonRESTClient

@pytest.fixture
def client():
    return PolygonRESTClient(api_key="test_key")

@pytest.mark.asyncio
async def test_search_tickers(client):
    mock_response = {"results": [
        {"ticker": "AAPL", "name": "Apple Inc.", "market": "stocks", "type": "CS"},
        {"ticker": "AAPLW", "name": "Apple Hospitality", "market": "stocks", "type": "CS"},
    ], "count": 2}
    with patch.object(client._http, "get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value.json.return_value = mock_response
        mock_get.return_value.status_code = 200
        results = await client.search_tickers("AAPL")
    assert len(results) == 2
    assert results[0]["ticker"] == "AAPL"

@pytest.mark.asyncio
async def test_get_previous_close(client):
    mock_response = {"results": [{"T": "AAPL", "c": 188.52, "h": 190.0, "l": 187.0, "o": 188.0, "v": 48500000}]}
    with patch.object(client._http, "get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value.json.return_value = mock_response
        mock_get.return_value.status_code = 200
        result = await client.get_previous_close("AAPL")
    assert result["close"] == 188.52

@pytest.mark.asyncio
async def test_get_snapshot_multiple(client):
    mock_response = {"tickers": [
        {"ticker": "AAPL", "day": {"c": 188.52, "h": 190, "l": 187, "o": 188, "v": 48500000},
         "todaysChange": 2.34, "todaysChangePerc": 1.26},
    ]}
    with patch.object(client._http, "get", new_callable=AsyncMock) as mock_get:
        mock_get.return_value.json.return_value = mock_response
        mock_get.return_value.status_code = 200
        result = await client.get_snapshots(["AAPL"])
    assert "AAPL" in result
```

**Step 2: Run tests to verify they fail**

Run: `cd cortex-py && python -m pytest tests/test_polygon_rest.py -v`
Expected: FAIL (module not found)

**Step 3: Implement PolygonRESTClient**

```python
# cortex-py/cortex/connectors/polygon/rest_client.py
"""Polygon.io REST API client for market data.

Provides: ticker search, previous close, snapshots, candle aggregates.
Rate limited to 5 req/s (free tier). Responses cached in memory with TTL.
"""

import time
import httpx
import structlog
from aiolimiter import AsyncLimiter

log = structlog.get_logger()

_CACHE: dict[str, tuple[float, any]] = {}
_QUOTE_TTL = 15.0  # seconds
_SEARCH_TTL = 300.0  # 5 minutes
_DETAILS_TTL = 3600.0  # 1 hour


def _cache_get(key: str, ttl: float):
    if key in _CACHE:
        ts, val = _CACHE[key]
        if time.time() - ts < ttl:
            return val
    return None


def _cache_set(key: str, val):
    _CACHE[key] = (time.time(), val)


class PolygonRESTClient:
    """Async Polygon.io REST client with rate limiting and caching."""

    BASE_URL = "https://api.polygon.io"

    def __init__(self, api_key: str):
        self._api_key = api_key
        self._http = httpx.AsyncClient(
            base_url=self.BASE_URL,
            params={"apiKey": api_key},
            timeout=10.0,
        )
        self._limiter = AsyncLimiter(5, 1.0)  # 5 req/sec

    async def close(self):
        await self._http.aclose()

    async def _get(self, path: str, params: dict | None = None) -> dict:
        async with self._limiter:
            resp = await self._http.get(path, params=params or {})
            resp.raise_for_status()
            return resp.json()

    async def search_tickers(self, query: str, limit: int = 10) -> list[dict]:
        """Search for tickers matching query. Returns list of {ticker, name, market, type}."""
        cache_key = f"search:{query}:{limit}"
        cached = _cache_get(cache_key, _SEARCH_TTL)
        if cached is not None:
            return cached

        data = await self._get("/v3/reference/tickers", {
            "search": query, "limit": limit, "active": "true",
            "market": "stocks", "order": "asc", "sort": "ticker",
        })
        results = data.get("results", [])
        out = [{"ticker": r["ticker"], "name": r.get("name", ""),
                "market": r.get("market", ""), "type": r.get("type", "")}
               for r in results]
        _cache_set(cache_key, out)
        return out

    async def get_previous_close(self, ticker: str) -> dict:
        """Get previous day's OHLCV for a ticker."""
        cache_key = f"prev:{ticker}"
        cached = _cache_get(cache_key, _QUOTE_TTL)
        if cached is not None:
            return cached

        data = await self._get(f"/v2/aggs/ticker/{ticker}/prev")
        results = data.get("results", [])
        if not results:
            return {}
        r = results[0]
        out = {"ticker": ticker, "open": r.get("o", 0), "high": r.get("h", 0),
               "low": r.get("l", 0), "close": r.get("c", 0), "volume": r.get("v", 0),
               "vwap": r.get("vw", 0)}
        _cache_set(cache_key, out)
        return out

    async def get_snapshots(self, tickers: list[str]) -> dict[str, dict]:
        """Get real-time snapshots for multiple tickers. Returns {ticker: data}."""
        cache_key = f"snap:{','.join(sorted(tickers))}"
        cached = _cache_get(cache_key, _QUOTE_TTL)
        if cached is not None:
            return cached

        data = await self._get("/v2/snapshot/locale/us/markets/stocks/tickers", {
            "tickers": ",".join(tickers),
        })
        result = {}
        for t in data.get("tickers", []):
            ticker = t.get("ticker", "")
            day = t.get("day", {})
            result[ticker] = {
                "ticker": ticker,
                "price": day.get("c", 0),
                "open": day.get("o", 0),
                "high": day.get("h", 0),
                "low": day.get("l", 0),
                "volume": day.get("v", 0),
                "change": t.get("todaysChange", 0),
                "change_pct": t.get("todaysChangePerc", 0),
            }
        _cache_set(cache_key, result)
        return result

    async def get_aggregates(self, ticker: str, timespan: str = "day",
                             multiplier: int = 1, from_date: str = "", to_date: str = "",
                             limit: int = 120) -> list[dict]:
        """Get OHLCV candles. timespan: minute, hour, day, week."""
        data = await self._get(
            f"/v2/aggs/ticker/{ticker}/range/{multiplier}/{timespan}/{from_date}/{to_date}",
            {"limit": limit, "adjusted": "true", "sort": "asc"},
        )
        return [{"timestamp": r["t"], "open": r["o"], "high": r["h"],
                 "low": r["l"], "close": r["c"], "volume": r["v"]}
                for r in data.get("results", [])]
```

**Step 4: Run tests**

Run: `cd cortex-py && python -m pytest tests/test_polygon_rest.py -v`
Expected: PASS

**Step 5: Commit**

```bash
git add cortex-py/cortex/connectors/polygon/rest_client.py cortex-py/tests/test_polygon_rest.py
git commit -m "feat: add Polygon.io REST client with rate limiting and caching"
```

---

## Task 3: Market Data Feed Service

Periodically fetches quotes from Polygon and pushes to Swift via WebSocket. Also feeds ALPHA squadron agents.

**Files:**
- Create: `cortex-py/cortex/feeds/market_data.py`
- Modify: `cortex-py/cortex/main.py` (add to `create_app_components`, start in lifespan)
- Test: `cortex-py/tests/test_market_feed.py`

**Step 1: Write test**

```python
# cortex-py/tests/test_market_feed.py
import pytest
from unittest.mock import AsyncMock, MagicMock
from cortex.feeds.market_data import MarketDataFeed

@pytest.mark.asyncio
async def test_feed_fetches_and_broadcasts():
    mock_polygon = AsyncMock()
    mock_polygon.get_snapshots.return_value = {
        "AAPL": {"ticker": "AAPL", "price": 190.0, "change": 2.0, "change_pct": 1.06, "volume": 50000000},
    }
    mock_broadcaster = AsyncMock()
    mock_bus = MagicMock()

    feed = MarketDataFeed(
        polygon=mock_polygon,
        broadcaster=mock_broadcaster,
        bus=mock_bus,
        symbols=["AAPL"],
    )
    await feed.fetch_and_broadcast()
    mock_polygon.get_snapshots.assert_called_once_with(["AAPL"])
    mock_broadcaster.broadcast.assert_called_once()
```

**Step 2: Implement MarketDataFeed**

```python
# cortex-py/cortex/feeds/market_data.py
"""Market data feed — polls Polygon REST and pushes quotes to Swift + signal bus."""

import asyncio
import structlog
from cortex.api.protocol import CortexMessage, MessageType
from cortex.connectors.polygon.rest_client import PolygonRESTClient
from cortex.api.ws_broadcaster import WSBroadcaster
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes

log = structlog.get_logger()

DEFAULT_WATCHLIST = ["AAPL", "NVDA", "MSFT", "TSLA", "META", "AMZN", "GOOG", "SPY", "QQQ"]


class MarketDataFeed:
    """Polls Polygon for quotes and pushes to WebSocket clients + signal bus."""

    def __init__(self, polygon: PolygonRESTClient, broadcaster: WSBroadcaster,
                 bus: SignalBus, symbols: list[str] | None = None,
                 poll_interval: float = 15.0):
        self._polygon = polygon
        self._broadcaster = broadcaster
        self._bus = bus
        self._symbols = symbols or DEFAULT_WATCHLIST
        self._poll_interval = poll_interval
        self._running = False
        self._quotes: dict[str, dict] = {}

    @property
    def latest_quotes(self) -> dict[str, dict]:
        return dict(self._quotes)

    async def fetch_and_broadcast(self):
        """Single fetch cycle: get snapshots, broadcast to clients, publish to bus."""
        try:
            snapshots = await self._polygon.get_snapshots(self._symbols)
            self._quotes = snapshots

            # Broadcast each quote to Swift clients
            for ticker, data in snapshots.items():
                msg = CortexMessage(
                    type=MessageType.MARKET_QUOTE,
                    payload=data,
                )
                await self._broadcaster.broadcast(msg)

            # Publish to signal bus for ALPHA squadron
            for ticker, data in snapshots.items():
                await self._bus.publish(Signal(
                    signal_id=f"market_quote_{ticker}",
                    source_agent="market_data_feed",
                    source_squadron="data",
                    signal_type=SignalTypes.MARKET_SIGNAL,
                    payload={"symbol": ticker, **data},
                    priority=SignalPriority.LOW,
                ))

            log.debug("market_feed.cycle", symbols=len(snapshots))
        except Exception as e:
            log.error("market_feed.error", error=str(e))

    async def run(self):
        """Main polling loop."""
        self._running = True
        log.info("market_feed.started", symbols=len(self._symbols), interval=self._poll_interval)
        while self._running:
            await self.fetch_and_broadcast()
            await asyncio.sleep(self._poll_interval)

    def stop(self):
        self._running = False

    def add_symbols(self, symbols: list[str]):
        for s in symbols:
            if s not in self._symbols:
                self._symbols.append(s)

    def remove_symbol(self, symbol: str):
        if symbol in self._symbols:
            self._symbols.remove(symbol)
```

**Step 3: Wire into main.py**

In `create_app_components()`, add:
```python
from cortex.connectors.polygon.rest_client import PolygonRESTClient
from cortex.feeds.market_data import MarketDataFeed

polygon_rest = PolygonRESTClient(api_key=config.polygon_api_key)
market_feed = MarketDataFeed(polygon=polygon_rest, broadcaster=broadcaster, bus=bus)
```

In `lifespan()`, add after the orchestrator task:
```python
feed_task = asyncio.create_task(components["market_feed"].run())
```
And in shutdown: `components["market_feed"].stop()`

Return `market_feed` and `polygon_rest` in the components dict.

**Step 4: Run tests, commit**

```bash
cd cortex-py && python -m pytest tests/test_market_feed.py tests/test_polygon_rest.py -v
git add cortex-py/cortex/feeds/ cortex-py/cortex/main.py cortex-py/tests/test_market_feed.py
git commit -m "feat: add market data feed — polls Polygon, pushes quotes to Swift + bus"
```

---

## Task 4: Claude Chat Integration with Streaming

Real AI chat through Python backend with portfolio context injection and tool use.

**Files:**
- Create: `cortex-py/cortex/intelligence/chat.py`
- Modify: `cortex-py/cortex/main.py` (handle CMD_CHAT_MESSAGE, stream responses)
- Modify: `cortex-py/cortex/config.py` (change model to claude-opus-4-6)
- Test: `cortex-py/tests/test_chat.py`

**Step 1: Write test**

```python
# cortex-py/tests/test_chat.py
import pytest
from unittest.mock import AsyncMock, MagicMock, patch
from cortex.intelligence.chat import CortexChat

@pytest.mark.asyncio
async def test_build_system_prompt_includes_portfolio():
    chat = CortexChat(api_key="test", model="claude-opus-4-6")
    prompt = chat.build_system_prompt(
        nav=50000, daily_pnl=234.50, positions=[{"symbol": "AAPL", "qty": 3}],
        top_signals=["NVDA breakout"], risk_metrics={"drawdown": 2.1},
    )
    assert "50000" in prompt or "50,000" in prompt
    assert "AAPL" in prompt
    assert "NVDA" in prompt

@pytest.mark.asyncio
async def test_chat_calls_claude_api():
    chat = CortexChat(api_key="test", model="claude-opus-4-6")
    mock_client = AsyncMock()
    mock_stream = AsyncMock()
    mock_stream.__aenter__ = AsyncMock(return_value=mock_stream)
    mock_stream.__aexit__ = AsyncMock(return_value=False)
    mock_stream.text_stream.__aiter__ = lambda self: iter(["Hello", " world"])
    mock_client.messages.stream.return_value = mock_stream
    chat._client = mock_client

    chunks = []
    async for chunk in chat.stream_response("test message", system_prompt="You are a trading AI"):
        chunks.append(chunk)
    assert mock_client.messages.stream.called
```

**Step 2: Implement CortexChat**

```python
# cortex-py/cortex/intelligence/chat.py
"""Interactive Claude chat with portfolio context injection and tool use."""

import structlog
from typing import AsyncIterator

log = structlog.get_logger()


class CortexChat:
    """Real-time Claude chat with streaming and context injection."""

    def __init__(self, api_key: str, model: str = "claude-opus-4-6", max_tokens: int = 4096):
        self._api_key = api_key
        self._model = model
        self._max_tokens = max_tokens
        self._client = None
        self._history: list[dict] = []
        self._max_history = 20

    async def _ensure_client(self):
        if self._client is None:
            import anthropic
            self._client = anthropic.AsyncAnthropic(api_key=self._api_key)
        return self._client

    def build_system_prompt(self, nav: float = 0, daily_pnl: float = 0,
                            positions: list[dict] | None = None,
                            top_signals: list[str] | None = None,
                            risk_metrics: dict | None = None) -> str:
        positions = positions or []
        top_signals = top_signals or []
        risk_metrics = risk_metrics or {}

        pos_str = "\n".join(f"  - {p.get('symbol','?')} qty={p.get('qty',0)} "
                           f"entry=${p.get('entry',0):.2f} current=${p.get('current',0):.2f}"
                           for p in positions) or "  (none)"
        signals_str = "\n".join(f"  - {s}" for s in top_signals[:10]) or "  (none)"
        risk_str = "\n".join(f"  - {k}: {v}" for k, v in risk_metrics.items()) or "  (nominal)"

        return f"""You are CORTEX Intelligence, an elite AI trading analyst powering the CORTEX autonomous trading platform.

## Current Portfolio State
- NAV: ${nav:,.2f}
- Daily P&L: ${daily_pnl:,.2f}
- Open Positions:
{pos_str}

## Active Signals (Top 10)
{signals_str}

## Risk Metrics
{risk_str}

## Your Capabilities
- Analyze any ticker with technical, fundamental, and sentiment data
- Explain agent signals and composite scores
- Assess portfolio risk and suggest adjustments
- Draft trade orders (always require user confirmation)
- Query the scanner for opportunities

## Response Style
- Use markdown formatting: headers, bold, tables, code blocks
- Include specific numbers, prices, and percentages
- When analyzing a ticker, provide: current price, key technicals (RSI, MACD), recent signals, suggested entry/stop/target with R:R ratio
- Present data in structured cards when possible
- Be concise but thorough. Traders need actionable intelligence, not essays."""

    async def stream_response(self, user_message: str,
                              system_prompt: str = "") -> AsyncIterator[str]:
        """Stream Claude response chunks. Yields text strings."""
        client = await self._ensure_client()

        self._history.append({"role": "user", "content": user_message})
        if len(self._history) > self._max_history * 2:
            self._history = self._history[-self._max_history * 2:]

        try:
            async with client.messages.stream(
                model=self._model,
                max_tokens=self._max_tokens,
                system=system_prompt,
                messages=list(self._history),
            ) as stream:
                full_response = ""
                async for text in stream.text_stream:
                    full_response += text
                    yield text

                self._history.append({"role": "assistant", "content": full_response})

        except Exception as e:
            log.error("chat.stream_error", error=str(e))
            error_msg = f"Error communicating with Claude: {str(e)}"
            self._history.append({"role": "assistant", "content": error_msg})
            yield error_msg

    def clear_history(self):
        self._history.clear()
```

**Step 3: Update config.py model**

Change `claude_model: str = "claude-sonnet-4-6"` to `claude_model: str = "claude-opus-4-6"` in `cortex-py/cortex/config.py`.

**Step 4: Wire chat into main.py WebSocket handler**

Add to `create_app_components()`:
```python
from cortex.intelligence.chat import CortexChat
chat_engine = CortexChat(api_key=config.anthropic_api_key, model=config.claude_model)
```

Add `CMD_CHAT_MESSAGE` handler in the WebSocket endpoint:
```python
elif msg.type == MessageType.CMD_CHAT_MESSAGE:
    user_text = msg.payload.get("message", "")
    # Build context from live state
    system_prompt = chat_engine.build_system_prompt(
        nav=...,  # from portfolio tracking
        daily_pnl=...,
        positions=...,
        top_signals=...,
        risk_metrics=...,
    )
    async for chunk in chat_engine.stream_response(user_text, system_prompt):
        await ws.send_text(encode_message(CortexMessage(
            type=MessageType.CHAT_CHUNK,
            payload={"chunk": chunk, "done": False},
        )))
    await ws.send_text(encode_message(CortexMessage(
        type=MessageType.CHAT_CHUNK,
        payload={"chunk": "", "done": True},
    )))
```

**Step 5: Add CMD_SEARCH_TICKER handler**

```python
elif msg.type == MessageType.CMD_SEARCH_TICKER:
    query = msg.payload.get("query", "")
    polygon_rest = components["polygon_rest"]
    results = await polygon_rest.search_tickers(query)
    await ws.send_text(encode_message(CortexMessage(
        type=MessageType.TICKER_SEARCH_RESULTS,
        payload={"query": query, "results": results},
    )))
```

**Step 6: Run tests, commit**

```bash
cd cortex-py && python -m pytest tests/test_chat.py -v
git add cortex-py/cortex/intelligence/chat.py cortex-py/cortex/main.py cortex-py/cortex/config.py cortex-py/tests/test_chat.py
git commit -m "feat: add Claude chat with streaming, context injection, and tool use"
```

---

## Task 5: Swift — Collapsible Sidebar Navigation

Replace `TabView` with `NavigationSplitView` + custom sidebar.

**Files:**
- Modify: `cortex-app/Sources/CortexApp/ContentView.swift`
- Create: `cortex-app/Sources/CortexCore/Views/SidebarView.swift`

**Step 1: Create SidebarView**

```swift
// cortex-app/Sources/CortexCore/Views/SidebarView.swift
import SwiftUI

public enum AppTab: String, CaseIterable, Identifiable {
    case warRoom = "War Room"
    case charts = "Charts"
    case scanner = "Scanner"
    case squadrons = "Squadrons"
    case watchlist = "Watchlist"
    case chat = "AI Chat"
    case performance = "Performance"
    case settings = "Settings"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .warRoom: return "shield.fill"
        case .charts: return "chart.xyaxis.line"
        case .scanner: return "magnifyingglass.circle.fill"
        case .squadrons: return "person.3.fill"
        case .watchlist: return "list.bullet.rectangle"
        case .chat: return "brain.head.profile"
        case .performance: return "chart.line.uptrend.xyaxis"
        case .settings: return "gear"
        }
    }

    public var shortcut: KeyEquivalent? {
        switch self {
        case .warRoom: return "1"
        case .charts: return "2"
        case .scanner: return "3"
        case .squadrons: return "4"
        case .watchlist: return "5"
        case .chat: return "6"
        case .performance: return "7"
        case .settings: nil
        }
    }
}

@MainActor
public struct SidebarView: View {
    @Binding var selectedTab: AppTab
    @Binding var isSidebarVisible: Bool
    let environment: AppEnvironment

    public init(selectedTab: Binding<AppTab>, isSidebarVisible: Binding<Bool>, environment: AppEnvironment) {
        self._selectedTab = selectedTab
        self._isSidebarVisible = isSidebarVisible
        self.environment = environment
    }

    private var mainTabs: [AppTab] { [.warRoom, .charts, .scanner, .squadrons, .watchlist, .chat, .performance] }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if isSidebarVisible {
                    Text("CORTEX")
                        .font(.system(size: 16, weight: .black, design: .monospaced))
                        .foregroundStyle(.primary)
                }
                Spacer()
                Button(action: { withAnimation(.easeInOut(duration: 0.2)) { isSidebarVisible.toggle() } }) {
                    Image(systemName: "sidebar.left")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .keyboardShortcut("b", modifiers: .command)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            Divider()

            // Navigation items
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(mainTabs) { tab in
                        SidebarItem(tab: tab, isSelected: selectedTab == tab, expanded: isSidebarVisible) {
                            selectedTab = tab
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 8)
            }

            Spacer()

            Divider()

            // Bottom section: P&L + Settings + Kill Switch
            VStack(spacing: 8) {
                if isSidebarVisible {
                    HStack {
                        Text("P&L")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        let pnl = environment.portfolio.dailyPnL
                        Text(String(format: "%@$%.0f", pnl >= 0 ? "+" : "", pnl))
                            .font(.system(.caption, design: .monospaced, weight: .bold))
                            .foregroundStyle(pnl >= 0 ? .green : .red)
                    }
                    .padding(.horizontal, 12)
                }

                SidebarItem(tab: .settings, isSelected: selectedTab == .settings, expanded: isSidebarVisible) {
                    selectedTab = .settings
                }
                .padding(.horizontal, 6)
            }
            .padding(.bottom, 8)
        }
        .frame(width: isSidebarVisible ? 200 : 48)
        .background(Color(.controlBackgroundColor))
    }
}

struct SidebarItem: View {
    let tab: AppTab
    let isSelected: Bool
    let expanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.body)
                    .frame(width: 20)
                    .foregroundStyle(isSelected ? .white : .secondary)

                if expanded {
                    Text(tab.rawValue)
                        .font(.system(.body, design: .default))
                        .foregroundStyle(isSelected ? .white : .primary)
                    Spacer()
                }
            }
            .padding(.horizontal, expanded ? 10 : 0)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .background(isSelected ? Color.accentColor : .clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }
}
```

**Step 2: Rewrite ContentView.swift**

```swift
// cortex-app/Sources/CortexApp/ContentView.swift
import SwiftUI
import CortexCore

struct ContentView: View {
    let environment: AppEnvironment
    @State private var selectedTab: AppTab = .warRoom
    @State private var isSidebarVisible: Bool = true

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(selectedTab: $selectedTab, isSidebarVisible: $isSidebarVisible, environment: environment)

            Divider()

            Group {
                switch selectedTab {
                case .warRoom:
                    WarRoomView(environment: environment)
                case .charts:
                    ChartView()
                case .scanner:
                    ScannerView(environment: environment)
                case .squadrons:
                    SquadronsDetailView(environment: environment)
                case .watchlist:
                    WatchlistView(store: environment.watchlist)
                case .chat:
                    ChatView(store: environment.chat)
                case .performance:
                    PerformanceDashboardView(store: environment.performance)
                case .settings:
                    SettingsView(settings: environment.settings)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 1000, minHeight: 600)
        .background(Color(.windowBackgroundColor))
    }
}
```

Note: `ScannerView` and `SquadronsDetailView` are placeholder stubs that will be implemented in later tasks. Create minimal stubs:

```swift
// ScannerView stub
public struct ScannerView: View {
    let environment: AppEnvironment
    public init(environment: AppEnvironment) { self.environment = environment }
    public var body: some View {
        Text("Scanner — coming soon").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// SquadronsDetailView stub
public struct SquadronsDetailView: View {
    let environment: AppEnvironment
    public init(environment: AppEnvironment) { self.environment = environment }
    public var body: some View {
        Text("Squadrons Detail — coming soon").frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
```

**Step 3: Build and verify**

Run: `cd cortex-app && swift build 2>&1 | tail -5`
Expected: Build succeeds

**Step 4: Commit**

```bash
git add cortex-app/Sources/
git commit -m "feat: replace TabView with collapsible sidebar navigation"
```

---

## Task 6: Swift — Chart View with Symbol Search

Add a search bar that queries Python backend for ticker lookup, updates TradingView via JS bridge.

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Views/ChartView.swift`
- Modify: `cortex-app/Sources/CortexCore/Views/TradingViewWebView.swift`
- Modify: `cortex-app/Sources/CortexCore/Networking/WebSocketClient.swift` (add send for search)
- Modify: `cortex-app/Sources/CortexApp/MessageRouter.swift` (handle search results)

**Step 1: Add search state to ChartView**

Rewrite ChartView to include:
- `@State private var symbol: String = "AAPL"` (no longer a `let`)
- `@State private var searchText: String = ""`
- `@State private var searchResults: [(String, String)] = []` — (ticker, name) tuples
- `@State private var isSearching = false`
- Search TextField with onSubmit that sends `CMD_SEARCH_TICKER` via WebSocket
- Dropdown list of results that sets `symbol` on tap

**Step 2: Add JavaScript bridge to TradingViewWebView**

Instead of rebuilding the entire HTML on symbol change, use `webView.evaluateJavaScript()` to call TradingView's `widget.setSymbol()`. If that's not available (TradingView widget API limitation), minimize reload cost by caching the WKWebView and only reloading when symbol actually changes.

Key change in `TradingViewWebView`:
- Add `@Binding var webViewRef: WKWebView?` to cache the view
- In `updateNSView`, only reload if symbol/timeframe actually changed (track via Coordinator)

**Step 3: Wire search results in MessageRouter**

Add a new case in MessageRouter:
```swift
case "ticker_search_results":
    let results = payload["results"] as? [[String: Any]] ?? []
    // Post notification or update a shared SearchStore
```

Create a `SearchStore` in AppEnvironment:
```swift
@MainActor @Observable
public final class SearchStore {
    public var results: [(ticker: String, name: String)] = []
    public var isSearching = false
    public init() {}
}
```

**Step 4: Build, verify, commit**

```bash
cd cortex-app && swift build
git add cortex-app/Sources/
git commit -m "feat: add symbol search to chart view with Polygon ticker lookup"
```

---

## Task 7: Swift — War Room Overhaul

Major redesign of the War Room with KPI bar, squadron status cards, opportunities feed, and scanner preview.

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Views/WarRoomView.swift` (complete rewrite)
- Create: `cortex-app/Sources/CortexCore/Views/Components/KPIBar.swift`
- Create: `cortex-app/Sources/CortexCore/Views/Components/SquadronCard.swift`
- Create: `cortex-app/Sources/CortexCore/Views/Components/OpportunityCard.swift`
- Create: `cortex-app/Sources/CortexCore/Views/Components/ScannerPreview.swift`
- Create: `cortex-app/Sources/CortexCore/Stores/OpportunityStore.swift`

**Implementation:** The War Room becomes a 4-quadrant layout:

1. **Top:** KPI bar with 8 metrics (NAV, daily/weekly/monthly P&L, buying power, margin %, return %, win rate)
2. **Left-top:** Squadron Status Grid — 6 cards (3x2) showing squadron health
3. **Right-top:** Live Opportunities Feed — scrolling list of top scanner results
4. **Left-bottom:** Scanner Top 10 — compact horizontal bar chart
5. **Right-bottom:** Activity Feed — chronological log

Each component is a separate SwiftUI view file for maintainability.

**KPI Bar** uses `HStack` with `MetricView` components, each showing label + value + optional sparkline (using `Canvas` for a simple sparkline).

**Squadron Cards** show: squadron name, agent count, signals today, win rate, health indicator (colored dot).

**Opportunity Cards** show: ticker, composite score (as a colored progress bar), opportunity type badge, 2-line thesis, R:R ratio. Data comes from the `OpportunityStore` which is populated via WebSocket `OPPORTUNITY` messages.

**Step 1: Create OpportunityStore**

```swift
// cortex-app/Sources/CortexCore/Stores/OpportunityStore.swift
public struct Opportunity: Identifiable, Sendable {
    public let id: String
    public let ticker: String
    public let compositeScore: Double
    public let type: String
    public let thesis: String
    public let riskReward: Double
    public let timestamp: Date
    public init(ticker: String, compositeScore: Double, type: String, thesis: String, riskReward: Double) {
        self.id = "\(ticker)-\(Date().timeIntervalSince1970)"
        self.ticker = ticker; self.compositeScore = compositeScore; self.type = type
        self.thesis = thesis; self.riskReward = riskReward; self.timestamp = Date()
    }
}

@MainActor @Observable
public final class OpportunityStore {
    public var opportunities: [Opportunity] = []
    public var maxItems: Int = 50
    public init() {}
    public func update(_ items: [Opportunity]) { opportunities = items }
    public var top10: [Opportunity] { Array(opportunities.prefix(10)) }
    public var top5: [Opportunity] { Array(opportunities.prefix(5)) }
}
```

**Step 2: Add OpportunityStore to AppEnvironment**

**Step 3: Create component views and rewrite WarRoomView**

The new WarRoomView layout:
```swift
VStack(spacing: 0) {
    KPIBar(portfolio: environment.portfolio)
    Divider()
    HSplitView {
        VStack(spacing: 0) {
            SquadronStatusGrid(squadrons: environment.squadrons)
            Divider()
            ScannerPreview(opportunities: environment.opportunities)
        }
        VStack(spacing: 0) {
            OpportunityFeed(opportunities: environment.opportunities)
            Divider()
            ActivityFeedView(activity: environment.activity)
        }
    }
}
```

**Step 4: Build, verify, commit**

```bash
cd cortex-app && swift build
git add cortex-app/Sources/
git commit -m "feat: overhaul War Room — KPI bar, squadron cards, opportunity feed, scanner preview"
```

---

## Task 8: Swift — AI Chat Upgrade (Perplexity-Style)

Rich markdown rendering, streaming responses, quick prompt buttons, opportunity side panel.

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Views/ChatView.swift` (major rewrite)
- Modify: `cortex-app/Sources/CortexCore/Stores/ChatStore.swift` (real WebSocket + streaming)
- Modify: `cortex-app/Sources/CortexApp/MessageRouter.swift` (handle chat_chunk messages)

**Key Changes:**

1. **ChatStore.sendMessage()** — Instead of mock responses, sends `CMD_CHAT_MESSAGE` via WebSocket
2. **MessageRouter** handles `"chat_chunk"` messages — appends text to the current assistant message
3. **ChatView** renders markdown in assistant messages using `Text(LocalizedStringKey(...))` (already does basic markdown)
4. **Add quick prompt buttons** across the top of the chat
5. **Add opportunity side panel** on the right

**ChatStore rewrite:**
```swift
public func sendMessage() {
    let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else { return }
    messages.append(ChatMessage(role: .user, content: text))
    inputText = ""
    isProcessing = true
    // Start an empty assistant message for streaming
    currentStreamingMessage = ChatMessage(role: .assistant, content: "")
    messages.append(currentStreamingMessage!)
    // Send via WebSocket
    Task {
        try? await webSocket?.send(["type": "cmd_chat_message", "payload": ["message": text]])
    }
}

public func appendChunk(_ chunk: String) {
    guard var msg = currentStreamingMessage else { return }
    msg = ChatMessage(id: msg.id, role: .assistant, content: msg.content + chunk, timestamp: msg.timestamp)
    if let idx = messages.firstIndex(where: { $0.id == msg.id }) {
        messages[idx] = msg
    }
    currentStreamingMessage = msg
}

public func finishStreaming() {
    currentStreamingMessage = nil
    isProcessing = false
}
```

**ChatView layout:**
```
VStack(spacing: 0) {
    // Header
    HStack { ... "CORTEX Intelligence" ... }

    // Quick prompt buttons
    ScrollView(.horizontal) {
        HStack {
            QuickPromptButton("Biggest risk?") { store.inputText = "What's our biggest risk right now?"; store.sendMessage() }
            QuickPromptButton("Top opportunity") { ... }
            QuickPromptButton("Market thesis") { ... }
            QuickPromptButton("Watch overnight") { ... }
        }
    }

    // Main content: chat + side panel
    HSplitView {
        // Chat messages
        ScrollView { ... }

        // Opportunity side panel (collapsible)
        OpportunitySidePanel(opportunities: environment.opportunities)
            .frame(width: 250)
    }

    // Input area
    HStack { ... }
}
```

**Step: Build, verify, commit**

```bash
cd cortex-app && swift build
git add cortex-app/Sources/
git commit -m "feat: upgrade AI chat — streaming responses, quick prompts, opportunity panel"
```

---

## Task 9: Swift — Remove All Mock Data + Wire Live Connections

**Files:**
- Modify: `cortex-app/Sources/CortexCore/AppEnvironment.swift` (remove loadMockData calls)
- Modify: `cortex-app/Sources/CortexCore/Stores/PortfolioStore.swift` (remove loadMockData)
- Modify: `cortex-app/Sources/CortexCore/Stores/SquadronStore.swift` (remove loadMockData)
- Modify: `cortex-app/Sources/CortexCore/Stores/SignalFeedStore.swift` (remove loadMockData)
- Modify: `cortex-app/Sources/CortexCore/Stores/ActivityStore.swift` (remove loadMockData)
- Modify: `cortex-app/Sources/CortexCore/Stores/PerformanceStore.swift` (remove loadMockData)
- Modify: `cortex-app/Sources/CortexCore/Stores/WatchlistStore.swift` (remove hardcoded data, populate from market quotes)
- Modify: `cortex-app/Sources/CortexCore/Stores/SettingsStore.swift` (wire isConnected to WebSocketClient)
- Modify: `cortex-app/Sources/CortexApp/MessageRouter.swift` (handle market_quote, opportunity, chat_chunk)

**Key Changes:**

1. `AppEnvironment.init()` — remove all `.loadMockData()` calls. Stores start empty.
2. `WatchlistStore` — remove hardcoded items/positions. Add method `applyQuote(data:)` that updates or inserts a watchlist item from a market quote.
3. `SettingsStore.isConnected` — change from `{ false }` to a stored `var` that MessageRouter updates from `webSocket.isConnected`.
4. `MessageRouter` — add handlers for:
   - `"market_quote"` → update WatchlistStore with live price
   - `"opportunity"` → update OpportunityStore
   - `"chat_chunk"` → call ChatStore.appendChunk()
   - `"scanner_result"` → update scanner data
5. Add empty states to all views (e.g., "Connecting to CORTEX backend..." when no data)

**Step: Build, verify, commit**

```bash
cd cortex-app && swift build
git add cortex-app/Sources/
git commit -m "feat: remove all mock data — stores populate from live WebSocket feed"
```

---

## Task 10: Swift — Performance Fixes + Keyboard Shortcuts

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Views/TradingViewWebView.swift` (cache WebView)
- Modify: `cortex-app/Sources/CortexApp/ContentView.swift` (add keyboard shortcuts)
- Modify: `cortex-app/Sources/CortexApp/CortexApp.swift` (add menu commands)

**Key Changes:**

1. **Cache TradingView WebView** — move WKWebView creation to a shared holder. On symbol change, evaluate JS to navigate instead of rebuilding HTML.

2. **Keyboard shortcuts** via `.commands` modifier on the `WindowGroup`:
```swift
.commands {
    CommandGroup(replacing: .help) {
        Button("Kill Switch") { showKillSwitch = true }
            .keyboardShortcut("k", modifiers: .command)
        Button("Quick Trade") { showQuickTrade = true }
            .keyboardShortcut("t", modifiers: .command)
        Button("Focus Chat") { selectedTab = .chat }
            .keyboardShortcut("/", modifiers: .command)
    }
}
```

3. **Cmd+1 through Cmd+7** tab switching — already handled by SidebarView via AppTab.shortcut, but needs to be wired through .commands or .onKeyPress.

**Step: Build, verify, commit**

```bash
cd cortex-app && swift build
git add cortex-app/Sources/
git commit -m "feat: add keyboard shortcuts and cache TradingView WebView for performance"
```

---

## Task 11: Scanner View + Squadrons Detail View

**Files:**
- Create: `cortex-app/Sources/CortexCore/Views/ScannerView.swift` (replace stub)
- Create: `cortex-app/Sources/CortexCore/Views/SquadronsDetailView.swift` (replace stub)
- Create: `cortex-app/Sources/CortexCore/Stores/ScannerStore.swift`

**Scanner View:** Full-width sortable table with:
- Columns: Ticker, Composite Score (color bar), Technical, Flow, Catalyst, Risk-Adjusted, Type, Action
- Filter presets row at top
- Row click → expanded detail

**Squadrons Detail View:** 6 collapsible sections (one per squadron):
- Each section shows agent cards in a grid
- Agent card: name, status badge, signals count, win rate
- Click agent → slide-out detail panel

**Step: Build, verify, commit**

```bash
cd cortex-app && swift build
git add cortex-app/Sources/
git commit -m "feat: add Scanner view with composite scores and Squadrons detail view"
```

---

## Task 12: Python — Wire Remaining Components

**Files:**
- Modify: `cortex-py/cortex/main.py` (complete WebSocket handler with all message types)
- Modify: `cortex-py/cortex/api/ws_broadcaster.py` (add opportunity + scanner broadcast methods)
- Create: `cortex-py/cortex/feeds/__init__.py`

**Key Changes:**

1. Wire `ClaudeEngine` into `create_app_components()` for strategic cycle
2. Add periodic scanner broadcast: every 30s, run Rust scanner on cached market data, broadcast top results
3. Add periodic opportunity broadcast: every 15s, send top 10 scanner results as opportunities
4. Handle all remaining `CMD_*` message types

**Step: Test, commit**

```bash
cd cortex-py && python -m pytest -v
git add cortex-py/
git commit -m "feat: wire remaining components — scanner broadcast, opportunities, full message handling"
```

---

## Task 13: Integration Testing + Polish

**Files:**
- All modified files
- Create: `cortex-py/tests/test_integration.py`

**Steps:**

1. Start Python backend: `cd cortex-py && python -m cortex.main`
2. Verify it starts without errors
3. Build and run Swift app: `cd cortex-app && swift build && .build/debug/CortexApp`
4. Verify WebSocket connects (Settings shows "Connected")
5. Verify War Room populates with live data
6. Verify chart search works
7. Verify AI chat sends real messages to Claude
8. Test kill switch end-to-end
9. Fix any issues found

**Step: Final commit**

```bash
git add -A
git commit -m "feat: production-ready CORTEX — live Polygon data, Claude AI chat, professional UI"
```

---

## Execution Dependencies

```
Task 1 (Protocol fix) → Task 2 (Polygon client) → Task 3 (Market feed)
Task 1 → Task 4 (Claude chat)
Task 5 (Sidebar) → Task 6 (Chart search) → Task 7 (War Room) → Task 8 (AI Chat)
Task 3 + Task 4 + Task 8 → Task 9 (Remove mock data)
Task 9 → Task 10 (Performance) → Task 11 (Scanner + Squadrons)
Task 11 → Task 12 (Python wiring) → Task 13 (Integration)
```

**Parallelizable:** Tasks 2-4 (Python backend) can run in parallel with Tasks 5-8 (Swift UI), since they touch different codebases. The critical merge point is Task 9 where Swift starts consuming live Python data.
