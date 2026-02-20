import pytest
from unittest.mock import AsyncMock, MagicMock
from cortex.connectors.ibkr.client import IBKRConnectionManager, IBKRConfig
from cortex.connectors.ibkr.rate_limiter import IBKRRateLimiter


def test_ibkr_config_defaults():
    config = IBKRConfig()
    assert config.host == "127.0.0.1"
    assert config.port == 4001
    assert config.client_id == 1
    assert config.max_reconnect_attempts == 10


@pytest.mark.asyncio
async def test_connection_manager_initial_state():
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config)
    assert mgr.is_connected is False
    assert mgr.reconnect_count == 0


@pytest.mark.asyncio
async def test_connection_manager_tracks_reconnects():
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config)
    mgr._reconnect_count = 3
    assert mgr.reconnect_count == 3


# ── Rate limiter wiring tests ─────────────────────────────────────


def test_rate_limiter_accepted_and_stored():
    """IBKRConnectionManager accepts an optional rate_limiter parameter."""
    config = IBKRConfig()
    limiter = IBKRRateLimiter()
    mgr = IBKRConnectionManager(config, rate_limiter=limiter)
    assert mgr._rate_limiter is limiter


def test_rate_limiter_defaults_to_none():
    """Without a rate_limiter kwarg, _rate_limiter should be None."""
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config)
    assert mgr._rate_limiter is None


@pytest.mark.asyncio
async def test_place_order_calls_rate_limiter():
    """place_order must acquire_order from rate limiter before calling IBKR."""
    limiter = IBKRRateLimiter()
    limiter.acquire_order = AsyncMock()
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config, rate_limiter=limiter)
    # Fake a connected IB instance
    mgr._ib = MagicMock()
    mgr._ib.placeOrder = MagicMock(return_value=None)

    await mgr.place_order(MagicMock(), MagicMock())
    limiter.acquire_order.assert_awaited_once()


@pytest.mark.asyncio
async def test_get_positions_calls_rate_limiter():
    """get_positions must acquire_account from rate limiter."""
    limiter = IBKRRateLimiter()
    limiter.acquire_account = AsyncMock()
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config, rate_limiter=limiter)
    mgr._ib = MagicMock()
    mgr._ib.positions = MagicMock(return_value=[])

    await mgr.get_positions()
    limiter.acquire_account.assert_awaited_once()


@pytest.mark.asyncio
async def test_get_account_summary_calls_rate_limiter():
    """get_account_summary must acquire_account from rate limiter."""
    limiter = IBKRRateLimiter()
    limiter.acquire_account = AsyncMock()
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config, rate_limiter=limiter)
    mgr._ib = MagicMock()
    mgr._ib.accountSummary = MagicMock(return_value=[])

    await mgr.get_account_summary()
    limiter.acquire_account.assert_awaited_once()


@pytest.mark.asyncio
async def test_get_historical_data_calls_rate_limiter():
    """get_historical_data must acquire_historical from rate limiter."""
    limiter = IBKRRateLimiter()
    limiter.acquire_historical = AsyncMock()
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config, rate_limiter=limiter)
    mgr._ib = MagicMock()
    mgr._ib.reqHistoricalDataAsync = AsyncMock(return_value=[])

    await mgr.get_historical_data(MagicMock())
    limiter.acquire_historical.assert_awaited_once()


def test_subscribe_market_data_checks_limit():
    """subscribe_market_data must consult rate limiter for slot availability."""
    limiter = IBKRRateLimiter()
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config, rate_limiter=limiter)
    mgr._ib = MagicMock()
    mgr._ib.reqMktData = MagicMock()

    # First subscription should succeed
    mgr.subscribe_market_data(MagicMock(), "AAPL")
    assert limiter.active_subscriptions == 1

    # Fill to the limit
    for i in range(49):
        mgr.subscribe_market_data(MagicMock(), f"SYM{i}")
    assert limiter.active_subscriptions == 50

    # 51st should raise
    with pytest.raises(RuntimeError, match="Market data limit reached"):
        mgr.subscribe_market_data(MagicMock(), "OVERFLOW")


def test_unsubscribe_market_data_frees_slot():
    """unsubscribe_market_data must tell rate limiter to release the slot."""
    limiter = IBKRRateLimiter()
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config, rate_limiter=limiter)
    mgr._ib = MagicMock()
    mgr._ib.reqMktData = MagicMock()
    mgr._ib.cancelMktData = MagicMock()

    mgr.subscribe_market_data(MagicMock(), "AAPL")
    assert limiter.active_subscriptions == 1

    mgr.unsubscribe_market_data(MagicMock(), "AAPL")
    assert limiter.active_subscriptions == 0


@pytest.mark.asyncio
async def test_reconcile_positions_calls_rate_limiter():
    """_reconcile_positions must acquire_account from rate limiter."""
    limiter = IBKRRateLimiter()
    limiter.acquire_account = AsyncMock()
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config, rate_limiter=limiter)
    mgr._ib = MagicMock()
    mgr._ib.positions = MagicMock(return_value=[])

    await mgr._reconcile_positions()
    limiter.acquire_account.assert_awaited_once()


@pytest.mark.asyncio
async def test_methods_work_without_rate_limiter():
    """All methods must work when rate_limiter is None (backwards compatible)."""
    config = IBKRConfig()
    mgr = IBKRConnectionManager(config)  # No rate_limiter
    mgr._ib = MagicMock()
    mgr._ib.placeOrder = MagicMock(return_value=None)
    mgr._ib.positions = MagicMock(return_value=[])
    mgr._ib.accountSummary = MagicMock(return_value=[])
    mgr._ib.reqHistoricalDataAsync = AsyncMock(return_value=[])
    mgr._ib.reqMktData = MagicMock()
    mgr._ib.cancelMktData = MagicMock()

    # None of these should raise
    await mgr.place_order(MagicMock(), MagicMock())
    await mgr.get_positions()
    await mgr.get_account_summary()
    await mgr.get_historical_data(MagicMock())
    mgr.subscribe_market_data(MagicMock(), "AAPL")
    mgr.unsubscribe_market_data(MagicMock(), "AAPL")
