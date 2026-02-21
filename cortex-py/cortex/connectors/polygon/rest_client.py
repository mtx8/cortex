"""Polygon.io REST client for market data lookups.

Provides ticker search, previous close, snapshots, and aggregates.
Rate limited to 5 requests/second via aiolimiter.
Includes an in-memory TTL cache to minimize redundant API calls.

API key is passed as a query parameter (apiKey).
"""

import time
from dataclasses import dataclass, field

import httpx
import structlog
from aiolimiter import AsyncLimiter

log = structlog.get_logger()

BASE_URL = "https://api.polygon.io"

# Cache TTLs in seconds
_TTL_QUOTES = 15.0
_TTL_SEARCH = 300.0  # 5 minutes
_TTL_DETAILS = 3600.0  # 1 hour


@dataclass
class _CacheEntry:
    data: object
    expires_at: float


class _TTLCache:
    """Simple in-memory TTL cache keyed by string."""

    def __init__(self):
        self._store: dict[str, _CacheEntry] = {}

    def get(self, key: str) -> object | None:
        entry = self._store.get(key)
        if entry is None:
            return None
        if time.monotonic() > entry.expires_at:
            del self._store[key]
            return None
        return entry.data

    def set(self, key: str, data: object, ttl: float) -> None:
        self._store[key] = _CacheEntry(data=data, expires_at=time.monotonic() + ttl)

    def clear(self) -> None:
        self._store.clear()

    def evict_expired(self) -> int:
        now = time.monotonic()
        expired = [k for k, v in self._store.items() if now > v.expires_at]
        for k in expired:
            del self._store[k]
        return len(expired)


