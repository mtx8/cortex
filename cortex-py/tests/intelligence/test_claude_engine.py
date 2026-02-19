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

    async def _handler(s):
        emitted.append(s)

    bus.subscribe("intelligence.strategy_update", _handler)

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
