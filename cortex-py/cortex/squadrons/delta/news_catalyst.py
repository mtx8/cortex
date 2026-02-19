"""News Catalyst — DELTA squadron intelligence agent.

Monitors news feeds for market-moving catalysts and scores sentiment.
Detects earnings, FDA, merger, insider, congress, and macro catalysts
using keyword-based analysis. Emits delta.news_catalyst signals on the bus.

Scoring method:
- Keyword-based sentiment: positive vs negative word counts
- Score = (pos - neg) / max(pos + neg, 1), range [-1, 1]
- Label: >0.1 positive, <-0.1 negative, else neutral
"""

from collections import deque
from dataclasses import dataclass, field
from enum import Enum
import time
import structlog

from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority
from cortex.orchestrator.signals import SignalTypes
from cortex.squadrons.base import BaseAgent

log = structlog.get_logger()


class CatalystType(str, Enum):
    EARNINGS = "earnings"
    FDA = "fda"
    MERGER = "merger"
    INSIDER = "insider"
    CONGRESS = "congress"
    MACRO = "macro"
    UNKNOWN = "unknown"


@dataclass
class NewsItem:
    headline: str
    source: str
    symbols: list[str]
    published_at: float
    url: str = ""


@dataclass
class SentimentScore:
    score: float  # -1 to 1
    label: str  # positive / negative / neutral
    confidence: float  # abs(score)


# ── Keyword sets ──────────────────────────────────────────────────────

_POSITIVE_WORDS = frozenset({
    "beat", "beats",
    "record",
    "surge", "surges",
    "approval",
    "growth",
    "upgrade", "upgrades",
    "rally", "rallies",
    "breakout",
    "strong",
    "exceeds",
    "raises",
    "guidance",
    "bullish",
    "soars",
})

_NEGATIVE_WORDS = frozenset({
    "miss", "misses",
    "layoff", "layoffs",
    "decline", "declines",
    "warning",
    "loss",
    "downgrade", "downgrades",
    "crash", "crashes",
    "weak",
    "falls",
    "cuts",
    "bearish",
    "plunge", "plunges",
    "deficit",
})

# ── Catalyst keyword mappings ────────────────────────────────────────

_CATALYST_KEYWORDS: list[tuple[CatalystType, frozenset[str]]] = [
    (CatalystType.EARNINGS, frozenset({
        "earnings", "eps", "revenue", "quarterly", "guidance",
    })),
    (CatalystType.FDA, frozenset({
        "fda", "approval", "drug", "clinical", "trial",
    })),
    (CatalystType.MERGER, frozenset({
        "acquisition", "merger", "buyout", "takeover",
    })),
    (CatalystType.INSIDER, frozenset({
        "insider", "ceo", "director", "executive",
    })),
    (CatalystType.CONGRESS, frozenset({
        "congress", "senator", "representative",
    })),
    (CatalystType.MACRO, frozenset({
        "fed", "interest rate", "inflation", "gdp",
    })),
]


class NewsCatalyst(BaseAgent):
    """DELTA intelligence agent — news sentiment and catalyst detection."""

    agent_id = "news_catalyst"
    squadron = "delta"
    subscriptions = [SignalTypes.NEWS_CATALYST]

    def __init__(self, bus: SignalBus):
        super().__init__(bus)
        self._recent: deque[dict] = deque(maxlen=500)
        self._items_processed: int = 0

    # ── Public API ───────────────────────────────────────────────────

    def score_sentiment(self, text: str) -> SentimentScore:
        """Keyword-based sentiment scoring. Returns SentimentScore."""
        words = text.lower().split()
        pos_count = sum(1 for w in words if w.strip(".,!?;:'\"()") in _POSITIVE_WORDS)
        neg_count = sum(1 for w in words if w.strip(".,!?;:'\"()") in _NEGATIVE_WORDS)

        denom = max(pos_count + neg_count, 1)
        score = (pos_count - neg_count) / denom

        if score > 0.1:
            label = "positive"
        elif score < -0.1:
            label = "negative"
        else:
            label = "neutral"

        return SentimentScore(
            score=score,
            label=label,
            confidence=abs(score),
        )

    def detect_catalyst(self, item: NewsItem) -> CatalystType:
        """Detect the catalyst type from a news headline via keyword matching."""
        headline_lower = item.headline.lower()

        for catalyst_type, keywords in _CATALYST_KEYWORDS:
            if catalyst_type == CatalystType.INSIDER:
                # INSIDER requires one of insider/ceo/director/executive
                # AND one of buy/sell in the headline
                has_insider_keyword = any(kw in headline_lower for kw in keywords)
                has_trade_keyword = "buy" in headline_lower or "sell" in headline_lower
                if has_insider_keyword and has_trade_keyword:
                    return CatalystType.INSIDER
            else:
                if any(kw in headline_lower for kw in keywords):
                    return catalyst_type

        return CatalystType.UNKNOWN

    def process_item(self, item: NewsItem) -> dict | None:
        """Score + classify a news item. Returns dict if actionable, else None.

        An item is actionable when it has at least one symbol and
        abs(sentiment score) > 0.1.
        """
        sentiment = self.score_sentiment(item.headline)
        catalyst = self.detect_catalyst(item)

        if not item.symbols or abs(sentiment.score) <= 0.1:
            return None

        result = {
            "symbol": item.symbols[0],
            "symbols": item.symbols,
            "headline": item.headline,
            "source": item.source,
            "sentiment": sentiment.score,
            "sentiment_label": sentiment.label,
            "confidence": sentiment.confidence,
            "catalyst": catalyst.value,
            "published_at": item.published_at,
            "processed_at": time.time(),
        }

        self._recent.append(result)
        self._items_processed += 1
        return result

    def get_recent(self, count: int) -> list[dict]:
        """Return the last *count* processed items from the buffer."""
        items = list(self._recent)
        return items[-count:]

    # ── BaseAgent interface ──────────────────────────────────────────

    async def handle_signal(self, signal: Signal) -> None:
        """Handle delta.news_catalyst signals from the bus."""
        payload = signal.payload
        headline = payload.get("headline", "")
        source = payload.get("source", "unknown")
        symbols = payload.get("symbols", [])
        published_at = payload.get("published_at", time.time())
        url = payload.get("url", "")

        item = NewsItem(
            headline=headline,
            source=source,
            symbols=symbols,
            published_at=published_at,
            url=url,
        )

        result = self.process_item(item)
        if result:
            log.info(
                "news_catalyst.processed",
                symbol=result["symbol"],
                sentiment=result["sentiment"],
                catalyst=result["catalyst"],
            )
            await self.emit(
                SignalTypes.NEWS_CATALYST,
                payload=result,
                priority=SignalPriority.NORMAL,
            )

    def to_dict(self) -> dict:
        base = super().to_dict()
        base.update({
            "items_processed": self._items_processed,
            "recent_count": len(self._recent),
        })
        return base
