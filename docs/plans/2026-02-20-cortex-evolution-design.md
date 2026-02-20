# CORTEX Platform Evolution — Design Document

**Date:** 2026-02-20
**Goal:** Transform CORTEX from a working prototype into a professional-grade autonomous trading command center with contextual AI, advanced scanning, comprehensive financials, and live trading capability.

---

## Architecture Overview

### New Navigation Architecture

**Top Tab Bar** (horizontal, persistent across all views):
| Tab | Icon | Purpose |
|-----|------|---------|
| War Room | `shield.checkered` | Command dashboard — KPIs, squadrons, kill switch |
| Markets | `chart.line.uptrend.xyaxis` | Charts, TradingView, technical analysis |
| Scanner | `antenna.radiowaves.left.and.right` | AI-powered opportunity scanner with filters |
| Financials | `building.columns.fill` | Stock research, fundamentals, SEC filings, sentiment |
| Watchlist | `eye.circle.fill` | Portfolio watchlist and open positions |
| Squadrons | `person.3.sequence.fill` | Agent management across all 6 squadrons |
| Performance | `chart.bar.xaxis` | P&L analytics, equity curve, trade history |
| Settings | `gearshape.2.fill` | Connection, risk limits, autonomy dial |

**Left Context Pane** (per-tab sections, collapsible):
Each tab has its own contextual left pane with relevant sub-sections.

**Right AI Overlay Pane** (global, invokable from anywhere):
- Triggered by sparkle icon (✨) in top bar → uses SF Symbol `sparkles`
- Slides in from right with slight transparency (0.95 opacity)
- Can expand to fullscreen
- Context-aware: knows current tab + section
- Persists conversation across tab switches

### Tab-Specific Left Pane Sections

**War Room:**
- Overview (KPIs + kill switch)
- Squadron Status
- Activity Feed
- Risk Alerts

**Markets:**
- Favorites
- Indices (SPY, QQQ, DIA, IWM)
- Stocks
- Crypto
- Options

**Scanner:**
- All Opportunities
- Momentum
- Volume Surges
- Breakouts
- Short Candidates
- Catalyst Events
- Options Flow
- Custom Filters

**Financials:**
- Search / Overview
- Fundamentals
- SEC Filings
- News & Catalysts
- Social Sentiment
- AI Analysis

**Watchlist:**
- Active Positions
- All Symbols
- Alerts
- Order History

**Squadrons:**
- All Squadrons
- ALPHA (Signal Intelligence)
- BRAVO (Order Execution)
- CHARLIE (Options Analysis)
- DELTA (Market Intelligence)
- ECHO (Risk Management)
- FOXTROT (Tax & Yield)

**Performance:**
- Dashboard
- Equity Curve
- Trade Log
- Tax Report

**Settings:**
- Connection
- API Keys
- Risk Limits
- Autonomy
- Appearance

---

## Cortex AI Overlay

### Behavior
- **Invocation:** Click sparkle icon in top bar, or Cmd+Shift+A
- **Appearance:** Slides from right, 400px width, slightly transparent background (NSColor with 0.95 alpha)
- **Fullscreen:** Toggle button to expand AI pane to fill the content area
- **Context injection:** On every message, AI receives:
  - Current tab name
  - Current left pane section
  - Relevant data from current view (e.g., selected symbol, scanner filters, position data)
  - Full portfolio summary (always available)
- **Persistence:** Conversation history persists across tab switches
- **Close:** Click sparkle icon again, press Escape, or click outside

### Context Protocol
The AI overlay sends a `cmd_chat_message` with enriched payload:
```json
{
  "type": "cmd_chat_message",
  "payload": {
    "message": "user's question",
    "context": {
      "current_tab": "scanner",
      "current_section": "short_candidates",
      "selected_symbol": "TSLA",
      "visible_data": { ... }
    }
  }
}
```

---

## Scanner Overhaul

### Filter System
Hierarchical filters with AND/OR logic:
- **Market:** US Stocks, Crypto, Options
- **Sector:** Technology, Healthcare, Financials, Energy, Consumer, Industrial, Real Estate, Utilities, Materials, Communication
- **Market Cap:** Mega (>200B), Large (10-200B), Mid (2-10B), Small (300M-2B), Micro (<300M)
- **Signal Type:** Momentum, Volume, Breakout, Reversal, Catalyst, Options Flow, Earnings
- **Direction:** Long only, Short only, Both
- **Score Threshold:** Minimum composite score slider (0-100)
- **Price Range:** Min/Max price filter
- **Volume:** Minimum relative volume threshold

