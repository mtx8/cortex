"""Tests for MarketDataFeed."""

import asyncio
import pytest
from unittest.mock import AsyncMock, MagicMock, patch

from cortex.feeds.market_data import MarketDataFeed, DEFAULT_WATCHLIST
from cortex.connectors.polygon.rest_client import PolygonRESTClient
from cortex.api.ws_broadcaster import WSBroadcaster
from cortex.orchestrator.bus import SignalBus


@pytest.fixture
def bus():
    return SignalBus()


@pytest.fixture
def broadcaster(bus):
    return WSBroadcaster(bus=bus)


@pytest.fixture
def polygon_client():
    return PolygonRESTClient(api_key="test-key")


@pytest.fixture
def feed(polygon_client, broadcaster, bus):
    return MarketDataFeed(
        polygon_client=polygon_client,
        broadcaster=broadcaster,
        bus=bus,
        poll_interval=1.0,
    )


def test_default_watchlist(feed):
    assert feed.watchlist == DEFAULT_WATCHLIST
    assert "AAPL" in feed.watchlist
    assert "NVDA" in feed.watchlist
    assert "SPY" in feed.watchlist
    assert "QQQ" in feed.watchlist


def test_custom_watchlist(polygon_client, broadcaster, bus):
    feed = MarketDataFeed(
        polygon_client=polygon_client,
        broadcaster=broadcaster,
        bus=bus,
        watchlist=["AAPL", "MSFT"],
    )
    assert feed.watchlist == ["AAPL", "MSFT"]


def test_add_ticker(feed):
    initial_len = len(feed.watchlist)
    feed.add_ticker("AMD")
    assert "AMD" in feed.watchlist
    assert len(feed.watchlist) == initial_len + 1


def test_add_duplicate_ticker(feed):
    initial_len = len(feed.watchlist)
    feed.add_ticker("AAPL")  # already in default watchlist
    assert len(feed.watchlist) == initial_len


def test_add_ticker_uppercases(feed):
    feed.add_ticker("amd")
    assert "AMD" in feed.watchlist


def test_remove_ticker(feed):
    feed.add_ticker("AMD")
    feed.remove_ticker("AMD")
    assert "AMD" not in feed.watchlist


def test_remove_nonexistent_ticker(feed):
    initial_len = len(feed.watchlist)
    feed.remove_ticker("NONEXISTENT")
    assert len(feed.watchlist) == initial_len


def test_initial_state(feed):
    assert feed.poll_count == 0
    assert feed.is_running is False
    assert feed.last_quotes == {}


def test_to_dict(feed):
    d = feed.to_dict()
    assert d["running"] is False
    assert d["poll_count"] == 0
    assert d["poll_interval"] == 1.0
    assert len(d["watchlist"]) == len(DEFAULT_WATCHLIST)


MOCK_SNAPSHOTS = [
    {
        "ticker": "AAPL",
        "price": 185.50,
        "change": 2.50,
        "change_pct": 1.37,
        "volume": 50000000,
        "open": 183.0,
        "high": 186.0,
        "low": 182.5,
        "prev_close": 183.0,
        "updated": 1700000000000,
    },
    {
        "ticker": "MSFT",
        "price": 378.0,
        "change": 4.0,
        "change_pct": 1.07,
        "volume": 20000000,
        "open": 374.0,
        "high": 380.0,
        "low": 373.0,
        "prev_close": 374.0,
        "updated": 1700000000000,
    },
]


@pytest.mark.asyncio
async def test_poll_once_broadcasts_quotes(feed, bus):
    """Verify _poll_once fetches data and broadcasts to WS clients."""
    with patch.object(
        feed._polygon, "get_snapshots", new_callable=AsyncMock, return_value=MOCK_SNAPSHOTS
    ):
        with patch.object(feed._broadcaster, "broadcast", new_callable=AsyncMock) as mock_broadcast:
            with patch.object(bus, "publish", new_callable=AsyncMock) as mock_publish:
                results = await feed._poll_once()

    assert len(results) == 2
    assert feed.poll_count == 1

    # Should have broadcast 2 MARKET_QUOTE messages
    assert mock_broadcast.call_count == 2
    first_call_msg = mock_broadcast.call_args_list[0][0][0]
    assert first_call_msg.type.value == "market_quote"
    assert first_call_msg.payload["ticker"] == "AAPL"

    # Should have published 4 signals to the bus (2 feeds.market_quote + 2 alpha.market_signal bridge)
    assert mock_publish.call_count == 4


@pytest.mark.asyncio
async def test_poll_once_updates_last_quotes(feed, bus):
    with patch.object(
        feed._polygon, "get_snapshots", new_callable=AsyncMock, return_value=MOCK_SNAPSHOTS
    ):
        with patch.object(feed._broadcaster, "broadcast", new_callable=AsyncMock):
            with patch.object(bus, "publish", new_callable=AsyncMock):
                await feed._poll_once()

    assert "AAPL" in feed.last_quotes
    assert feed.last_quotes["AAPL"]["price"] == 185.50
    assert "MSFT" in feed.last_quotes


@pytest.mark.asyncio
async def test_poll_once_handles_error(feed, bus):
    with patch.object(
        feed._polygon, "get_snapshots", new_callable=AsyncMock, side_effect=Exception("API error")
    ):
        results = await feed._poll_once()

    assert results == []
    assert feed.poll_count == 0  # Should not increment on error


@pytest.mark.asyncio
async def test_poll_once_empty_watchlist(polygon_client, broadcaster, bus):
    feed = MarketDataFeed(
        polygon_client=polygon_client,
        broadcaster=broadcaster,
        bus=bus,
        watchlist=[],
    )
    results = await feed._poll_once()
    assert results == []


@pytest.mark.asyncio
async def test_start_stop_cycle(feed, bus):
    """Verify start/stop lifecycle."""
    with patch.object(
        feed._polygon, "get_snapshots", new_callable=AsyncMock, return_value=MOCK_SNAPSHOTS
    ):
        with patch.object(feed._broadcaster, "broadcast", new_callable=AsyncMock):
            with patch.object(bus, "publish", new_callable=AsyncMock):
                # Start in background
                task = asyncio.create_task(feed.start())

                # Yield control so the task starts executing
                await asyncio.sleep(0.05)
                assert feed.is_running is True

                # Let it poll once
                await asyncio.sleep(0.15)
                assert feed.poll_count >= 1

                # Stop
                await feed.stop()
                await asyncio.sleep(0.05)
                task.cancel()
                try:
                    await task
                except asyncio.CancelledError:
                    pass

                assert feed.is_running is False


@pytest.mark.asyncio
async def test_signal_bus_payload(feed, bus):
    """Verify the signal published to the bus has correct structure."""
    published_signals = []

    async def capture_signal(signal):
        published_signals.append(signal)

    with patch.object(
        feed._polygon, "get_snapshots", new_callable=AsyncMock, return_value=[MOCK_SNAPSHOTS[0]]
    ):
        with patch.object(feed._broadcaster, "broadcast", new_callable=AsyncMock):
            with patch.object(bus, "publish", new_callable=AsyncMock) as mock_publish:
                await feed._poll_once()

    signal = mock_publish.call_args_list[0][0][0]
    assert signal.source_agent == "market_data_feed"
    assert signal.source_squadron == "feeds"
    assert signal.signal_type == "feeds.market_quote"
    assert signal.payload["ticker"] == "AAPL"
    assert signal.payload["price"] == 185.50
