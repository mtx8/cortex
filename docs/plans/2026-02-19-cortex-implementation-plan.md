# CORTEX Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a macOS-native autonomous AI trading platform with 44 agents across 6 squadrons, trading stocks/options (IBKR) and crypto (Coinbase), powered by Claude API.

**Architecture:** Monolith-first Python backend (FastAPI + asyncio) with Rust scanner engine via PyO3 FFI. Native Swift macOS app communicating over WebSocket with MessagePack encoding. QuestDB + PostgreSQL + SQLite + Redis for storage.

**Tech Stack:** Python 3.12+, Rust 1.75+, Swift 5.9+, FastAPI, uvloop, ib_async, PyO3, SwiftUI, AppKit, Claude API (Anthropic SDK), QuestDB, PostgreSQL 16, Redis 7, SQLite

**Design doc:** `docs/plans/2026-02-19-cortex-platform-design.md`

---

## Phase 1: Project Skeleton & Infrastructure (Week 1)

### Task 1: Initialize Python Project Structure

**Files:**
- Create: `cortex-py/pyproject.toml`
- Create: `cortex-py/cortex/__init__.py`
- Create: `cortex-py/cortex/config.py`
- Create: `cortex-py/cortex/main.py`
- Create: `cortex-py/cortex/squadrons/__init__.py`
- Create: `cortex-py/cortex/squadrons/alpha/__init__.py`
- Create: `cortex-py/cortex/squadrons/bravo/__init__.py`
- Create: `cortex-py/cortex/squadrons/charlie/__init__.py`
- Create: `cortex-py/cortex/squadrons/delta/__init__.py`
- Create: `cortex-py/cortex/squadrons/echo/__init__.py`
- Create: `cortex-py/cortex/squadrons/foxtrot/__init__.py`
- Create: `cortex-py/cortex/orchestrator/__init__.py`
- Create: `cortex-py/cortex/connectors/__init__.py`
- Create: `cortex-py/cortex/storage/__init__.py`
- Create: `cortex-py/cortex/intelligence/__init__.py`
- Create: `cortex-py/tests/__init__.py`
- Create: `cortex-py/tests/conftest.py`

**Step 1: Create pyproject.toml with all dependencies**

```toml
[project]
name = "cortex"
version = "0.1.0"
requires-python = ">=3.12"
dependencies = [
    "fastapi>=0.111.0",
    "uvicorn[standard]>=0.30.0",
    "uvloop>=0.19.0",
    "websockets>=12.0",
    "httpx>=0.27.0",
    "redis[hiredis]>=5.0.0",
    "asyncpg>=0.29.0",
    "pydantic>=2.7.0",
    "pydantic-settings>=2.3.0",
    "aiolimiter>=1.1.0",
    "orjson>=3.10.0",
    "structlog>=24.2.0",
    "anthropic>=0.28.0",
    "ib_async>=0.9.0",
    "msgpack>=1.0.0",
]

[project.optional-dependencies]
dev = [
    "pytest>=8.0.0",
    "pytest-asyncio>=0.23.0",
    "pytest-cov>=5.0.0",
    "ruff>=0.4.0",
]

[tool.pytest.ini_options]
asyncio_mode = "auto"
testpaths = ["tests"]

[tool.ruff]
target-version = "py312"
line-length = 100
```

**Step 2: Create config.py with pydantic-settings**

```python
# cortex-py/cortex/config.py
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
    claude_model: str = "claude-sonnet-4-6"
    strategic_cycle_seconds: int = 300

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
```

**Step 3: Create main.py FastAPI app with lifespan**

```python
# cortex-py/cortex/main.py
import uvloop
uvloop.install()

from contextlib import asynccontextmanager
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
import structlog

from cortex.config import CortexConfig

log = structlog.get_logger()
config = CortexConfig()


@asynccontextmanager
async def lifespan(app: FastAPI):
    log.info("cortex.starting", ws_port=config.ws_port)
    yield
    log.info("cortex.shutdown")


app = FastAPI(title="CORTEX", lifespan=lifespan)


@app.websocket("/ws")
async def websocket_endpoint(ws: WebSocket):
    await ws.accept()
    log.info("ws.connected")
    try:
        while True:
            data = await ws.receive_bytes()
            # MessagePack decode will be handled by message router
            await ws.send_bytes(data)  # Echo for now
    except WebSocketDisconnect:
        log.info("ws.disconnected")
```

**Step 4: Create conftest.py with shared fixtures**

```python
# cortex-py/tests/conftest.py
import pytest
from cortex.config import CortexConfig


@pytest.fixture
def config():
    return CortexConfig(
        redis_url="redis://127.0.0.1:6379/1",  # Test DB
        postgres_dsn="postgresql://cortex:cortex@localhost:5432/cortex_test",
    )
```

**Step 5: Write smoke test**

```python
# cortex-py/tests/test_smoke.py
from cortex.config import CortexConfig


def test_config_loads_defaults():
    config = CortexConfig()
    assert config.ws_port == 8765
    assert config.max_concurrent_positions == 15
    assert config.total_drawdown_kill_pct == 20.0
```

**Step 6: Install and run test**

Run: `cd cortex-py && pip install -e ".[dev]" && pytest tests/test_smoke.py -v`
Expected: PASS

**Step 7: Commit**

```bash
git add cortex-py/
git commit -m "feat: initialize cortex python project structure with config"
```

---

### Task 2: SignalBus — The Nervous System

**Files:**
- Create: `cortex-py/cortex/orchestrator/signals.py`
- Create: `cortex-py/cortex/orchestrator/bus.py`
- Test: `cortex-py/tests/orchestrator/test_bus.py`

**Step 1: Write the signal types and bus failing test**

```python
# cortex-py/tests/orchestrator/__init__.py
```

```python
# cortex-py/tests/orchestrator/test_bus.py
import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority


@pytest.mark.asyncio
async def test_bus_publishes_and_delivers():
    bus = SignalBus()
    received = []

    async def handler(signal: Signal):
        received.append(signal)

    bus.subscribe("test.signal", handler)

    task = asyncio.create_task(bus.run())

    await bus.publish(Signal(
        signal_id="s1",
        source_agent="test_agent",
        source_squadron="alpha",
        signal_type="test.signal",
        payload={"ticker": "AAPL"},
        priority=SignalPriority.NORMAL,
    ))

    await asyncio.sleep(0.05)
    task.cancel()

    assert len(received) == 1
    assert received[0].payload["ticker"] == "AAPL"


@pytest.mark.asyncio
async def test_bus_priority_ordering():
    bus = SignalBus()
    received = []

    async def handler(signal: Signal):
        received.append(signal.signal_id)

    bus.subscribe_all(handler)

    # Publish low priority first, then critical
    await bus.publish(Signal(
        signal_id="low",
        source_agent="a", source_squadron="a",
        signal_type="x", payload={},
        priority=SignalPriority.LOW,
    ))
    await bus.publish(Signal(
        signal_id="critical",
        source_agent="a", source_squadron="a",
        signal_type="x", payload={},
        priority=SignalPriority.CRITICAL,
    ))

    task = asyncio.create_task(bus.run())
    await asyncio.sleep(0.05)
    task.cancel()

    assert received[0] == "critical"
    assert received[1] == "low"


@pytest.mark.asyncio
async def test_bus_wildcard_subscriber():
    bus = SignalBus()
    received = []

    async def handler(signal: Signal):
        received.append(signal.signal_type)

    bus.subscribe_all(handler)

    task = asyncio.create_task(bus.run())

    await bus.publish(Signal(
        signal_id="s1", source_agent="a", source_squadron="a",
        signal_type="alpha.signal", payload={},
        priority=SignalPriority.NORMAL,
    ))
    await bus.publish(Signal(
        signal_id="s2", source_agent="a", source_squadron="a",
        signal_type="echo.risk_breach", payload={},
        priority=SignalPriority.CRITICAL,
    ))

    await asyncio.sleep(0.05)
    task.cancel()

    assert "alpha.signal" in received
    assert "echo.risk_breach" in received
```

