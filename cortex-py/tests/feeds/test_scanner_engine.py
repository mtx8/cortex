"""ScannerEngine (Rust-accelerated technical scanner) tests."""

import pytest

pytest.importorskip("cortex_scanner")

from cortex.feeds.scanner_engine import ScannerEngine


def _trend(start: float, step: float, n: int = 40) -> list[float]:
    return [start + step * i for i in range(n)]


def test_scan_returns_sorted_composite_scores():
    eng = ScannerEngine()
    assert eng.available
    history = {
        "NVDA": _trend(100, 1.5),     # strong uptrend
        "AAPL": _trend(180, 0.2),     # mild uptrend
        "INTC": _trend(50, -0.8),     # downtrend
    }
    volumes = {"NVDA": 2_000_000, "AAPL": 1_000_000, "INTC": 800_000}
    avg = {"NVDA": 1_000_000, "AAPL": 1_000_000, "INTC": 1_000_000}
    results = eng.scan(history, volumes, avg)
    assert results, "expected scan results"
    syms = [r["symbol"] for r in results]
    assert set(syms) <= {"NVDA", "AAPL", "INTC"}
    # sorted descending by composite score
    scores = [r["composite_score"] for r in results]
    assert scores == sorted(scores, reverse=True)
    for r in results:
        assert {"symbol", "composite_score", "rsi", "macd_histogram"} <= set(r.keys())


def test_short_history_is_skipped():
    eng = ScannerEngine()
    results = eng.scan({"TSLA": [100.0, 101.0, 102.0]})  # < 30 bars
    assert results == []


def test_empty_input():
    eng = ScannerEngine()
    assert eng.scan({}) == []


def test_min_score_filter():
    eng = ScannerEngine()
    history = {"NVDA": _trend(100, 1.5)}
    all_results = eng.scan(history)
    filtered = eng.scan(history, min_score=101.0)  # above max possible (0..100)
    assert filtered == []
    assert isinstance(all_results, list)
