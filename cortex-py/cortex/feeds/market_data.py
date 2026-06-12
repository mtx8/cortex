"""Market data feed — polls Polygon snapshots and broadcasts to Swift clients.

Runs as a background asyncio task. Every poll_interval seconds it:
1. Fetches snapshots for the watchlist from PolygonRESTClient
2. Broadcasts MARKET_QUOTE messages to connected Swift clients via WSBroadcaster
3. Publishes price signals to the SignalBus for ALPHA squadron agents
"""

import asyncio
import random
from collections import deque
import structlog

from cortex.api.protocol import MessageType, CortexMessage
from cortex.api.ws_broadcaster import WSBroadcaster
from cortex.connectors.polygon.rest_client import PolygonRESTClient
from cortex.orchestrator.bus import SignalBus, Signal, SignalPriority

log = structlog.get_logger()

DEFAULT_WATCHLIST: list[str] = [
    # Mega Cap Tech
    "AAPL", "NVDA", "MSFT", "GOOG", "META", "AMZN", "TSLA", "AVGO", "ORCL", "CRM",
    # Large Cap Tech
    "INTC", "NFLX", "ADBE", "CSCO", "QCOM", "AMAT", "MU", "PANW", "NOW", "UBER",
    # Financials
    "JPM", "BAC", "GS", "MS", "V", "MA", "BRK.B", "C", "WFC", "AXP",
    # Healthcare
    "UNH", "JNJ", "LLY", "PFE", "ABBV", "MRK", "TMO", "ABT", "BMY", "AMGN",
    # Energy
    "XOM", "CVX", "COP", "SLB", "EOG",
    # Consumer
    "WMT", "COST", "HD", "NKE", "SBUX", "MCD",
    # Industrials
    "CAT", "BA", "GE", "HON", "UPS",
    # ETFs
    "SPY", "QQQ", "IWM", "DIA", "XLF", "XLE", "XLK", "XLV",
]