### Short Selling Intelligence
New signal types for short candidates:
- **Short Interest Spike:** Track SI% changes via Polygon/external data
- **SEC Filing Alerts:** 8-K filings (bankruptcy, going concern), 10-K risk factors
- **Exchange Delisting Notices:** Compliance warnings
- **Earnings Miss Patterns:** Post-earnings drift signals
- **Insider Selling:** Form 4 bulk sells
- **Technical Breakdown:** Below key support with volume

### AI Insights Per Opportunity
Each scanner result gets an AI micro-analysis:
- Risk assessment (1-5 scale)
- Entry/exit price levels
- Time horizon recommendation
- Confidence level
- Key catalyst or risk factor

### Empty State
When no opportunities match filters:
- AI provides market context ("Market is in low-volatility consolidation...")
- Suggests relaxing filters
- Highlights any sector rotation or macro signals

---

## Financials Section

### Stock Search & Research
When user searches for a ticker (e.g., "TSLA"):

**Fundamentals Panel:**
- Market Cap
- Shares Outstanding
- Float
- Short Interest (% of float)
- Avg Volume
- 52-Week High/Low
- P/E Ratio
- Sector & Industry
- Exchange

**News Panel:**
- Major financial news (via news APIs)
- SEC EDGAR filings (10-K, 10-Q, 8-K, Form 4)
- Earnings dates and estimates
- Analyst ratings summary

**Social Sentiment Panel:**
- Social media mention volume (trending indicator)
- Sentiment score (bullish/bearish/neutral)
- Trending keywords associated with ticker

**AI Analysis Panel:**
- Automatic buy/sell/hold recommendation
- Short selling opportunity assessment
- Key risks and catalysts
- Technical levels (support/resistance)
- Comparison to sector peers

### Data Sources
- **Polygon.io:** Fundamentals, aggregates, reference data
- **SEC EDGAR:** Filings (free API, no key needed)
- **News:** Polygon news API (included with Polygon key)

---

## Live API Connections

### Claude API (Priority 1)
- Already wired in `cortex/intelligence/chat.py`
- Needs: `CORTEX_ANTHROPIC_API_KEY` set in environment
- Streaming works via Anthropic SDK
- System prompt includes portfolio context

### Polygon.io (Priority 1)
- Already wired in `cortex/connectors/polygon/rest_client.py`
- Needs: `CORTEX_POLYGON_API_KEY` set in environment
- Endpoints: snapshots, search, aggregates, previous close

### Interactive Brokers (Priority 2)
- Connector exists at `cortex/connectors/ibkr/client.py`
- Needs: TWS or IB Gateway running locally (port 4001 live, 4002 paper)
- Wire into: StatusBroadcaster (portfolio), OrderSniper (execution), DrawdownShield (NAV)
- Create `rate_limiter.py` per CLAUDE.md

### SEC EDGAR (Priority 2)
- Free API, no key needed
- REST endpoint: `https://efts.sec.gov/LATEST/search-index?q=...`
- Company filings: `https://data.sec.gov/submissions/CIK{cik}.json`

---

## Implementation Tasks (Ordered)

### Phase 1: UI Architecture (Swift) — Tasks 1-4
1. New top tab bar + left context pane framework
2. Cortex AI overlay pane (right side, transparent, context-aware)
3. Redesigned Scanner view with filter system
4. New Financials section view

### Phase 2: Backend Intelligence (Python) — Tasks 5-8
5. Enhanced chat context protocol (tab/section awareness)
6. SEC EDGAR connector for filings and fundamentals
7. Enhanced scanner with short-selling signals
8. Financials data aggregation endpoint

### Phase 3: Live Connections (Python) — Tasks 9-11
9. Wire Claude API with real key + verify streaming
10. Wire IBKR connector into main.py + rate limiter
11. Wire all API keys and verify data flow

### Phase 4: Trading Readiness — Tasks 12-13
12. Paper trading verification (IBKR paper account)
13. Live trading switch with safety checks
