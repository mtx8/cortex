"""Tests for OptionsFeed — option chain data from Polygon.io."""

import pytest
from unittest.mock import AsyncMock, MagicMock

from cortex.feeds.options import OptionsFeed
from cortex.connectors.polygon.rest_client import PolygonRESTClient


# ─── Fixtures ────────────────────────────────────────────────────────


@pytest.fixture
def polygon():
    return PolygonRESTClient(api_key="test-key")


@pytest.fixture
def broadcaster():
    mock = MagicMock()
    mock.broadcast = AsyncMock()
    return mock


@pytest.fixture
def rate_limiter():
    mock = MagicMock()
    mock.acquire_general = AsyncMock()
    return mock


@pytest.fixture
def feed(polygon, broadcaster, rate_limiter):
    return OptionsFeed(
        polygon_client=polygon,
        broadcaster=broadcaster,
        rate_limiter=rate_limiter,
    )


@pytest.fixture
def feed_no_broadcaster(polygon):
    return OptionsFeed(polygon_client=polygon)


# ─── Mock Data ───────────────────────────────────────────────────────

MOCK_CHAIN_RESPONSE = {
    "results": [
        {
            "details": {
                "ticker": "O:AAPL260321C00185000",
                "strike_price": 185.0,
                "expiration_date": "2026-03-21",
                "contract_type": "call",
            },
            "greeks": {
                "delta": 0.55,
                "gamma": 0.03,
                "theta": -0.05,
                "vega": 0.25,
            },
            "day": {"close": 8.50, "volume": 1500},
            "last_quote": {"bid": 8.40, "ask": 8.60},
            "open_interest": 5000,
            "implied_volatility": 0.28,
        },
        {
            "details": {
                "ticker": "O:AAPL260321P00185000",
                "strike_price": 185.0,
                "expiration_date": "2026-03-21",
                "contract_type": "put",
            },
            "greeks": {
                "delta": -0.45,
                "gamma": 0.03,
                "theta": -0.04,
                "vega": 0.24,
            },
            "day": {"close": 6.20, "volume": 800},
            "last_quote": {"bid": 6.10, "ask": 6.30},
            "open_interest": 3200,
            "implied_volatility": 0.26,
        },
        {
            "details": {
                "ticker": "O:AAPL260321C00190000",
                "strike_price": 190.0,
                "expiration_date": "2026-03-21",
                "contract_type": "call",
            },
            "greeks": {
                "delta": 0.42,
                "gamma": 0.025,
                "theta": -0.04,
                "vega": 0.22,
            },
            "day": {"close": 5.80, "volume": 2200},
            "last_quote": {"bid": 5.70, "ask": 5.90},
            "open_interest": 8000,
            "implied_volatility": 0.30,
        },
    ],
}

MOCK_CONTRACTS_RESPONSE = {
    "results": [
        {"expiration_date": "2026-03-21"},
        {"expiration_date": "2026-03-21"},  # duplicate should be deduped
        {"expiration_date": "2026-04-17"},
        {"expiration_date": "2026-05-16"},
        {"expiration_date": "2026-06-19"},
    ],
}


# ─── get_chain Tests ─────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_get_chain_basic(feed, polygon, broadcaster):
    """Test basic chain fetch with calls and puts."""
    with unittest_mock_request(polygon, MOCK_CHAIN_RESPONSE):
        chain = await feed.get_chain("AAPL", expiration="2026-03-21")

    assert chain["symbol"] == "AAPL"
    assert chain["expiration"] == "2026-03-21"
    assert len(chain["calls"]) == 2  # Two calls in mock data
    assert len(chain["puts"]) == 1
    assert chain["total_contracts"] == 3

    # Verify call details
    call = chain["calls"][0]
    assert call["strike"] == 185.0
    assert call["bid"] == 8.40
    assert call["ask"] == 8.60
    assert call["last"] == 8.50
    assert call["volume"] == 1500
    assert call["open_interest"] == 5000
    assert call["iv"] == 0.28
    assert call["delta"] == 0.55

    # Verify put details
    put = chain["puts"][0]
    assert put["strike"] == 185.0
    assert put["contract_type"] == "put"
    assert put["delta"] == -0.45
    await polygon.close()


@pytest.mark.asyncio
async def test_get_chain_uppercases_symbol(feed, polygon):
    """Test that symbol is uppercased."""
    with unittest_mock_request(polygon, MOCK_CHAIN_RESPONSE) as mock_req:
        await feed.get_chain("aapl")

    # Verify the request path used uppercase
    call_args = mock_req.call_args
    assert "AAPL" in call_args[0][0]
    await polygon.close()