# Static metadata for sector and market cap classification.
# Sector values match the Swift ScannerFilterStore.Sector enum raw values exactly.
# Market cap values match the Swift ScannerFilterStore.CapSize enum raw values exactly.
TICKER_METADATA: dict[str, dict[str, str]] = {
    # Mega Cap Tech
    "AAPL": {"sector": "Technology", "market_cap": "Mega"},
    "NVDA": {"sector": "Technology", "market_cap": "Mega"},
    "MSFT": {"sector": "Technology", "market_cap": "Mega"},
    "GOOG": {"sector": "Communication", "market_cap": "Mega"},
    "META": {"sector": "Communication", "market_cap": "Mega"},
    "AMZN": {"sector": "Technology", "market_cap": "Mega"},
    "TSLA": {"sector": "Consumer Disc.", "market_cap": "Mega"},
    "AVGO": {"sector": "Technology", "market_cap": "Mega"},
    "ORCL": {"sector": "Technology", "market_cap": "Mega"},
    "CRM": {"sector": "Technology", "market_cap": "Large"},
    # Large Cap Tech
    "INTC": {"sector": "Technology", "market_cap": "Large"},
    "NFLX": {"sector": "Communication", "market_cap": "Large"},
    "ADBE": {"sector": "Technology", "market_cap": "Large"},
    "CSCO": {"sector": "Technology", "market_cap": "Large"},
    "QCOM": {"sector": "Technology", "market_cap": "Large"},
    "AMAT": {"sector": "Technology", "market_cap": "Large"},
    "MU": {"sector": "Technology", "market_cap": "Large"},
    "PANW": {"sector": "Technology", "market_cap": "Large"},
    "NOW": {"sector": "Technology", "market_cap": "Large"},
    "UBER": {"sector": "Technology", "market_cap": "Large"},
    # Financials
    "JPM": {"sector": "Financials", "market_cap": "Mega"},
    "BAC": {"sector": "Financials", "market_cap": "Large"},
    "GS": {"sector": "Financials", "market_cap": "Large"},
    "MS": {"sector": "Financials", "market_cap": "Large"},
    "V": {"sector": "Financials", "market_cap": "Mega"},
    "MA": {"sector": "Financials", "market_cap": "Mega"},
    "BRK.B": {"sector": "Financials", "market_cap": "Mega"},
    "C": {"sector": "Financials", "market_cap": "Large"},
    "WFC": {"sector": "Financials", "market_cap": "Large"},
    "AXP": {"sector": "Financials", "market_cap": "Large"},
    # Healthcare
    "UNH": {"sector": "Healthcare", "market_cap": "Mega"},
    "JNJ": {"sector": "Healthcare", "market_cap": "Mega"},
    "LLY": {"sector": "Healthcare", "market_cap": "Mega"},
    "PFE": {"sector": "Healthcare", "market_cap": "Large"},
    "ABBV": {"sector": "Healthcare", "market_cap": "Large"},
    "MRK": {"sector": "Healthcare", "market_cap": "Large"},
    "TMO": {"sector": "Healthcare", "market_cap": "Large"},
    "ABT": {"sector": "Healthcare", "market_cap": "Large"},
    "BMY": {"sector": "Healthcare", "market_cap": "Large"},
    "AMGN": {"sector": "Healthcare", "market_cap": "Large"},
    # Energy
    "XOM": {"sector": "Energy", "market_cap": "Mega"},
    "CVX": {"sector": "Energy", "market_cap": "Mega"},
    "COP": {"sector": "Energy", "market_cap": "Large"},
    "SLB": {"sector": "Energy", "market_cap": "Large"},
    "EOG": {"sector": "Energy", "market_cap": "Large"},
    # Consumer
    "WMT": {"sector": "Consumer Staples", "market_cap": "Mega"},
    "COST": {"sector": "Consumer Staples", "market_cap": "Large"},
    "HD": {"sector": "Consumer Disc.", "market_cap": "Mega"},
    "NKE": {"sector": "Consumer Disc.", "market_cap": "Large"},
    "SBUX": {"sector": "Consumer Disc.", "market_cap": "Large"},
    "MCD": {"sector": "Consumer Disc.", "market_cap": "Mega"},
    # Industrials
    "CAT": {"sector": "Industrials", "market_cap": "Large"},
    "BA": {"sector": "Industrials", "market_cap": "Large"},
    "GE": {"sector": "Industrials", "market_cap": "Large"},
    "HON": {"sector": "Industrials", "market_cap": "Large"},
    "UPS": {"sector": "Industrials", "market_cap": "Large"},
    # ETFs — mapped to matching sector for sector-specific ETFs
    "SPY": {"sector": "Financials", "market_cap": "Mega"},
    "QQQ": {"sector": "Technology", "market_cap": "Mega"},
    "IWM": {"sector": "Financials", "market_cap": "Large"},
    "DIA": {"sector": "Industrials", "market_cap": "Large"},
    "XLF": {"sector": "Financials", "market_cap": "Large"},
    "XLE": {"sector": "Energy", "market_cap": "Large"},
    "XLK": {"sector": "Technology", "market_cap": "Large"},
    "XLV": {"sector": "Healthcare", "market_cap": "Large"},
}

# Sector-based score biases for more realistic scanner output
_SECTOR_SCORE_BIAS: dict[str, tuple[float, float]] = {
    "Technology": (50, 95),       # Tech: slight high-momentum bias
    "Communication": (45, 90),    # Communication: moderate range
    "Healthcare": (35, 80),       # Healthcare: value-oriented, lower ceiling
    "Financials": (40, 85),       # Financials: moderate range
    "Energy": (25, 98),           # Energy: wider, more volatile range
    "Consumer Disc.": (40, 88),   # Consumer discretionary: moderate
    "Consumer Staples": (35, 75), # Consumer staples: narrower, defensive
    "Industrials": (38, 82),      # Industrials: moderate range
    "Materials": (35, 85),        # Materials: moderate
    "Utilities": (30, 70),        # Utilities: narrow, defensive
    "Real Estate": (30, 75),      # Real estate: narrow
}

OPPORTUNITY_TYPES: list[str] = ["Momentum", "Volume", "Catalyst", "Breakout", "Flow"]

OPPORTUNITY_THESES: dict[str, str] = {
    "Momentum": "Strong momentum with RSI trending and volume confirmation",
    "Volume": "Unusual volume spike detected, institutional activity likely",
    "Catalyst": "Upcoming catalyst event with positive sentiment signals",
    "Breakout": "Breaking above key resistance level with increasing volume",
    "Flow": "Significant options flow detected, smart money positioning",
}


