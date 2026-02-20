"""Tests for FinancialsAggregator — combines Polygon, EDGAR, and AI analysis."""

import pytest
from unittest.mock import AsyncMock, patch, MagicMock
import orjson

from cortex.feeds.financials import FinancialsAggregator
from cortex.connectors.polygon.rest_client import PolygonRESTClient
from cortex.connectors.sec.edgar_client import EDGARClient
from cortex.intelligence.chat import CortexChat
from cortex.api.protocol import MessageType


# ─── Fixtures ────────────────────────────────────────────────────────

@pytest.fixture
def polygon():
    client = PolygonRESTClient(api_key="test-key")
    return client


@pytest.fixture
def edgar():
    return EDGARClient()


@pytest.fixture
def chat():
    return CortexChat(api_key="test-key")


@pytest.fixture
def aggregator(polygon, edgar, chat):
    return FinancialsAggregator(
        polygon_client=polygon,
        edgar_client=edgar,
        chat=chat,
    )


@pytest.fixture
def aggregator_no_chat(polygon, edgar):
    return FinancialsAggregator(
        polygon_client=polygon,
        edgar_client=edgar,
        chat=None,
    )


@pytest.fixture
def mock_ws():
    """Mock WebSocket for progressive result delivery."""
    ws = AsyncMock()
    ws.send_text = AsyncMock()
    return ws


# ─── Polygon Data Tests ─────────────────────────────────────────────

@pytest.mark.asyncio
async def test_get_polygon_data(aggregator, polygon):
    """Test Polygon data aggregation."""
    with patch.object(
        polygon, "get_snapshots", new_callable=AsyncMock,
        return_value=[{
            "ticker": "AAPL",
            "price": 185.50,
            "change": 2.50,
            "change_pct": 1.37,
            "volume": 50000000,
        }],
    ), patch.object(
        polygon, "get_previous_close", new_callable=AsyncMock,
        return_value={"ticker": "AAPL", "close": 183.0, "volume": 48000000},
    ):
        result = await aggregator._get_polygon_data("AAPL")

    assert result is not None
    assert result["symbol"] == "AAPL"
    assert result["price"] == 185.50
    assert result["change"] == 2.50
    assert result["prev_close"] == 183.0
    await polygon.close()


@pytest.mark.asyncio
async def test_get_polygon_data_error(aggregator, polygon):
    """Test Polygon error returns None."""
    with patch.object(
        polygon, "get_snapshots", new_callable=AsyncMock,
        side_effect=Exception("API error"),
    ):
        result = await aggregator._get_polygon_data("AAPL")

    assert result is None
    await polygon.close()


@pytest.mark.asyncio
async def test_get_polygon_data_empty_snapshots(aggregator, polygon):
    """Test Polygon data when snapshots return empty."""
    with patch.object(
        polygon, "get_snapshots", new_callable=AsyncMock, return_value=[],
    ), patch.object(
        polygon, "get_previous_close", new_callable=AsyncMock,
        return_value={"ticker": "AAPL", "close": 183.0, "volume": 48000000},
    ):
        result = await aggregator._get_polygon_data("AAPL")

    assert result is not None
    assert result["symbol"] == "AAPL"
    assert result["price"] == 183.0  # Falls back to prev close
    await polygon.close()


# ─── EDGAR Data Tests ────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_get_edgar_data(aggregator, edgar):
    """Test EDGAR data aggregation."""
    mock_filings = [
        {"type": "10-K", "filed_date": "2024-11-01", "description": "Annual Report", "url": "http://..."},
    ]
    mock_info = {"name": "Apple Inc.", "cik": "0000320193"}

    with patch.object(
        edgar, "get_filings", new_callable=AsyncMock, return_value=mock_filings,
    ), patch.object(
        edgar, "get_company_info", new_callable=AsyncMock, return_value=mock_info,
    ):
        result = await aggregator._get_edgar_data("AAPL")

    assert result["filings"] == mock_filings
    assert result["company_info"] == mock_info
    await edgar.close()


@pytest.mark.asyncio
async def test_get_edgar_data_error(aggregator, edgar):
    """Test EDGAR error returns empty data."""
    with patch.object(
        edgar, "get_filings", new_callable=AsyncMock, side_effect=Exception("timeout"),
    ):
        result = await aggregator._get_edgar_data("AAPL")

    assert result["filings"] == []
    assert result["company_info"] is None
    await edgar.close()


