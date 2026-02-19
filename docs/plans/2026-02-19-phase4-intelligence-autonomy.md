# Phase 4: Intelligence + Autonomy Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add Claude strategic intelligence, DELTA intelligence squadron, configurable autonomy dial, crypto connector, Swift WebSocket client, and full system orchestrator to complete the CORTEX trading platform.

**Architecture:** Claude API powers a strategic cycle that runs every 5 minutes, analyzing portfolio state and market conditions to issue strategy updates via SignalBus. The autonomy dial gates which signals require human approval vs. auto-execute. A system orchestrator manages agent lifecycle, health monitoring, and graceful shutdown. The Swift app connects via MessagePack WebSocket for real-time state streaming.

**Tech Stack:** Python 3.12+/asyncio, anthropic SDK (Claude API), httpx (HTTP feeds), coinbase-advanced-py (crypto), Swift 5.9+/SwiftUI/@Observable, MessagePack binary protocol

---

## Task 29: Claude Intelligence Engine

**Files:**
- Create: `cortex-py/cortex/intelligence/claude_engine.py`
- Create: `cortex-py/cortex/intelligence/prompts.py`
- Test: `cortex-py/tests/intelligence/test_claude_engine.py`
- Test: `cortex-py/tests/intelligence/__init__.py`

**Step 1: Write the failing tests**

```python
# tests/intelligence/__init__.py
# empty

# tests/intelligence/test_claude_engine.py
import pytest
from unittest.mock import AsyncMock, patch, MagicMock
from cortex.intelligence.claude_engine import ClaudeEngine, StrategyDecision
from cortex.intelligence.prompts import build_strategic_prompt, build_risk_assessment_prompt
from cortex.orchestrator.bus import SignalBus


def test_strategy_decision_dataclass():
    d = StrategyDecision(
        market_regime="bullish",
        sector_focus=["tech", "energy"],
        risk_appetite=0.7,
        signals_to_amplify=["alpha.entry_signal"],
        signals_to_suppress=["alpha.gap_detected"],
        reasoning="Tech momentum strong, energy breakout",
    )
    assert d.market_regime == "bullish"
    assert d.risk_appetite == 0.7
    assert len(d.sector_focus) == 2


def test_build_strategic_prompt():
    prompt = build_strategic_prompt(
        nav=100000,
        daily_pnl=500,
        positions=[{"symbol": "AAPL", "pnl": 200}],
        recent_signals=["alpha.entry_signal: MSFT"],
        drawdown_pct=2.0,
        win_rate=0.62,
    )
    assert "100000" in prompt or "100,000" in prompt
    assert "AAPL" in prompt
    assert isinstance(prompt, str)
    assert len(prompt) > 100


def test_build_risk_assessment_prompt():
    prompt = build_risk_assessment_prompt(
        symbol="TSLA",
        entry_price=200.0,
        position_size=10,
        portfolio_nav=100000,
        current_drawdown=3.0,
    )
    assert "TSLA" in prompt
    assert "200" in prompt


@pytest.mark.asyncio
async def test_engine_strategic_cycle_emits_signal():
    bus = SignalBus()
    engine = ClaudeEngine(bus=bus, api_key="test-key")

    mock_response = MagicMock()
    mock_response.content = [MagicMock(text='{"market_regime":"neutral","sector_focus":["tech"],"risk_appetite":0.5,"signals_to_amplify":[],"signals_to_suppress":[],"reasoning":"Sideways market"}')]

    emitted = []
    bus.subscribe("intelligence.strategy_update", lambda s: emitted.append(s))

    import asyncio
    task = asyncio.create_task(bus.run())

    with patch.object(engine, "_call_claude", new_callable=AsyncMock, return_value=mock_response):
        decision = await engine.run_strategic_cycle(
            nav=100000, daily_pnl=0, positions=[], recent_signals=[], drawdown_pct=0, win_rate=0.5
        )

    await asyncio.sleep(0.05)
    task.cancel()

    assert decision.market_regime == "neutral"
    assert len(emitted) == 1


@pytest.mark.asyncio
async def test_engine_handles_api_error_gracefully():
    bus = SignalBus()
    engine = ClaudeEngine(bus=bus, api_key="test-key")

    with patch.object(engine, "_call_claude", new_callable=AsyncMock, side_effect=Exception("API down")):
        decision = await engine.run_strategic_cycle(
            nav=100000, daily_pnl=0, positions=[], recent_signals=[], drawdown_pct=0, win_rate=0.5
        )

    assert decision is None


def test_engine_respects_cycle_interval():
    bus = SignalBus()
    engine = ClaudeEngine(bus=bus, api_key="test-key", cycle_seconds=300)
    assert engine.cycle_seconds == 300


def test_strategy_decision_to_dict():
    d = StrategyDecision(
        market_regime="bearish",
        sector_focus=[],
        risk_appetite=0.3,
        signals_to_amplify=[],
        signals_to_suppress=[],
        reasoning="Risk off",
    )
    result = d.to_dict()
    assert result["market_regime"] == "bearish"
    assert result["risk_appetite"] == 0.3
```

**Step 2: Run tests to verify they fail**

