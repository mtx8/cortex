"""Tests for GOLF Squadron — Adaptive Learning Agents.

Tests cover:
- Agent initialization and BaseAgent compliance
- Signal handling and filtering
- to_dict() output for status reporting
- Core logic for pattern learning, regime detection, etc.
"""

import pytest
import asyncio
import time

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.golf.trade_historian import TradeHistorian, TradeRecord
from cortex.squadrons.golf.pattern_learner import PatternLearner
from cortex.squadrons.golf.strategy_optimizer import StrategyOptimizer
from cortex.squadrons.golf.regime_detector import RegimeDetector
from cortex.squadrons.golf.performance_tracker import PerformanceTracker
from cortex.squadrons.golf.drawdown_analyzer import DrawdownAnalyzer
from cortex.squadrons.golf.sector_momentum import SectorMomentum
from cortex.squadrons.golf.correlation_tracker import CorrelationTracker


# ── Helpers ──────────────────────────────────────────────────────────

def make_signal(signal_type: str, payload: dict) -> Signal:
    return Signal(
        signal_id="test_1",
        source_agent="test",
        source_squadron="test",
        signal_type=signal_type,
        payload=payload,
        priority=SignalPriority.NORMAL,
    )


# ── Agent Initialization ────────────────────────────────────────────

class TestAgentInit:
    """All GOLF agents must follow BaseAgent conventions."""

    def test_trade_historian_init(self):
        bus = SignalBus()
        agent = TradeHistorian(bus)
        assert agent.agent_id == "trade_historian"
        assert agent.squadron == "golf"
        assert agent.status == "idle"

    def test_pattern_learner_init(self):
        bus = SignalBus()
        agent = PatternLearner(bus)
        assert agent.agent_id == "pattern_learner"
        assert agent.squadron == "golf"

    def test_strategy_optimizer_init(self):
        bus = SignalBus()
        agent = StrategyOptimizer(bus)
        assert agent.agent_id == "strategy_optimizer"
        assert agent.squadron == "golf"

    def test_regime_detector_init(self):
        bus = SignalBus()
        agent = RegimeDetector(bus)
        assert agent.agent_id == "regime_detector"
        assert agent.squadron == "golf"

    def test_performance_tracker_init(self):
        bus = SignalBus()
        agent = PerformanceTracker(bus)
        assert agent.agent_id == "performance_tracker"
        assert agent.squadron == "golf"

    def test_drawdown_analyzer_init(self):
        bus = SignalBus()
        agent = DrawdownAnalyzer(bus)
        assert agent.agent_id == "drawdown_analyzer"
        assert agent.squadron == "golf"

    def test_sector_momentum_init(self):
        bus = SignalBus()
        agent = SectorMomentum(bus)
        assert agent.agent_id == "sector_momentum"
        assert agent.squadron == "golf"

    def test_correlation_tracker_init(self):
        bus = SignalBus()
        agent = CorrelationTracker(bus)
        assert agent.agent_id == "correlation_tracker"
        assert agent.squadron == "golf"


# ── to_dict() ────────────────────────────────────────────────────────

