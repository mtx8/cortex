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