# ─── News Tests ──────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_get_news(aggregator, polygon):
    """Test news fetching from Polygon."""
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {
        "results": [
            {
                "id": "abc123",
                "title": "Apple Reports Record Earnings",
                "publisher": {"name": "Reuters"},
                "published_utc": "2024-11-01T10:00:00Z",
                "article_url": "https://reuters.com/...",
                "tickers": ["AAPL"],
            },
            {
                "id": "def456",
                "title": "iPhone Sales Surge",
                "publisher": {"name": "Bloomberg"},
                "published_utc": "2024-10-31T08:00:00Z",
                "article_url": "https://bloomberg.com/...",
                "tickers": ["AAPL", "TSM"],
            },
        ]
    }

    mock_http_client = AsyncMock()
    mock_http_client.get = AsyncMock(return_value=mock_resp)

    with patch.object(polygon, "_get_client", new_callable=AsyncMock, return_value=mock_http_client):
        news = await aggregator._get_news("AAPL")

    assert len(news) == 2
    assert news[0]["title"] == "Apple Reports Record Earnings"
    assert news[0]["source"] == "Reuters"
    assert news[1]["tickers"] == ["AAPL", "TSM"]
    await polygon.close()


@pytest.mark.asyncio
async def test_get_news_error(aggregator, polygon):
    """Test news error returns empty list."""
    mock_http_client = AsyncMock()
    mock_http_client.get = AsyncMock(side_effect=Exception("API error"))

    with patch.object(polygon, "_get_client", new_callable=AsyncMock, return_value=mock_http_client):
        news = await aggregator._get_news("AAPL")

    assert news == []
    await polygon.close()


@pytest.mark.asyncio
async def test_get_news_empty_response(aggregator, polygon):
    """Test news with no results."""
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {"results": []}

    mock_http_client = AsyncMock()
    mock_http_client.get = AsyncMock(return_value=mock_resp)

    with patch.object(polygon, "_get_client", new_callable=AsyncMock, return_value=mock_http_client):
        news = await aggregator._get_news("AAPL")

    assert news == []
    await polygon.close()


# ─── AI Analysis Tests ───────────────────────────────────────────────

@pytest.mark.asyncio
async def test_generate_ai_analysis(aggregator, chat):
    """Test AI analysis generation with mock chat."""
    ai_response = "Recommendation: Strong Buy\nKey Risks:\n- Macro headwinds\n- Competition"

    with patch.object(chat, "_get_client", new_callable=AsyncMock, return_value=None):
        # Use the fallback mode — won't produce real analysis
        analysis = await aggregator._generate_ai_analysis(
            "AAPL",
            {"price": 185.0, "market_cap": 2800000000000, "pe_ratio": 29.0, "short_interest": 0.7},
            {"filings": [{"type": "10-K", "filed_date": "2024-11-01"}]},
            [{"title": "Apple earnings beat expectations"}],
        )

    # When SDK is unavailable, the chat yields a fallback message
    assert analysis is not None
    assert analysis["symbol"] == "AAPL"
    assert analysis["recommendation"] in ["Hold", "Buy", "Sell", "Strong Buy", "Strong Sell"]


@pytest.mark.asyncio
async def test_generate_ai_analysis_no_chat(aggregator_no_chat):
    """Test that AI analysis returns None when no chat is configured."""
    analysis = await aggregator_no_chat._generate_ai_analysis("AAPL", None, {}, [])
    assert analysis is None


@pytest.mark.asyncio
async def test_generate_ai_analysis_error(aggregator, chat):
    """Test AI analysis handles errors gracefully."""
    with patch.object(
        chat, "stream_response",
        side_effect=Exception("Claude API error"),
    ):
        analysis = await aggregator._generate_ai_analysis(
            "AAPL", None, {"filings": []}, []
        )

    assert analysis is None


# ─── Recommendation Parsing Tests ────────────────────────────────────

def test_parse_recommendation_strong_buy(aggregator):
    assert aggregator._parse_recommendation("This is a Strong Buy.") == "Strong Buy"


def test_parse_recommendation_strong_sell(aggregator):
    assert aggregator._parse_recommendation("Recommendation: Strong Sell.") == "Strong Sell"


def test_parse_recommendation_buy(aggregator):
    assert aggregator._parse_recommendation("We recommend a Buy at current levels.") == "Buy"


def test_parse_recommendation_sell(aggregator):
    assert aggregator._parse_recommendation("This stock is a clear Sell.") == "Sell"


def test_parse_recommendation_hold(aggregator):
    assert aggregator._parse_recommendation("No clear direction, maintaining neutral stance.") == "Hold"


