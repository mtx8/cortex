"""Comprehensive tests for CHARLIE Options Flow Intelligence.

All tests are self-contained with deterministic inputs.
Timestamps use ``time.time()`` with small offsets.

pytest-asyncio ``auto`` mode is configured in pyproject.toml, so
``async def`` tests are discovered automatically.
"""

import time

import pytest

from cortex.orchestrator.bus import SignalBus
from cortex.squadrons.charlie.flow_intelligence import (
    FlowAlert,
    FlowDetector,
    FlowIntelligence,
    FlowType,
    OptionsFlow,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _make_flow(
    *,
    symbol: str = "AAPL",
    option_type: str = "call",
    strike: float = 150.0,
    expiry: str = "2026-06-19",
    premium: float = 50_000.0,
    volume: int = 500,
    open_interest: int = 5_000,
    side: str = "buy",
    flow_type: FlowType = FlowType.UNUSUAL_SIZE,
    timestamp: float | None = None,
    is_sweep: bool = False,
    exchange_count: int = 1,
    flow_id: str | None = None,
) -> OptionsFlow:
    return OptionsFlow(
        flow_id=flow_id or f"flow-{id(object()):x}",
        symbol=symbol,
        option_type=option_type,
        strike=strike,
        expiry=expiry,
        premium=premium,
        volume=volume,
        open_interest=open_interest,
        side=side,
        flow_type=flow_type,
        timestamp=timestamp or time.time(),
        is_sweep=is_sweep,
        exchange_count=exchange_count,
    )


@pytest.fixture
def detector() -> FlowDetector:
    return FlowDetector()


@pytest.fixture
def bus() -> SignalBus:
    return SignalBus()


@pytest.fixture
def agent(bus: SignalBus) -> FlowIntelligence:
    return FlowIntelligence(bus)


# ---------------------------------------------------------------------------
# 1. test_detect_unusual_high_volume
# ---------------------------------------------------------------------------

class TestDetectUnusualHighVolume:
    def test_triggers_alert(self, detector: FlowDetector) -> None:
        """Volume > 3x average should produce an alert."""
        flow = _make_flow(volume=1000, premium=10_000.0)
        avg_volume = 200.0  # ratio = 5.0 > 3.0

        alert = detector.detect_unusual(flow, avg_volume)

        assert alert is not None
        assert alert.symbol == "AAPL"
        assert "unusual" in alert.alert_type
        assert alert.confidence > 0.0
        assert alert.total_premium == 10_000.0
        assert len(alert.flows) == 1
        assert alert.flows[0] is flow


# ---------------------------------------------------------------------------
# 2. test_detect_unusual_normal_volume
# ---------------------------------------------------------------------------

class TestDetectUnusualNormalVolume:
    def test_no_alert(self, detector: FlowDetector) -> None:
        """Volume below threshold and premium below threshold: no alert."""
        flow = _make_flow(volume=200, premium=10_000.0)
        avg_volume = 200.0  # ratio = 1.0 < 3.0

        alert = detector.detect_unusual(flow, avg_volume)

        assert alert is None

    def test_just_below_threshold(self, detector: FlowDetector) -> None:
        """Volume at 2.9x average: still no alert."""
        flow = _make_flow(volume=290, premium=50_000.0)
        avg_volume = 100.0  # ratio = 2.9 < 3.0

        alert = detector.detect_unusual(flow, avg_volume)

        assert alert is None


# ---------------------------------------------------------------------------
# 3. test_detect_unusual_high_premium
# ---------------------------------------------------------------------------

class TestDetectUnusualHighPremium:
    def test_triggers_alert(self, detector: FlowDetector) -> None:
        """Premium >= $100k should produce an alert even with normal volume."""
        flow = _make_flow(volume=100, premium=150_000.0)
        avg_volume = 100.0  # ratio = 1.0, below volume threshold

        alert = detector.detect_unusual(flow, avg_volume)

        assert alert is not None
        assert alert.total_premium == 150_000.0
        assert "premium" in alert.alert_type or "unusual" in alert.alert_type

    def test_exactly_at_threshold(self, detector: FlowDetector) -> None:
        """Premium exactly at $100k triggers alert."""
        flow = _make_flow(volume=50, premium=100_000.0)
        avg_volume = 50.0

        alert = detector.detect_unusual(flow, avg_volume)

        assert alert is not None


# ---------------------------------------------------------------------------
# 4. test_detect_sweep
# ---------------------------------------------------------------------------

class TestDetectSweep:
    def test_sweep_detected(self, detector: FlowDetector) -> None:
        """3+ exchanges grouped as sweep produces an alert."""
        now = time.time()
        flows = [
            _make_flow(exchange_count=1, timestamp=now, flow_id=f"s{i}")
            for i in range(3)
        ]
        # Total exchange_count = 3 >= threshold

        alerts = detector.detect_sweep(flows)

        assert len(alerts) == 1
        alert = alerts[0]
        assert "sweep" in alert.alert_type
        assert len(alert.flows) == 3

    def test_below_sweep_threshold(self, detector: FlowDetector) -> None:
        """2 exchanges total is below threshold: no alert."""
        flows = [
            _make_flow(exchange_count=1, flow_id=f"s{i}")
            for i in range(2)
        ]

        alerts = detector.detect_sweep(flows)

        assert len(alerts) == 0

    def test_different_contracts_not_grouped(self, detector: FlowDetector) -> None:
        """Flows on different strikes should not be grouped together."""
        flows = [
            _make_flow(strike=150.0, exchange_count=2, flow_id="a"),
            _make_flow(strike=160.0, exchange_count=2, flow_id="b"),
        ]

        alerts = detector.detect_sweep(flows)

        assert len(alerts) == 0

    def test_single_flow_multi_exchange(self, detector: FlowDetector) -> None:
        """A single flow with exchange_count >= threshold triggers sweep."""
        flows = [_make_flow(exchange_count=4, flow_id="multi")]

        alerts = detector.detect_sweep(flows)

        assert len(alerts) == 1


# ---------------------------------------------------------------------------
# 5. test_detect_accumulation
# ---------------------------------------------------------------------------

class TestDetectAccumulation:
    def test_accumulation_detected(self, detector: FlowDetector) -> None:
        """5 orders in the same contract within 30 minutes triggers alert."""
        base_ts = time.time()
        flows = [
            _make_flow(
                timestamp=base_ts + i * 60,  # 1 min apart
                flow_id=f"acc-{i}",
            )
            for i in range(5)
        ]

        alerts = detector.detect_accumulation(flows, window_minutes=30.0)

        assert len(alerts) >= 1
        alert = alerts[0]
        assert alert.alert_type == "accumulation"
        assert len(alert.flows) >= 3

    def test_no_accumulation_outside_window(self, detector: FlowDetector) -> None:
        """Orders spread over hours should not trigger accumulation."""
        base_ts = time.time()
        flows = [
            _make_flow(
                timestamp=base_ts + i * 3600,  # 1 hour apart
                flow_id=f"spread-{i}",
            )
            for i in range(5)
        ]

        alerts = detector.detect_accumulation(flows, window_minutes=30.0)

        assert len(alerts) == 0

    def test_different_option_types_separate(self, detector: FlowDetector) -> None:
        """Call and put flows on the same strike should NOT be grouped."""
        base_ts = time.time()
        calls = [
            _make_flow(option_type="call", timestamp=base_ts + i, flow_id=f"c{i}")
            for i in range(2)
        ]
        puts = [
            _make_flow(option_type="put", timestamp=base_ts + i, flow_id=f"p{i}")
            for i in range(2)
        ]

        alerts = detector.detect_accumulation(calls + puts, window_minutes=30.0)

        # Neither group alone reaches 3 orders
        assert len(alerts) == 0


# ---------------------------------------------------------------------------
# 6. test_classify_sentiment_bullish
# ---------------------------------------------------------------------------

class TestClassifySentimentBullish:
    def test_more_call_premium(self, detector: FlowDetector) -> None:
        """More call premium than put premium -> bullish."""
        flows = [
            _make_flow(option_type="call", premium=200_000.0, flow_id="c1"),
            _make_flow(option_type="put", premium=50_000.0, flow_id="p1"),
        ]

        sentiment = detector.classify_sentiment(flows)

        assert sentiment == "bullish"

    def test_all_calls(self, detector: FlowDetector) -> None:
        """All calls -> bullish."""
        flows = [
            _make_flow(option_type="call", premium=100_000.0, flow_id=f"c{i}")
            for i in range(3)
        ]

        assert detector.classify_sentiment(flows) == "bullish"


# ---------------------------------------------------------------------------
# 7. test_classify_sentiment_bearish
# ---------------------------------------------------------------------------

class TestClassifySentimentBearish:
    def test_more_put_premium(self, detector: FlowDetector) -> None:
        """More put premium than call premium -> bearish."""
        flows = [
            _make_flow(option_type="call", premium=30_000.0, flow_id="c1"),
            _make_flow(option_type="put", premium=120_000.0, flow_id="p1"),
        ]

        sentiment = detector.classify_sentiment(flows)

        assert sentiment == "bearish"

    def test_all_puts(self, detector: FlowDetector) -> None:
        """All puts -> bearish."""
        flows = [
            _make_flow(option_type="put", premium=100_000.0, flow_id=f"p{i}")
            for i in range(3)
        ]

        assert detector.classify_sentiment(flows) == "bearish"

    def test_equal_premium_neutral(self, detector: FlowDetector) -> None:
        """Equal call and put premium -> neutral."""
        flows = [
            _make_flow(option_type="call", premium=100_000.0, flow_id="c1"),
            _make_flow(option_type="put", premium=100_000.0, flow_id="p1"),
        ]

        assert detector.classify_sentiment(flows) == "neutral"


# ---------------------------------------------------------------------------
# 8. test_confidence_scoring
# ---------------------------------------------------------------------------

class TestConfidenceScoring:
    def test_higher_volume_ratio_higher_confidence(self, detector: FlowDetector) -> None:
        """A flow with a higher volume ratio should produce higher confidence."""
        flow_lo = _make_flow(volume=400, premium=50_000.0, flow_id="lo")
        flow_hi = _make_flow(volume=2000, premium=50_000.0, flow_id="hi")
        avg_volume = 100.0

        conf_lo = detector._compute_confidence(flow_lo, avg_volume)
        conf_hi = detector._compute_confidence(flow_hi, avg_volume)

        assert conf_hi > conf_lo

    def test_higher_premium_higher_confidence(self, detector: FlowDetector) -> None:
        """A flow with higher premium should produce higher confidence."""
        flow_lo = _make_flow(volume=300, premium=10_000.0, flow_id="lo")
        flow_hi = _make_flow(volume=300, premium=500_000.0, flow_id="hi")
        avg_volume = 100.0

        conf_lo = detector._compute_confidence(flow_lo, avg_volume)
        conf_hi = detector._compute_confidence(flow_hi, avg_volume)

        assert conf_hi > conf_lo

    def test_confidence_bounded(self, detector: FlowDetector) -> None:
        """Confidence must be in [0, 1] even with extreme inputs."""
        flow = _make_flow(volume=100_000, premium=50_000_000.0)
        conf = detector._compute_confidence(flow, 1.0)

        assert 0.0 <= conf <= 1.0

    def test_zero_avg_volume(self, detector: FlowDetector) -> None:
        """Zero average volume should not crash."""
        flow = _make_flow(volume=500, premium=200_000.0)
        conf = detector._compute_confidence(flow, 0.0)

        assert 0.0 <= conf <= 1.0


# ---------------------------------------------------------------------------
# 9. test_ingest_triggers_alert
# ---------------------------------------------------------------------------

class TestIngestTriggersAlert:
    async def test_ingest_unusual_flow(self, agent: FlowIntelligence) -> None:
        """Ingesting a flow with high volume should generate an alert."""
        flow = _make_flow(volume=1000, premium=200_000.0)

        await agent.ingest(flow, avg_volume=100.0)

        alerts = agent.get_recent_alerts()
        assert len(alerts) >= 1
        assert any(a.symbol == "AAPL" for a in alerts)

    async def test_ingest_normal_flow_no_alert(self, agent: FlowIntelligence) -> None:
        """Ingesting a normal flow should produce no alert."""
        flow = _make_flow(volume=50, premium=5_000.0)

        await agent.ingest(flow, avg_volume=100.0)

        alerts = agent.get_recent_alerts()
        assert len(alerts) == 0


# ---------------------------------------------------------------------------
# 10. test_recent_alerts_ordering
# ---------------------------------------------------------------------------

class TestRecentAlertsOrdering:
    async def test_most_recent_first(self, agent: FlowIntelligence) -> None:
        """get_recent_alerts returns alerts sorted newest-first."""
        base_ts = time.time()

        for i in range(5):
            flow = _make_flow(
                volume=2000,
                premium=200_000.0,
                timestamp=base_ts + i,
                flow_id=f"order-{i}",
                symbol=f"SYM{i}",
            )
            await agent.ingest(flow, avg_volume=100.0)

        alerts = agent.get_recent_alerts()
        assert len(alerts) >= 2

        # Verify descending timestamp order
        for j in range(len(alerts) - 1):
            assert alerts[j].timestamp >= alerts[j + 1].timestamp

    async def test_count_limit(self, agent: FlowIntelligence) -> None:
        """get_recent_alerts(count=2) returns at most 2."""
        base_ts = time.time()

        for i in range(5):
            flow = _make_flow(
                volume=2000,
                premium=200_000.0,
                timestamp=base_ts + i,
                flow_id=f"limit-{i}",
                symbol=f"LIM{i}",
            )
            await agent.ingest(flow, avg_volume=100.0)

        alerts = agent.get_recent_alerts(count=2)
        assert len(alerts) <= 2


# ---------------------------------------------------------------------------
# 11. test_alerts_by_symbol
# ---------------------------------------------------------------------------

class TestAlertsBySymbol:
    async def test_filtered_correctly(self, agent: FlowIntelligence) -> None:
        """get_alerts_by_symbol returns only matching alerts."""
        for sym in ("AAPL", "TSLA", "AAPL", "MSFT"):
            flow = _make_flow(
                symbol=sym,
                volume=2000,
                premium=200_000.0,
                flow_id=f"sym-{sym}-{id(object()):x}",
            )
            await agent.ingest(flow, avg_volume=100.0)

        aapl_alerts = agent.get_alerts_by_symbol("AAPL")
        tsla_alerts = agent.get_alerts_by_symbol("TSLA")
        goog_alerts = agent.get_alerts_by_symbol("GOOG")

        assert all(a.symbol == "AAPL" for a in aapl_alerts)
        assert all(a.symbol == "TSLA" for a in tsla_alerts)
        assert len(goog_alerts) == 0
        assert len(aapl_alerts) >= 2
        assert len(tsla_alerts) >= 1

    async def test_ordered_newest_first(self, agent: FlowIntelligence) -> None:
        """Symbol-filtered alerts should be newest-first."""
        base_ts = time.time()

        for i in range(3):
            flow = _make_flow(
                symbol="NVDA",
                volume=2000,
                premium=200_000.0,
                timestamp=base_ts + i,
                flow_id=f"nvda-{i}",
            )
            await agent.ingest(flow, avg_volume=100.0)

        alerts = agent.get_alerts_by_symbol("NVDA")
        for j in range(len(alerts) - 1):
            assert alerts[j].timestamp >= alerts[j + 1].timestamp