**Step 2: Run tests to verify they fail**

Run: `cd cortex-py && pytest tests/orchestrator/test_bus.py -v`
Expected: FAIL (ImportError)

**Step 3: Implement signals.py and bus.py**

```python
# cortex-py/cortex/orchestrator/signals.py
"""Complete signal type registry for inter-agent communication."""


class SignalTypes:
    # ALPHA -> everyone
    MARKET_SIGNAL = "alpha.market_signal"
    PATTERN_DETECTED = "alpha.pattern_detected"
    VOLUME_SURGE = "alpha.volume_surge"
    GAP_DETECTED = "alpha.gap_detected"
    SECTOR_ROTATION = "alpha.sector_rotation"
    ENTRY_SIGNAL = "alpha.entry_signal"
    EXIT_SIGNAL = "alpha.exit_signal"

    # CHARLIE -> BRAVO
    OPTIONS_ENTRY = "charlie.options_entry"
    OPTIONS_EXIT = "charlie.options_exit"
    SWEEP_DETECTED = "charlie.sweep_detected"

    # DELTA -> ALPHA, CHARLIE
    NEWS_CATALYST = "delta.news_catalyst"
    EARNINGS_ALERT = "delta.earnings_alert"
    INSIDER_SIGNAL = "delta.insider_signal"
    CONGRESS_TRADE = "delta.congress_trade"
    EDGAR_FILING = "delta.edgar_filing"

    # ECHO -> everyone (risk overrides all)
    RISK_BREACH = "echo.risk_breach"
    DRAWDOWN_WARNING = "echo.drawdown_warning"
    KILL_SWITCH = "echo.kill_switch"
    POSITION_SIZE = "echo.position_size"

    # BRAVO -> ECHO, FOXTROT
    ORDER_FILLED = "bravo.order_filled"
    ORDER_REJECTED = "bravo.order_rejected"
    SLIPPAGE_REPORT = "bravo.slippage_report"

    # FOXTROT -> BRAVO
    TAX_HARVEST_SIGNAL = "foxtrot.tax_harvest"
    WASH_SALE_BLOCK = "foxtrot.wash_sale_block"

    # System
    AGENT_HEALTH = "system.agent_health"
    STRATEGY_UPDATE = "intelligence.strategy_update"
```

```python
# cortex-py/cortex/orchestrator/bus.py
"""SignalBus — the central nervous system of CORTEX.
ALL inter-agent communication goes through here. No exceptions.
Squadron agents NEVER import from other squadrons directly."""

import asyncio
import time
from collections import defaultdict
from dataclasses import dataclass, field
from enum import IntEnum
from typing import Callable, Awaitable
import structlog

log = structlog.get_logger()


class SignalPriority(IntEnum):
    CRITICAL = 0  # Kill switch, risk breach
    HIGH = 1      # Order execution signals
    NORMAL = 2    # Standard agent signals
    LOW = 3       # Analytics, non-actionable


@dataclass
class Signal:
    signal_id: str
    source_agent: str
    source_squadron: str
    signal_type: str
    payload: dict
    priority: SignalPriority
    timestamp: float = field(default_factory=time.time)
    target_agents: list[str] = field(default_factory=list)

    def __lt__(self, other: "Signal") -> bool:
        return self.priority < other.priority


class SignalBus:
    def __init__(self):
        self._queue: asyncio.PriorityQueue[tuple[int, float, Signal]] = (
            asyncio.PriorityQueue()
        )
        self._subscribers: dict[str, list[Callable[[Signal], Awaitable[None]]]] = (
            defaultdict(list)
        )
        self._state: dict[str, Signal] = {}
        self._dispatch_count = 0
        self._seq = 0  # Tie-breaker for same priority

    async def publish(self, signal: Signal) -> None:
        self._seq += 1
        await self._queue.put((signal.priority.value, self._seq, signal))

    def subscribe(
        self, signal_type: str, handler: Callable[[Signal], Awaitable[None]]
    ) -> None:
        self._subscribers[signal_type].append(handler)

    def subscribe_all(
        self, handler: Callable[[Signal], Awaitable[None]]
    ) -> None:
        self._subscribers["*"].append(handler)

    async def run(self) -> None:
        while True:
            _, _, signal = await self._queue.get()
            self._state[signal.signal_type] = signal
            self._dispatch_count += 1

            handlers = list(self._subscribers.get(signal.signal_type, []))
            handlers += list(self._subscribers.get("*", []))

            if handlers:
                results = await asyncio.gather(
                    *[h(signal) for h in handlers],
                    return_exceptions=True,
                )
                for i, result in enumerate(results):
                    if isinstance(result, Exception):
                        log.error(
                            "bus.handler_error",
                            signal_type=signal.signal_type,
                            error=str(result),
                        )

            self._queue.task_done()

    def get_current_state(self) -> dict[str, Signal]:
        return dict(self._state)

    @property
    def dispatch_count(self) -> int:
        return self._dispatch_count
```

**Step 4: Run tests to verify they pass**

Run: `cd cortex-py && pytest tests/orchestrator/test_bus.py -v`
Expected: 3 PASSED

**Step 5: Commit**

```bash
git add cortex-py/cortex/orchestrator/ cortex-py/tests/orchestrator/
git commit -m "feat: implement SignalBus with priority queue and wildcard subscribers"
```

---

### Task 3: Base Agent Framework

**Files:**
- Create: `cortex-py/cortex/squadrons/base.py`
- Test: `cortex-py/tests/squadrons/test_base.py`

**Step 1: Write failing test for base agent**

```python
# cortex-py/tests/squadrons/__init__.py
```