```bash
cd /Users/mackensonjeanlouis/Desktop/cortex/.worktrees/phase1/cortex-py
source .venv/bin/activate
python -m pytest tests/intelligence/test_claude_engine.py -v
```
Expected: FAIL with ImportError

**Step 3: Write the prompts module**

```python
# cortex/intelligence/prompts.py
"""Prompt templates for Claude strategic intelligence cycle."""


def build_strategic_prompt(
    nav: float,
    daily_pnl: float,
    positions: list[dict],
    recent_signals: list[str],
    drawdown_pct: float,
    win_rate: float,
) -> str:
    positions_text = "\n".join(
        f"  - {p.get('symbol', '?')}: P&L ${p.get('pnl', 0):.2f}"
        for p in positions
    ) or "  (no open positions)"

    signals_text = "\n".join(f"  - {s}" for s in recent_signals[-20:]) or "  (none)"

    return f"""You are the strategic intelligence core of CORTEX, an autonomous trading system.
Analyze the current portfolio state and market conditions, then output a JSON strategy decision.

## Current Portfolio State
- NAV: ${nav:,.2f}
- Daily P&L: ${daily_pnl:,.2f}
- Current Drawdown: {drawdown_pct:.1f}%
- Win Rate: {win_rate:.1%}
- Open Positions:
{positions_text}

## Recent Signals (last 20)
{signals_text}

## Your Task
Output a JSON object with exactly these fields:
{{
  "market_regime": "bullish" | "bearish" | "neutral" | "volatile",
  "sector_focus": ["sector1", "sector2"],
  "risk_appetite": 0.0 to 1.0,
  "signals_to_amplify": ["signal.type.to.boost"],
  "signals_to_suppress": ["signal.type.to.ignore"],
  "reasoning": "1-2 sentence explanation"
}}

Respond ONLY with the JSON object, no markdown fences or explanation."""


def build_risk_assessment_prompt(
    symbol: str,
    entry_price: float,
    position_size: int,
    portfolio_nav: float,
    current_drawdown: float,
) -> str:
    notional = entry_price * position_size
    pct_of_nav = (notional / portfolio_nav * 100) if portfolio_nav > 0 else 0

    return f"""Assess the risk of this proposed trade:

- Symbol: {symbol}
- Entry Price: ${entry_price:.2f}
- Position Size: {position_size} shares
- Notional: ${notional:,.2f} ({pct_of_nav:.1f}% of NAV)
- Current Drawdown: {current_drawdown:.1f}%
- Portfolio NAV: ${portfolio_nav:,.2f}

Output JSON:
{{
  "approve": true | false,
  "confidence": 0.0 to 1.0,
  "reasoning": "explanation"
}}

Respond ONLY with the JSON object."""
```

**Step 4: Write the engine module**

```python
# cortex/intelligence/claude_engine.py
"""Claude Intelligence Engine — strategic AI cycle for CORTEX.

Runs every N seconds (default 300), analyzes portfolio state,
and emits strategy_update signals to guide agent behavior.

RULE: Claude is NEVER in the execution hot path. Strategic cycle only.
"""

import json
import time
from dataclasses import dataclass, field
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.intelligence.prompts import build_strategic_prompt

log = structlog.get_logger()


@dataclass
class StrategyDecision:
    market_regime: str
    sector_focus: list[str]
    risk_appetite: float
    signals_to_amplify: list[str]
    signals_to_suppress: list[str]
    reasoning: str
    timestamp: float = field(default_factory=time.time)

    def to_dict(self) -> dict:
        return {
            "market_regime": self.market_regime,
            "sector_focus": self.sector_focus,
            "risk_appetite": self.risk_appetite,
            "signals_to_amplify": self.signals_to_amplify,
            "signals_to_suppress": self.signals_to_suppress,
            "reasoning": self.reasoning,
            "timestamp": self.timestamp,
        }


class ClaudeEngine:
    """Strategic intelligence cycle using Claude API.
    NOT in the execution hot path — runs on a timer."""

    def __init__(
        self,
        bus: SignalBus,
        api_key: str,
        model: str = "claude-sonnet-4-6",
        cycle_seconds: int = 300,
        max_tokens: int = 1024,
    ):
        self._bus = bus
        self._api_key = api_key
        self._model = model
        self.cycle_seconds = cycle_seconds
        self._max_tokens = max_tokens
        self._last_decision: StrategyDecision | None = None
        self._cycle_count = 0
        self._error_count = 0
        self._client = None  # Lazy init

    async def _get_client(self):
        if self._client is None:
            try:
                import anthropic
                self._client = anthropic.AsyncAnthropic(api_key=self._api_key)
            except ImportError:
                log.warning("anthropic SDK not installed, using mock mode")
                self._client = None
        return self._client

    async def _call_claude(self, prompt: str):
        client = await self._get_client()
        if client is None:
            return None
        return await client.messages.create(
            model=self._model,
            max_tokens=self._max_tokens,
            messages=[{"role": "user", "content": prompt}],
        )

    async def run_strategic_cycle(
        self,
        nav: float,
        daily_pnl: float,
        positions: list[dict],
        recent_signals: list[str],
        drawdown_pct: float,
        win_rate: float,
    ) -> StrategyDecision | None:
        """Execute one strategic cycle. Returns decision or None on error."""
        self._cycle_count += 1

        prompt = build_strategic_prompt(
            nav=nav, daily_pnl=daily_pnl, positions=positions,
            recent_signals=recent_signals, drawdown_pct=drawdown_pct,
            win_rate=win_rate,
        )

        try:
            response = await self._call_claude(prompt)
            if response is None:
                return None

            text = response.content[0].text
            data = json.loads(text)

            decision = StrategyDecision(
                market_regime=data.get("market_regime", "neutral"),
                sector_focus=data.get("sector_focus", []),
                risk_appetite=float(data.get("risk_appetite", 0.5)),
                signals_to_amplify=data.get("signals_to_amplify", []),
                signals_to_suppress=data.get("signals_to_suppress", []),
                reasoning=data.get("reasoning", ""),
            )

            self._last_decision = decision

            await self._bus.publish(Signal(
                signal_id=f"claude_strategy_{self._cycle_count}",
                source_agent="claude_engine",
                source_squadron="intelligence",
                signal_type=SignalTypes.STRATEGY_UPDATE,
                payload=decision.to_dict(),
                priority=SignalPriority.LOW,
            ))

            log.info(
                "claude.strategy_update",
                regime=decision.market_regime,
                risk_appetite=decision.risk_appetite,
                cycle=self._cycle_count,
            )

            return decision

        except Exception as e:
            self._error_count += 1
            log.error("claude.cycle_error", error=str(e), cycle=self._cycle_count)
            return None

    @property
    def last_decision(self) -> StrategyDecision | None:
        return self._last_decision

    def to_dict(self) -> dict:
        return {
            "cycle_count": self._cycle_count,
            "error_count": self._error_count,
            "model": self._model,
            "cycle_seconds": self.cycle_seconds,
            "last_decision": self._last_decision.to_dict() if self._last_decision else None,
        }
```