@pytest.mark.asyncio
async def test_get_chain_broadcasts(feed, polygon, broadcaster):
    """Test that chain data is broadcast to WebSocket clients."""
    with unittest_mock_request(polygon, MOCK_CHAIN_RESPONSE):
        await feed.get_chain("AAPL")

    broadcaster.broadcast.assert_awaited_once()
    msg = broadcaster.broadcast.call_args[0][0]
    assert msg.type.value == "option_chain_data"
    assert msg.payload["symbol"] == "AAPL"
    await polygon.close()


@pytest.mark.asyncio
async def test_get_chain_no_broadcaster(feed_no_broadcaster, polygon):
    """Test chain fetch without broadcaster (no broadcast attempted)."""
    with unittest_mock_request(polygon, MOCK_CHAIN_RESPONSE):
        chain = await feed_no_broadcaster.get_chain("AAPL")

    assert chain["total_contracts"] == 3
    await polygon.close()


@pytest.mark.asyncio
async def test_get_chain_error(feed, polygon):
    """Test chain fetch handles API errors gracefully."""
    with unittest_mock_request(polygon, side_effect=Exception("API error")):
        chain = await feed.get_chain("AAPL")

    assert chain["symbol"] == "AAPL"
    assert chain["calls"] == []
    assert chain["puts"] == []
    assert chain["total_contracts"] == 0
    assert "error" in chain
    await polygon.close()


@pytest.mark.asyncio
async def test_get_chain_empty_response(feed, polygon):
    """Test chain fetch with no results."""
    with unittest_mock_request(polygon, {"results": []}):
        chain = await feed.get_chain("AAPL")

    assert chain["calls"] == []
    assert chain["puts"] == []
    assert chain["total_contracts"] == 0
    await polygon.close()


@pytest.mark.asyncio
async def test_get_chain_with_option_type_filter(feed, polygon):
    """Test chain fetch with option_type filter."""
    with unittest_mock_request(polygon, MOCK_CHAIN_RESPONSE) as mock_req:
        await feed.get_chain("AAPL", option_type="call")

    # Verify the contract_type param was passed
    call_kwargs = mock_req.call_args
    params = call_kwargs[0][1] if len(call_kwargs[0]) > 1 else call_kwargs[1].get("params", {})
    assert params.get("contract_type") == "call"
    await polygon.close()


# ─── get_expirations Tests ───────────────────────────────────────────


@pytest.mark.asyncio
async def test_get_expirations(feed, polygon):
    """Test fetching available expirations."""
    with unittest_mock_request(polygon, MOCK_CONTRACTS_RESPONSE):
        expirations = await feed.get_expirations("AAPL")

    assert len(expirations) == 4  # Deduped from 5 results
    assert expirations[0] == "2026-03-21"
    assert expirations[-1] == "2026-06-19"
    # Verify sorted
    assert expirations == sorted(expirations)
    await polygon.close()


@pytest.mark.asyncio
async def test_get_expirations_uppercases(feed, polygon):
    """Test that symbol is uppercased."""
    with unittest_mock_request(polygon, MOCK_CONTRACTS_RESPONSE):
        expirations = await feed.get_expirations("aapl")

    assert len(expirations) == 4
    await polygon.close()


@pytest.mark.asyncio
async def test_get_expirations_error(feed, polygon):
    """Test expirations handles API errors gracefully."""
    with unittest_mock_request(polygon, side_effect=Exception("timeout")):
        expirations = await feed.get_expirations("AAPL")

    assert expirations == []
    await polygon.close()


@pytest.mark.asyncio
async def test_get_expirations_empty(feed, polygon):
    """Test expirations with no results."""
    with unittest_mock_request(polygon, {"results": []}):
        expirations = await feed.get_expirations("AAPL")

    assert expirations == []
    await polygon.close()


# ─── to_dict Tests ──────────────────────────────────────────────────


def test_to_dict(feed):
    d = feed.to_dict()
    assert d["has_polygon"] is True
    assert d["has_ibkr"] is False
    assert d["has_broadcaster"] is True


def test_to_dict_minimal(feed_no_broadcaster):
    d = feed_no_broadcaster.to_dict()
    assert d["has_polygon"] is True
    assert d["has_ibkr"] is False
    assert d["has_broadcaster"] is False


# ─── Helper ─────────────────────────────────────────────────────────


def unittest_mock_request(polygon, return_value=None, side_effect=None):
    """Context manager to mock polygon._request."""
    from unittest.mock import patch
    kwargs = {}
    if side_effect:
        kwargs["side_effect"] = side_effect
    else:
        kwargs["return_value"] = return_value
    return patch.object(polygon, "_request", new_callable=AsyncMock, **kwargs)
