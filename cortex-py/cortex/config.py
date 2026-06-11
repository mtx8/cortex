from pydantic_settings import BaseSettings
from pathlib import Path


class CortexConfig(BaseSettings):
    # Server
    host: str = "127.0.0.1"
    ws_port: int = 8765

    # Databases
    redis_url: str = "redis://127.0.0.1:6379/0"
    postgres_dsn: str = "postgresql://cortex:cortex@localhost:5432/cortex"
    questdb_ilp: str = "tcp::addr=localhost:9009;"
    sqlite_path: Path = Path.home() / ".cortex" / "agent_state.db"

    # Brokers
    ibkr_host: str = "127.0.0.1"
    ibkr_port: int = 4001
    ibkr_client_id: int = 1

    coinbase_api_key: str = ""
    coinbase_private_key: str = ""

    # Data feeds
    polygon_api_key: str = ""
    unusual_whales_api_key: str = ""
    benzinga_api_key: str = ""

    # AI
    anthropic_api_key: str = ""
    claude_model: str = "claude-opus-4-6"
    strategic_cycle_seconds: int = 300

    # Geo-intelligence (physical alpha — maritime AIS, seismic, chokepoints)
    geo_enabled: bool = True
    geo_poll_interval: float = 60.0
    # Free, keyless live AIS spine (Baltic). AISStream (global) needs a key.
    aisstream_api_key: str = ""
    eia_api_key: str = ""          # EIA petroleum status / chokepoint volumes
    fred_api_key: str = ""         # FRED yield curve / econ series

    # Risk defaults
    max_position_pct: float = 5.0
    max_single_trade_loss_usd: float = 500.0
    daily_drawdown_throttle_pct: float = 5.0
    daily_drawdown_halt_pct: float = 7.0
    weekly_drawdown_halt_pct: float = 10.0
    total_drawdown_kill_pct: float = 20.0
    max_concurrent_positions: int = 15
    max_daily_trades: int = 50

    model_config = {"env_prefix": "CORTEX_", "env_file": ".env"}