**Step 5: Run tests to verify they pass**

```bash
python -m pytest tests/intelligence/test_claude_engine.py -v
```
Expected: All 8 PASS

**Step 6: Commit**

```bash
git add cortex-py/cortex/intelligence/ cortex-py/tests/intelligence/
git commit -m "feat: implement Claude Intelligence Engine with strategic cycle"
```

---

## Task 30: DELTA News Catalyst Agent

**Files:**
- Create: `cortex-py/cortex/squadrons/delta/news_catalyst.py`
- Create: `cortex-py/tests/squadrons/delta/__init__.py`
- Create: `cortex-py/tests/squadrons/delta/test_news_catalyst.py`

**Step 1: Write the failing tests**

```python
# tests/squadrons/delta/test_news_catalyst.py
import pytest
import time
from cortex.orchestrator.bus import SignalBus
from cortex.squadrons.delta.news_catalyst import (
    NewsCatalyst, NewsItem, SentimentScore, CatalystType,
)


def test_news_item_creation():
    item = NewsItem(
        headline="AAPL beats earnings expectations",
        source="benzinga",
        symbols=["AAPL"],
        published_at=time.time(),
        url="https://example.com/article",
    )
    assert item.symbols == ["AAPL"]


def test_sentiment_scoring_positive():
    agent = _make_agent()
    score = agent.score_sentiment(
        "Apple reports record revenue, beats analyst expectations by 15%"
    )
    assert score.score > 0
    assert score.label == "positive"


def test_sentiment_scoring_negative():
    agent = _make_agent()
    score = agent.score_sentiment(
        "Company announces massive layoffs, revenue misses expectations"
    )
    assert score.score < 0
    assert score.label == "negative"


def test_sentiment_scoring_neutral():
    agent = _make_agent()
    score = agent.score_sentiment("Trading volume was average today")
    assert score.label == "neutral"


def test_catalyst_detection_earnings():
    agent = _make_agent()
    item = NewsItem(
        headline="TSLA Q4 earnings beat: EPS $1.50 vs $1.20 expected",
        source="benzinga",
        symbols=["TSLA"],
        published_at=time.time(),
    )
    catalyst = agent.detect_catalyst(item)
    assert catalyst == CatalystType.EARNINGS


def test_catalyst_detection_fda():
    agent = _make_agent()
    item = NewsItem(
        headline="FDA approves new drug from Pfizer for cancer treatment",
        source="benzinga",
        symbols=["PFE"],
        published_at=time.time(),
    )
    catalyst = agent.detect_catalyst(item)
    assert catalyst == CatalystType.FDA


def test_catalyst_detection_merger():
    agent = _make_agent()
    item = NewsItem(
        headline="Microsoft announces acquisition of gaming company for $10B",
        source="benzinga",
        symbols=["MSFT"],
        published_at=time.time(),
    )
    catalyst = agent.detect_catalyst(item)
    assert catalyst == CatalystType.MERGER


def test_process_item_high_impact():
    agent = _make_agent()
    item = NewsItem(
        headline="NVDA smashes earnings, raises guidance 50%",
        source="benzinga",
        symbols=["NVDA"],
        published_at=time.time(),
    )
    result = agent.process_item(item)
    assert result is not None
    assert result["symbol"] == "NVDA"
    assert result["sentiment"] > 0


def test_process_item_low_impact_filtered():
    agent = _make_agent()
    item = NewsItem(
        headline="Market slightly up today",
        source="benzinga",
        symbols=[],
        published_at=time.time(),
    )
    result = agent.process_item(item)
    assert result is None


def test_recent_items_buffer():
    agent = _make_agent()
    for i in range(5):
        agent.process_item(NewsItem(
            headline=f"AAPL news {i} with strong earnings beat",
            source="test",
            symbols=["AAPL"],
            published_at=time.time(),
        ))
    recent = agent.get_recent(3)
    assert len(recent) <= 3


def test_to_dict():
    agent = _make_agent()
    d = agent.to_dict()
    assert d["agent_id"] == "news_catalyst"
    assert d["squadron"] == "delta"


def _make_agent():
    bus = SignalBus()
    return NewsCatalyst(bus=bus)
```

