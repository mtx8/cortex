"""Tests for HOTEL Squadron — Market Microstructure Agents.

Tests cover:
- Agent initialization and BaseAgent compliance
- Signal handling and filtering
- to_dict() output for status reporting
- Core microstructure analysis logic
"""

import pytest
import time
from collections import deque

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.hotel.spread_analyzer import SpreadAnalyzer
from cortex.squadrons.hotel.depth_reader import DepthReader
from cortex.squadrons.hotel.tick_analyzer import TickAnalyzer
from cortex.squadrons.hotel.price_level_mapper import PriceLevelMapper
from cortex.squadrons.hotel.execution_optimizer import ExecutionOptimizer
from cortex.squadrons.hotel.latency_monitor import LatencyMonitor


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
    """All HOTEL agents must follow BaseAgent conventions."""

    def test_spread_analyzer_init(self):
        bus = SignalBus()
        agent = SpreadAnalyzer(bus)
        assert agent.agent_id == "spread_analyzer"
        assert agent.squadron == "hotel"
        assert agent.status == "idle"

    def test_depth_reader_init(self):
        bus = SignalBus()
        agent = DepthReader(bus)
        assert agent.agent_id == "depth_reader"
        assert agent.squadron == "hotel"

    def test_tick_analyzer_init(self):
        bus = SignalBus()
        agent = TickAnalyzer(bus)
        assert agent.agent_id == "tick_analyzer"
        assert agent.squadron == "hotel"

    def test_price_level_mapper_init(self):
        bus = SignalBus()
        agent = PriceLevelMapper(bus)
        assert agent.agent_id == "price_level_mapper"
        assert agent.squadron == "hotel"

    def test_execution_optimizer_init(self):
        bus = SignalBus()
        agent = ExecutionOptimizer(bus)
        assert agent.agent_id == "execution_optimizer"
        assert agent.squadron == "hotel"

    def test_latency_monitor_init(self):
        bus = SignalBus()
        agent = LatencyMonitor(bus)
        assert agent.agent_id == "latency_monitor"
        assert agent.squadron == "hotel"


# ── to_dict() ────────────────────────────────────────────────────────

