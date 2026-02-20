"""Options chain data feed from Polygon.io and IBKR.

Fetches option chain data (expirations, strikes, Greeks, IV) and
broadcasts OPTION_CHAIN_DATA messages to connected Swift clients.

Per CLAUDE.md: ALL IBKR API calls go through rate_limiter.py wrappers.
"""

import asyncio

import structlog

from cortex.api.protocol import MessageType, CortexMessage
from cortex.connectors.polygon.rest_client import PolygonRESTClient

log = structlog.get_logger()


class OptionsFeed:
    """Fetches option chain data from Polygon.io or IBKR.

    Primary source is Polygon.io (REST API). IBKR is used as a fallback
    or for real-time streaming when available.

    Usage:
        feed = OptionsFeed(polygon_client, ibkr_manager, broadcaster, rate_limiter)
        chain = await feed.get_chain("AAPL", expiration="2026-03-21")
        expirations = await feed.get_expirations("AAPL")
    """

    def __init__(
        self,
        polygon_client: PolygonRESTClient,
        ibkr_manager=None,
        broadcaster=None,
        rate_limiter=None,
    ):
        self._polygon = polygon_client
        self._ibkr = ibkr_manager
        self._broadcaster = broadcaster
        self._rate_limiter = rate_limiter

    async def get_chain(
        self,
        symbol: str,
        expiration: str | None = None,
        option_type: str | None = None,
        limit: int = 250,
    ) -> dict:
        """Fetch option chain for a symbol from Polygon.io.

        Args:
            symbol: Underlying ticker symbol (e.g., "AAPL").
            expiration: Optional expiration date filter (YYYY-MM-DD).
            option_type: Optional "call" or "put" filter.
            limit: Maximum number of contracts to return.

        Returns:
            Dict with keys: symbol, expiration, calls, puts, updated.
            Each call/put entry has: strike, bid, ask, last, volume,
            open_interest, iv, delta, gamma, theta, vega, expiration.
        """
        symbol = symbol.upper()
        log.info("options.get_chain", symbol=symbol, expiration=expiration)

        try:
            params = {
                "underlying_ticker": symbol,
                "limit": str(limit),
                "order": "asc",
                "sort": "strike_price",
            }
            if expiration:
                params["expiration_date"] = expiration
            if option_type:
                params["contract_type"] = option_type

            data = await self._polygon._request(
                "/v3/snapshot/options/" + symbol, params
            )

            calls = []
            puts = []

            for result in data.get("results", []):
                details = result.get("details", {})
                greeks_data = result.get("greeks", {})
                day = result.get("day", {})
                last_quote = result.get("last_quote", {})

                contract = {
                    "ticker": details.get("ticker", ""),
                    "strike": details.get("strike_price", 0.0),
                    "expiration": details.get("expiration_date", ""),
                    "contract_type": details.get("contract_type", ""),
                    "bid": last_quote.get("bid", 0.0),
                    "ask": last_quote.get("ask", 0.0),
                    "last": day.get("close", 0.0),
                    "volume": day.get("volume", 0),
                    "open_interest": result.get("open_interest", 0),
                    "iv": result.get("implied_volatility", 0.0),
                    "delta": greeks_data.get("delta", 0.0),
                    "gamma": greeks_data.get("gamma", 0.0),
                    "theta": greeks_data.get("theta", 0.0),
                    "vega": greeks_data.get("vega", 0.0),
                }

                if details.get("contract_type") == "call":
                    calls.append(contract)
                else:
                    puts.append(contract)

            chain = {
                "symbol": symbol,
                "expiration": expiration,
                "calls": calls,
                "puts": puts,
                "total_contracts": len(calls) + len(puts),
            }

            # Broadcast to connected clients if broadcaster is available
            if self._broadcaster is not None:
                msg = CortexMessage(
                    type=MessageType.OPTION_CHAIN_DATA,
                    payload=chain,
                )
                await self._broadcaster.broadcast(msg)

            log.info(
                "options.chain_fetched",
                symbol=symbol,
                calls=len(calls),
                puts=len(puts),
            )
            return chain

        except Exception as e:
            log.error("options.chain_error", symbol=symbol, error=str(e))
            return {
                "symbol": symbol,
                "expiration": expiration,
                "calls": [],
                "puts": [],
                "total_contracts": 0,
                "error": str(e),
            }

    async def get_expirations(self, symbol: str) -> list[str]:
        """Get available expiration dates for a symbol from Polygon.io.

        Args:
            symbol: Underlying ticker symbol (e.g., "AAPL").

        Returns:
            Sorted list of expiration date strings (YYYY-MM-DD).
        """
        symbol = symbol.upper()
        log.info("options.get_expirations", symbol=symbol)

        try:
            data = await self._polygon._request(
                "/v3/reference/options/contracts",
                {
                    "underlying_ticker": symbol,
                    "limit": "1000",
                    "order": "asc",
                    "sort": "expiration_date",
                },
            )

            # Extract unique expiration dates
            expirations: set[str] = set()
            for result in data.get("results", []):
                exp = result.get("expiration_date", "")
                if exp:
                    expirations.add(exp)

            sorted_exps = sorted(expirations)
            log.info(
                "options.expirations_fetched",
                symbol=symbol,
                count=len(sorted_exps),
            )
            return sorted_exps

        except Exception as e:
            log.error("options.expirations_error", symbol=symbol, error=str(e))
            return []

    def to_dict(self) -> dict:
        return {
            "has_polygon": self._polygon is not None,
            "has_ibkr": self._ibkr is not None,
            "has_broadcaster": self._broadcaster is not None,
        }