**Step 2: Run tests to verify they fail**

```bash
python -m pytest tests/squadrons/delta/test_news_catalyst.py -v
```

**Step 3: Implement the News Catalyst agent**

Create `cortex/squadrons/delta/news_catalyst.py` with:
- `CatalystType` enum: EARNINGS, FDA, MERGER, INSIDER, CONGRESS, MACRO, UNKNOWN
- `NewsItem` dataclass: headline, source, symbols, published_at, url (optional)
- `SentimentScore` dataclass: score (-1 to 1), label (positive/negative/neutral), confidence
- `NewsCatalyst(BaseAgent)`:
  - agent_id = "news_catalyst", squadron = "delta"
  - `score_sentiment(text)` — keyword-based scoring (positive words: beat, record, surge, approval, growth; negative: miss, layoff, decline, warning, loss)
  - `detect_catalyst(item)` — keyword matching for catalyst types
  - `process_item(item)` — score + classify + emit NEWS_CATALYST if high impact
  - `get_recent(count)` — buffered recent items
  - Buffer of recent NewsItems (deque, max 500)

**Step 4: Run tests**

```bash
python -m pytest tests/squadrons/delta/test_news_catalyst.py -v
```

**Step 5: Commit**

```bash
git add cortex-py/cortex/squadrons/delta/ cortex-py/tests/squadrons/delta/
git commit -m "feat: implement DELTA News Catalyst with sentiment scoring"
```

---

## Task 31: Autonomy Dial

**Files:**
- Create: `cortex-py/cortex/orchestrator/autonomy.py`
- Create: `cortex-py/tests/orchestrator/test_autonomy.py`

**Step 1: Write the failing tests**

```python
# tests/orchestrator/test_autonomy.py
import pytest
from cortex.orchestrator.autonomy import (
    AutonomyLevel, AutonomyDial, ActionGate,
)


def test_autonomy_levels():
    assert AutonomyLevel.FULL_MANUAL.value == 0
    assert AutonomyLevel.SUGGEST_ONLY.value == 1
    assert AutonomyLevel.SEMI_AUTO.value == 2
    assert AutonomyLevel.FULL_AUTO.value == 3


def test_default_level():
    dial = AutonomyDial()
    assert dial.level == AutonomyLevel.SUGGEST_ONLY


def test_set_level():
    dial = AutonomyDial()
    dial.set_level(AutonomyLevel.FULL_AUTO)
    assert dial.level == AutonomyLevel.FULL_AUTO


def test_gate_full_manual_blocks_all():
    dial = AutonomyDial(level=AutonomyLevel.FULL_MANUAL)
    gate = dial.check("alpha.entry_signal", notional=200.0)
    assert gate.allowed is False
    assert gate.requires_approval is True


def test_gate_suggest_only_requires_approval():
    dial = AutonomyDial(level=AutonomyLevel.SUGGEST_ONLY)
    gate = dial.check("alpha.entry_signal", notional=200.0)
    assert gate.allowed is True
    assert gate.requires_approval is True


def test_gate_semi_auto_small_trade():
    dial = AutonomyDial(level=AutonomyLevel.SEMI_AUTO, auto_threshold=300.0)
    gate = dial.check("alpha.entry_signal", notional=200.0)
    assert gate.allowed is True
    assert gate.requires_approval is False


def test_gate_semi_auto_large_trade():
    dial = AutonomyDial(level=AutonomyLevel.SEMI_AUTO, auto_threshold=300.0)
    gate = dial.check("alpha.entry_signal", notional=400.0)
    assert gate.allowed is True
    assert gate.requires_approval is True


def test_gate_full_auto_allows_all():
    dial = AutonomyDial(level=AutonomyLevel.FULL_AUTO)
    gate = dial.check("alpha.entry_signal", notional=500.0)
    assert gate.allowed is True
    assert gate.requires_approval is False


def test_kill_switch_always_allowed():
    dial = AutonomyDial(level=AutonomyLevel.FULL_MANUAL)
    gate = dial.check("echo.kill_switch", notional=0)
    assert gate.allowed is True
    assert gate.requires_approval is False


def test_risk_breach_always_allowed():
    dial = AutonomyDial(level=AutonomyLevel.FULL_MANUAL)
    gate = dial.check("echo.risk_breach", notional=0)
    assert gate.allowed is True
    assert gate.requires_approval is False


def test_to_dict():
    dial = AutonomyDial(level=AutonomyLevel.SEMI_AUTO, auto_threshold=250.0)
    d = dial.to_dict()
    assert d["level"] == "semi_auto"
    assert d["auto_threshold"] == 250.0


def test_history_tracking():
    dial = AutonomyDial(level=AutonomyLevel.FULL_AUTO)
    dial.check("alpha.entry_signal", notional=100.0)
    dial.check("alpha.entry_signal", notional=200.0)
    assert dial.checks_today == 2
    assert dial.auto_approved_today == 2
```