class TestToDict:
    """All agents must provide a to_dict() for status reporting."""

    def test_spread_analyzer_to_dict(self):
        bus = SignalBus()
        agent = SpreadAnalyzer(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "spread_analyzer"
        assert d["squadron"] == "hotel"
        assert "tracked_symbols" in d
        assert "alert_count" in d

    def test_depth_reader_to_dict(self):
        bus = SignalBus()
        agent = DepthReader(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "depth_reader"
        assert "imbalance_signals" in d

    def test_tick_analyzer_to_dict(self):
        bus = SignalBus()
        agent = TickAnalyzer(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "tick_analyzer"
        assert "patterns_detected" in d

    def test_price_level_mapper_to_dict(self):
        bus = SignalBus()
        agent = PriceLevelMapper(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "price_level_mapper"
        assert "tracked_symbols" in d

    def test_execution_optimizer_to_dict(self):
        bus = SignalBus()
        agent = ExecutionOptimizer(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "execution_optimizer"
        assert "recommendations" in d

    def test_latency_monitor_to_dict(self):
        bus = SignalBus()
        agent = LatencyMonitor(bus)
        d = agent.to_dict()
        assert d["agent_id"] == "latency_monitor"
        assert "order_latency_p50_ms" in d
        assert "alert_count" in d


# ── Signal Handling ──────────────────────────────────────────────────

class TestSignalHandling:
    """Test that agents correctly filter and process relevant signals."""

    @pytest.mark.asyncio
    async def test_spread_analyzer_processes_market_signal(self):
        bus = SignalBus()
        agent = SpreadAnalyzer(bus, lookback=10)

        # Feed several normal spreads first to build baseline
        for i in range(5):
            signal = make_signal(SignalTypes.MARKET_SIGNAL, {
                "symbol": "AAPL",
                "bid": 150.0,
                "ask": 150.05,
            })
            await agent.handle_signal(signal)

        assert "AAPL" in agent._spreads
        spread = agent.get_spread("AAPL")
        assert spread is not None
        assert spread > 0

    @pytest.mark.asyncio
    async def test_spread_analyzer_ignores_invalid_data(self):
        bus = SignalBus()
        agent = SpreadAnalyzer(bus)

        # No bid/ask
        signal = make_signal(SignalTypes.MARKET_SIGNAL, {
            "symbol": "AAPL",
            "close": 150.0,
        })
        await agent.handle_signal(signal)
        assert "AAPL" not in agent._spreads

    @pytest.mark.asyncio
    async def test_spread_analyzer_detects_wide_spread(self):
        bus = SignalBus()
        agent = SpreadAnalyzer(bus, lookback=10, alert_multiplier=1.5)

        # Build baseline with tight spreads
        for _ in range(5):
            signal = make_signal(SignalTypes.MARKET_SIGNAL, {
                "symbol": "AAPL",
                "bid": 150.0,
                "ask": 150.05,  # ~0.03% spread
            })
            await agent.handle_signal(signal)

        # Now a wide spread (10x wider)
        wide_signal = make_signal(SignalTypes.MARKET_SIGNAL, {
            "symbol": "AAPL",
            "bid": 149.50,
            "ask": 150.50,  # ~0.67% spread
        })
        await agent.handle_signal(wide_signal)
        assert agent._alert_count >= 1

    @pytest.mark.asyncio
    async def test_depth_reader_computes_imbalance(self):
        bus = SignalBus()
        agent = DepthReader(bus, imbalance_threshold=0.2)

        signal = make_signal(SignalTypes.MARKET_SIGNAL, {
            "symbol": "AAPL",
            "depth_bids": [[150.0, 1000], [149.9, 800], [149.8, 600]],
            "depth_asks": [[150.1, 200], [150.2, 150], [150.3, 100]],
        })
        await agent.handle_signal(signal)

        imbalance = agent.get_imbalance("AAPL")
        assert imbalance > 0  # More bid depth than ask depth

    @pytest.mark.asyncio
    async def test_depth_reader_ignores_missing_depth(self):
        bus = SignalBus()
        agent = DepthReader(bus)

        signal = make_signal(SignalTypes.MARKET_SIGNAL, {
            "symbol": "AAPL",
            "close": 150.0,
        })
        await agent.handle_signal(signal)
        assert agent.get_imbalance("AAPL") == 0.0

    @pytest.mark.asyncio
    async def test_tick_analyzer_tracks_ticks(self):
        bus = SignalBus()
        agent = TickAnalyzer(bus, lookback=50)

        prices = [100.0, 100.5, 101.0, 100.8, 101.2]
        for price in prices:
            signal = make_signal(SignalTypes.MARKET_SIGNAL, {
                "symbol": "AAPL",
                "close": price,
                "volume": 1000,
            })
            await agent.handle_signal(signal)

        assert "AAPL" in agent._ticks
        ratio = agent.get_tick_ratio("AAPL")
        assert ratio is not None
        assert "upticks" in ratio
        assert "downticks" in ratio

    @pytest.mark.asyncio
    async def test_tick_analyzer_detects_momentum_burst(self):
        bus = SignalBus()
        agent = TickAnalyzer(bus, momentum_threshold=5)

        # 5 consecutive upticks
        for i in range(6):
            signal = make_signal(SignalTypes.MARKET_SIGNAL, {
                "symbol": "AAPL",
                "close": 100.0 + i * 0.1,
                "volume": 1000,
            })
            await agent.handle_signal(signal)

        assert agent._pattern_count >= 1

    @pytest.mark.asyncio
    async def test_price_level_mapper_builds_profile(self):
        bus = SignalBus()
        agent = PriceLevelMapper(bus, update_interval=5)

        prices = [150.0, 150.5, 150.0, 151.0, 150.5, 150.0]
        for price in prices:
            signal = make_signal(SignalTypes.MARKET_SIGNAL, {
                "symbol": "AAPL",
                "close": price,
                "volume": 1000.0,
            })
            await agent.handle_signal(signal)

        assert "AAPL" in agent._volume_profile

    @pytest.mark.asyncio
    async def test_execution_optimizer_generates_recommendation(self):
        bus = SignalBus()
        agent = ExecutionOptimizer(bus)

        # Feed an entry signal
        entry_signal = make_signal(SignalTypes.ENTRY_SIGNAL, {
            "symbol": "AAPL",
            "confidence": 0.85,
            "direction": "long",
            "entry_price": 150.0,
        })
        await agent.handle_signal(entry_signal)
        assert agent._recommendation_count == 1

    @pytest.mark.asyncio
    async def test_execution_optimizer_uses_spread_context(self):
        bus = SignalBus()
        agent = ExecutionOptimizer(bus)

        # Feed spread alert first
        spread_signal = make_signal(SignalTypes.SPREAD_ALERT, {
            "symbol": "AAPL",
            "spread_pct": 0.5,
            "severity": "high",
        })
        await agent.handle_signal(spread_signal)
        assert "AAPL" in agent._spread_data

    @pytest.mark.asyncio
    async def test_latency_monitor_tracks_order_latency(self):
        bus = SignalBus()
        agent = LatencyMonitor(bus, alert_threshold_ms=5000)

        # Submit order
        submit_signal = make_signal(SignalTypes.ORDER_SUBMITTED, {
            "order_id": "ORD_001",
        })
        await agent.handle_signal(submit_signal)
        assert "ORD_001" in agent._pending_orders

        # Fill order (almost immediately)
        fill_signal = make_signal(SignalTypes.ORDER_FILLED, {
            "order_id": "ORD_001",
        })
        await agent.handle_signal(fill_signal)

        assert "ORD_001" not in agent._pending_orders
        assert len(agent._order_latencies) == 1

    @pytest.mark.asyncio
    async def test_latency_monitor_ignores_unknown_fills(self):
        bus = SignalBus()
        agent = LatencyMonitor(bus)

        fill_signal = make_signal(SignalTypes.ORDER_FILLED, {
            "order_id": "UNKNOWN",
        })
        await agent.handle_signal(fill_signal)
        assert len(agent._order_latencies) == 0


# ── Depth Reader Imbalance Math ──────────────────────────────────────

class TestDepthImbalanceMath:
    """Test order book imbalance calculations."""

    def test_balanced_book(self):
        bus = SignalBus()
        agent = DepthReader(bus)

        imbalance = agent._compute_imbalance(
            bids=[[100, 500], [99, 500]],
            asks=[[101, 500], [102, 500]],
        )
        assert imbalance == pytest.approx(0.0)

    def test_buy_heavy(self):
        bus = SignalBus()
        agent = DepthReader(bus)

        imbalance = agent._compute_imbalance(
            bids=[[100, 1000], [99, 800]],
            asks=[[101, 200], [102, 100]],
        )
        assert imbalance > 0.5

    def test_sell_heavy(self):
        bus = SignalBus()
        agent = DepthReader(bus)

        imbalance = agent._compute_imbalance(
            bids=[[100, 200], [99, 100]],
            asks=[[101, 1000], [102, 800]],
        )
        assert imbalance < -0.5

    def test_empty_book(self):
        bus = SignalBus()
        agent = DepthReader(bus)

        imbalance = agent._compute_imbalance(bids=[], asks=[])
        assert imbalance == 0.0


# ── Execution Optimizer Logic ────────────────────────────────────────

class TestExecutionLogic:
    """Test order type selection logic."""

    def test_wide_spread_suggests_limit(self):
        bus = SignalBus()
        agent = ExecutionOptimizer(bus, wide_spread_threshold=0.003)

        order_type, reason = agent._select_order_type(
            spread_info={"spread_pct": 0.5},  # 0.5% = 0.005 in decimal
            depth_info={},
            confidence=0.7,
        )
        assert order_type == "limit"

    def test_high_confidence_tight_spread_suggests_market(self):
        bus = SignalBus()
        agent = ExecutionOptimizer(bus)

        order_type, reason = agent._select_order_type(
            spread_info={"spread_pct": 0.05},  # 0.05% = very tight
            depth_info={},
            confidence=0.85,
        )
        assert order_type == "market"

    def test_favorable_imbalance_suggests_market(self):
        bus = SignalBus()
        agent = ExecutionOptimizer(bus)

        order_type, reason = agent._select_order_type(
            spread_info={"spread_pct": 0.1},
            depth_info={"imbalance": 0.5},
            confidence=0.6,
        )
        assert order_type == "market"


# ── Latency Percentile Math ─────────────────────────────────────────

class TestLatencyPercentile:
    """Test percentile calculation."""

    def test_p50(self):
        data = deque([10, 20, 30, 40, 50, 60, 70, 80, 90, 100])
        p50 = LatencyMonitor._percentile(data, 50)
        assert p50 == 60  # index 5

    def test_p95(self):
        data = deque(range(1, 101))  # 1-100
        p95 = LatencyMonitor._percentile(data, 95)
        assert p95 == 96

    def test_empty_data(self):
        data: deque[float] = deque()
        assert LatencyMonitor._percentile(data, 50) == 0.0
