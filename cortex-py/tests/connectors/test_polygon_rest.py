"""Tests for Polygon.io REST client."""

import pytest
from unittest.mock import AsyncMock, patch, MagicMock
import httpx

from cortex.connectors.polygon.rest_client import PolygonRESTClient, _TTLCache


# ─── TTL Cache Tests ──────────────────────────────────────────────────

def test_cache_set_and_get():
    cache = _TTLCache()
    cache.set("key1", {"data": 42}, ttl=60.0)
    assert cache.get("key1") == {"data": 42}


def test_cache_miss():
    cache = _TTLCache()
    assert cache.get("nonexistent") is None


def test_cache_expired(monkeypatch):
    import time
    cache = _TTLCache()
    cache.set("key1", "value", ttl=1.0)

    # Simulate time passing beyond TTL
    original_monotonic = time.monotonic
    monkeypatch.setattr(
        "cortex.connectors.polygon.rest_client.time.monotonic",
        lambda: original_monotonic() + 2.0,
    )
    assert cache.get("key1") is None


def test_cache_clear():
    cache = _TTLCache()
    cache.set("a", 1, ttl=60.0)
    cache.set("b", 2, ttl=60.0)
    cache.clear()
    assert cache.get("a") is None
    assert cache.get("b") is None


def test_cache_evict_expired(monkeypatch):
    import time
    cache = _TTLCache()
    cache.set("short", "x", ttl=0.001)
    cache.set("long", "y", ttl=3600.0)

    original_monotonic = time.monotonic
    monkeypatch.setattr(
        "cortex.connectors.polygon.rest_client.time.monotonic",
        lambda: original_monotonic() + 1.0,
    )
    evicted = cache.evict_expired()
    assert evicted == 1
    assert cache.get("long") is not None


# ─── Client Construction ──────────────────────────────────────────────

def test_client_creation():
    client = PolygonRESTClient(api_key="test-key")
    assert client._api_key == "test-key"
    assert client._base_url == "https://api.polygon.io"
    assert client.request_count == 0


def test_client_to_dict():
    client = PolygonRESTClient(api_key="abc")
    d = client.to_dict()
    assert d["has_api_key"] is True
    assert d["request_count"] == 0


def test_client_no_api_key():
    client = PolygonRESTClient(api_key="")
    assert client.to_dict()["has_api_key"] is False


# ─── API Method Tests (mocked HTTP) ──────────────────────────────────

@pytest.mark.asyncio
async def test_search_tickers():
    client = PolygonRESTClient(api_key="test-key")

    mock_response = MagicMock()
    mock_response.status_code = 200
    mock_response.raise_for_status = MagicMock()
    mock_response.json.return_value = {
        "results": [
            {
                "ticker": "AAPL",
                "name": "Apple Inc.",
                "market": "stocks",
                "locale": "us",
                "type": "CS",
                "currency_name": "usd",
            },
            {
                "ticker": "AAPD",
                "name": "Direxion Daily AAPL Bear 1X Shares",
                "market": "stocks",
                "locale": "us",
                "type": "ETF",
                "currency_name": "usd",
            },
        ],
        "status": "OK",
        "count": 2,
    }

    with patch.object(client, "_request", new_callable=AsyncMock, return_value=mock_response.json()):
        results = await client.search_tickers("AAPL")

    assert len(results) == 2
    assert results[0]["ticker"] == "AAPL"
    assert results[0]["name"] == "Apple Inc."
    await client.close()