**Step 2: Run tests**

```bash
python -m pytest tests/orchestrator/test_autonomy.py -v
```

**Step 3: Implement the autonomy dial**

Create `cortex/orchestrator/autonomy.py` with:
- `AutonomyLevel` IntEnum: FULL_MANUAL=0, SUGGEST_ONLY=1, SEMI_AUTO=2, FULL_AUTO=3
- `ActionGate` dataclass: allowed, requires_approval, reason
- `AutonomyDial`:
  - `__init__(level, auto_threshold=250.0)`
  - `set_level(level)`, `check(signal_type, notional)` -> ActionGate
  - Safety overrides: kill_switch and risk_breach ALWAYS pass regardless of level
  - `checks_today`, `auto_approved_today` counters
  - `reset_daily()`, `to_dict()`

**Step 4: Run tests, commit**

```bash
python -m pytest tests/orchestrator/test_autonomy.py -v
git add cortex-py/cortex/orchestrator/autonomy.py cortex-py/tests/orchestrator/test_autonomy.py
git commit -m "feat: implement configurable autonomy dial with 4 levels"
```

---

## Task 32: Coinbase Crypto Connector

**Files:**
- Create: `cortex-py/cortex/connectors/coinbase/__init__.py`
- Create: `cortex-py/cortex/connectors/coinbase/client.py`
- Create: `cortex-py/tests/connectors/test_coinbase_client.py`

**Step 1: Write the failing tests**

```python
# tests/connectors/test_coinbase_client.py
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
```

**Step 2-5: Implement, test, commit**

Implement `CoinbaseClient` with:
- Sandbox mode (default True) for testing without real API
- `get_balances()`, `submit_order()`, `cancel_order()`
- $500 notional cap in sandbox/test mode
- Supported pairs list: BTC-USD, ETH-USD, SOL-USD, DOGE-USD, etc.
- `CryptoBalance` dataclass with `total` property
- `CryptoOrder` dataclass with validation

```bash
python -m pytest tests/connectors/test_coinbase_client.py -v
git add cortex-py/cortex/connectors/coinbase/ cortex-py/tests/connectors/test_coinbase_client.py
git commit -m "feat: implement Coinbase crypto connector with sandbox mode"
```

---

## Task 33: Swift WebSocket Client

**Files:**
- Create: `cortex-app/Sources/CortexCore/Networking/WebSocketClient.swift`
- Create: `cortex-app/Sources/CortexCore/Networking/MessageDecoder.swift`
- Modify: `cortex-app/Sources/CortexCore/AppEnvironment.swift`
- Modify: `cortex-app/Package.swift` (add swift-msgpack dependency)
- Test: `cortex-app/Tests/CortexCoreTests/WebSocketTests.swift`

**Step 1: Write the failing tests**

```swift
// Tests/CortexCoreTests/WebSocketTests.swift
import Testing
@testable import CortexCore

@Test func testMessageDecoderPortfolio() async throws {
    let decoder = MessageDecoder()
    let payload: [String: Any] = ["nav": 100000.0, "daily_pnl": 500.0]
    let decoded = decoder.decodePortfolioUpdate(payload)
    #expect(decoded.nav == 100000.0)
    #expect(decoded.dailyPnL == 500.0)
}

@Test func testMessageDecoderAgentUpdate() async throws {
    let decoder = MessageDecoder()
    let payload: [String: Any] = [
        "agent_id": "signal_hunter",
        "squadron": "alpha",
        "status": "active",
        "signal_count": 42,
        "error_count": 0,
    ]
    let decoded = decoder.decodeAgentUpdate(payload)
    #expect(decoded["agent_id"] as? String == "signal_hunter")
}

@Test func testWebSocketClientDefaults() async throws {
    await MainActor.run {
        let client = WebSocketClient()
        #expect(client.isConnected == false)
        #expect(client.url == "ws://127.0.0.1:8765/ws")
    }
}

@Test func testWebSocketClientCustomURL() async throws {
    await MainActor.run {
        let client = WebSocketClient(url: "ws://localhost:9999/ws")
        #expect(client.url == "ws://localhost:9999/ws")
    }
}
```

**Step 2-5: Implement, test, commit**