def test_parse_recommendation_buy_without_sell(aggregator):
    """'Buy' wins when 'sell' does not appear near the buy keyword."""
    text = "Recommendation: Buy. The fundamentals are strong and growth is accelerating."
    assert aggregator._parse_recommendation(text) == "Buy"


def test_parse_recommendation_sell_in_context(aggregator):
    """'selloff' should not trigger a Sell recommendation — word boundaries matter."""
    text = "Recommendation: Buy. Note: there was a selloff recently but that creates opportunity."
    # The parser uses word boundaries, so 'selloff' does not match 'sell'
    assert aggregator._parse_recommendation(text) == "Buy"


# ─── Section Extraction Tests ────────────────────────────────────────

def test_extract_section_risks(aggregator):
    text = """Analysis for AAPL:

Key Risks:
- Macroeconomic headwinds
- Regulatory pressure in EU
- Competition from Samsung

Key Catalysts:
- iPhone 16 launch
"""
    risks = aggregator._extract_section(text, "risk")
    assert len(risks) == 3
    assert "Macroeconomic headwinds" in risks[0]
    assert "Regulatory pressure" in risks[1]
    assert "Competition from Samsung" in risks[2]


def test_extract_section_catalysts(aggregator):
    text = """Key Catalysts:
- iPhone 16 launch
- Services revenue growth
- AI integration

Target Price: $200
"""
    catalysts = aggregator._extract_section(text, "catalyst")
    assert len(catalysts) == 3
    assert "iPhone 16 launch" in catalysts[0]


def test_extract_section_empty(aggregator):
    text = "No relevant sections here."
    items = aggregator._extract_section(text, "risk")
    assert items == []


def test_extract_section_max_five(aggregator):
    text = "## Key Risks:\n" + "\n".join(f"- Risk item {i}" for i in range(10))
    items = aggregator._extract_section(text, "risk")
    assert len(items) <= 5


def test_extract_section_bullet_variants(aggregator):
    text = """Risks:
* First risk
- Second risk
1. Third risk
2) Fourth risk
"""
    items = aggregator._extract_section(text, "risk")
    assert len(items) >= 3  # At least the first 3 should be extracted


# ─── Progressive WebSocket Delivery Tests ────────────────────────────

@pytest.mark.asyncio
async def test_lookup_sends_profile_via_ws(aggregator, polygon, edgar, mock_ws):
    """Test that lookup sends profile data via WebSocket."""
    with patch.object(
        aggregator, "_get_polygon_data", new_callable=AsyncMock,
        return_value={"symbol": "AAPL", "price": 185.50},
    ), patch.object(
        aggregator, "_get_edgar_data", new_callable=AsyncMock,
        return_value={"filings": [], "company_info": None},
    ), patch.object(
        aggregator, "_get_news", new_callable=AsyncMock, return_value=[],
    ), patch.object(
        aggregator, "_generate_ai_analysis", new_callable=AsyncMock, return_value=None,
    ):
        results = await aggregator.lookup("AAPL", ws=mock_ws)

    assert results["profile"]["symbol"] == "AAPL"
    # At least one message sent (profile)
    assert mock_ws.send_text.call_count >= 1

    # Verify the first message is a FINANCIALS_PROFILE
    first_call_arg = mock_ws.send_text.call_args_list[0][0][0]
    parsed = orjson.loads(first_call_arg)
    assert parsed["type"] == "financials_profile"
    assert parsed["payload"]["symbol"] == "AAPL"
    await polygon.close()
    await edgar.close()


@pytest.mark.asyncio
async def test_lookup_sends_filings_via_ws(aggregator, polygon, edgar, mock_ws):
    """Test that lookup sends filings data via WebSocket."""
    mock_filings = [{"type": "10-K", "filed_date": "2024-11-01"}]

    with patch.object(
        aggregator, "_get_polygon_data", new_callable=AsyncMock, return_value=None,
    ), patch.object(
        aggregator, "_get_edgar_data", new_callable=AsyncMock,
        return_value={"filings": mock_filings, "company_info": None},
    ), patch.object(
        aggregator, "_get_news", new_callable=AsyncMock, return_value=[],
    ), patch.object(
        aggregator, "_generate_ai_analysis", new_callable=AsyncMock, return_value=None,
    ):
        results = await aggregator.lookup("AAPL", ws=mock_ws)

    assert results["filings"] == mock_filings
    # Should have sent filings message
    found_filings = False
    for call in mock_ws.send_text.call_args_list:
        parsed = orjson.loads(call[0][0])
        if parsed["type"] == "financials_filings":
            found_filings = True
            assert parsed["payload"]["items"] == mock_filings
    assert found_filings
    await polygon.close()
    await edgar.close()