```python
# cortex-py/tests/squadrons/test_base.py
import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.squadrons.base import BaseAgent


class MockAgent(BaseAgent):
    agent_id = "mock_agent"
    squadron = "test"
    subscriptions = ["test.signal"]

    def __init__(self, bus: SignalBus):
        super().__init__(bus)
        self.received: list[Signal] = []

    async def handle_signal(self, signal: Signal) -> None:
        self.received.append(signal)


@pytest.mark.asyncio
async def test_agent_receives_subscribed_signals():
    bus = SignalBus()
    agent = MockAgent(bus)
    agent.register()

    task = asyncio.create_task(bus.run())

    await bus.publish(Signal(
        signal_id="s1", source_agent="test", source_squadron="test",
        signal_type="test.signal", payload={"data": 1},
        priority=SignalPriority.NORMAL,
    ))
    await asyncio.sleep(0.05)
    task.cancel()

    assert len(agent.received) == 1
    assert agent.received[0].payload["data"] == 1


@pytest.mark.asyncio
async def test_agent_ignores_unsubscribed_signals():
    bus = SignalBus()
    agent = MockAgent(bus)
    agent.register()

    task = asyncio.create_task(bus.run())

    await bus.publish(Signal(
        signal_id="s1", source_agent="test", source_squadron="test",
        signal_type="other.signal", payload={},
        priority=SignalPriority.NORMAL,
    ))
    await asyncio.sleep(0.05)
    task.cancel()

    assert len(agent.received) == 0


@pytest.mark.asyncio
async def test_agent_status_tracking():
    bus = SignalBus()
    agent = MockAgent(bus)
    assert agent.status == "idle"

    agent.register()
    assert agent.status == "active"
```

**Step 2: Run to verify failure**

Run: `cd cortex-py && pytest tests/squadrons/test_base.py -v`
Expected: FAIL

**Step 3: Implement BaseAgent**

```python
# cortex-py/cortex/squadrons/base.py
"""Base class for all CORTEX agents. All 44 agents inherit from this."""

from abc import ABC, abstractmethod
import time
import structlog

from cortex.orchestrator.bus import SignalBus, Signal

log = structlog.get_logger()


class BaseAgent(ABC):
    agent_id: str = "unset"
    squadron: str = "unset"
    subscriptions: list[str] = []

    def __init__(self, bus: SignalBus):
        self._bus = bus
        self._status = "idle"
        self._signal_count = 0
        self._last_signal_ts: float | None = None
        self._error_count = 0

    @property
    def status(self) -> str:
        return self._status

    def register(self) -> None:
        for signal_type in self.subscriptions:
            self._bus.subscribe(signal_type, self._on_signal)
        self._status = "active"
        log.info("agent.registered", agent_id=self.agent_id, squadron=self.squadron)

    async def _on_signal(self, signal: Signal) -> None:
        self._signal_count += 1
        self._last_signal_ts = time.time()
        try:
            await self.handle_signal(signal)
        except Exception as e:
            self._error_count += 1
            log.error(
                "agent.handle_error",
                agent_id=self.agent_id,
                error=str(e),
                signal_type=signal.signal_type,
            )

    @abstractmethod
    async def handle_signal(self, signal: Signal) -> None:
        ...

    async def emit(self, signal_type: str, payload: dict, priority=None) -> None:
        from cortex.orchestrator.bus import SignalPriority
        await self._bus.publish(Signal(
            signal_id=f"{self.agent_id}_{self._signal_count}",
            source_agent=self.agent_id,
            source_squadron=self.squadron,
            signal_type=signal_type,
            payload=payload,
            priority=priority or SignalPriority.NORMAL,
        ))

    def to_dict(self) -> dict:
        return {
            "agent_id": self.agent_id,
            "squadron": self.squadron,
            "status": self._status,
            "signal_count": self._signal_count,
            "error_count": self._error_count,
            "last_signal_ts": self._last_signal_ts,
        }
```

**Step 4: Run tests**

Run: `cd cortex-py && pytest tests/squadrons/test_base.py -v`
Expected: 3 PASSED

**Step 5: Commit**

```bash
git add cortex-py/cortex/squadrons/base.py cortex-py/tests/squadrons/
git commit -m "feat: implement BaseAgent framework for all 44 agents"
```

---

### Task 4: Kill Switch Commander (ECHO)

**Files:**
- Create: `cortex-py/cortex/squadrons/echo/kill_switch.py`
- Test: `cortex-py/tests/squadrons/echo/test_kill_switch.py`

**Step 1: Write failing tests**

```python
# cortex-py/tests/squadrons/echo/__init__.py
```

```python
# cortex-py/tests/squadrons/echo/test_kill_switch.py
import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.echo.kill_switch import KillSwitchCommander, KillSwitchState


@pytest.mark.asyncio
async def test_kill_switch_starts_inactive():
    bus = SignalBus()
    ks = KillSwitchCommander(bus)
    assert ks.state == KillSwitchState.ARMED


@pytest.mark.asyncio
async def test_kill_switch_engages():
    bus = SignalBus()
    ks = KillSwitchCommander(bus)
    ks.register()

    killed_signals = []
    bus.subscribe(SignalTypes.KILL_SWITCH, lambda s: killed_signals.append(s))

    task = asyncio.create_task(bus.run())
    await ks.engage(reason="manual", triggered_by="user")
    await asyncio.sleep(0.05)
    task.cancel()

    assert ks.state == KillSwitchState.ENGAGED
    assert len(killed_signals) == 1
    assert killed_signals[0].payload["reason"] == "manual"


@pytest.mark.asyncio
async def test_kill_switch_blocks_when_engaged():
    bus = SignalBus()
    ks = KillSwitchCommander(bus)
    await ks.engage(reason="test", triggered_by="test")
    assert ks.is_halted is True


@pytest.mark.asyncio
async def test_kill_switch_disengage_requires_manual():
    bus = SignalBus()
    ks = KillSwitchCommander(bus)
    await ks.engage(reason="drawdown", triggered_by="drawdown_shield")

    ks.disengage(operator="user")
    assert ks.state == KillSwitchState.ARMED
    assert ks.is_halted is False
```

**Step 2: Run to verify failure**

Run: `cd cortex-py && pytest tests/squadrons/echo/test_kill_switch.py -v`
Expected: FAIL

**Step 3: Implement KillSwitchCommander**

```python
# cortex-py/cortex/squadrons/echo/kill_switch.py
"""Kill Switch Commander — emergency halt of all trading activity.
Phase 1 (halt flag) is synchronous and in-memory only.
No network call can delay it."""

import time
from enum import Enum
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class KillSwitchState(str, Enum):
    ARMED = "armed"           # Normal operation
    ENGAGED = "engaged"       # Halted, no trading
    RECOVERING = "recovering" # Closing positions


class KillSwitchCommander(BaseAgent):
    agent_id = "kill_switch_commander"
    squadron = "echo"
    subscriptions = []  # Doesn't subscribe — it COMMANDS

    def __init__(self, bus: SignalBus):
        super().__init__(bus)
        self._state = KillSwitchState.ARMED
        self._is_halted = False
        self._engaged_at: float | None = None
        self._engaged_reason: str | None = None
        self._engaged_by: str | None = None

    @property
    def state(self) -> KillSwitchState:
        return self._state

    @property
    def is_halted(self) -> bool:
        return self._is_halted

    async def engage(self, reason: str, triggered_by: str) -> None:
        # PHASE 1: Synchronous halt flag — this MUST be instant
        self._is_halted = True
        self._state = KillSwitchState.ENGAGED
        self._engaged_at = time.time()
        self._engaged_reason = reason
        self._engaged_by = triggered_by

        log.critical(
            "KILL_SWITCH_ENGAGED",
            reason=reason,
            triggered_by=triggered_by,
        )

        # Broadcast to all agents via bus
        await self.emit(
            SignalTypes.KILL_SWITCH,
            payload={
                "reason": reason,
                "triggered_by": triggered_by,
                "engaged_at": self._engaged_at,
                "phase": "halt",
            },
            priority=SignalPriority.CRITICAL,
        )

    def disengage(self, operator: str) -> None:
        log.warning("KILL_SWITCH_DISENGAGED", operator=operator)
        self._is_halted = False
        self._state = KillSwitchState.ARMED
        self._engaged_at = None
        self._engaged_reason = None

    async def handle_signal(self, signal: Signal) -> None:
        pass  # Kill switch doesn't react to signals — it commands

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "kill_switch_state": self._state.value,
            "is_halted": self._is_halted,
            "engaged_at": self._engaged_at,
            "engaged_reason": self._engaged_reason,
        })
        return base
```