Implement:
- `WebSocketClient`: @Observable, URLSessionWebSocketTask-based, auto-reconnect
- `MessageDecoder`: Decodes incoming MessagePack payloads to typed Swift structs
- Add `@Observable public var connectionState` to AppEnvironment
- NOTE: For MessagePack, use a simple manual decoder rather than adding a heavy dependency. The protocol uses simple dict payloads.

```bash
cd /Users/mackensonjeanlouis/Desktop/cortex/.worktrees/phase1/cortex-app
swift test
git add cortex-app/
git commit -m "feat: implement Swift WebSocket client with MessagePack decoder"
```

---

## Task 34: Swift Settings View

**Files:**
- Create: `cortex-app/Sources/CortexCore/Stores/SettingsStore.swift`
- Create: `cortex-app/Sources/CortexCore/Views/SettingsView.swift`
- Modify: `cortex-app/Sources/CortexCore/AppEnvironment.swift`
- Test: Add settings tests to `CortexCoreTests.swift`

**Step 1: Write tests, implement, commit**

`SettingsStore`: @Observable with server URL, autonomy level, theme, risk parameters.
`SettingsView`: SwiftUI form with sections for Connection, Autonomy, Risk Limits.

```bash
swift test
git add cortex-app/
git commit -m "feat: implement Swift Settings view with autonomy controls"
```

---

## Task 35: Swift Performance Dashboard

**Files:**
- Create: `cortex-app/Sources/CortexCore/Views/PerformanceDashboardView.swift`
- Create: `cortex-app/Sources/CortexCore/Stores/PerformanceStore.swift`
- Modify: `cortex-app/Sources/CortexCore/AppEnvironment.swift`

**Step 1: Write tests, implement, commit**

`PerformanceStore`: @Observable with equity curve data, daily P&L history, drawdown chart data, win/loss statistics.
`PerformanceDashboardView`: SwiftUI Charts with equity curve, daily bar chart, drawdown area chart, stats grid.

```bash
swift test
git add cortex-app/
git commit -m "feat: implement Swift Performance Dashboard with equity curve"
```

---

## Task 36: System Orchestrator

**Files:**
- Create: `cortex-py/cortex/orchestrator/system.py`
- Create: `cortex-py/tests/orchestrator/test_system.py`
- Modify: `cortex-py/cortex/main.py`

**Step 1: Write the failing tests**

```python
# tests/orchestrator/test_system.py
import pytest
import asyncio
from cortex.orchestrator.system import SystemOrchestrator, AgentHealth
from cortex.orchestrator.bus import SignalBus
from cortex.orchestrator.autonomy import AutonomyDial


def test_orchestrator_creation():
    bus = SignalBus()
    dial = AutonomyDial()
    orch = SystemOrchestrator(bus=bus, autonomy=dial)
    assert orch.agent_count == 0
    assert orch.is_running is False


def test_register_agent():
    bus = SignalBus()
    orch = SystemOrchestrator(bus=bus, autonomy=AutonomyDial())
    from cortex.squadrons.echo.kill_switch import KillSwitchCommander
    agent = KillSwitchCommander(bus=bus)
    orch.register_agent(agent)
    assert orch.agent_count == 1


def test_health_check():
    health = AgentHealth(
        agent_id="test", squadron="alpha",
        status="active", signal_count=10, error_count=0,
        last_signal_ts=1000.0,
    )
    assert health.is_healthy is True


def test_health_check_error_threshold():
    health = AgentHealth(
        agent_id="test", squadron="alpha",
        status="active", signal_count=10, error_count=8,
        last_signal_ts=1000.0,
    )
    assert health.is_healthy is False


def test_get_squadron_health():
    bus = SignalBus()
    orch = SystemOrchestrator(bus=bus, autonomy=AutonomyDial())
    from cortex.squadrons.alpha.signal_hunter import SignalHunter
    agent = SignalHunter(bus=bus)
    orch.register_agent(agent)
    health = orch.get_squadron_health("alpha")
    assert len(health) == 1


def test_to_dict():
    bus = SignalBus()
    orch = SystemOrchestrator(bus=bus, autonomy=AutonomyDial())
    d = orch.to_dict()
    assert "agent_count" in d
    assert "is_running" in d
    assert "autonomy" in d


@pytest.mark.asyncio
async def test_orchestrator_start_stop():
    bus = SignalBus()
    orch = SystemOrchestrator(bus=bus, autonomy=AutonomyDial())
    task = asyncio.create_task(orch.start())
    await asyncio.sleep(0.05)
    assert orch.is_running is True
    await orch.stop()
    task.cancel()
```

**Step 2-5: Implement, test, commit**

`SystemOrchestrator`:
- Registers all agents, starts SignalBus, manages lifecycle
- `register_agent(agent)`, `start()`, `stop()`
- Health monitoring: `get_agent_health()`, `get_squadron_health()`
- `AgentHealth` dataclass with `is_healthy` property (error_rate < 50%)
- Integration with AutonomyDial

```bash
python -m pytest tests/orchestrator/test_system.py -v
git add cortex-py/cortex/orchestrator/system.py cortex-py/tests/orchestrator/test_system.py
git commit -m "feat: implement System Orchestrator with agent lifecycle management"
```

