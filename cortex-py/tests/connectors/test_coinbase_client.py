import pytest
from cortex.connectors.coinbase.client import (
    CoinbaseClient, CryptoOrder, CryptoBalance,
)


def test_crypto_balance_creation():
    b = CryptoBalance(currency="BTC", available=1.5, hold=0.1)
    assert b.total == 1.6


def test_crypto_order_creation():
    o = CryptoOrder(
        symbol="BTC-USD", side="buy", quantity=0.01,
        order_type="market", status="pending",
    )
    assert o.symbol == "BTC-USD"


def test_client_initialization():
    client = CoinbaseClient(api_key="test", private_key="test")
    assert client.is_connected is False


def test_supported_pairs():
    client = CoinbaseClient(api_key="test", private_key="test")
    pairs = client.supported_pairs
    assert "BTC-USD" in pairs
    assert "ETH-USD" in pairs


@pytest.mark.asyncio
async def test_get_balances_mock():
    client = CoinbaseClient(api_key="test", private_key="test", sandbox=True)
    balances = await client.get_balances()
    assert isinstance(balances, list)


@pytest.mark.asyncio
async def test_submit_order_validation():
    client = CoinbaseClient(api_key="test", private_key="test", sandbox=True)
    order = CryptoOrder(
        symbol="BTC-USD", side="buy", quantity=0.001,
        order_type="market", status="pending",
    )
    result = await client.submit_order(order)
    assert result.status in ("filled", "submitted", "rejected")


@pytest.mark.asyncio
async def test_submit_order_notional_cap():
    client = CoinbaseClient(
        api_key="test", private_key="test",
        sandbox=True, max_notional=500.0,
    )
    order = CryptoOrder(
        symbol="BTC-USD", side="buy", quantity=1.0,
        order_type="market", status="pending",
        estimated_price=60000.0,
    )
    result = await client.submit_order(order)
    assert result.status == "rejected"
    assert "notional" in (result.rejection_reason or "").lower()


def test_to_dict():
    client = CoinbaseClient(api_key="test", private_key="test")
    d = client.to_dict()
    assert "connected" in d
    assert "sandbox" in d