**Step 4: Run tests**

Run: `cd cortex-py && pytest tests/squadrons/echo/test_kill_switch.py -v`
Expected: 4 PASSED

**Step 5: Commit**

```bash
git add cortex-py/cortex/squadrons/echo/ cortex-py/tests/squadrons/echo/
git commit -m "feat: implement Kill Switch Commander with instant halt flag"
```

---

### Task 5: Pre-Trade Risk Check Engine

**Files:**
- Create: `cortex-py/cortex/squadrons/echo/risk_checks.py`
- Test: `cortex-py/tests/squadrons/echo/test_risk_checks.py`

**Step 1: Write failing tests for pre-trade checks**

```python
# cortex-py/tests/squadrons/echo/test_risk_checks.py
import pytest
from cortex.squadrons.echo.risk_checks import (
    PreTradeCheck,
    CheckResult,
    OrderRequest,
    PortfolioState,
)


def make_portfolio(nav: float = 50000.0, daily_drawdown_pct: float = 0.0) -> PortfolioState:
    return PortfolioState(
        nav=nav,
        daily_drawdown_pct=daily_drawdown_pct,
        weekly_drawdown_pct=0.0,
        total_drawdown_pct=0.0,
        position_count=5,
        daily_trade_count=10,
    )


def make_order(
    symbol: str = "AAPL",
    quantity: float = 10,
    price: float = 150.0,
    asset_class: str = "equity",
    is_closing: bool = False,
) -> OrderRequest:
    return OrderRequest(
        symbol=symbol,
        quantity=quantity,
        estimated_price=price,
        asset_class=asset_class,
        side="buy",
        is_closing=is_closing,
    )


def test_order_within_limits_passes():
    checker = PreTradeCheck(max_position_pct=5.0, max_concurrent=15, max_daily_trades=50)
    portfolio = make_portfolio()
    order = make_order()  # $1500 order on $50K portfolio = 3%
    result = checker.run(order, portfolio, is_halted=False)
    assert result.approved is True


def test_kill_switch_blocks_all():
    checker = PreTradeCheck(max_position_pct=5.0, max_concurrent=15, max_daily_trades=50)
    portfolio = make_portfolio()
    order = make_order()
    result = checker.run(order, portfolio, is_halted=True)
    assert result.approved is False
    assert "HALTED" in result.rejections[0]


def test_oversized_position_rejected():
    checker = PreTradeCheck(max_position_pct=5.0, max_concurrent=15, max_daily_trades=50)
    portfolio = make_portfolio(nav=50000.0)
    order = make_order(quantity=100, price=150.0)  # $15,000 = 30% of $50K
    result = checker.run(order, portfolio, is_halted=False)
    assert result.approved is False
    assert any("position size" in r.lower() for r in result.rejections)


def test_drawdown_halt_blocks_new_positions():
    checker = PreTradeCheck(
        max_position_pct=5.0, max_concurrent=15, max_daily_trades=50,
        daily_drawdown_halt_pct=7.0,
    )
    portfolio = make_portfolio(daily_drawdown_pct=8.0)
    order = make_order()
    result = checker.run(order, portfolio, is_halted=False)
    assert result.approved is False


def test_closing_positions_allowed_during_drawdown():
    checker = PreTradeCheck(
        max_position_pct=5.0, max_concurrent=15, max_daily_trades=50,
        daily_drawdown_halt_pct=7.0,
    )
    portfolio = make_portfolio(daily_drawdown_pct=8.0)
    order = make_order(is_closing=True)
    result = checker.run(order, portfolio, is_halted=False)
    assert result.approved is True


def test_max_positions_blocks_new():
    checker = PreTradeCheck(max_position_pct=5.0, max_concurrent=5, max_daily_trades=50)
    portfolio = make_portfolio()
    portfolio.position_count = 5  # At limit
    order = make_order()
    result = checker.run(order, portfolio, is_halted=False)
    assert result.approved is False
```

**Step 2: Run to verify failure**

Run: `cd cortex-py && pytest tests/squadrons/echo/test_risk_checks.py -v`
Expected: FAIL

**Step 3: Implement PreTradeCheck**

