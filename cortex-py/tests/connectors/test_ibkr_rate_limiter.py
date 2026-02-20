"""Tests for IBKR rate limiter."""

import pytest
from cortex.connectors.ibkr.rate_limiter import IBKRRateLimiter


@pytest.fixture
def limiter():
    return IBKRRateLimiter()


@pytest.mark.asyncio
async def test_acquire_historical(limiter):
    await limiter.acquire_historical()
    assert limiter._stats["historical_requests"] == 1


@pytest.mark.asyncio
async def test_acquire_order(limiter):
    await limiter.acquire_order()
    assert limiter._stats["order_requests"] == 1


@pytest.mark.asyncio
async def test_acquire_account(limiter):
    await limiter.acquire_account()
    assert limiter._stats["account_requests"] == 1


@pytest.mark.asyncio
async def test_acquire_general(limiter):
    await limiter.acquire_general()
    assert limiter._stats["general_requests"] == 1


def test_market_data_subscribe_up_to_limit(limiter):
    """Subscribe up to 50 symbols, all should succeed."""
    for i in range(50):
        result = limiter.subscribe_market_data(f"SYM{i}")
        assert result is True
    assert limiter.active_subscriptions == 50


def test_market_data_reject_51st(limiter):
    """51st subscription should be rejected."""
    for i in range(50):
        limiter.subscribe_market_data(f"SYM{i}")

    result = limiter.subscribe_market_data("SYM50")
    assert result is False
    assert limiter.active_subscriptions == 50


def test_unsubscribe_frees_slot(limiter):
    """After unsubscribing, a new subscription should succeed."""
    for i in range(50):
        limiter.subscribe_market_data(f"SYM{i}")

    assert limiter.active_subscriptions == 50

    limiter.unsubscribe_market_data("SYM0")
    assert limiter.active_subscriptions == 49

    result = limiter.subscribe_market_data("NEW_SYM")
    assert result is True
    assert limiter.active_subscriptions == 50


def test_can_subscribe_already_subscribed(limiter):
    """can_subscribe returns True for an already-subscribed symbol even at limit."""
    for i in range(50):
        limiter.subscribe_market_data(f"SYM{i}")

    # Already subscribed symbol should still be allowed
    assert limiter.can_subscribe_market_data("SYM0") is True
    # New symbol should be rejected
    assert limiter.can_subscribe_market_data("NEW_SYM") is False


def test_to_dict_returns_stats(limiter):
    d = limiter.to_dict()
    assert "historical_requests" in d
    assert "order_requests" in d
    assert "account_requests" in d
    assert "general_requests" in d
    assert "rate_limited_waits" in d
    assert "active_market_data" in d
    assert "market_data_limit" in d
    assert d["active_market_data"] == 0
    assert d["market_data_limit"] == 50


@pytest.mark.asyncio
async def test_to_dict_after_requests(limiter):
    await limiter.acquire_historical()
    await limiter.acquire_order()
    await limiter.acquire_account()
    limiter.subscribe_market_data("AAPL")

    d = limiter.to_dict()
    assert d["historical_requests"] == 1
    assert d["order_requests"] == 1
    assert d["account_requests"] == 1
    assert d["active_market_data"] == 1


def test_unsubscribe_nonexistent_symbol(limiter):
    """Unsubscribing a symbol that's not subscribed should not error."""
    limiter.unsubscribe_market_data("NONEXISTENT")
    assert limiter.active_subscriptions == 0


def test_subscribe_same_symbol_twice(limiter):
    """Subscribing the same symbol twice should not double-count."""
    limiter.subscribe_market_data("AAPL")
    limiter.subscribe_market_data("AAPL")
    assert limiter.active_subscriptions == 1
