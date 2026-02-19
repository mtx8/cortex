# Production-Ready Core — Design Document

**Date:** 2026-02-19
**Goal:** Transform CORTEX from a mock demo into a live-data trading platform with real API connections, professional UI, and production-quality architecture.

---

## 1. Architecture

### Data Flow
```
Polygon.io REST ──→ Python Backend ──→ Redis Cache ──→ WebSocket ──→ Swift Stores
Finnhub REST ──────→ Python Backend ──→ (DELTA agents)
SEC EDGAR ─────────→ Python Backend ──→ (DELTA agents)
Claude API ←───────→ Python Backend ←──→ WebSocket ←──→ Swift ChatStore
IBKR/Coinbase ←───→ Python Backend ←──→ (BRAVO agents)
```

### Key Decisions
1. **Python backend = single secure data gateway.** Swift never calls external APIs directly. API keys stay server-side.
2. **TradingView widget loads its own data.** The embed already fetches from tradingview.com — we just need to make the symbol dynamic (user-searchable).
3. **Claude chat goes through Python.** Server-side context injection (portfolio, signals, agent state) before every Claude call.
4. **Polygon REST first, WebSocket later.** REST is debuggable and sufficient for MVP. Endpoints: `/v2/aggs/ticker/{ticker}/prev` (quotes), `/v3/reference/tickers` (search), `/v2/aggs/ticker/{ticker}/range` (candles).
5. **Remove all mock data.** Every `loadMockData()` call gets replaced with live WebSocket feeds.

---

## 2. Swift UI Overhaul

### 2.1 Navigation: Collapsible Left Sidebar
Replace `TabView` with `NavigationSplitView` + custom sidebar.

```
┌────────────┬──────────────────────────────────────────┐
│ ☰ CORTEX   │                                          │
│            │          Active View Content              │
│ ◉ War Room │                                          │
│ ◎ Charts   │                                          │
│ ◎ Scanner  │                                          │
│ ◎ Squadrons│                                          │
│ ◎ Watchlist│                                          │
│ ◎ AI Chat  │                                          │
│ ◎ Perf     │                                          │
│            │                                          │
│ ─────────  │                                          │
│ ◎ Settings │                                          │
│            │                                          │
│ [P&L: +$X] │                                          │
│ [Kill ⌘K]  │                                          │
└────────────┴──────────────────────────────────────────┘
```

- Toggle with Cmd+B or hamburger button
- Collapsed = icons only (48px wide), expanded = icons + labels (220px)
- Bottom section: daily P&L summary, kill switch quick-access
- Active tab highlighted with accent color

### 2.2 War Room Overhaul
```
┌─────────────────────────────────────────────────────────────┐
│ KPI BAR: NAV | Daily P&L (sparkline) | Weekly | Monthly    │
│          Buying Power | Margin % | Daily Return % | Win %  │
├──────────────────────────────┬──────────────────────────────┤
│ SQUADRON STATUS GRID         │ LIVE OPPORTUNITIES FEED      │
│ ┌─────┐ ┌─────┐ ┌─────┐    │ ┌──────────────────────────┐ │
│ │ALPHA│ │BRAVO│ │CHARLIE│   │ │ NVDA  Score:87  BUY      │ │
│ │7/7 ✓│ │6/6 ✓│ │7/7 ✓ │   │ │ Breakout above $890...   │ │
│ └─────┘ └─────┘ └──────┘    │ └──────────────────────────┘ │
│ ┌─────┐ ┌─────┐ ┌──────┐   │ ┌──────────────────────────┐ │
│ │DELTA│ │ECHO │ │FOXTROT│   │ │ AAPL  Score:72  WATCH    │ │
│ │8/8 ✓│ │6/6 ✓│ │6/6 ✓ │   │ │ Approaching resistance...│ │
│ └─────┘ └─────┘ └──────┘    │ └──────────────────────────┘ │
├──────────────────────────────┤                              │
│ SCANNER TOP 10               │ ACTIVITY FEED               │
│ NVDA  87.3 ████████▌        │ 14:23 ALPHA: NVDA entry sig │
│ AAPL  72.1 ███████▏         │ 14:22 ECHO: Risk check pass │
│ META  68.5 ██████▊          │ 14:21 BRAVO: Order filled   │
│ ...                          │ ...                          │
└──────────────────────────────┴──────────────────────────────┘
```

Components:
- **KPI Bar:** 8 metrics in a horizontal strip with mini sparkline charts (SwiftUI Canvas or Apple Charts). Live data from PortfolioStore via WebSocket.
- **Squadron Status Cards:** 6 cards in a 3x2 grid. Each shows: squadron name, active/total agents, signals today, win rate, health dot (green/yellow/red). Click to navigate to Squadrons tab filtered to that squadron.
- **Live Opportunities Feed:** Scrolling list of top scanner results sorted by composite score. Each card: ticker, score bar (color gradient), opportunity type tag, 2-sentence AI thesis, R:R ratio. Click to expand signal breakdown.
- **Scanner Top 10:** Compact horizontal bar chart of top composite scores with ticker labels.
- **Activity Feed:** Chronological log with severity icons, agent attribution, timestamps. Auto-scrolls.

