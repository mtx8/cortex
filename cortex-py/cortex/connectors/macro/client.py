"""MacroEgressClient — macro / fixed-income data through the hardened Rust egress.

Treasury average interest rates are FREE + KEYLESS (api.fiscaldata.treasury.gov);
FRED series need a free key (graceful no-key fallback). Every request goes through
the same host-allowlisted, https-only egress chokepoint as the geo feeds — keys
never touch the WebView, and a compromised caller still can't reach arbitrary hosts.
"""

from __future__ import annotations

import asyncio
import datetime
import xml.etree.ElementTree as ET

import structlog

log = structlog.get_logger()

try:
    import cortex_scanner as _cs  # type: ignore
except ImportError:  # pragma: no cover
    _cs = None

# Treasury "Average Interest Rates on U.S. Treasury Securities" — keyless, monthly.
# page[size] brackets must be percent-encoded.
TREASURY_AVG_RATES = (
    "https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v2/"
    "accounting/od/avg_interest_rates?sort=-record_date&page%5Bsize%5D=40"
)
FRED_OBSERVATIONS = "https://api.stlouisfed.org/fred/series/observations"
# Treasury "Daily Treasury Par Yield Curve Rates" — keyless Atom/XML, one entry
# per business day for the requested month. This is the canonical par-yield curve
# used to compute 2s10s / 3m10s, a real upgrade over the average-rate proxy.
PAR_YIELD_CURVE = (
    "https://home.treasury.gov/resource-center/data-chart-center/interest-rates/"
    "pages/xml?data=daily_treasury_yield_curve&field_tdr_date_value_month={ym}"
)
# Atom / ADO.NET dataservices namespaces used by the Treasury XML feed.
_ATOM_NS = "{http://www.w3.org/2005/Atom}"
_D_NS = "{http://schemas.microsoft.com/ado/2007/08/dataservices}"
# The <m:properties> wrapper is in the METADATA namespace; the fields inside are d:.
_M_NS = "{http://schemas.microsoft.com/ado/2007/08/dataservices/metadata}"
# Treasury BC_* property name -> short tenor label used in the curve dict.
_PAR_TENORS = {
    "BC_1MONTH": "1Mo", "BC_2MONTH": "2Mo", "BC_3MONTH": "3Mo", "BC_4MONTH": "4Mo",
    "BC_6MONTH": "6Mo", "BC_1YEAR": "1Yr", "BC_2YEAR": "2Yr", "BC_3YEAR": "3Yr",
    "BC_5YEAR": "5Yr", "BC_7YEAR": "7Yr", "BC_10YEAR": "10Yr", "BC_20YEAR": "20Yr",
    "BC_30YEAR": "30Yr",
}
# home.treasury.gov sits behind bot-mitigation that rejects non-browser clients.
# This is a PUBLIC gov data feed, so we present a browser UA for THIS host only.
# The Rust egress still enforces the exact-host allowlist + https + port-443 + byte
# cap + redirect containment, so this is a per-feed header, not a security relaxation.
_BROWSER_HEADERS = {
    "User-Agent": ("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                   "AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17 Safari/605.1.15"),
    "Accept": "application/atom+xml,application/xml,text/xml,*/*",
}
# Treasury "Rates of Exchange" — keyless USD reference FX (units of currency per USD).
FX_RATES = (
    "https://api.fiscaldata.treasury.gov/services/api/fiscal_service/v1/"
    "accounting/od/rates_of_exchange?fields=record_date,country_currency_desc,exchange_rate"
    "&sort=-record_date&page%5Bsize%5D=200"
)
_FX_MAJORS = {
    "Euro Zone-Euro": "EUR", "Japan-Yen": "JPY", "China-Yuan Renminbi": "CNY",
    "United Kingdom-Pound": "GBP", "Canada-Dollar": "CAD", "Switzerland-Franc": "CHF",
    "Australia-Dollar": "AUD", "Mexico-Peso": "MXN", "India-Rupee": "INR", "Brazil-Real": "BRL",
}

# Map a Treasury security_desc -> a short tenor bucket for spread/curve logic.
_SHORT_DESCS = {"Treasury Bills"}
_LONG_DESCS = {"Treasury Bonds"}


class MacroEgressClient:
    def __init__(self, fred_api_key: str = "", default_timeout_ms: int = 12000):
        self._fred_key = fred_api_key
        self._timeout_ms = default_timeout_ms

    @property
    def available(self) -> bool:
        return _cs is not None

    async def _fetch(self, url: str, timeout_ms: int | None = None, headers: dict | None = None):
        if _cs is None:
            raise RuntimeError("cortex_scanner egress core not installed")
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            None, _cs.geo_fetch, url, headers, timeout_ms or self._timeout_ms, 5 * 1024 * 1024
        )

    async def fetch_treasury_rates(self) -> dict:
        """Latest Treasury average interest rates. Returns
        {date, rates: {security_desc: pct}, short_pct, long_pct, spread_bps} or {}."""
        if _cs is None:
            return {}
        try:
            res = await self._fetch(TREASURY_AVG_RATES)
        except Exception as e:
            log.warning("macro.treasury_error", error=str(e))
            return {}
        if not res.ok:
            log.warning("macro.treasury_http", status=res.status)
            return {}
        try:
            import orjson
            data = orjson.loads(res.body)
        except Exception as e:
            log.warning("macro.treasury_parse", error=str(e))
            return {}
        rows = data.get("data", []) if isinstance(data, dict) else []
        if not rows:
            return {}
        # Rows are sorted by -record_date; keep only the most recent date's rows.
        latest = rows[0].get("record_date")
        rates: dict[str, float] = {}
        for r in rows:
            if r.get("record_date") != latest:
                break
            desc = r.get("security_desc", "")
            try:
                rates[desc] = float(r.get("avg_interest_rate_amt"))
            except (TypeError, ValueError):
                continue
        short = next((rates[d] for d in _SHORT_DESCS if d in rates), None)
        long = next((rates[d] for d in _LONG_DESCS if d in rates), None)
        spread_bps = round((long - short) * 100, 1) if (short is not None and long is not None) else None
        return {
            "date": latest,
            "rates": rates,
            "short_pct": short,
            "long_pct": long,
            "spread_bps": spread_bps,   # long minus short; negative ≈ inverted
        }

    def _parse_par_yield_xml(self, body: str) -> dict:
        """Parse the Treasury daily par-yield Atom/XML into the LATEST day's curve.
        Returns {} on any malformed/empty input (never raises). Tolerant of
        missing tenors. Entries are ascending by date, so the latest is the last
        well-dated entry we can parse."""
        try:
            root = ET.fromstring(body)
        except ET.ParseError as e:
            log.warning("macro.par_curve_parse", error=str(e))
            return {}
        best: dict | None = None
        best_date = ""
        for entry in root.iter(f"{_ATOM_NS}entry"):
            props = entry.find(f"{_ATOM_NS}content/{_M_NS}properties")
            if props is None:
                continue
            raw_date = props.findtext(f"{_D_NS}NEW_DATE")
            if not raw_date:
                continue
            # "2026-06-12T00:00:00" -> "2026-06-12"
            date = raw_date.split("T", 1)[0]
            tenors: dict[str, float] = {}
            for field, label in _PAR_TENORS.items():
                txt = props.findtext(f"{_D_NS}{field}")
                if txt is None or txt == "":
                    continue
                try:
                    tenors[label] = float(txt)
                except (TypeError, ValueError):
                    continue
            if not tenors:
                continue
            # Keep the chronologically latest dated entry (ISO dates sort lexically).
            if date >= best_date:
                best_date = date
                best = {"date": date, "tenors": tenors}
        if best is None:
            return {}
        tenors = best["tenors"]

        def _spread(long_label: str, short_label: str) -> float | None:
            lo, sh = tenors.get(long_label), tenors.get(short_label)
            if lo is None or sh is None:
                return None
            return round((lo - sh) * 100, 1)  # pct points -> bps

        best["spread_2s10s_bps"] = _spread("10Yr", "2Yr")
        best["spread_3m10s_bps"] = _spread("10Yr", "3Mo")
        return best

    async def fetch_par_yield_curve(self) -> dict:
        """Latest Treasury daily PAR-yield curve (canonical 2s10s / 3m10s). Returns
        {date, tenors:{1Mo:.., 3Mo:.., 2Yr:.., 10Yr:.., 30Yr:..},
         spread_2s10s_bps, spread_3m10s_bps} or {} on any failure (never raises).
        2s10s = 10Yr - 2Yr; 3m10s = 10Yr - 3Mo (bps); negative = inverted."""
        if _cs is None:
            return {}
        ym = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m")
        url = PAR_YIELD_CURVE.format(ym=ym)
        try:
            # Treasury is slow + bot-gated: longer timeout + browser UA for this host.
            res = await self._fetch(url, timeout_ms=30000, headers=_BROWSER_HEADERS)
        except Exception as e:
            log.warning("macro.par_curve_error", error=str(e))
            return {}
        if not res.ok:
            log.warning("macro.par_curve_http", status=res.status)
            return {}
        if res.truncated:
            # A truncated Atom feed can split an entry; refuse partial curve data.
            log.warning("macro.par_curve_truncated")
            return {}
        return self._parse_par_yield_xml(res.body)

    async def fetch_fx_rates(self) -> dict:
        """Latest USD reference FX for major currencies (keyless). Returns
        {date, rates: {EUR: units_per_USD, ...}} or {}. These are quarterly Treasury
        reporting rates — reference levels, not a real-time bid/ask feed."""
        if _cs is None:
            return {}
        try:
            res = await self._fetch(FX_RATES)
        except Exception as e:
            log.warning("macro.fx_error", error=str(e))
            return {}
        if not res.ok:
            return {}
        try:
            import orjson
            data = orjson.loads(res.body)
        except Exception as e:
            log.warning("macro.fx_parse", error=str(e))
            return {}
        rows = data.get("data", []) if isinstance(data, dict) else []
        if not rows:
            return {}
        latest = rows[0].get("record_date")
        out: dict[str, float] = {}
        for r in rows:
            if r.get("record_date") != latest:
                continue
            code = _FX_MAJORS.get(r.get("country_currency_desc", ""))
            if not code:
                continue
            try:
                out[code] = float(r.get("exchange_rate"))
            except (TypeError, ValueError):
                continue
        return {"date": latest, "rates": out}

    async def fetch_fred_latest(self, series_id: str) -> float | None:
        """Latest observation for a FRED series (e.g. DGS10). Needs a free key;
        returns None without one (graceful)."""
        if _cs is None or not self._fred_key:
            return None
        url = (f"{FRED_OBSERVATIONS}?series_id={series_id}&api_key={self._fred_key}"
               f"&file_type=json&sort_order=desc&limit=1")
        try:
            res = await self._fetch(url)
            if not res.ok:
                return None
            import orjson
            obs = orjson.loads(res.body).get("observations", [])
            if obs:
                return float(obs[0]["value"])
        except Exception as e:
            log.warning("macro.fred_error", series=series_id, error=str(e))
        return None

    def to_dict(self) -> dict:
        return {"available": self.available, "fred_key": bool(self._fred_key)}