@pytest.mark.asyncio
async def test_lookup_sends_news_via_ws(aggregator, polygon, edgar, mock_ws):
    """Test that lookup sends news data via WebSocket."""
    mock_news = [{"title": "Breaking: AAPL hits all-time high"}]

    with patch.object(
        aggregator, "_get_polygon_data", new_callable=AsyncMock, return_value=None,
    ), patch.object(
        aggregator, "_get_edgar_data", new_callable=AsyncMock,
        return_value={"filings": [], "company_info": None},
    ), patch.object(
        aggregator, "_get_news", new_callable=AsyncMock, return_value=mock_news,
    ), patch.object(
        aggregator, "_generate_ai_analysis", new_callable=AsyncMock, return_value=None,
    ):
        results = await aggregator.lookup("AAPL", ws=mock_ws)

    assert results["news"] == mock_news
    found_news = False
    for call in mock_ws.send_text.call_args_list:
        parsed = orjson.loads(call[0][0])
        if parsed["type"] == "financials_news":
            found_news = True
            assert parsed["payload"]["items"] == mock_news
    assert found_news
    await polygon.close()
    await edgar.close()


@pytest.mark.asyncio
async def test_lookup_sends_ai_analysis_via_ws(aggregator, polygon, edgar, mock_ws):
    """Test that lookup sends AI analysis via WebSocket."""
    mock_analysis = {"symbol": "AAPL", "recommendation": "Buy", "confidence": 0.7}

    with patch.object(
        aggregator, "_get_polygon_data", new_callable=AsyncMock, return_value=None,
    ), patch.object(
        aggregator, "_get_edgar_data", new_callable=AsyncMock,
        return_value={"filings": [], "company_info": None},
    ), patch.object(
        aggregator, "_get_news", new_callable=AsyncMock, return_value=[],
    ), patch.object(
        aggregator, "_generate_ai_analysis", new_callable=AsyncMock,
        return_value=mock_analysis,
    ):
        results = await aggregator.lookup("AAPL", ws=mock_ws)

    assert results["ai_analysis"] == mock_analysis
    found_analysis = False
    for call in mock_ws.send_text.call_args_list:
        parsed = orjson.loads(call[0][0])
        if parsed["type"] == "financials_ai_analysis":
            found_analysis = True
            assert parsed["payload"]["recommendation"] == "Buy"
    assert found_analysis
    await polygon.close()
    await edgar.close()


@pytest.mark.asyncio
async def test_lookup_no_ws(aggregator, polygon, edgar):
    """Test lookup works without WebSocket (returns dict only)."""
    with patch.object(
        aggregator, "_get_polygon_data", new_callable=AsyncMock,
        return_value={"symbol": "AAPL", "price": 185.0},
    ), patch.object(
        aggregator, "_get_edgar_data", new_callable=AsyncMock,
        return_value={"filings": [], "company_info": None},
    ), patch.object(
        aggregator, "_get_news", new_callable=AsyncMock, return_value=[],
    ), patch.object(
        aggregator, "_generate_ai_analysis", new_callable=AsyncMock, return_value=None,
    ):
        results = await aggregator.lookup("AAPL")

    assert results["profile"]["symbol"] == "AAPL"
    assert results["filings"] == []
    assert results["news"] == []
    await polygon.close()
    await edgar.close()


@pytest.mark.asyncio
async def test_lookup_uppercases_symbol(aggregator, polygon, edgar):
    """Test that lookup normalizes symbol to uppercase."""
    with patch.object(
        aggregator, "_get_polygon_data", new_callable=AsyncMock,
        return_value={"symbol": "AAPL", "price": 185.0},
    ) as mock_polygon, patch.object(
        aggregator, "_get_edgar_data", new_callable=AsyncMock,
        return_value={"filings": [], "company_info": None},
    ), patch.object(
        aggregator, "_get_news", new_callable=AsyncMock, return_value=[],
    ), patch.object(
        aggregator, "_generate_ai_analysis", new_callable=AsyncMock, return_value=None,
    ):
        await aggregator.lookup("aapl")

    # Verify the symbol was uppercased before calling _get_polygon_data
    mock_polygon.assert_called_once_with("AAPL")
    await polygon.close()
    await edgar.close()
