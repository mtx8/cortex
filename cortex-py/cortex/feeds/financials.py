"""Financials data aggregator — combines Polygon, EDGAR, and AI for comprehensive stock research."""

import asyncio
import structlog

from cortex.api.protocol import MessageType, CortexMessage, encode_message
from cortex.connectors.polygon.rest_client import PolygonRESTClient
from cortex.connectors.sec.edgar_client import EDGARClient
from cortex.intelligence.chat import CortexChat

log = structlog.get_logger()


class FinancialsAggregator:
    """Aggregates financial data from multiple sources for stock research."""

    def __init__(
        self,
        polygon_client: PolygonRESTClient,
        edgar_client: EDGARClient,
        chat: CortexChat | None = None,
    ):
        self._polygon = polygon_client
        self._edgar = edgar_client
        self._chat = chat

    async def lookup(self, symbol: str, broadcaster=None, ws=None) -> dict:
        """Full financial lookup for a symbol. Sends results progressively via WebSocket."""
        symbol = symbol.upper()
        results = {}

        # Run Polygon and EDGAR lookups in parallel
        polygon_task = asyncio.create_task(self._get_polygon_data(symbol))
        edgar_task = asyncio.create_task(self._get_edgar_data(symbol))

        # Get Polygon data first (usually faster)
        polygon_data = await polygon_task
        if polygon_data and ws:
            msg = CortexMessage(type=MessageType.FINANCIALS_PROFILE, payload=polygon_data)
            await ws.send_text(encode_message(msg))
        results["profile"] = polygon_data

        # Get EDGAR data
        edgar_data = await edgar_task
        if edgar_data.get("filings") and ws:
            msg = CortexMessage(
                type=MessageType.FINANCIALS_FILINGS,
                payload={"items": edgar_data["filings"]},
            )
            await ws.send_text(encode_message(msg))
        results["filings"] = edgar_data.get("filings", [])

        # Get news from Polygon
        news = await self._get_news(symbol)
        if news and ws:
            msg = CortexMessage(
                type=MessageType.FINANCIALS_NEWS,
                payload={"items": news},
            )
            await ws.send_text(encode_message(msg))
        results["news"] = news

        # Generate AI analysis if chat is available
        if self._chat:
            ai_analysis = await self._generate_ai_analysis(symbol, polygon_data, edgar_data, news)
            if ai_analysis and ws:
                msg = CortexMessage(
                    type=MessageType.FINANCIALS_AI_ANALYSIS,
                    payload=ai_analysis,
                )
                await ws.send_text(encode_message(msg))
            results["ai_analysis"] = ai_analysis

        return results

    async def _get_polygon_data(self, symbol: str) -> dict | None:
        """Get stock profile data from Polygon."""
        try:
            # Get snapshot for current price
            snapshots = await self._polygon.get_snapshots([symbol])
            snapshot = snapshots[0] if snapshots else {}

            # Get previous close for change data
            prev = await self._polygon.get_previous_close(symbol)

            profile = {
                "symbol": symbol,
                "price": snapshot.get("price", prev.get("close", 0)),
                "change": snapshot.get("change", 0),
                "change_percent": snapshot.get("change_pct", 0),
                "volume": snapshot.get("volume", 0),
                "market_cap": snapshot.get("market_cap", 0),
                "name": snapshot.get("name", symbol),
                "sector": snapshot.get("sector", "Unknown"),
                "industry": snapshot.get("industry", "Unknown"),
                "exchange": snapshot.get("exchange", ""),
                "shares_outstanding": snapshot.get("shares_outstanding", 0),
                "float": snapshot.get("float", 0),
                "short_interest": snapshot.get("short_interest", 0),
                "short_ratio": snapshot.get("short_ratio", 0),
                "avg_volume": snapshot.get("avg_volume", 0),
                "week_52_high": snapshot.get("week52_high", 0),
                "week_52_low": snapshot.get("week52_low", 0),
                "pe_ratio": snapshot.get("pe_ratio"),
                "forward_pe": snapshot.get("forward_pe"),
                "dividend_yield": snapshot.get("dividend_yield"),
                "beta": snapshot.get("beta"),
                "prev_close": prev.get("close", 0),
                "prev_volume": prev.get("volume", 0),
            }
            return profile
        except Exception as e:
            log.error("financials.polygon_error", symbol=symbol, error=str(e))
            return None

    async def _get_edgar_data(self, symbol: str) -> dict:
        """Get SEC filings and company info from EDGAR."""
        try:
            filings = await self._edgar.get_filings(
                symbol,
                filing_types=["10-K", "10-Q", "8-K", "4", "SC 13G", "SC 13D"],
                limit=20,
            )
            company_info = await self._edgar.get_company_info(symbol)
            return {
                "filings": filings,
                "company_info": company_info,
            }
        except Exception as e:
            log.error("financials.edgar_error", symbol=symbol, error=str(e))
            return {"filings": [], "company_info": None}

    async def _get_news(self, symbol: str) -> list[dict]:
        """Get news from Polygon news API."""
        try:
            # Polygon has a news endpoint — /v2/reference/news?ticker=AAPL
            client = await self._polygon._get_client()
            resp = await client.get(
                "/v2/reference/news",
                params={
                    "ticker": symbol,
                    "limit": 15,
                    "apiKey": self._polygon._api_key,
                },
            )
            if resp.status_code != 200:
                return []

            data = resp.json()
            articles = data.get("results", [])

            news_items = []
            for article in articles:
                news_items.append({
                    "id": article.get("id", ""),
                    "title": article.get("title", ""),
                    "source": article.get("publisher", {}).get("name", "Unknown"),
                    "published_at": article.get("published_utc", ""),
                    "url": article.get("article_url", ""),
                    "sentiment": "neutral",  # Polygon doesn't provide sentiment
                    "tickers": [t for t in article.get("tickers", [])],
                })

            return news_items
        except Exception as e:
            log.error("financials.news_error", symbol=symbol, error=str(e))
            return []

    async def _generate_ai_analysis(
        self,
        symbol: str,
        profile: dict | None,
        edgar_data: dict,
        news: list,
    ) -> dict | None:
        """Generate AI analysis using Claude."""
        if not self._chat:
            return None

        try:
            # Build a focused analysis prompt
            context_parts = [f"Analyze {symbol} for trading opportunities (both long and short)."]

            if profile:
                context_parts.append(f"Price: ${profile.get('price', 'N/A')}")
                context_parts.append(f"Market Cap: ${profile.get('market_cap', 'N/A')}")
                context_parts.append(f"P/E: {profile.get('pe_ratio', 'N/A')}")
                context_parts.append(f"Short Interest: {profile.get('short_interest', 0)}%")

            if news:
                headlines = [n["title"] for n in news[:5]]
                context_parts.append(f"Recent headlines: {'; '.join(headlines)}")

            if edgar_data.get("filings"):
                recent_filings = [
                    f"{f['type']} ({f['filed_date']})" for f in edgar_data["filings"][:5]
                ]
                context_parts.append(f"Recent SEC filings: {', '.join(recent_filings)}")

            prompt = "\n".join(context_parts)
            prompt += (
                "\n\nProvide: 1) Buy/Hold/Sell recommendation, 2) Short opportunity assessment, "
                "3) Key risks, 4) Key catalysts, 5) Support/resistance levels, 6) Target price, "
                "7) Confidence level (0-100%). Be specific and actionable."
            )

            # Collect the full response (not streaming for analysis)
            full_response = ""
            async for chunk in self._chat.stream_response(
                prompt, conversation_id=f"analysis_{symbol}"
            ):
                full_response += chunk

            # Parse the response into structured data
            analysis = {
                "symbol": symbol,
                "recommendation": self._parse_recommendation(full_response),
                "short_opportunity": (
                    "short" in full_response.lower()
                    and (
                        "opportunity" in full_response.lower()
                        or "candidate" in full_response.lower()
                    )
                ),
                "summary": full_response[:500],
                "full_analysis": full_response,
                "key_risks": self._extract_section(full_response, "risk"),
                "key_catalysts": self._extract_section(full_response, "catalyst"),
                "confidence": 0.7,  # Default confidence
            }
            return analysis
        except Exception as e:
            log.error("financials.ai_analysis_error", symbol=symbol, error=str(e))
            return None

    def _parse_recommendation(self, text: str) -> str:
        """Extract recommendation from AI response text."""
        import re
        text_lower = text.lower()
        if "strong buy" in text_lower:
            return "Strong Buy"
        elif "strong sell" in text_lower:
            return "Strong Sell"
        elif re.search(r"\bbuy\b", text_lower) and not re.search(
            r"\bsell\b", text_lower[: text_lower.index("buy") + 50]
        ):
            return "Buy"
        elif re.search(r"\bsell\b", text_lower):
            return "Sell"
        return "Hold"

    def _extract_section(self, text: str, keyword: str) -> list[str]:
        """Extract bullet points from a section of the AI response."""
        lines = text.split("\n")
        in_section = False
        items = []
        for line in lines:
            line_lower = line.lower().strip()
            if keyword in line_lower and (":" in line or "#" in line):
                in_section = True
                continue
            elif in_section:
                if line.strip().startswith(("-", "*", "\u2022", "1", "2", "3", "4", "5")):
                    cleaned = line.strip().lstrip("-*\u20220123456789.) ")
                    if cleaned:
                        items.append(cleaned)
                elif line.strip() == "" and items:
                    break
                elif (
                    any(
                        kw in line_lower
                        for kw in [
                            "risk",
                            "catalyst",
                            "support",
                            "resistance",
                            "target",
                            "recommendation",
                        ]
                    )
                    and items
                ):
                    break
        return items[:5]  # Max 5 items