class TestToDict:
    """All agents must provide a to_dict() for status reporting."""

    def test_trade_historian_to_dict(self):
        bus = SignalBus()
        agent = TradeHistorian(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "trade_historian"
        assert d["squadron"] == "golf"
        assert "total_recorded" in d
        assert "win_rate" in d

    def test_pattern_learner_to_dict(self):
        bus = SignalBus()
        agent = PatternLearner(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "pattern_learner"
        assert "patterns_found" in d
        assert "analysis_interval" in d

    def test_strategy_optimizer_to_dict(self):
        bus = SignalBus()
        agent = StrategyOptimizer(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "strategy_optimizer"
        assert "optimization_count" in d

    def test_regime_detector_to_dict(self):
        bus = SignalBus()
        agent = RegimeDetector(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "regime_detector"
        assert "tracked_symbols" in d
        assert "regime_changes" in d

    def test_performance_tracker_to_dict(self):
        bus = SignalBus()
        agent = PerformanceTracker(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "performance_tracker"
        assert "overall" in d
        assert d["overall"]["trade_count"] == 0

    def test_drawdown_analyzer_to_dict(self):
        bus = SignalBus()
        agent = DrawdownAnalyzer(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "drawdown_analyzer"
        assert "current_drawdown_pct" in d
        assert "consecutive_losses" in d

    def test_sector_momentum_to_dict(self):
        bus = SignalBus()
        agent = SectorMomentum(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "sector_momentum"
        assert "tracked_sectors" in d

    def test_correlation_tracker_to_dict(self):
        bus = SignalBus()
        agent = CorrelationTracker(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "correlation_tracker"
        assert "correlation_pairs" in d


# ── Signal Handling ──────────────────────────────────────────────────

class TestSignalHandling:
    """Test that agents correctly filter and process relevant signals."""

    @pytest.mark.asyncio
    async def test_trade_historian_records_fill(self):
        bus = SignalBus()
        agent = TradeHistorian(bus)

        # Open position
        buy_signal = make_signal(SignalTypes.ORDER_FILLED, {
            "symbol": "AAPL",
            "side": "buy",
            "fill_price": 150.0,
            "quantity": 10,
            "strategy": "momentum",
            "direction": "long",
            "reasons": ["RSI reversal"],
        })
        await agent.handle_signal(buy_signal)
        assert "AAPL" in agent._pending_entries

        # Close position
        sell_signal = make_signal(SignalTypes.ORDER_FILLED, {
            "symbol": "AAPL",
            "side": "sell",
            "fill_price": 155.0,
            "quantity": 10,
        })
        await agent.handle_signal(sell_signal)
        assert len(agent.trades) == 1
        assert agent.trades[0].pnl == 50.0  # (155 - 150) * 10
        assert agent.trades[0].strategy == "momentum"

    @pytest.mark.asyncio
    async def test_trade_historian_ignores_irrelevant_signals(self):
        bus = SignalBus()
        agent = TradeHistorian(bus)

        signal = make_signal(SignalTypes.MARKET_SIGNAL, {"symbol": "AAPL", "close": 150.0})
        # This should not raise — handle_signal filters by signal_type
        await agent.handle_signal(signal)
        assert len(agent.trades) == 0

    @pytest.mark.asyncio
    async def test_pattern_learner_counts_trades(self):
        bus = SignalBus()
        agent = PatternLearner(bus, analysis_interval=5)

        for i in range(4):
            signal = make_signal(SignalTypes.TRADE_RECORDED, {
                "pnl": 10.0,
                "strategy": "test",
                "symbol": "AAPL",
            })
            await agent.handle_signal(signal)

        assert agent._trade_count == 4

    @pytest.mark.asyncio
    async def test_pattern_learner_ignores_wrong_signal(self):
        bus = SignalBus()
        agent = PatternLearner(bus)

        signal = make_signal(SignalTypes.MARKET_SIGNAL, {"symbol": "AAPL"})
        await agent.handle_signal(signal)
        assert agent._trade_count == 0

    @pytest.mark.asyncio
    async def test_regime_detector_classifies_trending(self):
        bus = SignalBus()
        agent = RegimeDetector(bus, lookback=50, trend_strength_threshold=0.4)

        # Strongly trending prices
        for i in range(30):
            signal = make_signal(SignalTypes.MARKET_SIGNAL, {
                "symbol": "AAPL",
                "close": 100.0 + i * 2.0,
            })
            await agent.handle_signal(signal)

        regime = agent.get_regime("AAPL")
        assert regime in ("trending", "volatile", "quiet", "mean_reverting")

    @pytest.mark.asyncio
    async def test_regime_detector_ignores_non_market_signal(self):
        bus = SignalBus()
        agent = RegimeDetector(bus)

        signal = make_signal(SignalTypes.ORDER_FILLED, {"symbol": "AAPL"})
        await agent.handle_signal(signal)
        assert len(agent._prices) == 0

    @pytest.mark.asyncio
    async def test_performance_tracker_records_trades(self):
        bus = SignalBus()
        agent = PerformanceTracker(bus, update_interval=100)

        signal = make_signal(SignalTypes.TRADE_RECORDED, {
            "pnl": 50.0,
            "strategy": "momentum",
            "symbol": "AAPL",
        })
        await agent.handle_signal(signal)

        assert agent._trade_count == 1
        assert agent._overall.wins == 1
        assert agent._overall.win_rate == 1.0

        # Record a loss
        loss_signal = make_signal(SignalTypes.TRADE_RECORDED, {
            "pnl": -20.0,
            "strategy": "momentum",
            "symbol": "TSLA",
        })
        await agent.handle_signal(loss_signal)

        assert agent._trade_count == 2
        assert agent._overall.win_rate == 0.5

    @pytest.mark.asyncio
    async def test_drawdown_analyzer_tracks_equity(self):
        bus = SignalBus()
        agent = DrawdownAnalyzer(bus)

        # Two winning trades
        for _ in range(2):
            signal = make_signal(SignalTypes.TRADE_RECORDED, {"pnl": 100.0})
            await agent.handle_signal(signal)

        assert agent._current_equity == 200.0
        assert agent._peak_equity == 200.0

        # A loss — should enter drawdown
        loss_signal = make_signal(SignalTypes.TRADE_RECORDED, {"pnl": -50.0})
        await agent.handle_signal(loss_signal)

        assert agent._current_equity == 150.0
        assert agent.current_drawdown_pct == pytest.approx(25.0)

    @pytest.mark.asyncio
    async def test_sector_momentum_tracks_etfs(self):
        bus = SignalBus()
        agent = SectorMomentum(bus, lookback=20)

        # Feed XLK data
        for i in range(10):
            signal = make_signal(SignalTypes.MARKET_SIGNAL, {
                "symbol": "XLK",
                "close": 200.0 + i * 1.0,
            })
            await agent.handle_signal(signal)

        assert "XLK" in agent._prices
        assert len(agent._prices["XLK"]) == 10

    @pytest.mark.asyncio
    async def test_sector_momentum_ignores_non_sector_etf(self):
        bus = SignalBus()
        agent = SectorMomentum(bus)

        signal = make_signal(SignalTypes.MARKET_SIGNAL, {
            "symbol": "AAPL",
            "close": 150.0,
        })
        await agent.handle_signal(signal)
        assert "AAPL" not in agent._prices

    @pytest.mark.asyncio
    async def test_correlation_tracker_tracks_returns(self):
        bus = SignalBus()
        agent = CorrelationTracker(bus, lookback=30)

        # Feed two prices for SPY to generate a return
        for price in [450.0, 452.0, 454.0]:
            signal = make_signal(SignalTypes.MARKET_SIGNAL, {
                "symbol": "SPY",
                "close": price,
            })
            await agent.handle_signal(signal)

        assert "SPY" in agent._returns
        assert len(agent._returns["SPY"]) == 2  # 3 prices = 2 returns

    @pytest.mark.asyncio
    async def test_strategy_optimizer_handles_patterns(self):
        bus = SignalBus()
        agent = StrategyOptimizer(bus)

        signal = make_signal(SignalTypes.PATTERN_LEARNED, {
            "patterns": [
                {
                    "type": "strategy_edge",
                    "key": "momentum",
                    "win_rate": 0.72,
                    "sample_size": 50,
                    "avg_pnl": 25.0,
                }
            ],
            "trade_count": 100,
        })
        await agent.handle_signal(signal)
        assert agent._optimization_count == 1
        assert "momentum" in agent._strategy_params


# ── Pattern Learner Analysis Logic ───────────────────────────────────

class TestPatternLearnerAnalysis:
    """Test the core analysis methods of PatternLearner."""

    def _make_historian_with_trades(self, trades_data):
        """Create a TradeHistorian populated with trade records."""
        bus = SignalBus()
        historian = TradeHistorian(bus)
        for td in trades_data:
            record = TradeRecord(
                trade_id=f"test_{len(historian._trades)}",
                symbol=td.get("symbol", "AAPL"),
                direction="long",
                entry_price=100.0,
                exit_price=100.0 + td["pnl"],
                quantity=1,
                pnl=td["pnl"],
                pnl_pct=td["pnl"],
                entry_time=time.time() - 3600,
                exit_time=time.time(),
                holding_period_seconds=td.get("holding", 600),
                strategy=td.get("strategy", "momentum"),
                entry_reasons=td.get("reasons", []),
                sector=td.get("sector", "Technology"),
            )
            historian._trades.append(record)
        return historian

    @pytest.mark.asyncio
    async def test_analyze_by_strategy(self):
        bus = SignalBus()
        trades = (
            [{"pnl": 10.0, "strategy": "momentum"}] * 15
            + [{"pnl": -5.0, "strategy": "momentum"}] * 5
        )
        historian = self._make_historian_with_trades(trades)
        learner = PatternLearner(
            bus, trade_historian=historian, min_sample_size=10, min_win_rate=0.6
        )

        await learner._analyze_patterns()
        # 15/20 = 75% win rate for momentum -> should find pattern
        strategy_patterns = [p for p in learner.patterns if p["type"] == "strategy_edge"]
        assert len(strategy_patterns) >= 1
        assert strategy_patterns[0]["win_rate"] == 0.75

    @pytest.mark.asyncio
    async def test_no_pattern_below_threshold(self):
        bus = SignalBus()
        trades = (
            [{"pnl": 10.0, "strategy": "bad_strat"}] * 10
            + [{"pnl": -5.0, "strategy": "bad_strat"}] * 15
        )
        historian = self._make_historian_with_trades(trades)
        learner = PatternLearner(
            bus, trade_historian=historian, min_sample_size=10, min_win_rate=0.6
        )

        await learner._analyze_patterns()
        # 10/25 = 40% — below threshold
        strategy_patterns = [p for p in learner.patterns if p["type"] == "strategy_edge"]
        assert len(strategy_patterns) == 0


# ── Regime Detector Classification ───────────────────────────────────

class TestRegimeClassification:
    """Test regime classification logic directly."""

    def test_classify_trending(self):
        bus = SignalBus()
        agent = RegimeDetector(
            bus, trend_strength_threshold=0.4, volatility_low_threshold=0.01,
        )
        # Strong uptrend with some noise to avoid near-zero volatility
        prices = [100.0 + i * 2.0 + (i % 3) * 0.5 for i in range(20)]
        regime = agent._classify_regime(prices)
        assert regime == "trending"

    def test_classify_volatile(self):
        bus = SignalBus()
        agent = RegimeDetector(bus, volatility_high_threshold=0.5)
        # Wild swings
        prices = []
        for i in range(20):
            prices.append(100.0 + ((-1) ** i) * 20.0)
        regime = agent._classify_regime(prices)
        assert regime == "volatile"

    def test_classify_quiet(self):
        bus = SignalBus()
        agent = RegimeDetector(bus, volatility_low_threshold=0.5)
        # Nearly flat
        prices = [100.0 + i * 0.001 for i in range(20)]
        regime = agent._classify_regime(prices)
        assert regime == "quiet"


# ── Correlation Tracker Math ─────────────────────────────────────────

class TestCorrelationMath:
    """Test Pearson correlation calculation."""

    def test_perfect_positive_correlation(self):
        x = [1.0, 2.0, 3.0, 4.0, 5.0]
        y = [2.0, 4.0, 6.0, 8.0, 10.0]
        corr = CorrelationTracker._pearson_correlation(x, y)
        assert corr is not None
        assert corr == pytest.approx(1.0, abs=0.001)

    def test_perfect_negative_correlation(self):
        x = [1.0, 2.0, 3.0, 4.0, 5.0]
        y = [10.0, 8.0, 6.0, 4.0, 2.0]
        corr = CorrelationTracker._pearson_correlation(x, y)
        assert corr is not None
        assert corr == pytest.approx(-1.0, abs=0.001)

    def test_insufficient_data_returns_none(self):
        corr = CorrelationTracker._pearson_correlation([1.0, 2.0], [3.0, 4.0])
        assert corr is None

    def test_zero_variance_returns_none(self):
        x = [5.0, 5.0, 5.0, 5.0, 5.0]
        y = [1.0, 2.0, 3.0, 4.0, 5.0]
        corr = CorrelationTracker._pearson_correlation(x, y)
        assert corr is None
