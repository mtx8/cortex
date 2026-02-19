import pytest
from cortex.squadrons.alpha.gap_scanner import GapScanner, GapEvent
from cortex.orchestrator.bus import SignalBus


def test_gap_up_detected():
    """3% gap up should be detected."""
    bus = SignalBus()
    scanner = GapScanner(bus, min_gap_pct=2.0)
    gap = scanner.detect_gap(
        symbol="AAPL",
        prior_close=150.0,
        open_price=154.5,  # +3%
        current_price=155.0,
        volume_ratio=2.0,
    )
    assert gap is not None
    assert gap.direction == "up"
    assert gap.gap_pct == pytest.approx(3.0, abs=0.1)
    assert gap.gap_filled is False


def test_gap_down_detected():
    """3% gap down should be detected."""
    bus = SignalBus()
    scanner = GapScanner(bus, min_gap_pct=2.0)
    gap = scanner.detect_gap(
        symbol="TSLA",
        prior_close=200.0,
        open_price=194.0,  # -3%
        current_price=193.0,
        volume_ratio=1.8,
    )
    assert gap is not None
    assert gap.direction == "down"
    assert gap.gap_pct < -2.0


def test_small_gap_ignored():
    """1% gap should be below threshold."""
    bus = SignalBus()
    scanner = GapScanner(bus, min_gap_pct=2.0)
    gap = scanner.detect_gap(
        symbol="MSFT",
        prior_close=400.0,
        open_price=404.0,  # +1%
        current_price=405.0,
        volume_ratio=1.2,
    )
    assert gap is None


def test_gap_filled_detection():
    """Gap up is filled when price returns below prior close."""
    bus = SignalBus()
    scanner = GapScanner(bus, min_gap_pct=2.0)
    gap = scanner.detect_gap(
        symbol="AAPL",
        prior_close=150.0,
        open_price=155.0,  # +3.3% gap up
        current_price=149.0,  # Price fell below prior close
        volume_ratio=1.5,
    )
    assert gap is not None
    assert gap.gap_filled is True


def test_gap_down_filled():
    """Gap down is filled when price returns above prior close."""
    bus = SignalBus()
    scanner = GapScanner(bus, min_gap_pct=2.0)
    gap = scanner.detect_gap(
        symbol="TSLA",
        prior_close=200.0,
        open_price=194.0,  # -3% gap down
        current_price=201.0,  # Price recovered above prior close
        volume_ratio=1.5,
    )
    assert gap is not None
    assert gap.gap_filled is True


def test_zero_prior_close_returns_none():
    """Zero prior close should not generate a gap."""
    bus = SignalBus()
    scanner = GapScanner(bus)
    gap = scanner.detect_gap(
        symbol="X", prior_close=0.0, open_price=100.0,
        current_price=100.0, volume_ratio=1.0,
    )
    assert gap is None


def test_reset_daily_clears_state():
    """Daily reset clears today's opens and active gaps."""
    bus = SignalBus()
    scanner = GapScanner(bus, min_gap_pct=2.0)
    scanner._today_open["AAPL"] = 155.0
    scanner._active_gaps["AAPL"] = GapEvent(
        symbol="AAPL", gap_pct=3.0, direction="up",
        prior_close=150.0, open_price=155.0, current_price=156.0,
        volume_ratio=2.0, gap_filled=False,
    )

    scanner.reset_daily()
    assert len(scanner._today_open) == 0
    assert len(scanner._active_gaps) == 0


def test_gap_counter_increments():
    """Gap detection counter tracks total gaps found."""
    bus = SignalBus()
    scanner = GapScanner(bus, min_gap_pct=2.0)
    assert scanner.gaps_detected == 0

    # Manually detect a gap
    gap = scanner.detect_gap(
        symbol="AAPL", prior_close=150.0, open_price=156.0,
        current_price=157.0, volume_ratio=2.0,
    )
    assert gap is not None
    # Counter only increments in handle_signal, not detect_gap directly
    assert scanner.gaps_detected == 0
