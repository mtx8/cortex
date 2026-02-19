import pytest
from cortex.config import CortexConfig


@pytest.fixture
def config():
    return CortexConfig(
        redis_url="redis://127.0.0.1:6379/1",
        postgres_dsn="postgresql://cortex:cortex@localhost:5432/cortex_test",
    )