```python
# cortex-py/cortex/squadrons/echo/risk_checks.py
"""Pre-trade risk checks. Every order must pass ALL checks.
Target execution time: <10ms (all in-memory, no I/O)."""

from dataclasses import dataclass, field
import time


@dataclass
class OrderRequest:
    symbol: str
    quantity: float
    estimated_price: float
    asset_class: str  # "equity" | "option" | "crypto"
    side: str  # "buy" | "sell"
    is_closing: bool = False
    stop_loss: float | None = None


@dataclass
class PortfolioState:
    nav: float
    daily_drawdown_pct: float
    weekly_drawdown_pct: float
    total_drawdown_pct: float
    position_count: int
    daily_trade_count: int


@dataclass
class CheckResult:
    approved: bool
    rejections: list[str] = field(default_factory=list)
    warnings: list[str] = field(default_factory=list)
    check_duration_ms: float = 0.0


class PreTradeCheck:
    def __init__(
        self,
        max_position_pct: float = 5.0,
        max_concurrent: int = 15,
        max_daily_trades: int = 50,
        daily_drawdown_halt_pct: float = 7.0,
        weekly_drawdown_halt_pct: float = 10.0,
        total_drawdown_halt_pct: float = 20.0,
        max_single_trade_loss: float = 500.0,
    ):
        self._max_position_pct = max_position_pct
        self._max_concurrent = max_concurrent
        self._max_daily_trades = max_daily_trades
        self._daily_halt = daily_drawdown_halt_pct
        self._weekly_halt = weekly_drawdown_halt_pct
        self._total_halt = total_drawdown_halt_pct
        self._max_loss = max_single_trade_loss

    def run(
        self, order: OrderRequest, portfolio: PortfolioState, is_halted: bool
    ) -> CheckResult:
        start = time.perf_counter()
        rejections: list[str] = []
        warnings: list[str] = []

        # CHECK 1: Kill switch
        if is_halted:
            rejections.append("System is HALTED. No orders permitted.")
            return CheckResult(
                approved=False,
                rejections=rejections,
                check_duration_ms=(time.perf_counter() - start) * 1000,
            )

        # Closing positions bypass most checks
        if order.is_closing:
            return CheckResult(
                approved=True,
                check_duration_ms=(time.perf_counter() - start) * 1000,
            )

        # CHECK 2: Drawdown halt
        if portfolio.daily_drawdown_pct >= self._daily_halt:
            rejections.append(
                f"Daily drawdown {portfolio.daily_drawdown_pct:.1f}% >= halt {self._daily_halt}%"
            )
        if portfolio.weekly_drawdown_pct >= self._weekly_halt:
            rejections.append(
                f"Weekly drawdown {portfolio.weekly_drawdown_pct:.1f}% >= halt {self._weekly_halt}%"
            )
        if portfolio.total_drawdown_pct >= self._total_halt:
            rejections.append(
                f"Total drawdown {portfolio.total_drawdown_pct:.1f}% >= halt {self._total_halt}%"
            )

        # CHECK 3: Position sizing
        order_value = order.quantity * order.estimated_price
        position_pct = (order_value / portfolio.nav) * 100 if portfolio.nav > 0 else 100
        if position_pct > self._max_position_pct:
            rejections.append(
                f"Position size {position_pct:.1f}% exceeds max {self._max_position_pct}%"
            )

        # CHECK 4: Concurrent positions
        if portfolio.position_count >= self._max_concurrent:
            rejections.append(
                f"At max concurrent positions ({self._max_concurrent})"
            )

        # CHECK 5: Daily trade count
        if portfolio.daily_trade_count >= self._max_daily_trades:
            rejections.append(f"Daily trade limit ({self._max_daily_trades}) reached")

        duration = (time.perf_counter() - start) * 1000
        return CheckResult(
            approved=len(rejections) == 0,
            rejections=rejections,
            warnings=warnings,
            check_duration_ms=duration,
        )
```

**Step 4: Run tests**

Run: `cd cortex-py && pytest tests/squadrons/echo/test_risk_checks.py -v`
Expected: 6 PASSED

**Step 5: Commit**

```bash
git add cortex-py/cortex/squadrons/echo/risk_checks.py cortex-py/tests/squadrons/echo/test_risk_checks.py
git commit -m "feat: implement pre-trade risk check engine with 5 check categories"
```

---

### Task 6: WebSocket Server with MessagePack Protocol

**Files:**
- Create: `cortex-py/cortex/api/__init__.py`
- Create: `cortex-py/cortex/api/protocol.py`
- Create: `cortex-py/cortex/api/ws_server.py`
- Modify: `cortex-py/cortex/main.py`
- Test: `cortex-py/tests/api/test_protocol.py`

**Step 1: Write failing tests for protocol**

```python
# cortex-py/tests/api/__init__.py
```

```python
# cortex-py/tests/api/test_protocol.py
import pytest
import msgpack
from cortex.api.protocol import CortexMessage, MessageType, encode_message, decode_message


def test_encode_decode_roundtrip():
    msg = CortexMessage(
        type=MessageType.PORTFOLIO_UPDATE,
        payload={"nav": 50000.0, "daily_pnl": 150.0},
    )
    encoded = encode_message(msg)
    assert isinstance(encoded, bytes)

    decoded = decode_message(encoded)
    assert decoded.type == MessageType.PORTFOLIO_UPDATE
    assert decoded.payload["nav"] == 50000.0


def test_kill_switch_command():
    msg = CortexMessage(
        type=MessageType.CMD_KILL_SWITCH,
        payload={"reason": "manual"},
    )
    encoded = encode_message(msg)
    decoded = decode_message(encoded)
    assert decoded.type == MessageType.CMD_KILL_SWITCH


def test_agent_update_message():
    msg = CortexMessage(
        type=MessageType.AGENT_UPDATE,
        payload={
            "agent_id": "signal_hunter",
            "status": "active",
            "signal_count": 42,
        },
    )
    encoded = encode_message(msg)
    decoded = decode_message(encoded)
    assert decoded.payload["agent_id"] == "signal_hunter"
```

**Step 2: Run to verify failure**

Run: `cd cortex-py && pytest tests/api/test_protocol.py -v`
Expected: FAIL

**Step 3: Implement protocol**

```python
# cortex-py/cortex/api/protocol.py
"""MessagePack-based WebSocket protocol for Swift <-> Python communication."""

from dataclasses import dataclass
from enum import IntEnum
import msgpack
import time


class MessageType(IntEnum):
    # Server -> Client (streaming)
    PORTFOLIO_UPDATE = 1
    AGENT_UPDATE = 2
    SIGNAL_FIRED = 3
    SCANNER_RESULT = 4
    ACTIVITY_EVENT = 5
    OPPORTUNITY = 6
    CHAT_TOKEN = 7
    KILL_SWITCH_STATUS = 8

    # Client -> Server (commands)
    CMD_KILL_SWITCH = 100
    CMD_DISENGAGE_KILL = 101
    CMD_SET_AUTONOMY = 102
    CMD_TOGGLE_AGENT = 103
    CMD_QUICK_TRADE = 104
    CMD_CHAT_MESSAGE = 105
    CMD_SUBSCRIBE_SCANNER = 106


@dataclass
class CortexMessage:
    type: MessageType
    payload: dict
    timestamp: float | None = None

    def __post_init__(self):
        if self.timestamp is None:
            self.timestamp = time.time()


def encode_message(msg: CortexMessage) -> bytes:
    return msgpack.packb({
        "t": int(msg.type),
        "p": msg.payload,
        "ts": msg.timestamp,
    }, use_bin_type=True)


def decode_message(data: bytes) -> CortexMessage:
    raw = msgpack.unpackb(data, raw=False)
    return CortexMessage(
        type=MessageType(raw["t"]),
        payload=raw["p"],
        timestamp=raw["ts"],
    )
```

**Step 4: Run tests**

Run: `cd cortex-py && pytest tests/api/test_protocol.py -v`
Expected: 3 PASSED

**Step 5: Commit**

```bash
git add cortex-py/cortex/api/ cortex-py/tests/api/
git commit -m "feat: implement MessagePack WebSocket protocol for Swift communication"
```

---

### Task 7: Initialize Rust Scanner Project

**Files:**
- Create: `cortex-rs/Cargo.toml`
- Create: `cortex-rs/src/lib.rs`
- Create: `cortex-rs/src/scanner.rs`
- Test: inline Rust tests

**Step 1: Create Cargo.toml**

```toml
# cortex-rs/Cargo.toml
[package]
name = "cortex-scanner"
version = "0.1.0"
edition = "2021"

[lib]
name = "cortex_scanner"
crate-type = ["cdylib"]

[dependencies]
pyo3 = { version = "0.22", features = ["extension-module"] }
rayon = "1.10"
serde = { version = "1.0", features = ["derive"] }
serde_json = "1.0"

[profile.release]
opt-level = 3
lto = "fat"
codegen-units = 1
```