### 2.3 Chart View with Search
```
┌─────────────────────────────────────────────┐
│ [🔍 Search ticker...  ] [1m 5m 15m 1H D W] │
│  ┌─ Dropdown ──────┐                        │
│  │ AAPL - Apple Inc│                        │
│  │ AAPLW - ...     │                        │
│  └─────────────────┘                        │
├─────────────────────────────────────────────┤
│           TradingView Chart Widget           │
│              (full height)                   │
└─────────────────────────────────────────────┘
```

- Search bar at top left with type-ahead autocomplete
- Search hits Python backend → Polygon `/v3/reference/tickers?search={query}` → returns matches
- Selected symbol updates TradingView widget
- Cache the WKWebView — don't recreate on every symbol change, use JS bridge to update symbol
- Timeframe selector persists across symbol changes

### 2.4 AI Chat (Perplexity-Style)
```
┌───────────────────────────────────────┬─────────────────┐
│ CORTEX Intelligence                   │ TOP OPPORTUNITIES│
│                                       │                 │
│ [Quick Prompts Row]                   │ NVDA  87 ██████ │
│ "Biggest risk?" "Top opportunity"     │ AAPL  72 █████  │
│ "Market thesis" "Watch overnight"     │ META  68 ████▌  │
│                                       │ TSLA  61 ████   │
│ ┌─────────────────────────────────┐   │ SPY   55 ███▌   │
│ │ User: Analyze NVDA              │   │                 │
│ └─────────────────────────────────┘   │ [Review Trade]  │
│                                       │                 │
│ ┌─────────────────────────────────┐   │                 │
│ │ 🧠 CORTEX:                      │   │                 │
│ │                                 │   │                 │
│ │ ## NVDA Analysis                │   │                 │
│ │ **Price:** $892.45 (+1.79%)     │   │                 │
│ │                                 │   │                 │
│ │ ┌─── Signal Summary ─────────┐ │   │                 │
│ │ │ ALPHA: Breakout confirmed  │ │   │                 │
│ │ │ CHARLIE: Call flow +2.3x   │ │   │                 │
│ │ │ ECHO: Risk check PASS      │ │   │                 │
│ │ └────────────────────────────┘ │   │                 │
│ │                                 │   │                 │
│ │ **Entry:** $892 | **Stop:** $875│   │                 │
│ │ **Target:** $920 | **R:R:** 1.6 │   │                 │
│ └─────────────────────────────────┘   │                 │
│                                       │                 │
│ [Ask about trades, signals, risk...]  │                 │
└───────────────────────────────────────┴─────────────────┘
```