class MarketDataFeed:
    """Polls Polygon snapshots and fans out market quotes to WebSocket clients
    and the internal SignalBus."""

    def __init__(
        self,
        polygon_client: PolygonRESTClient,
        broadcaster: WSBroadcaster,
        bus: SignalBus,
        watchlist: list[str] | None = None,
        poll_interval: float = 15.0,
        status_broadcaster=None,
        scanner_engine=None,
    ):
        self._polygon = polygon_client
        self._broadcaster = broadcaster
        self._bus = bus
        self._watchlist: list[str] = list(watchlist or DEFAULT_WATCHLIST)
        self._poll_interval = poll_interval
        self._running = False
        self._poll_count = 0
        self._last_quotes: dict[str, dict] = {}
        self._task: asyncio.Task | None = None
        self._status_broadcaster = status_broadcaster
        # Scanner opportunity state — seeded per-ticker so scores drift slowly
        self._rng = random.Random(42)
        self._scanner_scores: dict[str, dict] = {}
        # Rolling close-price history per ticker → real Rust composite scoring once
        # enough bars accumulate (demo drift is the fallback until then).
        self._scanner_engine = scanner_engine
        self._price_history: dict[str, deque] = {}

    @property
    def watchlist(self) -> list[str]:
        return list(self._watchlist)

    @property
    def poll_count(self) -> int:
        return self._poll_count

    @property
    def is_running(self) -> bool:
        return self._running

    @property
    def last_quotes(self) -> dict[str, dict]:
        return dict(self._last_quotes)

    def add_ticker(self, ticker: str) -> None:
        ticker = ticker.upper()
        if ticker not in self._watchlist:
            self._watchlist.append(ticker)
            log.info("feed.ticker_added", ticker=ticker, watchlist_size=len(self._watchlist))

    def remove_ticker(self, ticker: str) -> None:
        ticker = ticker.upper()
        if ticker in self._watchlist:
            self._watchlist.remove(ticker)
            self._last_quotes.pop(ticker, None)
            log.info("feed.ticker_removed", ticker=ticker, watchlist_size=len(self._watchlist))

    async def _poll_once(self) -> list[dict]:
        """Fetch snapshots, broadcast to WS clients, publish to bus. Returns snapshots."""
        if not self._watchlist:
            return []

        try:
            snapshots = await self._polygon.get_snapshots(self._watchlist)
        except Exception as e:
            log.error("feed.poll_error", error=str(e))
            snapshots = []

        self._poll_count += 1

        for quote in snapshots:
            ticker = quote.get("ticker", "")
            self._last_quotes[ticker] = quote
            price = quote.get("price", 0) or 0
            if price > 0:
                self._price_history.setdefault(ticker, deque(maxlen=80)).append(float(price))

            # Broadcast to Swift clients
            msg = CortexMessage(
                type=MessageType.MARKET_QUOTE,
                payload=quote,
            )
            await self._broadcaster.broadcast(msg)

            # Publish to SignalBus for ALPHA squadron agents
            await self._bus.publish(Signal(
                signal_id=f"market_quote_{ticker}_{self._poll_count}",
                source_agent="market_data_feed",
                source_squadron="feeds",
                signal_type="feeds.market_quote",
                payload=quote,
                priority=SignalPriority.LOW,
            ))

            # Bridge to ALPHA squadron agents — they subscribe to alpha.market_signal
            await self._bus.publish(Signal(
                signal_id=f"alpha_market_{ticker}_{self._poll_count}",
                source_agent="market_data_feed",
                source_squadron="feeds",
                signal_type="alpha.market_signal",
                payload=quote,
                priority=SignalPriority.LOW,
            ))

        # Broadcast scanner opportunities for watchlist symbols
        await self._broadcast_scanner_opportunities()

        # Compute simulated portfolio NAV from watchlist prices for demo until IBKR is connected
        if self._status_broadcaster and self._last_quotes:
            total_value = sum(q.get("price", 0) for q in self._last_quotes.values())
            # Simulated NAV: base capital + watchlist value as a proxy
            simulated_nav = 100_000.0 + total_value
            daily_pnl = sum(q.get("change", 0) for q in self._last_quotes.values())
            self._status_broadcaster.update_portfolio(
                nav=simulated_nav,
                daily_pnl=daily_pnl,
            )

        log.debug(
            "feed.poll_complete",
            poll=self._poll_count,
            tickers=len(snapshots),
        )
        return snapshots

    async def start(self) -> None:
        """Start the polling loop. Call this as an asyncio task."""
        self._running = True
        log.info(
            "feed.starting",
            watchlist=self._watchlist,
            interval=self._poll_interval,
        )

        while self._running:
            await self._poll_once()
            try:
                await asyncio.sleep(self._poll_interval)
            except asyncio.CancelledError:
                break

        log.info("feed.stopped", polls=self._poll_count)

    async def stop(self) -> None:
        """Signal the polling loop to stop."""
        self._running = False
        log.info("feed.stop_requested")

    @property
    def scanner_opportunities(self) -> list[dict]:
        """Return current scanner scores as a list of opportunity dicts (sorted by score desc).
        Uses the real Rust composite score where available (same as the live broadcast),
        so the initial snapshot + chat context agree with what clients see streamed."""
        real = self._real_scanner_scores()
        opps = []
        for ticker, state in self._scanner_scores.items():
            opp_type = state.get("type", "Momentum")
            score = round(real.get(ticker, state.get("score", 50)), 1)
            meta = TICKER_METADATA.get(ticker, {"sector": "Unknown", "market_cap": "Unknown"})
            opps.append({
                "ticker": ticker,
                "score": score,
                "type": opp_type,
                "risk_reward": state.get("rr", 1.5),
                "direction": "short" if opp_type == "Flow" else "long",
                "thesis": f"{ticker}: {OPPORTUNITY_THESES.get(opp_type, 'Scanner result')}",
                "sector": meta["sector"],
                "market_cap": meta["market_cap"],
            })
        opps.sort(key=lambda x: x["score"], reverse=True)
        return opps

    def _real_scanner_scores(self) -> dict[str, float]:
        """Rust-computed composite scores for tickers with enough price history.
        Empty until ≥30 bars accumulate or if the engine isn't wired."""
        if self._scanner_engine is None or not self._scanner_engine.available:
            return {}
        hist = {t: list(h) for t, h in self._price_history.items() if len(h) >= 30}
        if not hist:
            return {}
        try:
            results = self._scanner_engine.scan(hist)
        except Exception as e:
            log.warning("feed.real_scanner_error", error=str(e))
            return {}
        return {r["symbol"]: r["composite_score"] for r in results}

    async def _broadcast_scanner_opportunities(self) -> None:
        """Generate and broadcast scanner opportunity data for watchlist symbols.
        Uses real Rust composite scores where available, demo drift otherwise."""
        if self._broadcaster.client_count == 0:
            return

        real = self._real_scanner_scores()
        for ticker in self._watchlist:
            meta = TICKER_METADATA.get(ticker, {"sector": "Unknown", "market_cap": "Unknown"})
            sector = meta["sector"]

            # Initialize or drift the score for this ticker
            if ticker not in self._scanner_scores:
                # Use sector-based score range for more realistic variation
                lo, hi = _SECTOR_SCORE_BIAS.get(sector, (40, 95))
                self._scanner_scores[ticker] = {
                    "score": self._rng.uniform(lo, hi),
                    "type": self._rng.choice(OPPORTUNITY_TYPES),
                    "rr": round(self._rng.uniform(1.0, 3.0), 1),
                }

            state = self._scanner_scores[ticker]
            # Small random drift each cycle (±3 points), clamped to [20, 98]
            state["score"] = max(20, min(98, state["score"] + self._rng.uniform(-3, 3)))

            opp_type = state["type"]
            score = round(state["score"], 1)
            engine = "demo"
            # Override with the real Rust composite score once history is sufficient.
            if ticker in real:
                score = round(real[ticker], 1)
                engine = "rust"
            direction = "short" if opp_type == "Flow" else "long"

            msg = CortexMessage(
                type=MessageType.SCANNER_RESULT,
                payload={
                    "id": ticker,
                    "ticker": ticker,
                    "composite_score": score,
                    "type": opp_type,
                    "thesis": f"{ticker}: {OPPORTUNITY_THESES.get(opp_type, 'Scanner result')}",
                    "risk_reward": state["rr"],
                    "direction": direction,
                    "sector": sector,
                    "market": "US Stocks",
                    "market_cap": meta["market_cap"],
                    "short_interest": 0.0,
                    "engine": engine,
                    "ai_insight": (f"Rust composite {score}" if engine == "rust"
                                   else f"High momentum score ({score}) with {opp_type.lower()} pattern"),
                },
            )
            await self._broadcaster.broadcast(msg)

    def to_dict(self) -> dict:
        return {
            "running": self._running,
            "poll_count": self._poll_count,
            "watchlist": self._watchlist,
            "poll_interval": self._poll_interval,
            "tracked_tickers": len(self._last_quotes),
        }