**Step 2: Implement scanner with PyO3 bindings**

```rust
// cortex-rs/src/lib.rs
use pyo3::prelude::*;

mod scanner;

#[pymodule]
fn cortex_scanner(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(scanner::scan_symbols, m)?)?;
    m.add_class::<scanner::ScanResult>()?;
    Ok(())
}
```

```rust
// cortex-rs/src/scanner.rs
use pyo3::prelude::*;
use rayon::prelude::*;
use std::panic;

#[pyclass]
#[derive(Clone)]
pub struct ScanResult {
    #[pyo3(get)]
    pub symbol: String,
    #[pyo3(get)]
    pub composite_score: f64,
    #[pyo3(get)]
    pub momentum_score: f64,
    #[pyo3(get)]
    pub volume_score: f64,
}

#[pyfunction]
pub fn scan_symbols(
    _py: Python,
    symbols: Vec<String>,
    prices: Vec<f64>,
    volumes: Vec<f64>,
    avg_volumes: Vec<f64>,
) -> PyResult<Vec<ScanResult>> {
    // Catch any Rust panics at FFI boundary
    let result = panic::catch_unwind(|| {
        symbols
            .par_iter()
            .enumerate()
            .map(|(i, symbol)| {
                let vol_ratio = if avg_volumes[i] > 0.0 {
                    volumes[i] / avg_volumes[i]
                } else {
                    0.0
                };
                let volume_score = (vol_ratio - 1.0).max(0.0).min(1.0);
                let momentum_score = 0.5; // Placeholder — needs price history

                ScanResult {
                    symbol: symbol.clone(),
                    composite_score: (volume_score * 0.4 + momentum_score * 0.6) * 100.0,
                    momentum_score: momentum_score * 100.0,
                    volume_score: volume_score * 100.0,
                }
            })
            .collect::<Vec<_>>()
    });

    match result {
        Ok(results) => Ok(results),
        Err(_) => Err(PyErr::new::<pyo3::exceptions::PyRuntimeError, _>(
            "Scanner panic caught at FFI boundary",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scan_basic() {
        let symbols = vec!["AAPL".to_string(), "MSFT".to_string()];
        let prices = vec![150.0, 400.0];
        let volumes = vec![2_000_000.0, 500_000.0];
        let avg_volumes = vec![1_000_000.0, 1_000_000.0];

        Python::with_gil(|py| {
            let results = scan_symbols(py, symbols, prices, volumes, avg_volumes).unwrap();
            assert_eq!(results.len(), 2);
            assert!(results[0].volume_score > results[1].volume_score); // AAPL has 2x volume
        });
    }
}
```

**Step 3: Build and test**

Run: `cd cortex-rs && cargo test`
Expected: test passes

**Step 4: Build Python extension**

Run: `cd cortex-rs && pip install maturin && maturin develop`
Expected: Builds .so and installs in Python environment

**Step 5: Commit**

```bash
git add cortex-rs/
git commit -m "feat: implement Rust scanner engine with PyO3 FFI bindings"
```

---

### Task 8: Initialize Swift macOS App

**Files:**
- Create: `cortex-app/CORTEX.xcodeproj` (via Xcode CLI or manual)
- Create: `cortex-app/CORTEX/App/CORTEXApp.swift`
- Create: `cortex-app/CORTEX/App/AppEnvironment.swift`
- Create: `cortex-app/CORTEX/Core/Transport/WebSocketClient.swift`
- Create: `cortex-app/CORTEX/Core/Transport/MessagePackCoder.swift`
- Create: `cortex-app/CORTEX/Core/Stores/PortfolioStore.swift`
- Create: `cortex-app/CORTEX/Core/Stores/SquadronStore.swift`
- Create: `cortex-app/CORTEX/Core/Stores/KillSwitchStore.swift`
- Create: `cortex-app/CORTEX/Features/WarRoom/WarRoomView.swift`

**Note:** This task creates the Xcode project using `swift package init` for the core module and a manual Xcode project for the app. Due to the complexity of Xcode project creation via CLI, use `xcodebuild` or create manually.

**Step 1: Create Swift Package for core logic**

```swift
// cortex-app/Package.swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "CortexApp",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CortexCore", targets: ["CortexCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/flight-school/MessagePack.git", from: "1.2.0"),
        .package(url: "https://github.com/kishikawakatsumi/KeychainAccess.git", from: "4.2.2"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
    ],
    targets: [
        .target(
            name: "CortexCore",
            dependencies: [
                "MessagePack",
                "KeychainAccess",
                .product(name: "Logging", package: "swift-log"),
            ]
        ),
        .testTarget(
            name: "CortexCoreTests",
            dependencies: ["CortexCore"]
        ),
    ]
)
```

**Step 2: Create AppEnvironment**

```swift
// cortex-app/Sources/CortexCore/AppEnvironment.swift
import Foundation

@MainActor
@Observable
public final class AppEnvironment {
    public let portfolio = PortfolioStore()
    public let squadrons = SquadronStore()
    public let killSwitch = KillSwitchStore()
    public let websocket: WebSocketClient

    public init() {
        self.websocket = WebSocketClient(
            url: URL(string: "ws://127.0.0.1:8765/ws")!
        )
    }
}
```

**Step 3: Create PortfolioStore**

```swift
// cortex-app/Sources/CortexCore/Stores/PortfolioStore.swift
import Foundation

@MainActor
@Observable
public final class PortfolioStore {
    public var totalPnL: Double = 0.0
    public var dailyPnL: Double = 0.0
    public var winRate: Double = 0.0
    public var sharpeRatio: Double = 0.0
    public var buyingPower: Double = 0.0
    public var openPositionCount: Int = 0
    public var nav: Double = 0.0

    public init() {}

    public func apply(_ update: [String: Any]) {
        if let nav = update["nav"] as? Double { self.nav = nav }
        if let pnl = update["total_pnl"] as? Double { self.totalPnL = pnl }
        if let daily = update["daily_pnl"] as? Double { self.dailyPnL = daily }
        if let wr = update["win_rate"] as? Double { self.winRate = wr }
        if let sr = update["sharpe_ratio"] as? Double { self.sharpeRatio = sr }
        if let bp = update["buying_power"] as? Double { self.buyingPower = bp }
        if let pos = update["position_count"] as? Int { self.openPositionCount = pos }
    }
}
```

**Step 4: Create KillSwitchStore**

```swift
// cortex-app/Sources/CortexCore/Stores/KillSwitchStore.swift
import Foundation

@MainActor
@Observable
public final class KillSwitchStore {
    public var isActive: Bool = false
    public var isEngaging: Bool = false
    public var engagedAt: Date? = nil
    public var reason: String? = nil

    private var sendCommand: ((Data) -> Void)?

    public init() {}

    public func configure(sendCommand: @escaping (Data) -> Void) {
        self.sendCommand = sendCommand
    }

    public func engage() {
        isEngaging = true
        // Send kill switch command to backend
        // The backend will confirm via WebSocket, which sets isActive
        let payload: [String: Any] = ["t": 100, "p": ["reason": "manual"], "ts": Date().timeIntervalSince1970]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            sendCommand?(data)
        }
    }

    public func confirmEngaged(reason: String) {
        isEngaging = false
        isActive = true
        engagedAt = Date()
        self.reason = reason
    }

    public func disengage() {
        isActive = false
        isEngaging = false
        engagedAt = nil
        reason = nil
    }
}
```