---

## Task 37: WebSocket State Broadcasting

**Files:**
- Create: `cortex-py/cortex/api/ws_broadcaster.py`
- Create: `cortex-py/tests/api/test_ws_broadcaster.py`
- Modify: `cortex-py/cortex/main.py`

**Step 1: Write the failing tests**

```python
# tests/api/test_ws_broadcaster.py
import pytest
from cortex.api.ws_broadcaster import WSBroadcaster
from cortex.api.protocol import MessageType, CortexMessage, encode_message, decode_message
from cortex.orchestrator.bus import SignalBus


def test_broadcaster_creation():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    assert bc.client_count == 0


def test_build_portfolio_message():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    msg = bc.build_portfolio_message(
        nav=100000, daily_pnl=500, total_pnl=5000,
        win_rate=0.6, open_positions=3,
    )
    assert msg.type == MessageType.PORTFOLIO_UPDATE
    assert msg.payload["nav"] == 100000


def test_build_agent_message():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    msg = bc.build_agent_message(
        agent_id="signal_hunter", squadron="alpha",
        status="active", signal_count=42, error_count=0,
    )
    assert msg.type == MessageType.AGENT_UPDATE
    assert msg.payload["agent_id"] == "signal_hunter"


def test_build_signal_message():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    msg = bc.build_signal_message(
        signal_type="alpha.entry_signal",
        source_agent="signal_hunter",
        symbol="AAPL",
        payload={"confidence": 0.85},
    )
    assert msg.type == MessageType.SIGNAL_FIRED


def test_build_kill_switch_message():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    msg = bc.build_kill_switch_message(active=True, reason="manual")
    assert msg.type == MessageType.KILL_SWITCH_STATUS
    assert msg.payload["active"] is True


def test_encode_decode_roundtrip():
    bus = SignalBus()
    bc = WSBroadcaster(bus=bus)
    msg = bc.build_portfolio_message(
        nav=50000, daily_pnl=-200, total_pnl=1000,
        win_rate=0.55, open_positions=2,
    )
    encoded = encode_message(msg)
    decoded = decode_message(encoded)
    assert decoded.type == MessageType.PORTFOLIO_UPDATE
    assert decoded.payload["nav"] == 50000
```

**Step 2-5: Implement, test, commit**

`WSBroadcaster`:
- Subscribes to bus with `subscribe_all` to capture all signals
- `build_*_message()` methods for each MessageType
- `add_client(ws)`, `remove_client(ws)`, `broadcast(msg)` — fan out to all connected WebSockets
- Client tracking with `client_count` property

```bash
python -m pytest tests/api/test_ws_broadcaster.py -v
git add cortex-py/cortex/api/ws_broadcaster.py cortex-py/tests/api/test_ws_broadcaster.py
git commit -m "feat: implement WebSocket state broadcaster for Swift app"
```

---

## Task 38: Integration Tests — Cross-Squadron Signal Flow

**Files:**
- Create: `cortex-py/tests/integration/__init__.py`
- Create: `cortex-py/tests/integration/test_signal_flow.py`
- Create: `cortex-py/tests/integration/test_trade_lifecycle.py`

**Step 1: Write integration tests**

```python
# tests/integration/test_signal_flow.py
"""Integration tests: verify signal flow across squadrons."""
import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.alpha.signal_hunter import SignalHunter
from cortex.squadrons.echo.risk_guardian import RiskGuardian
from cortex.squadrons.echo.kill_switch import KillSwitchCommander
from cortex.squadrons.bravo.order_sniper import OrderSniper
from cortex.storage.audit import AuditTrail


@pytest.mark.asyncio
async def test_entry_signal_flows_through_pipeline():
    """ALPHA entry signal -> ECHO risk check -> BRAVO order execution."""
    bus = SignalBus()
    audit = AuditTrail()

    # Register agents
    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: False)
    guardian.register()

    sniper = OrderSniper(bus=bus, audit=audit, simulation=True, default_market_price=100.0)
    sniper.register()

    task = asyncio.create_task(bus.run())

    # Emit entry signal (simulating ALPHA)
    await bus.publish(Signal(
        signal_id="test_entry_001",
        source_agent="signal_hunter",
        source_squadron="alpha",
        signal_type=SignalTypes.ENTRY_SIGNAL,
        payload={"symbol": "AAPL", "entry_price": 150.0, "stop_loss": 145.0, "side": "buy"},
        priority=SignalPriority.NORMAL,
    ))

    await asyncio.sleep(0.1)
    task.cancel()

    # Verify the signal was processed
    assert guardian._signal_count >= 1


@pytest.mark.asyncio
async def test_kill_switch_halts_all_trading():
    """Kill switch should prevent any order execution."""
    bus = SignalBus()
    kill_switch = KillSwitchCommander(bus=bus)
    kill_switch.register()

    # Engage kill switch
    await kill_switch.engage("test halt")
    assert kill_switch.is_halted is True

    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: kill_switch.is_halted)

    # Try to process - should be blocked
    decision = guardian.evaluate(
        symbol="AAPL", asset_class="equity",
        entry_price=150.0, stop_loss_price=145.0, side="buy",
        nav=50000, position_count=0, daily_trade_count=0,
    )
    assert decision.approved is False
    assert any("kill" in r.lower() for r in decision.rejections)
```

