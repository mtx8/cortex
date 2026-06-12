"""MacroEgressClient — macro / fixed-income data through the hardened Rust egress.

Treasury average interest rates are FREE + KEYLESS (api.fiscaldata.treasury.gov);
FRED series need a free key (graceful no-key fallback). Every request goes through
the same host-allowlisted, https-only egress chokepoint as the geo feeds — keys
never touch the WebView, and a compromised caller still can't reach arbitrary hosts.
"""

from __future__ import annotations

import asyncio
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

    async def _fetch(self, url: str, timeout_ms: int | None = None):
        if _cs is None:
            raise RuntimeError("cortex_scanner egress core not installed")
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(
            None, _cs.geo_fetch, url, None, timeout_ms or self._timeout_ms, 5 * 1024 * 1024
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
