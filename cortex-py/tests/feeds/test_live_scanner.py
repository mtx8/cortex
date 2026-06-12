"""MarketDataFeed live (Rust) scanner integration — real scores once history exists."""

from collections import deque

import pytest

pytest.importorskip("cortex_scanner")

from cortex.feeds.market_data import MarketDataFeed
from cortex.feeds.scanner_engine import ScannerEngine


def _trend(start, step, n=40):
    return [start + step * i for i in range(n)]


class _FakeBroadcaster:
    def __init__(self):
        self.client_count = 1
        self.sent = []

    async def broadcast(self, msg):
        self.sent.append(msg)


def _feed_with_history(broadcaster=None):
    feed = MarketDataFeed(
        polygon_client=None, broadcaster=broadcaster, bus=None,
        watchlist=["NVDA", "AAPL"], scanner_engine=ScannerEngine(),
    )
    feed._price_history = {
        "NVDA": deque(_trend(100, 1.5), maxlen=80),
        "AAPL": deque(_trend(180, 0.2), maxlen=80),
    }
    return feed


def test_real_scores_once_history_sufficient():
    feed = _feed_with_history()
    scores = feed._real_scanner_scores()
    assert "NVDA" in scores and "AAPL" in scores
    assert all(isinstance(v, float) for v in scores.values())


def test_no_real_scores_without_history():
    feed = MarketDataFeed(polygon_client=None, broadcaster=None, bus=None,
                          scanner_engine=ScannerEngine())
    feed._price_history = {"NVDA": deque([100.0, 101.0], maxlen=80)}  # < 30 bars
    assert feed._real_scanner_scores() == {}


def test_no_engine_means_demo_only():
    feed = MarketDataFeed(polygon_client=None, broadcaster=None, bus=None)  # no engine
    feed._price_history = {"NVDA": deque(_trend(100, 1.5), maxlen=80)}
    assert feed._real_scanner_scores() == {}


async def test_broadcast_uses_rust_engine_flag():
    b = _FakeBroadcaster()
    feed = _feed_with_history(b)
    await feed._broadcast_scanner_opportunities()
    payloads = {m.payload["ticker"]: m.payload for m in b.sent}
    assert payloads["NVDA"]["engine"] == "rust"
    assert payloads["AAPL"]["engine"] == "rust"
    # real composite scores are bounded 0..100
    assert 0.0 <= payloads["NVDA"]["composite_score"] <= 100.0