@pytest.mark.asyncio
async def test_search_tickers_caching():
    client = PolygonRESTClient(api_key="test-key")

    mock_data = {
        "results": [{"ticker": "AAPL", "name": "Apple Inc.", "market": "stocks",
                      "locale": "us", "type": "CS", "currency_name": "usd"}],
        "status": "OK",
    }

    call_count = 0
    original_request = client._request

    async def counting_request(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        return mock_data

    with patch.object(client, "_request", side_effect=counting_request):
        r1 = await client.search_tickers("AAPL")
        r2 = await client.search_tickers("AAPL")

    assert call_count == 1  # Only one actual request thanks to cache
    assert r1 == r2
    await client.close()


@pytest.mark.asyncio
async def test_get_previous_close():
    client = PolygonRESTClient(api_key="test-key")

    mock_data = {
        "results": [{
            "T": "AAPL", "o": 182.0, "h": 185.0, "l": 181.0,
            "c": 184.5, "v": 50000000, "vw": 183.5, "t": 1700000000000,
        }],
        "status": "OK",
    }

    with patch.object(client, "_request", new_callable=AsyncMock, return_value=mock_data):
        result = await client.get_previous_close("AAPL")

    assert result["ticker"] == "AAPL"
    assert result["close"] == 184.5
    assert result["volume"] == 50000000
    await client.close()


@pytest.mark.asyncio
async def test_get_previous_close_no_data():
    client = PolygonRESTClient(api_key="test-key")

    mock_data = {"results": [], "status": "OK"}

    with patch.object(client, "_request", new_callable=AsyncMock, return_value=mock_data):
        result = await client.get_previous_close("FAKE")

    assert result["ticker"] == "FAKE"
    assert "error" in result
    await client.close()


@pytest.mark.asyncio
async def test_get_snapshots():
    client = PolygonRESTClient(api_key="test-key")

    mock_data = {
        "tickers": [
            {
                "ticker": "AAPL",
                "day": {"o": 182.0, "h": 185.0, "l": 181.0, "c": 184.5, "v": 50000000},
                "prevDay": {"c": 181.0},
                "lastTrade": {"p": 184.5},
                "updated": 1700000000000,
            },
            {
                "ticker": "MSFT",
                "day": {"o": 375.0, "h": 380.0, "l": 374.0, "c": 378.0, "v": 20000000},
                "prevDay": {"c": 374.0},
                "lastTrade": {"p": 378.0},
                "updated": 1700000000000,
            },
        ],
        "status": "OK",
    }

    with patch.object(client, "_request", new_callable=AsyncMock, return_value=mock_data):
        results = await client.get_snapshots(["AAPL", "MSFT"])

    assert len(results) == 2
    assert results[0]["ticker"] == "AAPL"
    assert results[0]["price"] == 184.5
    assert results[0]["change_pct"] == pytest.approx(1.9337, abs=0.01)
    assert results[1]["ticker"] == "MSFT"
    await client.close()


@pytest.mark.asyncio
async def test_get_aggregates():
    client = PolygonRESTClient(api_key="test-key")

    mock_data = {
        "results": [
            {"o": 180.0, "h": 182.0, "l": 179.0, "c": 181.0, "v": 1000000, "vw": 180.5, "t": 1700000000000, "n": 500},
            {"o": 181.0, "h": 184.0, "l": 180.0, "c": 183.0, "v": 1200000, "vw": 182.0, "t": 1700086400000, "n": 600},
        ],
        "status": "OK",
    }

    with patch.object(client, "_request", new_callable=AsyncMock, return_value=mock_data):
        results = await client.get_aggregates(
            "AAPL", timespan="day", from_date="2024-01-01", to_date="2024-01-02"
        )

    assert len(results) == 2
    assert results[0]["close"] == 181.0
    assert results[1]["transactions"] == 600
    await client.close()


@pytest.mark.asyncio
async def test_clear_cache():
    client = PolygonRESTClient(api_key="test-key")

    mock_data = {
        "results": [{"ticker": "AAPL", "name": "Apple Inc.", "market": "stocks",
                      "locale": "us", "type": "CS", "currency_name": "usd"}],
    }

    call_count = 0

    async def counting_request(*args, **kwargs):
        nonlocal call_count
        call_count += 1
        return mock_data

    with patch.object(client, "_request", side_effect=counting_request):
        await client.search_tickers("AAPL")
        client.clear_cache()
        await client.search_tickers("AAPL")

    assert call_count == 2  # Cache was cleared, so two requests
    await client.close()
