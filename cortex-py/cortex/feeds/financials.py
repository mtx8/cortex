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

        try:
            # Run Polygon and EDGAR lookups in parallel
            polygon_task = asyncio.create_task(self._get_polygon_data(symbol))
            edgar_task = asyncio.create_task(self._get_edgar_data(symbol))

            # Get Polygon data first (usually faster)
            polygon_data = await polygon_task

            # Always send profile so the client clears isLoading
            profile_payload = polygon_data or {
                "symbol": symbol,
                "name": symbol,
                "price": 0,
                "change": 0,
                "change_percent": 0,
                "sector": "Unknown",
                "industry": "Unknown",
                "exchange": "",
                "market_cap": 0,
                "volume": 0,
            }
            if ws:
                msg = CortexMessage(type=MessageType.FINANCIALS_PROFILE, payload=profile_payload)
                await ws.send_text(encode_message(msg))
            results["profile"] = profile_payload

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

            # Derive sentiment from news headlines and send to client
            if news:
                sentiment = self._derive_sentiment(news)
                if ws:
                    msg = CortexMessage(
                        type=MessageType.FINANCIALS_SENTIMENT,
                        payload=sentiment,
                    )
                    await ws.send_text(encode_message(msg))
                results["sentiment"] = sentiment

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

        except Exception as e:
            log.error("financials.lookup_error", symbol=symbol, error=str(e))
            if ws:
                err_msg = CortexMessage(
                    type=MessageType.FINANCIALS_ERROR,
                    payload={"symbol": symbol, "error": str(e)},
                )
                await ws.send_text(encode_message(err_msg))

        return results

    async def _get_polygon_data(self, symbol: str) -> dict | None:
        """Get stock profile data from Polygon by combining multiple endpoints.

        Data sources:
        - Ticker Details (/v3/reference/tickers) → name, market_cap, sector, shares
        - Previous Close (/v2/aggs/ticker/prev) → price, change, volume
        - Snapshot (if available) → real-time price override
        - 52-Week Range (from daily aggregates) → high/low
        """
        try:
            # Run all lookups in parallel for speed
            details_task = asyncio.create_task(self._polygon.get_ticker_details(symbol))
            prev_task = asyncio.create_task(self._polygon.get_previous_close(symbol))
            range_task = asyncio.create_task(self._polygon.get_52_week_range(symbol))

            # Snapshot may fail on free plans — don't block on it
            snapshot = {}
            try:
                snapshots = await self._polygon.get_snapshots([symbol])
                snapshot = snapshots[0] if snapshots else {}
            except Exception:
                log.debug("financials.snapshot_unavailable", symbol=symbol)

            details = await details_task
            prev = await prev_task
            week_range = await range_task

            # Price: prefer snapshot (real-time) > prev close
            price = snapshot.get("price") or prev.get("close", 0)
            prev_close = snapshot.get("prev_close") or prev.get("close", 0)
            change = snapshot.get("change") or (price - prev_close if prev_close else 0)
            change_pct = snapshot.get("change_pct") or (
                (change / prev_close * 100) if prev_close else 0
            )

            # Map SIC description to a sector category
            sector = self._sic_to_sector(details.get("sic_description", ""))

            profile = {
                "symbol": symbol,
                "name": details.get("name", symbol),
                "price": round(price, 2),
                "change": round(change, 2),
                "change_percent": round(change_pct, 2),
                "volume": snapshot.get("volume") or prev.get("volume", 0),
                "market_cap": details.get("market_cap", 0),
                "sector": sector,
                "industry": details.get("sic_description", "Unknown"),
                "exchange": details.get("primary_exchange", ""),
                "shares_outstanding": details.get("shares_outstanding", 0),
                "float": details.get("shares_outstanding", 0),  # Approximate
                "short_interest": 0,  # Not available in basic Polygon
                "short_ratio": 0,
                "avg_volume": 0,  # Would need multiple days of data
                "week_52_high": week_range.get("week_52_high", 0),
                "week_52_low": week_range.get("week_52_low", 0),
                "pe_ratio": None,  # Would need earnings data
                "forward_pe": None,
                "dividend_yield": None,
                "beta": None,
                "prev_close": prev_close,
                "prev_volume": prev.get("volume", 0),
            }
            return profile
        except Exception as e:
            log.error("financials.polygon_error", symbol=symbol, error=str(e))
            return None

    @staticmethod
    def _sic_to_sector(sic_description: str) -> str:
        """Map SIC description to a broad sector category.

        Order matters — more specific matches come before broader ones
        to avoid false positives (e.g., "Industrial Chemicals" -> Materials, not Industrials).
        """
        if not sic_description:
            return "Unknown"
        desc = sic_description.lower()
        # Check specific/compound terms before broad ones
        if any(w in desc for w in ["real estate", "reit"]):
            return "Real Estate"
        if any(w in desc for w in ["software", "computer", "semiconductor", "electronic", "data processing"]):
            return "Technology"
        if any(w in desc for w in ["pharmaceutical", "medical", "biological", "health", "surgical"]):
            return "Healthcare"
        if any(w in desc for w in ["chemical", "paper", "metal", "steel", "lumber"]):
            return "Materials"
        if any(w in desc for w in ["bank", "insurance", "financial", "security broker"]):
            return "Financials"
        if any(w in desc for w in ["oil", "gas", "petroleum", "coal", "mining", "crude"]):
            return "Energy"
        if any(w in desc for w in ["retail", "restaurant", "hotel", "motor vehicle", "apparel"]):
            return "Consumer Disc."
        if any(w in desc for w in ["food", "beverage", "grocery", "tobacco", "household"]):
            return "Consumer Staples"
        if any(w in desc for w in ["aircraft", "industrial", "machinery", "construction", "defense"]):
            return "Industrials"
        if any(w in desc for w in ["electric", "gas distribution", "water supply", "utility"]):
            return "Utilities"
        if any(w in desc for w in ["television", "radio", "cable", "telephone", "communication", "publishing"]):
            return "Communication"
        if "investment" in desc or "trust" in desc:
            return "Financials"
        return "Other"

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
        """Get news from Polygon news API via the public client method."""
        try:
            articles = await self._polygon.get_news(symbol, limit=15)
            # Add sentiment field for each article (Polygon doesn't provide it)
            for article in articles:
                article["sentiment"] = "neutral"
            return articles
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

    def _derive_sentiment(self, news: list[dict]) -> dict:
        """Simple keyword-based sentiment analysis on news headlines."""
        positive_words = {"surge", "rally", "beat", "upgrade", "growth", "record"}
        negative_words = {"crash", "plunge", "miss", "downgrade", "loss", "decline", "warning"}

        positive_count = 0
        negative_count = 0

        for item in news:
            headline = item.get("title", "").lower()
            words = set(headline.split())
            if words & positive_words:
                positive_count += 1
            if words & negative_words:
                negative_count += 1

        total = len(news)
        if positive_count > negative_count:
            overall = "bullish"
        elif negative_count > positive_count:
            overall = "bearish"
        else:
            overall = "neutral"

        # Score 0-100: 50 is neutral, >50 bullish, <50 bearish
        if total > 0:
            score = int(50 + ((positive_count - negative_count) / total) * 50)
            score = max(0, min(100, score))
        else:
            score = 50

        # Derive trend from positive/negative balance
        if positive_count > negative_count + 1:
            trend = "rising"
        elif negative_count > positive_count + 1:
            trend = "falling"
        else:
            trend = "stable"

        # Extract top keywords from headlines
        from collections import Counter
        word_counts: Counter[str] = Counter()
        stop_words = {"the", "a", "an", "is", "in", "at", "to", "for", "of", "and", "on", "by", "with", "from"}
        for item in news:
            headline = item.get("title", "")
            for word in headline.split():
                cleaned = word.strip(".,!?:;\"'()[]").capitalize()
                if len(cleaned) > 2 and cleaned.lower() not in stop_words:
                    word_counts[cleaned] += 1
        top_keywords = [w for w, _ in word_counts.most_common(7)]

        # Convert score from 0-100 to -1..1 range for Swift sentiment gauge
        sentiment_score = (score - 50) / 50.0

        return {
            "sentiment_score": sentiment_score,
            "mention_volume": total,
            "trend": trend,
            "top_keywords": top_keywords,
            # Also include raw data for backward compat
            "overall_sentiment": overall,
            "score": score,
            "positive_count": positive_count,
            "negative_count": negative_count,
            "total_analyzed": total,
        }

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
