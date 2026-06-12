"""MacroEgressClient Treasury-rates parsing (mocked egress, no network)."""

import orjson
import pytest

import cortex.connectors.macro.client as macro_mod
from cortex.connectors.macro.client import MacroEgressClient


class _FakeResult:
    def __init__(self, body, ok=True, status=200, truncated=False):
        self.body = body
        self.ok = ok
        self.status = status
        self.truncated = truncated


class _FakeCS:
    """Stand-in for the cortex_scanner egress with a canned response."""
    def __init__(self, body):
        self._body = body

    def geo_fetch(self, url, headers, timeout_ms, max_bytes):
        return _FakeResult(self._body)


_TREASURY_BODY = orjson.dumps({
    "data": [
        {"record_date": "2026-05-31", "security_desc": "Treasury Bills", "avg_interest_rate_amt": "5.10"},
        {"record_date": "2026-05-31", "security_desc": "Treasury Bonds", "avg_interest_rate_amt": "4.20"},
        {"record_date": "2026-05-31", "security_desc": "Treasury Notes", "avg_interest_rate_amt": "4.00"},
        {"record_date": "2026-04-30", "security_desc": "Treasury Bills", "avg_interest_rate_amt": "5.00"},
    ]
}).decode()


async def test_treasury_parse_latest_and_spread(monkeypatch):
    monkeypatch.setattr(macro_mod, "_cs", _FakeCS(_TREASURY_BODY))
    client = MacroEgressClient()
    out = await client.fetch_treasury_rates()
    assert out["date"] == "2026-05-31"
    assert out["rates"]["Treasury Bills"] == 5.10
    assert out["short_pct"] == 5.10 and out["long_pct"] == 4.20
    # long minus short = (4.20 - 5.10) * 100 = -90 bps (inverted)
    assert out["spread_bps"] == -90.0
    # only the latest date's rows are kept (the 2026-04-30 row is excluded)
    assert "2026-04-30" not in str(out)


async def test_treasury_empty_on_no_data(monkeypatch):
    monkeypatch.setattr(macro_mod, "_cs", _FakeCS(orjson.dumps({"data": []}).decode()))
    assert await MacroEgressClient().fetch_treasury_rates() == {}


async def test_fred_none_without_key():
    # No FRED key -> graceful None (no network).
    assert await MacroEgressClient(fred_api_key="").fetch_fred_latest("DGS10") is None


_FX_BODY = orjson.dumps({
    "data": [
        {"record_date": "2026-03-31", "country_currency_desc": "Euro Zone-Euro", "exchange_rate": "0.92"},
        {"record_date": "2026-03-31", "country_currency_desc": "Japan-Yen", "exchange_rate": "150.0"},
        {"record_date": "2026-03-31", "country_currency_desc": "Narnia-Gold", "exchange_rate": "1.0"},
        {"record_date": "2025-12-31", "country_currency_desc": "Euro Zone-Euro", "exchange_rate": "0.90"},
    ]
}).decode()


async def test_fx_parse_majors_latest_only(monkeypatch):
    monkeypatch.setattr(macro_mod, "_cs", _FakeCS(_FX_BODY))
    out = await MacroEgressClient().fetch_fx_rates()
    assert out["date"] == "2026-03-31"
    assert out["rates"]["EUR"] == 0.92 and out["rates"]["JPY"] == 150.0
    assert "Narnia-Gold" not in out["rates"]  # non-major excluded
    assert len(out["rates"]) == 2            # old date row excluded