Features:
- **Rich markdown rendering** in assistant messages (headers, bold, code blocks, tables)
- **Signal summary cards** inline (colored badges for each squadron's input)
- **Data cards** for price/entry/stop/target (structured, not plain text)
- **Quick prompt buttons** across top (configurable)
- **Opportunity side panel** (collapsible) showing top 5 from scanner with "Review Trade" buttons
- **Real Claude API** with tool use: scanner query, agent data pull, ticker history lookup, trade order drafting
- **Streaming responses** for perceived speed

### 2.5 Scanner View (New Tab)
Full-width sortable table:
- Columns: Ticker, Composite Score (visual bar), Technical, Flow, Catalyst, Risk-Adjusted, Type, Action, R:R
- Row click → expanded detail with contributing signals and agent attribution
- Filter presets: "Options Flow", "Insider Buying", "Earnings This Week", "High Momentum", "Mean Reversion"
- Custom filter builder

### 2.6 Squadrons View (Enhanced)
- 6 squadron sections, each expandable
- Agent cards: name, status badge (green/yellow/red), signals today, win rate, P&L attribution
- Click agent → slide-out detail panel: activity log, config params, performance chart, pause/resume

---

## 3. Python Backend Changes

### 3.1 New WebSocket Message Types

Add to `protocol.py`:
```
CMD_SEARCH_TICKER = 107      # Client → Server: {query: "NVDA"}
CMD_CHAT_MESSAGE = 108       # Client → Server: {message: "analyze NVDA"}
TICKER_SEARCH_RESULTS = 9    # Server → Client: {results: [...]}
CHAT_RESPONSE = 10           # Server → Client: {content: "...", done: bool}
CHAT_RESPONSE_CHUNK = 11     # Server → Client: streaming chunk
SCANNER_RESULTS = 12         # Server → Client: {results: [...]}
OPPORTUNITIES = 13           # Server → Client: top opportunities list
MARKET_QUOTE = 14            # Server → Client: live quote update
```

### 3.2 New API Endpoints in main.py

Handle new message types in the WebSocket handler:
- `CMD_SEARCH_TICKER` → call Polygon `/v3/reference/tickers?search={query}` → return results
- `CMD_CHAT_MESSAGE` → build context (portfolio + signals + scanner) → call Claude API with tool use → stream response chunks back
- Periodic scanner results push (every 30s during market hours)
- Periodic quote updates for watchlist symbols

### 3.3 Polygon REST Integration

New file: `cortex/connectors/polygon/rest_client.py`
- `search_tickers(query)` → `/v3/reference/tickers`
- `get_previous_close(ticker)` → `/v2/aggs/ticker/{ticker}/prev`
- `get_snapshot(tickers)` → `/v2/snapshot/locale/us/markets/stocks/tickers`
- `get_ticker_details(ticker)` → `/v3/reference/tickers/{ticker}`
- Rate limiting via aiolimiter (5 req/s for free tier)
- Response caching in Redis (TTL: 15s for quotes, 1hr for ticker details)

### 3.4 Claude Chat Integration

Enhance `claude_engine.py`:
- Add `chat()` method for interactive conversation (separate from strategic cycle)
- System prompt dynamically built with: portfolio state, top signals, scanner results, risk metrics
- Tool definitions: `search_scanner`, `get_agent_status`, `get_ticker_signals`, `draft_trade_order`
- Streaming via `client.messages.stream()` for real-time response chunks
- Model: `claude-opus-4-6` for all chat (per spec)

### 3.5 Live Data Feed

New file: `cortex/feeds/market_data.py`
- On startup, fetch Polygon snapshots for watchlist symbols
- Push `MARKET_QUOTE` messages to Swift every 15 seconds
- Feed price data into ALPHA squadron agents via SignalBus
- During market hours: poll Polygon REST every 15s
- After hours: poll every 60s

### 3.6 Connect Claude Engine to Orchestrator

In `create_app_components()`:
- Instantiate `ClaudeEngine` with `config.anthropic_api_key`
- Register strategic cycle as a periodic task (every 5 min)
- Make Claude engine available for chat requests

---

## 4. Performance Fixes

### Swift
1. **Cache TradingView WebView** — keep a single WKWebView instance, update symbol via JavaScript bridge instead of rebuilding HTML
2. **Lazy view loading** — use `LazyView` wrapper so tabs don't initialize until first visit
3. **Batch store updates** — collect WebSocket messages for 100ms then apply all at once to avoid rapid redraws
4. **Pre-connect WebSocket** on app launch, before UI renders

### Python
1. **Redis caching** for Polygon responses (avoid redundant API calls)
2. **Connection pooling** for all HTTP clients (httpx with connection pool)
3. **Batch WebSocket sends** — collect updates for 100ms then send single frame

---

## 5. Keyboard Shortcuts

| Shortcut | Action |
|----------|--------|
| Cmd+K | Kill Switch modal |
| Cmd+T | Quick Trade popover |
| Cmd+/ | Focus AI Chat input |
| Cmd+1-7 | Switch tabs |
| Cmd+B | Toggle sidebar |
| Cmd+Shift+N | New alert rule |

---

## 6. Security

1. All API keys in env vars (CORTEX_ prefix) — never in Swift binary
2. Claude API key stays server-side — Swift sends chat text, Python injects context and calls Claude
3. Kill switch is synchronous in-memory — no network dependency (existing, verified)
4. All broker connections through official APIs only
5. Wash sale guard is a hard gate — no override possible (existing, verified)
6. Risk Guardian approval required before every trade execution (existing, verified)

---

## 7. Implementation Order

### Phase A: Backend Real APIs (Python)
1. Polygon REST client with caching
2. Market data feed (periodic polling + push to Swift)
3. Claude chat integration (streaming + tool use)
4. New WebSocket message types
5. Ticker search endpoint
6. Scanner results push

### Phase B: Swift UI Overhaul
1. Replace TabView with NavigationSplitView + collapsible sidebar
2. War Room overhaul (KPI bar, squadron cards, opportunities, scanner preview)
3. Chart search (symbol picker + JS bridge for TradingView)
4. AI Chat upgrade (rich markdown, side panel, quick prompts, streaming)
5. Scanner view (new)
6. Squadrons view (enhanced)

### Phase C: Wiring + Performance
1. Remove all loadMockData() — stores populate from WebSocket
2. Cache TradingView WebView
3. Lazy view loading
4. Keyboard shortcuts
5. Connect PortfolioStore.isConnected to WebSocketClient state

### Phase D: Polish + Testing
1. Loading states and error handling for all views
2. Empty states when no data
3. Verify kill switch end-to-end
4. Verify risk pipeline end-to-end
5. Test with real Polygon API key
6. Test with real Claude API key
