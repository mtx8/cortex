import pytest
from cortex.squadrons.alpha.volume_profiler import VolumeProfiler, VolumeSurge
from cortex.orchestrator.bus import SignalBus


def test_no_surge_below_threshold():
    """Volume at 1.2x avg should not trigger."""
    bus = SignalBus()
    profiler = VolumeProfiler(bus, moderate_threshold=1.5)
    profiler._volumes["AAPL"] = _deque([1000] * 20 + [1200])
    profiler._prices["AAPL"] = _deque([150] * 20 + [151])

    result = profiler.analyze("AAPL")
    assert result is None


def test_moderate_surge():
    """Volume at 1.8x avg triggers moderate surge."""
    bus = SignalBus()
    profiler = VolumeProfiler(bus, moderate_threshold=1.5, significant_threshold=2.0)
    profiler._volumes["AAPL"] = _deque([1000] * 20 + [1800])
    profiler._prices["AAPL"] = _deque([150] * 20 + [153])

    result = profiler.analyze("AAPL")
    assert result is not None
    assert result.surge_level == "moderate"
    assert 1.5 <= result.relative_volume < 2.0


def test_significant_surge():
    """Volume at 2.5x avg triggers significant surge."""
    bus = SignalBus()
    profiler = VolumeProfiler(bus, significant_threshold=2.0, extreme_threshold=3.0)
    profiler._volumes["AAPL"] = _deque([1000] * 20 + [2500])
    profiler._prices["AAPL"] = _deque([150] * 20 + [155])

    result = profiler.analyze("AAPL")
    assert result is not None
    assert result.surge_level == "significant"


def test_extreme_surge():
    """Volume at 4x avg triggers extreme surge."""
    bus = SignalBus()
    profiler = VolumeProfiler(bus, extreme_threshold=3.0)
    profiler._volumes["AAPL"] = _deque([1000] * 20 + [4000])
    profiler._prices["AAPL"] = _deque([150] * 20 + [160])

    result = profiler.analyze("AAPL")
    assert result is not None
    assert result.surge_level == "extreme"
    assert result.relative_volume >= 3.0


def test_volume_acceleration_detected():
    """3+ consecutive bars of increasing volume = acceleration."""
    bus = SignalBus()
    profiler = VolumeProfiler(bus, moderate_threshold=1.5, acceleration_bars=3)
    # 17 bars at 1000, then 3 increasing bars: 1800, 2500, 3500
    profiler._volumes["TSLA"] = _deque([1000] * 17 + [1800, 2500, 3500])
    profiler._prices["TSLA"] = _deque([200] * 17 + [205, 210, 215])

    result = profiler.analyze("TSLA")
    assert result is not None
    assert result.acceleration is True


def test_no_acceleration_without_consecutive_increase():
    """Non-consecutive volume increase = no acceleration."""
    bus = SignalBus()
    profiler = VolumeProfiler(bus, moderate_threshold=1.5, acceleration_bars=3)
    # Volume goes up, down, up — not consecutive
    profiler._volumes["TSLA"] = _deque([1000] * 17 + [2000, 1500, 2500])
    profiler._prices["TSLA"] = _deque([200] * 17 + [205, 203, 208])

    result = profiler.analyze("TSLA")
    assert result is not None
    assert result.acceleration is False


def test_price_change_calculated():
    """Price change % should reflect current vs prior bar."""
    bus = SignalBus()
    profiler = VolumeProfiler(bus, moderate_threshold=1.5)
    profiler._volumes["AAPL"] = _deque([1000] * 19 + [150, 2000])
    profiler._prices["AAPL"] = _deque([100] * 19 + [100, 105])  # 5% up

    result = profiler.analyze("AAPL")
    assert result is not None
    assert 4.5 <= result.price_change_pct <= 5.5


def test_insufficient_data_returns_none():
    """Only 1 bar of data should return None."""
    bus = SignalBus()
    profiler = VolumeProfiler(bus)
    profiler._volumes["NEW"] = _deque([5000])
    profiler._prices["NEW"] = _deque([100])

    result = profiler.analyze("NEW")
    assert result is None


def _deque(values):
    """Helper to create deque from list."""
    from collections import deque
    return deque(values, maxlen=50)
