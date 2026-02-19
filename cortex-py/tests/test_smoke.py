from cortex.config import CortexConfig


def test_config_loads_defaults():
    config = CortexConfig()
    assert config.ws_port == 8765
    assert config.max_concurrent_positions == 15
    assert config.total_drawdown_kill_pct == 20.0