```python
# tests/integration/test_trade_lifecycle.py
"""Integration tests: full trade lifecycle from signal to fill."""
import asyncio
import pytest
from cortex.orchestrator.bus import SignalBus
from cortex.orchestrator.trade_pipeline import TradePipeline, PipelineStage
from cortex.squadrons.echo.risk_guardian import RiskGuardian
from cortex.storage.audit import AuditTrail


@pytest.mark.asyncio
async def test_full_trade_lifecycle():
    """Signal -> Risk Check -> Size -> Submit -> Fill."""
    bus = SignalBus()
    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: False)
    pipeline = TradePipeline(bus=bus, risk_guardian=guardian)

    order = await pipeline.process_entry_signal(
        symbol="MSFT", asset_class="equity", side="buy",
        entry_price=400.0, stop_loss=395.0,
        source_signal_id="sig_lifecycle", source_agent="test",
        nav=50000.0,
    )

    assert order.stage == PipelineStage.SUBMITTED
    assert order.quantity > 0
    # $500 cap: at $400/share, max 1 share
    assert order.quantity == 1
    assert order.quantity * 400.0 <= 500.0

    pipeline.mark_filled(order.order_id, fill_price=400.05)
    assert order.stage == PipelineStage.FILLED


@pytest.mark.asyncio
async def test_drawdown_blocks_trade():
    """High drawdown should reject the trade."""
    bus = SignalBus()
    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: False)
    pipeline = TradePipeline(bus=bus, risk_guardian=guardian)

    order = await pipeline.process_entry_signal(
        symbol="AAPL", asset_class="equity", side="buy",
        entry_price=150.0, stop_loss=145.0,
        source_signal_id="sig_dd", source_agent="test",
        nav=50000.0,
        daily_drawdown_pct=8.0,
    )

    assert order.stage == PipelineStage.REJECTED


@pytest.mark.asyncio
async def test_expensive_stock_rejected():
    """Stock priced above $500 should be rejected by notional cap."""
    bus = SignalBus()
    guardian = RiskGuardian(bus=bus, kill_switch_check=lambda: False)
    pipeline = TradePipeline(bus=bus, risk_guardian=guardian)

    order = await pipeline.process_entry_signal(
        symbol="BRK.A", asset_class="equity", side="buy",
        entry_price=600.0, stop_loss=590.0,
        source_signal_id="sig_exp", source_agent="test",
        nav=100000.0,
    )

    assert order.stage == PipelineStage.REJECTED
```

**Step 2: Run integration tests**

```bash
python -m pytest tests/integration/ -v
```

**Step 3: Commit**

```bash
git add cortex-py/tests/integration/
git commit -m "feat: add cross-squadron integration tests"
```

---

## Task 39: Wire Up main.py with Full Orchestrator

**Files:**
- Modify: `cortex-py/cortex/main.py`
- Create: `cortex-py/tests/test_main_wiring.py`

**Step 1: Write tests**

```python
# tests/test_main_wiring.py
import pytest
from cortex.main import create_app_components


def test_create_components():
    components = create_app_components()
    assert "bus" in components
    assert "orchestrator" in components
    assert "autonomy" in components
    assert "pipeline" in components


def test_components_wired():
    components = create_app_components()
    orch = components["orchestrator"]
    assert orch.agent_count > 0
```

**Step 2: Update main.py**

Add `create_app_components()` factory that wires:
- SignalBus
- AutonomyDial
- RiskGuardian (with all ECHO agents)
- TradePipeline
- SystemOrchestrator
- All squadron agents registered
- WSBroadcaster
- ClaudeEngine (if API key present)

Update the lifespan to start/stop the orchestrator.

**Step 3: Run, commit**

```bash
python -m pytest tests/test_main_wiring.py -v
git add cortex-py/cortex/main.py cortex-py/tests/test_main_wiring.py
git commit -m "feat: wire up main.py with full system orchestrator"
```

---

## Task 40: Full Test Suite Verification + Final Commit

**Files:**
- No new files

**Step 1: Run complete test suite**

```bash
# Python
cd /Users/mackensonjeanlouis/Desktop/cortex/.worktrees/phase1/cortex-py
source .venv/bin/activate
python -m pytest tests/ -v --tb=short

# Rust
cd /Users/mackensonjeanlouis/Desktop/cortex/.worktrees/phase1/cortex-rs
cargo test

# Swift
cd /Users/mackensonjeanlouis/Desktop/cortex/.worktrees/phase1/cortex-app
swift test
```

**Step 2: Fix any failures**

Address any test failures found during the full suite run.

**Step 3: Final commit and branch summary**

```bash
git log --oneline | head -30
python -m pytest tests/ -q  # Final count
```

Expected: 300+ Python tests + 7+ Rust tests + 13+ Swift tests, all passing.

**Step 4: Use finishing-a-development-branch skill**

Present options for merging the `feature/phase1-infrastructure` branch.
