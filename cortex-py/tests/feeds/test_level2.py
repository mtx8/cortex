"""Tests for Level2Feed — order book data streaming."""

import pytest
from unittest.mock import AsyncMock, MagicMock

from cortex.feeds.level2 import Level2Feed, L2BookSnapshot, L2Row


# ─── Fixtures ────────────────────────────────────────────────────────


@pytest.fixture
def ibkr_manager():
    return MagicMock()


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
def feed(ibkr_manager, broadcaster, rate_limiter):
    return Level2Feed(
        ibkr_manager=ibkr_manager,
        broadcaster=broadcaster,
        rate_limiter=rate_limiter,
    )


@pytest.fixture
def feed_no_limiter(ibkr_manager, broadcaster):
    return Level2Feed(
        ibkr_manager=ibkr_manager,
        broadcaster=broadcaster,
        rate_limiter=None,
    )


# ─── L2BookSnapshot Tests ───────────────────────────────────────────


def test_l2_book_snapshot_empty():
    book = L2BookSnapshot(symbol="AAPL")
    d = book.to_dict()
    assert d["symbol"] == "AAPL"
    assert d["bids"] == []
    assert d["asks"] == []
    assert d["timestamp"] == 0.0


def test_l2_book_snapshot_with_data():
    book = L2BookSnapshot(
        symbol="AAPL",
        bids=[L2Row(price=185.00, size=100, num_orders=3)],
        asks=[L2Row(price=185.10, size=200, num_orders=5)],
        timestamp=1700000000.0,
    )
    d = book.to_dict()
    assert d["symbol"] == "AAPL"
    assert len(d["bids"]) == 1
    assert d["bids"][0] == {"price": 185.00, "size": 100, "orders": 3}
    assert len(d["asks"]) == 1
    assert d["asks"][0] == {"price": 185.10, "size": 200, "orders": 5}
    assert d["timestamp"] == 1700000000.0


def test_l2_book_snapshot_multiple_rows():
    book = L2BookSnapshot(
        symbol="NVDA",
        bids=[
            L2Row(price=500.00, size=50, num_orders=2),
            L2Row(price=499.90, size=100, num_orders=4),
            L2Row(price=499.80, size=200, num_orders=8),
        ],
        asks=[
            L2Row(price=500.10, size=30, num_orders=1),
            L2Row(price=500.20, size=80, num_orders=3),
        ],
    )
    d = book.to_dict()
    assert len(d["bids"]) == 3
    assert len(d["asks"]) == 2
    assert d["bids"][0]["price"] == 500.00
    assert d["bids"][2]["size"] == 200


def test_l2_row_defaults():
    row = L2Row(price=100.0, size=50)
    assert row.num_orders == 0


# ─── Level2Feed Lifecycle Tests ─────────────────────────────────────


def test_initial_state(feed):
    assert feed.active_symbol is None
    assert feed.is_running is False
    assert feed.book.symbol == ""


@pytest.mark.asyncio
async def test_subscribe(feed, rate_limiter):
    await feed.subscribe("AAPL", num_rows=10)

    assert feed.active_symbol == "AAPL"
    assert feed.is_running is True
    assert feed.book.symbol == "AAPL"
    rate_limiter.acquire_general.assert_awaited_once()


@pytest.mark.asyncio
async def test_subscribe_without_rate_limiter(feed_no_limiter):
    await feed_no_limiter.subscribe("AAPL")

    assert feed_no_limiter.active_symbol == "AAPL"
    assert feed_no_limiter.is_running is True


@pytest.mark.asyncio
async def test_unsubscribe(feed, rate_limiter):
    await feed.subscribe("AAPL")
    rate_limiter.acquire_general.reset_mock()

    await feed.unsubscribe()

    assert feed.active_symbol is None
    assert feed.is_running is False
    assert feed.book.symbol == ""
    rate_limiter.acquire_general.assert_awaited_once()


@pytest.mark.asyncio
async def test_unsubscribe_when_not_subscribed(feed, rate_limiter):
    """Unsubscribing when nothing is active should be a no-op."""
    await feed.unsubscribe()

    assert feed.active_symbol is None
    rate_limiter.acquire_general.assert_not_awaited()


@pytest.mark.asyncio
async def test_subscribe_replaces_existing(feed, rate_limiter):
    """Subscribing to a new symbol should auto-unsubscribe from the old one."""
    await feed.subscribe("AAPL")
    await feed.subscribe("MSFT")

    assert feed.active_symbol == "MSFT"
    assert feed.book.symbol == "MSFT"
    # 3 calls: subscribe AAPL, unsubscribe AAPL, subscribe MSFT
    assert rate_limiter.acquire_general.await_count == 3


# ─── push_update Tests ──────────────────────────────────────────────


@pytest.mark.asyncio
async def test_push_update_broadcasts(feed, broadcaster):
    await feed.subscribe("AAPL")

    bids = [{"price": 185.00, "size": 100, "num_orders": 3}]
    asks = [{"price": 185.10, "size": 200, "num_orders": 5}]
    await feed.push_update(bids, asks)

    broadcaster.broadcast.assert_awaited_once()
    msg = broadcaster.broadcast.call_args[0][0]
    assert msg.type.value == "l2_update"
    assert msg.payload["symbol"] == "AAPL"
    assert len(msg.payload["bids"]) == 1
    assert len(msg.payload["asks"]) == 1
    assert msg.payload["bids"][0]["price"] == 185.00
    assert msg.payload["asks"][0]["price"] == 185.10
    assert msg.payload["timestamp"] > 0


@pytest.mark.asyncio
async def test_push_update_no_symbol(feed, broadcaster):
    """push_update should be a no-op when no symbol is subscribed."""
    bids = [{"price": 185.00, "size": 100, "num_orders": 3}]
    asks = [{"price": 185.10, "size": 200, "num_orders": 5}]
    await feed.push_update(bids, asks)

    broadcaster.broadcast.assert_not_awaited()


@pytest.mark.asyncio
async def test_push_update_updates_book(feed):
    await feed.subscribe("AAPL")

    bids = [
        {"price": 185.00, "size": 100, "num_orders": 3},
        {"price": 184.90, "size": 200, "num_orders": 5},
    ]
    asks = [{"price": 185.10, "size": 50, "num_orders": 1}]
    await feed.push_update(bids, asks)

    assert len(feed.book.bids) == 2
    assert len(feed.book.asks) == 1
    assert feed.book.bids[0].price == 185.00
    assert feed.book.bids[1].size == 200
    assert feed.book.timestamp > 0


# ─── to_dict Tests ──────────────────────────────────────────────────


def test_to_dict_initial(feed):
    d = feed.to_dict()
    assert d["active_symbol"] is None
    assert d["running"] is False
    assert d["num_rows"] == 20


@pytest.mark.asyncio
async def test_to_dict_subscribed(feed):
    await feed.subscribe("TSLA", num_rows=10)
    d = feed.to_dict()
    assert d["active_symbol"] == "TSLA"
    assert d["running"] is True
    assert d["num_rows"] == 10