**Step 5: Commit**

```bash
git add cortex-app/
git commit -m "feat: initialize Swift macOS app with core stores and WebSocket transport"
```

---

### Task 9: Database Schema Setup Scripts

**Files:**
- Create: `cortex-py/scripts/setup_databases.sh`
- Create: `cortex-py/cortex/storage/postgres_schema.sql`
- Create: `cortex-py/cortex/storage/questdb_schema.sql`

**Step 1: Create PostgreSQL schema**

```sql
-- cortex-py/cortex/storage/postgres_schema.sql

CREATE TABLE IF NOT EXISTS orders (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    agent_id        TEXT NOT NULL,
    broker          TEXT NOT NULL CHECK (broker IN ('ibkr', 'coinbase')),
    symbol          TEXT NOT NULL,
    order_type      TEXT NOT NULL CHECK (order_type IN ('market','limit','stop','stop_limit')),
    side            TEXT NOT NULL CHECK (side IN ('buy','sell')),
    quantity        NUMERIC(18, 8) NOT NULL,
    limit_price     NUMERIC(18, 8),
    stop_price      NUMERIC(18, 8),
    broker_order_id TEXT UNIQUE,
    status          TEXT NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','submitted','partial','filled','cancelled','rejected')),
    submitted_at    TIMESTAMPTZ,
    filled_at       TIMESTAMPTZ,
    fill_price      NUMERIC(18, 8),
    fill_quantity   NUMERIC(18, 8),
    commission      NUMERIC(18, 8)
);

CREATE TABLE IF NOT EXISTS trades (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    open_order_id   UUID REFERENCES orders(id),
    close_order_id  UUID REFERENCES orders(id),
    symbol          TEXT NOT NULL,
    quantity        NUMERIC(18, 8) NOT NULL,
    open_price      NUMERIC(18, 8) NOT NULL,
    close_price     NUMERIC(18, 8) NOT NULL,
    open_at         TIMESTAMPTZ NOT NULL,
    close_at        TIMESTAMPTZ NOT NULL,
    realized_pnl    NUMERIC(18, 8) NOT NULL,
    commissions     NUMERIC(18, 8) NOT NULL DEFAULT 0,
    net_pnl         NUMERIC(18, 8) GENERATED ALWAYS AS (realized_pnl - commissions) STORED,
    agent_id        TEXT NOT NULL,
    strategy_tag    TEXT
);

CREATE TABLE IF NOT EXISTS audit_trail (
    id              BIGSERIAL PRIMARY KEY,
    event_id        UUID NOT NULL UNIQUE,
    ts              TIMESTAMPTZ NOT NULL DEFAULT now(),
    event_type      TEXT NOT NULL,
    source_agent    TEXT NOT NULL,
    source_squadron TEXT NOT NULL,
    triggered_by_event_id UUID,
    signal_payload  JSONB,
    trade_id        UUID
);

CREATE TABLE IF NOT EXISTS tax_lots (
    lot_id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    symbol          TEXT NOT NULL,
    asset_class     TEXT NOT NULL,
    exchange        TEXT NOT NULL,
    quantity        NUMERIC(18, 8) NOT NULL,
    remaining_qty   NUMERIC(18, 8) NOT NULL,
    cost_basis_per_unit NUMERIC(18, 8) NOT NULL,
    acquisition_date TIMESTAMPTZ NOT NULL,
    status          TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open', 'closed', 'partial')),
    wash_sale_adj   NUMERIC(18, 8) DEFAULT 0,
    agent_id        TEXT
);

-- Indexes
CREATE INDEX IF NOT EXISTS idx_orders_symbol ON orders (symbol, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_orders_agent ON orders (agent_id, status);
CREATE INDEX IF NOT EXISTS idx_trades_agent ON trades (agent_id, close_at DESC);
CREATE INDEX IF NOT EXISTS idx_audit_ts ON audit_trail (ts DESC);
CREATE INDEX IF NOT EXISTS idx_audit_type ON audit_trail (event_type, ts DESC);
CREATE INDEX IF NOT EXISTS idx_tax_lots_symbol ON tax_lots (symbol, status);
```

**Step 2: Create QuestDB schema**

```sql
-- cortex-py/cortex/storage/questdb_schema.sql

CREATE TABLE IF NOT EXISTS quotes (
    ts          TIMESTAMP,
    symbol      SYMBOL CAPACITY 10000 CACHE,
    bid         DOUBLE,
    ask         DOUBLE,
    bid_size    INT,
    ask_size    INT,
    source      SYMBOL CAPACITY 10 CACHE
) TIMESTAMP(ts) PARTITION BY DAY WAL;

CREATE TABLE IF NOT EXISTS ohlcv (
    ts          TIMESTAMP,
    symbol      SYMBOL CAPACITY 10000 CACHE,
    open        DOUBLE,
    high        DOUBLE,
    low         DOUBLE,
    close       DOUBLE,
    volume      LONG,
    vwap        DOUBLE,
    timeframe   SYMBOL CAPACITY 10 CACHE
) TIMESTAMP(ts) PARTITION BY MONTH WAL;

CREATE TABLE IF NOT EXISTS options_chain (
    ts          TIMESTAMP,
    symbol      SYMBOL CAPACITY 10000 CACHE,
    expiry      TIMESTAMP,
    strike      DOUBLE,
    option_type SYMBOL CAPACITY 2 CACHE,
    bid         DOUBLE,
    ask         DOUBLE,
    iv          DOUBLE,
    delta       DOUBLE,
    gamma       DOUBLE,
    theta       DOUBLE,
    vega        DOUBLE,
    open_interest LONG,
    volume      LONG
) TIMESTAMP(ts) PARTITION BY MONTH WAL;
```

**Step 3: Create setup script**

```bash
#!/bin/bash
# cortex-py/scripts/setup_databases.sh
set -e

echo "=== CORTEX Database Setup ==="

# PostgreSQL
echo "[1/3] Setting up PostgreSQL..."
createdb cortex 2>/dev/null || echo "Database 'cortex' already exists"
psql -d cortex -f cortex/storage/postgres_schema.sql
echo "PostgreSQL: OK"

# QuestDB (assumes QuestDB running on port 9000)
echo "[2/3] Setting up QuestDB..."
while IFS= read -r line; do
    if [ -n "$line" ] && [[ ! "$line" =~ ^-- ]]; then
        curl -s -G "http://localhost:9000/exec" --data-urlencode "query=$line" > /dev/null
    fi
done < cortex/storage/questdb_schema.sql
echo "QuestDB: OK"

# Redis (just verify connection)
echo "[3/3] Verifying Redis..."
redis-cli ping | grep -q PONG && echo "Redis: OK" || echo "Redis: FAILED - is redis-server running?"

echo "=== Setup Complete ==="
```