class PolygonRESTClient:
    """Async Polygon.io REST client with rate limiting and caching."""

    def __init__(
        self,
        api_key: str,
        base_url: str = BASE_URL,
        rate_limit: float = 5.0,  # requests per second
    ):
        self._api_key = api_key
        self._base_url = base_url.rstrip("/")
        self._limiter = AsyncLimiter(max_rate=rate_limit, time_period=1.0)
        self._cache = _TTLCache()
        self._client: httpx.AsyncClient | None = None
        self._request_count = 0

    async def _get_client(self) -> httpx.AsyncClient:
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                base_url=self._base_url,
                timeout=httpx.Timeout(10.0),
                headers={"Accept": "application/json"},
            )
        return self._client

    async def close(self) -> None:
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
            self._client = None

    async def _request(self, path: str, params: dict | None = None) -> dict:
        """Make a rate-limited GET request to Polygon API."""
        async with self._limiter:
            client = await self._get_client()
            all_params = {"apiKey": self._api_key}
            if params:
                all_params.update(params)
            self._request_count += 1
            response = await client.get(path, params=all_params)
            response.raise_for_status()
            return response.json()

    async def search_tickers(
        self,
        query: str,
        market: str = "stocks",
        limit: int = 10,
    ) -> list[dict]:
        """Search for tickers matching the query string.

        Returns list of dicts with keys: ticker, name, market, locale, type.
        Cached for 5 minutes.
        """
        cache_key = f"search:{query}:{market}:{limit}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        data = await self._request("/v3/reference/tickers", {
            "search": query,
            "market": market,
            "active": "true",
            "limit": str(limit),
        })

        results = [
            {
                "ticker": r.get("ticker", ""),
                "name": r.get("name", ""),
                "market": r.get("market", ""),
                "locale": r.get("locale", ""),
                "type": r.get("type", ""),
                "currency_name": r.get("currency_name", ""),
            }
            for r in data.get("results", [])
        ]

        self._cache.set(cache_key, results, _TTL_SEARCH)
        log.debug("polygon.search_tickers", query=query, count=len(results))
        return results

    async def get_previous_close(self, ticker: str) -> dict:
        """Get the previous trading day's OHLCV for a ticker.

        Returns dict with keys: ticker, open, high, low, close, volume, vwap.
        Cached for 15s.
        """
        cache_key = f"prev_close:{ticker}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        data = await self._request(f"/v2/aggs/ticker/{ticker}/prev")

        results_list = data.get("results", [])
        if not results_list:
            result = {"ticker": ticker, "error": "no data"}
        else:
            r = results_list[0]
            result = {
                "ticker": ticker,
                "open": r.get("o", 0.0),
                "high": r.get("h", 0.0),
                "low": r.get("l", 0.0),
                "close": r.get("c", 0.0),
                "volume": r.get("v", 0),
                "vwap": r.get("vw", 0.0),
                "timestamp": r.get("t", 0),
            }

        self._cache.set(cache_key, result, _TTL_QUOTES)
        log.debug("polygon.prev_close", ticker=ticker)
        return result

    async def get_snapshots(self, tickers: list[str]) -> list[dict]:
        """Get current snapshot data for multiple tickers.

        Returns list of dicts with: ticker, price, change, change_pct, volume,
        open, high, low, prev_close, updated.
        Cached for 15s per batch key.
        """
        tickers_key = ",".join(sorted(tickers))
        cache_key = f"snapshots:{tickers_key}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        data = await self._request("/v2/snapshot/locale/us/markets/stocks/tickers", {
            "tickers": ",".join(tickers),
        })

        results = []
        for item in data.get("tickers", []):
            day = item.get("day", {})
            prev_day = item.get("prevDay", {})
            last_trade = item.get("lastTrade", {})

            price = last_trade.get("p", day.get("c", 0.0))
            prev_close = prev_day.get("c", 0.0)
            change = price - prev_close if prev_close else 0.0
            change_pct = (change / prev_close * 100) if prev_close else 0.0

            results.append({
                "ticker": item.get("ticker", ""),
                "price": price,
                "change": round(change, 4),
                "change_pct": round(change_pct, 4),
                "volume": day.get("v", 0),
                "open": day.get("o", 0.0),
                "high": day.get("h", 0.0),
                "low": day.get("l", 0.0),
                "prev_close": prev_close,
                "updated": item.get("updated", 0),
            })

        self._cache.set(cache_key, results, _TTL_QUOTES)
        log.debug("polygon.snapshots", count=len(results))
        return results

    async def get_aggregates(
        self,
        ticker: str,
        timespan: str = "day",
        multiplier: int = 1,
        from_date: str = "",
        to_date: str = "",
        limit: int = 120,
    ) -> list[dict]:
        """Get aggregate bars for a ticker.

        Args:
            ticker: Stock ticker symbol.
            timespan: One of: second, minute, hour, day, week, month, quarter, year.
            multiplier: Multiplier for the timespan.
            from_date: Start date (YYYY-MM-DD).
            to_date: End date (YYYY-MM-DD).
            limit: Max number of results.

        Returns list of dicts with: open, high, low, close, volume, vwap, timestamp, n.
        Cached for 1 hour for daily+, 15s for intraday.
        """
        cache_key = f"aggs:{ticker}:{timespan}:{multiplier}:{from_date}:{to_date}:{limit}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        params = {"limit": str(limit), "adjusted": "true", "sort": "asc"}

        path = f"/v2/aggs/ticker/{ticker}/range/{multiplier}/{timespan}/{from_date}/{to_date}"
        data = await self._request(path, params)

        results = [
            {
                "open": r.get("o", 0.0),
                "high": r.get("h", 0.0),
                "low": r.get("l", 0.0),
                "close": r.get("c", 0.0),
                "volume": r.get("v", 0),
                "vwap": r.get("vw", 0.0),
                "timestamp": r.get("t", 0),
                "transactions": r.get("n", 0),
            }
            for r in data.get("results", [])
        ]

        # Use appropriate TTL based on timespan
        ttl = _TTL_DETAILS if timespan in ("day", "week", "month", "quarter", "year") else _TTL_QUOTES
        self._cache.set(cache_key, results, ttl)
        log.debug("polygon.aggregates", ticker=ticker, timespan=timespan, count=len(results))
        return results

    async def get_ticker_details(self, ticker: str) -> dict:
        """Get comprehensive ticker details (name, sector, market cap, etc.).

        Uses /v3/reference/tickers/{ticker} — available on all Polygon plans.
        Returns dict with fundamentals. Cached for 1 hour.
        """
        cache_key = f"details:{ticker}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        try:
            data = await self._request(f"/v3/reference/tickers/{ticker}")
            r = data.get("results", {})
            result = {
                "ticker": r.get("ticker", ticker),
                "name": r.get("name", ticker),
                "market_cap": r.get("market_cap", 0),
                "shares_outstanding": r.get("share_class_shares_outstanding", 0)
                    or r.get("weighted_shares_outstanding", 0),
                "description": r.get("description", ""),
                "sic_code": r.get("sic_code", ""),
                "sic_description": r.get("sic_description", ""),
                "primary_exchange": r.get("primary_exchange", ""),
                "type": r.get("type", ""),
                "locale": r.get("locale", ""),
                "homepage_url": r.get("homepage_url", ""),
                "total_employees": r.get("total_employees", 0),
                "list_date": r.get("list_date", ""),
                "branding": r.get("branding", {}),
            }
            self._cache.set(cache_key, result, _TTL_DETAILS)
            log.debug("polygon.ticker_details", ticker=ticker)
            return result
        except Exception as e:
            log.warning("polygon.ticker_details_error", ticker=ticker, error=str(e))
            return {"ticker": ticker, "name": ticker}

    async def get_news(self, ticker: str, limit: int = 15) -> list[dict]:
        """Get recent news articles for a ticker.

        Uses /v2/reference/news — available on all Polygon plans.
        Returns list of article dicts. Cached for 5 minutes.
        """
        cache_key = f"news:{ticker}:{limit}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        try:
            data = await self._request("/v2/reference/news", {
                "ticker": ticker,
                "limit": str(limit),
            })
            articles = data.get("results", [])
            result = [
                {
                    "id": a.get("id", ""),
                    "title": a.get("title", ""),
                    "source": a.get("publisher", {}).get("name", "Unknown"),
                    "published_at": a.get("published_utc", ""),
                    "url": a.get("article_url", ""),
                    "tickers": a.get("tickers", []),
                }
                for a in articles
            ]
            self._cache.set(cache_key, result, _TTL_SEARCH)
            log.debug("polygon.news", ticker=ticker, count=len(result))
            return result
        except Exception as e:
            log.warning("polygon.news_error", ticker=ticker, error=str(e))
            return []

    async def get_52_week_range(self, ticker: str) -> dict:
        """Calculate 52-week high/low from daily aggregates.

        Returns dict with keys: week_52_high, week_52_low. Cached for 1 hour.
        """
        cache_key = f"52wk:{ticker}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        try:
            from datetime import date, timedelta
            to_date = date.today().isoformat()
            from_date = (date.today() - timedelta(days=365)).isoformat()

            data = await self._request(
                f"/v2/aggs/ticker/{ticker}/range/1/day/{from_date}/{to_date}",
                {"adjusted": "true", "sort": "asc", "limit": "370"},
            )

            results = data.get("results", [])
            if not results:
                return {"week_52_high": 0, "week_52_low": 0}

            highs = [r.get("h", 0) for r in results]
            lows = [r.get("l", float("inf")) for r in results if r.get("l", 0) > 0]

            result = {
                "week_52_high": max(highs) if highs else 0,
                "week_52_low": min(lows) if lows else 0,
            }
            self._cache.set(cache_key, result, _TTL_DETAILS)
            log.debug("polygon.52wk_range", ticker=ticker, high=result["week_52_high"], low=result["week_52_low"])
            return result
        except Exception as e:
            log.warning("polygon.52wk_range_error", ticker=ticker, error=str(e))
            return {"week_52_high": 0, "week_52_low": 0}

    @property
    def request_count(self) -> int:
        return self._request_count

    def clear_cache(self) -> None:
        self._cache.clear()

    def to_dict(self) -> dict:
        return {
            "request_count": self._request_count,
            "base_url": self._base_url,
            "has_api_key": bool(self._api_key),
        }
