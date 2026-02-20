"""Tests for SEC EDGAR API client."""

import pytest
from unittest.mock import AsyncMock, patch, MagicMock

from cortex.connectors.sec.edgar_client import EDGARClient, _cik_cache


# ─── Fixtures ────────────────────────────────────────────────────────

@pytest.fixture(autouse=True)
def clear_cik_cache():
    """Clear the module-level CIK cache between tests."""
    _cik_cache.clear()
    yield
    _cik_cache.clear()


@pytest.fixture
def edgar():
    return EDGARClient()


# ─── CIK Lookup Tests ───────────────────────────────────────────────

@pytest.mark.asyncio
async def test_get_cik_found(edgar):
    """Test CIK lookup when ticker is found."""
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {
        "0": {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc."},
        "1": {"cik_str": 789019, "ticker": "MSFT", "title": "Microsoft Corp"},
    }

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        cik = await edgar.get_cik("AAPL")

    assert cik == "0000320193"
    await edgar.close()


@pytest.mark.asyncio
async def test_get_cik_not_found(edgar):
    """Test CIK lookup when ticker doesn't exist."""
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {
        "0": {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc."},
    }

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        cik = await edgar.get_cik("FAKESYMBOL")

    assert cik is None
    await edgar.close()


@pytest.mark.asyncio
async def test_get_cik_cached(edgar):
    """Test that CIK lookups are cached."""
    _cik_cache["AAPL"] = "0000320193"
    cik = await edgar.get_cik("AAPL")
    assert cik == "0000320193"
    await edgar.close()


@pytest.mark.asyncio
async def test_get_cik_case_insensitive(edgar):
    """Test that CIK lookup normalizes to uppercase."""
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {
        "0": {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc."},
    }

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        cik = await edgar.get_cik("aapl")

    assert cik == "0000320193"
    await edgar.close()


@pytest.mark.asyncio
async def test_get_cik_network_error(edgar):
    """Test CIK lookup gracefully handles network errors."""
    with patch.object(
        edgar._client, "get", new_callable=AsyncMock, side_effect=Exception("Connection refused")
    ):
        cik = await edgar.get_cik("AAPL")

    assert cik is None
    await edgar.close()


# ─── Filings Tests ──────────────────────────────────────────────────

MOCK_SUBMISSIONS = {
    "name": "Apple Inc.",
    "cik": "0000320193",
    "sic": "3571",
    "sicDescription": "Electronic Computers",
    "exchanges": ["Nasdaq"],
    "stateOfIncorporation": "CA",
    "fiscalYearEnd": "0930",
    "filings": {
        "recent": {
            "form": ["10-K", "10-Q", "8-K", "4", "SC 13G"],
            "filingDate": ["2024-11-01", "2024-08-02", "2024-07-15", "2024-06-20", "2024-05-10"],
            "primaryDocDescription": [
                "Annual Report",
                "Quarterly Report",
                "Current Report",
                "Statement of Changes",
                "Beneficial Ownership",
            ],
            "accessionNumber": [
                "0000320193-24-000100",
                "0000320193-24-000080",
                "0000320193-24-000070",
                "0000320193-24-000060",
                "0000320193-24-000050",
            ],
            "primaryDocument": [
                "aapl-20240928.htm",
                "aapl-20240629.htm",
                "aapl-20240715.htm",
                "xslForm4X01.htm",
                "sc13g.htm",
            ],
        }
    },
}


@pytest.mark.asyncio
async def test_get_filings(edgar):
    """Test fetching filings with no type filter."""
    _cik_cache["AAPL"] = "0000320193"

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = MOCK_SUBMISSIONS

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        filings = await edgar.get_filings("AAPL")

    assert len(filings) == 5
    assert filings[0]["type"] == "10-K"
    assert filings[0]["filed_date"] == "2024-11-01"
    assert filings[0]["description"] == "Annual Report"
    assert "Archives/edgar" in filings[0]["url"]
    await edgar.close()


@pytest.mark.asyncio
async def test_get_filings_filtered(edgar):
    """Test fetching filings filtered by type."""
    _cik_cache["AAPL"] = "0000320193"

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = MOCK_SUBMISSIONS

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        filings = await edgar.get_filings("AAPL", filing_types=["10-K", "10-Q"])

    assert len(filings) == 2
    assert filings[0]["type"] == "10-K"
    assert filings[1]["type"] == "10-Q"
    await edgar.close()


@pytest.mark.asyncio
async def test_get_filings_limit(edgar):
    """Test that the limit parameter is respected."""
    _cik_cache["AAPL"] = "0000320193"

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = MOCK_SUBMISSIONS

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        filings = await edgar.get_filings("AAPL", limit=2)

    assert len(filings) == 2
    await edgar.close()


@pytest.mark.asyncio
async def test_get_filings_no_cik(edgar):
    """Test that missing CIK returns empty list."""
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {}

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        filings = await edgar.get_filings("FAKESYM")

    assert filings == []
    await edgar.close()


@pytest.mark.asyncio
async def test_get_filings_api_error(edgar):
    """Test that API errors return empty list."""
    _cik_cache["AAPL"] = "0000320193"

    mock_resp = MagicMock()
    mock_resp.status_code = 500
    mock_resp.json.return_value = {}

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        filings = await edgar.get_filings("AAPL")

    assert filings == []
    await edgar.close()


@pytest.mark.asyncio
async def test_get_filings_network_error(edgar):
    """Test that network errors return empty list."""
    _cik_cache["AAPL"] = "0000320193"

    with patch.object(
        edgar._client, "get", new_callable=AsyncMock, side_effect=Exception("timeout")
    ):
        filings = await edgar.get_filings("AAPL")

    assert filings == []
    await edgar.close()


# ─── Company Info Tests ──────────────────────────────────────────────

@pytest.mark.asyncio
async def test_get_company_info(edgar):
    """Test fetching company info."""
    _cik_cache["AAPL"] = "0000320193"

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = MOCK_SUBMISSIONS

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        info = await edgar.get_company_info("AAPL")

    assert info is not None
    assert info["name"] == "Apple Inc."
    assert info["cik"] == "0000320193"
    assert info["sic"] == "3571"
    assert info["sic_description"] == "Electronic Computers"
    assert info["ticker"] == "AAPL"
    assert info["exchange"] == "Nasdaq"
    assert info["state"] == "CA"
    assert info["fiscal_year_end"] == "0930"
    await edgar.close()


@pytest.mark.asyncio
async def test_get_company_info_no_cik(edgar):
    """Test company info returns None when CIK not found."""
    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = {}

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        info = await edgar.get_company_info("FAKESYM")

    assert info is None
    await edgar.close()


@pytest.mark.asyncio
async def test_get_company_info_api_error(edgar):
    """Test company info returns None on API error."""
    _cik_cache["AAPL"] = "0000320193"

    mock_resp = MagicMock()
    mock_resp.status_code = 404

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        info = await edgar.get_company_info("AAPL")

    assert info is None
    await edgar.close()


@pytest.mark.asyncio
async def test_get_company_info_no_exchanges(edgar):
    """Test company info handles missing exchanges list."""
    _cik_cache["AAPL"] = "0000320193"

    mock_data = dict(MOCK_SUBMISSIONS)
    mock_data = {**mock_data, "exchanges": []}

    mock_resp = MagicMock()
    mock_resp.status_code = 200
    mock_resp.json.return_value = mock_data

    with patch.object(edgar._client, "get", new_callable=AsyncMock, return_value=mock_resp):
        info = await edgar.get_company_info("AAPL")

    assert info is not None
    assert info["exchange"] == ""
    await edgar.close()


# ─── Close Tests ─────────────────────────────────────────────────────

@pytest.mark.asyncio
async def test_close(edgar):
    """Test client close."""
    with patch.object(edgar._client, "aclose", new_callable=AsyncMock) as mock_close:
        await edgar.close()
        mock_close.assert_called_once()
