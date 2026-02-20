"""Tests for LearningTracker."""

import pytest
from unittest.mock import AsyncMock, MagicMock

from cortex.simulation.learning_tracker import LearningTracker, LearningInsight


# ── LearningInsight tests ───────────────────────────────────────────


def test_insight_to_dict():
    insight = LearningInsight(
        pattern_type="momentum",
        description="momentum signals show 60% win rate over 20 trades",
        win_rate=0.6,
        sample_size=20,
        confidence="medium",
        timestamp=1000.0,
    )
    d = insight.to_dict()
    assert d["pattern_type"] == "momentum"
    assert d["win_rate"] == 0.6
    assert d["sample_size"] == 20
    assert d["confidence"] == "medium"
    assert d["timestamp"] == 1000.0


# ── LearningTracker tests ───────────────────────────────────────────


def test_initial_state():
    tracker = LearningTracker()
    assert tracker.insights == []
    assert tracker.to_dict()["total_trades"] == 0
    assert tracker.to_dict()["insights_count"] == 0
    assert tracker.to_dict()["analysis_interval"] == 50


def test_record_trade():
    tracker = LearningTracker()
    tracker.record_trade({"symbol": "AAPL", "side": "buy", "pnl": 100.0})
    assert tracker.to_dict()["total_trades"] == 1


def test_analysis_triggers_at_interval():
    """Analysis should run every analysis_interval trades."""
    tracker = LearningTracker(analysis_interval=10)

    # Record 10 winning momentum trades (enough to trigger analysis)
    for i in range(10):
        tracker.record_trade({
            "symbol": "AAPL",
            "side": "sell",
            "signal_type": "momentum",
            "pnl": 50.0,
        })

    # Should have produced at least one insight
    assert len(tracker.insights) >= 1
    assert tracker.insights[0].pattern_type == "momentum"
    assert tracker.insights[0].win_rate == 1.0


def test_no_analysis_below_threshold():
    """Should not analyze if fewer than 10 trades total."""
    tracker = LearningTracker(analysis_interval=5)

    # Record only 5 trades — analysis interval hit but total < 10
    for i in range(5):
        tracker.record_trade({
            "symbol": "AAPL",
            "signal_type": "momentum",
            "pnl": 50.0,
        })

    assert len(tracker.insights) == 0


def test_no_insight_for_low_win_rate():
    """Insights only generated for win_rate > 55%."""
    tracker = LearningTracker(analysis_interval=10)

    # 5 winners, 5 losers = 50% win rate -> no insight
    for i in range(5):
        tracker.record_trade({
            "symbol": "AAPL",
            "signal_type": "mean_reversion",
            "pnl": 50.0,
        })
    for i in range(5):
        tracker.record_trade({
            "symbol": "AAPL",
            "signal_type": "mean_reversion",
            "pnl": -50.0,
        })

    assert len(tracker.insights) == 0


def test_skip_signal_type_with_few_trades():
    """Signal types with < 5 trades are skipped."""
    tracker = LearningTracker(analysis_interval=10)

    # 7 momentum trades + 3 breakout trades = 10 total
    for i in range(7):
        tracker.record_trade({
            "symbol": "AAPL",
            "signal_type": "momentum",
            "pnl": 50.0,
        })
    for i in range(3):
        tracker.record_trade({
            "symbol": "MSFT",
            "signal_type": "breakout",
            "pnl": 50.0,
        })

    # Only momentum should generate insight (7 trades), breakout skipped (3 < 5)
    momentum_insights = [i for i in tracker.insights if i.pattern_type == "momentum"]
    breakout_insights = [i for i in tracker.insights if i.pattern_type == "breakout"]
    assert len(momentum_insights) >= 1
    assert len(breakout_insights) == 0


def test_confidence_levels():
    """Test low/medium/high confidence thresholds."""
    tracker = LearningTracker(analysis_interval=10)

    # 10 trades: should produce "low" confidence (sample < 15)
    for i in range(10):
        tracker.record_trade({
            "signal_type": "alpha_signal",
            "pnl": 100.0,
        })

    low_insights = [i for i in tracker.insights if i.confidence == "low"]
    assert len(low_insights) >= 1

    # Add 10 more for total 20 -> medium confidence (15 <= sample < 30)
    for i in range(10):
        tracker.record_trade({
            "signal_type": "alpha_signal",
            "pnl": 100.0,
        })

    medium_insights = [i for i in tracker.insights if i.confidence == "medium"]
    assert len(medium_insights) >= 1

    # Add 10 more for total 30 -> high confidence (sample >= 30)
    for i in range(10):
        tracker.record_trade({
            "signal_type": "alpha_signal",
            "pnl": 100.0,
        })

    high_insights = [i for i in tracker.insights if i.confidence == "high"]
    assert len(high_insights) >= 1


def test_unknown_signal_type():
    """Trades without signal_type default to 'unknown'."""
    tracker = LearningTracker(analysis_interval=10)

    for i in range(10):
        tracker.record_trade({"symbol": "AAPL", "pnl": 100.0})

    unknown_insights = [i for i in tracker.insights if i.pattern_type == "unknown"]
    assert len(unknown_insights) >= 1


def test_to_dict():
    tracker = LearningTracker(analysis_interval=25)
    tracker.record_trade({"symbol": "AAPL", "pnl": 100.0})
    d = tracker.to_dict()
    assert d["total_trades"] == 1
    assert d["insights_count"] == 0
    assert d["analysis_interval"] == 25


@pytest.mark.asyncio
async def test_broadcast_insights():
    broadcaster = MagicMock()
    broadcaster.broadcast = AsyncMock()
    tracker = LearningTracker(analysis_interval=10, broadcaster=broadcaster)

    # Generate some insights
    for i in range(10):
        tracker.record_trade({
            "signal_type": "momentum",
            "pnl": 100.0,
        })

    assert len(tracker.insights) >= 1

    await tracker.broadcast_insights()
    assert broadcaster.broadcast.called

    call_args = broadcaster.broadcast.call_args[0][0]
    assert call_args.type.value == "learning_insight"
    assert "insights" in call_args.payload
    assert "total_trades" in call_args.payload


@pytest.mark.asyncio
async def test_broadcast_no_insights():
    """No broadcast when there are no insights."""
    broadcaster = MagicMock()
    broadcaster.broadcast = AsyncMock()
    tracker = LearningTracker(broadcaster=broadcaster)

    await tracker.broadcast_insights()
    assert not broadcaster.broadcast.called


@pytest.mark.asyncio
async def test_broadcast_no_broadcaster():
    """No error when broadcaster is None."""
    tracker = LearningTracker(analysis_interval=10, broadcaster=None)

    for i in range(10):
        tracker.record_trade({"signal_type": "momentum", "pnl": 100.0})

    await tracker.broadcast_insights()  # should not raise
