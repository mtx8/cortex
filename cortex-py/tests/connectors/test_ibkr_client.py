import pytest
from cortex.connectors.ibkr.client import IBKRConnectionManager, IBKRConfig


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