**Step 4: Commit**

```bash
chmod +x cortex-py/scripts/setup_databases.sh
git add cortex-py/scripts/ cortex-py/cortex/storage/
git commit -m "feat: add database schemas for PostgreSQL, QuestDB, and setup script"
```

---

### Task 10: IBKR Connection Manager

**Files:**
- Create: `cortex-py/cortex/connectors/ibkr/__init__.py`
- Create: `cortex-py/cortex/connectors/ibkr/client.py`
- Test: `cortex-py/tests/connectors/test_ibkr_client.py`

**Step 1: Write failing test (unit test with mock)**

```python
# cortex-py/tests/connectors/__init__.py
```

```python
# cortex-py/tests/connectors/test_ibkr_client.py
import pytest
from unittest.mock import AsyncMock, MagicMock
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
```

**Step 2: Run to verify failure**

Run: `cd cortex-py && pytest tests/connectors/test_ibkr_client.py -v`
Expected: FAIL

**Step 3: Implement IBKR connection manager**

```python
# cortex-py/cortex/connectors/ibkr/client.py
"""IBKR Connection Manager — handles TWS API connection lifecycle.
Uses ib_async for async compatibility. Reconnects automatically.
Position reconciliation on every reconnect."""

from dataclasses import dataclass
import structlog

log = structlog.get_logger()


@dataclass
class IBKRConfig:
    host: str = "127.0.0.1"
    port: int = 4001  # IB Gateway paper: 4002, live: 4001
    client_id: int = 1
    max_reconnect_attempts: int = 10
    reconnect_delay_seconds: float = 5.0
    paper_trading: bool = True


class IBKRConnectionManager:
    def __init__(self, config: IBKRConfig):
        self._config = config
        self._connected = False
        self._reconnect_count = 0
        self._ib = None  # Will be ib_async.IB instance

    @property
    def is_connected(self) -> bool:
        return self._connected

    @property
    def reconnect_count(self) -> int:
        return self._reconnect_count

    async def connect(self) -> bool:
        try:
            from ib_async import IB
            self._ib = IB()
            await self._ib.connectAsync(
                host=self._config.host,
                port=self._config.port,
                clientId=self._config.client_id,
            )
            self._connected = True
            log.info("ibkr.connected", port=self._config.port, client_id=self._config.client_id)
            return True
        except Exception as e:
            log.error("ibkr.connect_failed", error=str(e))
            self._connected = False
            return False

    async def disconnect(self) -> None:
        if self._ib:
            self._ib.disconnect()
            self._connected = False
            log.info("ibkr.disconnected")

    async def reconnect(self) -> bool:
        self._reconnect_count += 1
        log.warning("ibkr.reconnecting", attempt=self._reconnect_count)
        await self.disconnect()
        success = await self.connect()
        if success:
            await self._reconcile_positions()
        return success

    async def _reconcile_positions(self) -> None:
        """Fetch true positions from IBKR and reconcile with local state.
        Called on every reconnect to prevent phantom positions."""
        if not self._ib:
            return
        try:
            positions = self._ib.positions()
            log.info("ibkr.positions_reconciled", count=len(positions))
        except Exception as e:
            log.error("ibkr.reconcile_failed", error=str(e))
```

**Step 4: Run tests**

Run: `cd cortex-py && pytest tests/connectors/test_ibkr_client.py -v`
Expected: 3 PASSED

**Step 5: Commit**

```bash
git add cortex-py/cortex/connectors/ cortex-py/tests/connectors/
git commit -m "feat: implement IBKR connection manager with reconnect and position reconciliation"
```

---

## Phase 2-4: Summary (detailed tasks created as Phase 1 completes)

### Phase 2: First Squadrons (Week 2)
- Task 11: ECHO Risk Guardian (aggregates all pre-trade checks)
- Task 12: ECHO Position Sizer (Kelly/fixed-fractional)
- Task 13: ECHO Drawdown Shield (throttle/halt/kill algorithm)
- Task 14: ALPHA Signal Hunter (RSI + MACD + volume)
- Task 15: ALPHA Volume Profiler (relative volume)
- Task 16: ALPHA Gap Scanner (pre-market gaps)
- Task 17: Polygon.io WebSocket connector
- Task 18: Wire ALPHA -> SignalBus -> TradePipeline -> ECHO -> paper trading
- Task 19: Swift War Room: real-time P&L, agent grid, signal feed
- Task 20: End-to-end audit trail

### Phase 3: Execution + Options (Week 3)
- Task 21: BRAVO Order Sniper (market + limit via IBKR)
- Task 22: BRAVO Spread Optimizer
- Task 23: CHARLIE Greeks Engine + IV Surface Mapper
- Task 24: CHARLIE Options Flow Intelligence (Unusual Whales feed)
- Task 25: Rust scanner: composite scoring via PyO3
- Task 26: FOXTROT Wash Sale Guard
- Task 27: FOXTROT Harvest Bot (identification mode)
- Task 28: Live trading with $500/trade cap

### Phase 4: Intelligence + Autonomy (Week 4)
- Task 29: Claude Intelligence Engine (5-minute strategic cycle)
- Task 30: DELTA News Interceptor (Benzinga WebSocket)
- Task 31: DELTA Earnings Oracle
- Task 32: DELTA EDGAR Sentinel (SEC RSS feed)
- Task 33: Autonomy dial (Full/Semi/Signal per squadron)
- Task 34: FOXTROT Gain Timer
- Task 35: Coinbase connector + Crypto Arb Bot
- Task 36: Swift AI Chat view with Claude streaming
- Task 37: Swift Quick Trade panel (⌘T)
- Task 38: Swift Menu Bar widget
- Task 39: Performance dashboard (win rates, slippage, P&L by squadron)
- Task 40: Full integration test suite

---

## CLAUDE.md (to be created at project root)

```markdown
# CORTEX Architecture Rules

## Enforced Patterns
1. ALL secrets in ~/.cortex/secrets.toml or environment variables. Never hardcode keys.
2. ALL inter-squadron communication via SignalBus. Agents NEVER import from other squadrons.
3. ALL Python async code uses asyncio + uvloop.
4. ALL IBKR API calls go through rate_limiter.py wrappers.
5. ALL agents inherit BaseAgent and implement handle_signal().
6. ALL orders go through TradePipeline -> PreTradeCheck. No bypassing.
7. Claude NEVER in execution hot path. Strategic cycle only.
8. Kill switch Phase 1 is synchronous in-memory. No network dependency.
9. Position reconciliation on every IBKR reconnect.

## Package Decisions (do not change)
- HTTP: httpx | IBKR: ib_async | Coinbase: coinbase-advanced-py
- Redis: redis[hiredis] | Postgres: asyncpg | JSON: orjson
- Validation: pydantic v2 | Config: pydantic-settings
- Rate limiting: aiolimiter | Logging: structlog
```
