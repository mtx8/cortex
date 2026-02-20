# CORTEX Mega-Enhancement Design Document

**Date:** 2026-02-20
**Status:** In Progress
**Scope:** 12 major enhancements covering War Room, Trade View, Simulation Mode, Options Calculator, Squadrons, Watchlist, Left Pane UX, and AI Contextual Awareness

---

## Table of Contents

1. [War Room Redesign](#1-war-room-redesign)
2. [Markets View Left Pane Fix](#2-markets-view-left-pane-fix)
3. [Options Profit Calculator](#3-options-profit-calculator)
4. [Squadron Agent Functionality + New Agents](#4-squadron-agent-functionality--new-agents)
5. [Watchlist Fix](#5-watchlist-fix)
6. [Squadron View Enhancement](#6-squadron-view-enhancement)
7. [Left Pane Collapse UX](#7-left-pane-collapse-ux)
8. [Trade View (NEW)](#8-trade-view)
9. [Simulation Mode (NEW)](#9-simulation-mode)
10. [Cortex AI Contextual Awareness](#10-cortex-ai-contextual-awareness)
11. [Cross-Cutting: Consistency & Polish](#11-cross-cutting-consistency--polish)

---

## 1. War Room Redesign

### Problems
- "Live Signals" section shows "no signals" — the backend StatusBroadcaster sends signals via WebSocket but the War Room view isn't subscribing to the `signal_fired` message type or the signal list in the store is never populated
- Activity box takes disproportionate space, crowding the KPI bar and squadron status
- Overall design is functional but lacks the intensity of a professional trading command center

### Root Cause Analysis
The War Room's signal feed relies on `OpportunityStore.opportunities` which only populates when scanner results arrive. When no scanner is actively running (or market is closed), the feed is empty. The activity feed uses a static mock array or a deque that doesn't persist across reconnects.

### Design

**Layout Restructure (3-column grid):**
```
+------------------------------------------+
|  KPI BAR (full width, compact)           |
|  P&L | Win Rate | Sharpe | Positions     |
+------------------------------------------+
| SQUADRON     | SIGNAL FEED  | RISK       |
| STATUS       | (live stream)| DASHBOARD  |
| (6 cards     | entry/exit   | drawdown   |
|  with pulse) | signals,     | VaR gauge  |
|              | fill alerts  | heat map   |
+--------------+--------------+------------+
| ACTIVITY FEED (compact, scrolling)       |
| [severity icon] [time] [message] [agent] |
+------------------------------------------+
```

**Signal Feed Fix:**
- Subscribe to `SignalTypes.ENTRY_SIGNAL`, `EXIT_SIGNAL`, `RISK_BREACH`, `NEWS_CATALYST` in the War Room's store
- Create a new `SignalFeedStore` that accumulates signals from WebSocket `signal_fired` messages
- Show last 50 signals with live animation (slide-in from top)
- When empty: show "Markets Closed — Waiting for signals" with a pulse animation, not just "No signals"

**Activity Feed Compact:**
- Reduce from unbounded height to max 200px with auto-scroll
- Severity-based coloring: green (fills), yellow (warnings), red (risk breaches), blue (info)
- Group repeated events (e.g., "3 fills in last minute" instead of 3 separate entries)

**KPI Bar Enhancements:**
- Sparkline mini-charts (7-day) behind each KPI value using Swift Charts
- Animated value transitions (count-up/down effect)
- Color-coded: green when positive, red when negative, with smooth color transitions

**Risk Dashboard Panel (NEW):**
- Drawdown gauge (circular) — current daily/weekly/total
- VaR value with confidence interval
- Correlation heat map (top 5 positions)
- Kill switch button with animated state indicator

**Priority:** High
**Files affected:**
- Swift: `WarRoomView.swift`, new `SignalFeedStore.swift`, `KPIBar.swift`, new `RiskDashboardView.swift`
- Python: `ws_broadcaster.py` (ensure signals are forwarded), `main.py`

---

## 2. Markets View Left Pane Fix

### Problem
Left pane sections don't reflect the Markets view accurately. The current sections may be hardcoded placeholders from the `AppTab.sections` array that don't match what's actually useful for market analysis.

### Design

**Correct Left Pane Sections for Markets:**
| Section | Purpose |
|---------|---------|
| Favorites | User-starred symbols (persisted) |
| Indices | SPY, QQQ, DIA, IWM, VIX — always visible |
| Stocks | Recently viewed / searched stocks |
| Crypto | BTC, ETH, SOL + user crypto watchlist |
| Options | Option chains the user has opened |
| Sectors | SPDR sector ETFs (XLK, XLF, XLE, etc.) |

**Implementation:**
- Each section click loads the corresponding asset into the TradingView chart
- Sections are populated from a combination of:
  - Hardcoded indices/sectors (always present)
  - User favorites (persisted via `UserDefaults`)
  - Recently viewed symbols (deque, max 20)
- The `selectedSection` environment value wired to switch between section views

**Priority:** Medium
**Files affected:** `AppTab.swift` (sections), `ContentView.swift` (section handling), `MarketsView.swift` (new, or modify `ChartView.swift`)

---

## 3. Options Profit Calculator

### Design Decision
The Options Profit Calculator will be a **new section within the Financials tab** (not a separate tab), accessible via the left pane under "Options Analysis". This keeps the tab count manageable and groups all research tools together.

### Architecture

**Data Flow:**
```
User selects symbol → Fetch option chain from IBKR API (primary) or Polygon (fallback)
  → Display chain table (calls/puts by strike/expiry)
  → User selects contract(s)
  → Calculate P&L surface using Black-Scholes-Merton (speed) with American exercise adjustment
  → Display interactive profit/loss chart
```

**Backend: New Options Data Feed (`cortex-py/cortex/feeds/options.py`)**
- `get_option_chain(symbol)` — fetches full chain from IBKR via `ib_async` or Polygon.io REST
- `calculate_profit(contracts, underlying_prices, dates)` — BSM calculator
- Greeks computation: delta, gamma, theta, vega per leg
- Multi-leg strategy support: verticals, iron condors, straddles, strangles
- Returns: P&L matrix (underlying price x date to expiration)

**Swift UI Components:**
- `OptionChainView` — sortable table with strike prices, bid/ask, volume, OI, IV, Greeks
- `ProfitCalculatorView` — interactive P&L chart (Swift Charts), sliders for price range and date
- `StrategyBuilderView` — select multiple legs, auto-detect strategy type
- Heatmap visualization: profit zones (green) vs loss zones (red) across price/time grid

**Calculation Engine:**
- Black-Scholes-Merton for European-style (most options)
- Binomial tree (50-step) for American-style when early exercise matters
- IV from market mid prices using Newton-Raphson root finding
- Max profit, max loss, breakeven points auto-calculated

**WebSocket Messages:**
- New `CMD_GET_OPTION_CHAIN` (type 107) — request chain for symbol
- New `OPTION_CHAIN_DATA` (type 9) — response with full chain
- New `CMD_CALCULATE_PROFIT` (type 108) — request P&L calculation
- New `PROFIT_CALCULATION` (type 10) — response with P&L matrix

**Priority:** High (core value-add for options trading)
**Files affected:**
- Python: new `cortex/feeds/options.py`, new `cortex/calculators/options_pricing.py`, modify `main.py`, modify `protocol.py`
- Swift: new `OptionChainView.swift`, new `ProfitCalculatorView.swift`, new `OptionsStore.swift`, modify `FinancialsView.swift`

---

## 4. Squadron Agent Functionality + New Agents

### Current State Assessment
The 44 agents are **defined and registered** but most run on **mock/simulated data**. Key issues:
- Agents fire signals only when their data feeds provide real data
- Without Polygon.io and IBKR connected with real API keys, agents operate on placeholder data
- The agents ARE functional code — they just need live data to produce real signals

### Making Agents Truly Functional
1. **Wire live data feeds**: Polygon.io WebSocket → Redis Streams → Agent consumer groups
2. **IBKR paper trading**: Connect to IBKR paper account (port 4002) for real market data without real money
3. **Ensure signal flow**: ALPHA signals → ECHO risk checks → BRAVO execution → audit trail

### New Agent Teams for Profit Maximization

**GOLF Squadron — Adaptive Learning (8 agents, NEW)**

| Agent | Purpose | Value |
|-------|---------|-------|
| Trade Historian | Analyzes all historical trades, win/loss patterns by time, sector, catalyst | Foundation for learning |
| Pattern Learner | Identifies repeating patterns in winning trades (entry timing, sector, market regime) | Improves signal quality |
| Strategy Optimizer | A/B tests different parameter combinations on historical data | Finds optimal configs |
| Regime Detector | Classifies current market regime (trending/ranging/volatile/crash) in real-time | Adapts strategy |
| Performance Tracker | Tracks P&L attribution by agent, strategy, and time period | Identifies what works |
| Drawdown Analyzer | Studies drawdown patterns to predict and prevent future drawdowns | Risk reduction |
| Sector Momentum Tracker | Tracks sector rotation patterns and momentum persistence | Sector allocation |
| Correlation Tracker | Real-time correlation shifts between assets | Portfolio construction |

**HOTEL Squadron — Market Microstructure (6 agents, NEW)**

| Agent | Purpose | Value |
|-------|---------|-------|
| Spread Analyzer | Monitors bid-ask spreads for optimal entry timing | Reduces slippage |
| Depth Reader | Analyzes Level 2 order book for supply/demand imbalance | Better entries |
| Tick Analyzer | Detects abnormal tick patterns (accumulation/distribution) | Early signal |
| Price Level Mapper | Identifies key support/resistance from order flow | Entry/exit levels |
| Execution Optimizer | Routes orders to minimize market impact | Saves on execution |
| Latency Monitor | Tracks end-to-end latency from signal to fill | System health |

**Why These Squadrons:**
- Starting with $25K-$100K, the path to millions requires:
  1. **Compounding small edges** — Golf Squadron identifies what works and doubles down
  2. **Minimizing losses** — learning from drawdowns prevents account destruction
  3. **Optimal execution** — Hotel Squadron saves 5-15% on slippage, which compounds
  4. **Regime awareness** — not trading counter-trend in crashes preserves capital
- Estimated edge: 0.2-0.5% per trade improvement from learning + 0.1-0.3% from better execution
- At 50 trades/day, that's $50-400/day additional edge on $100K → $12K-$100K/year just from optimization

**Total Agent Count: 44 + 14 = 58 agents across 8 squadrons**

**Priority:** Critical (agents are the profit engine)
**Files affected:**
- Python: new `cortex/squadrons/golf/` (8 agents), new `cortex/squadrons/hotel/` (6 agents)
- Python: modify `main.py` (register new squadrons), modify `orchestrator/system.py`
- Swift: modify `SquadronsDetailView.swift` (show new squadrons)

---

## 5. Watchlist Fix

### Root Cause Analysis
The Watchlist view likely has these bugs:
1. **No shared state**: Adding a symbol in another view (e.g., Markets) doesn't write to the WatchlistStore
2. **No persistence**: WatchlistStore resets on app relaunch
3. **Alert system not wired**: Alert creation UI exists but doesn't connect to backend price monitoring

### Design

**Fix 1: Shared WatchlistStore**
- Make `WatchlistStore` a singleton in `AppEnvironment` (it likely already is)
- Add `addToWatchlist(symbol:)` method that:
  1. Adds to in-memory array
  2. Persists to UserDefaults (or SQLite for more complex data)
  3. Sends `CMD_SUBSCRIBE_WATCHLIST` to backend for real-time price updates
- Wire "Add to Watchlist" buttons in Markets, Scanner, Financials views to call this method

**Fix 2: Persistence**
- `UserDefaults.standard.set(symbols, forKey: "cortex_watchlist")` on every mutation
- Load on init: `UserDefaults.standard.stringArray(forKey: "cortex_watchlist") ?? []`

**Fix 3: Alert System**
- Backend: new `cortex/feeds/alerts.py` — price alert engine
  - Monitors price thresholds via Polygon.io WebSocket
  - Sends `ALERT_TRIGGERED` (new message type 11) when price crosses threshold
- Swift: `AlertStore` manages alert CRUD
  - Alert types: Price Above, Price Below, % Change, Volume Spike
  - Push notification via `UNUserNotificationCenter` when alert triggers
  - Visual badge on Watchlist tab when alerts are active

**Priority:** High (broken core feature)
**Files affected:**
- Swift: `WatchlistView.swift`, new/modify `WatchlistStore.swift`, new `AlertStore.swift`
- Python: new `cortex/feeds/alerts.py`, modify `protocol.py`, modify `main.py`

---

## 6. Squadron View Enhancement

### Design

**Agent Grid Tooltips:**
Each agent card on hover shows a floating tooltip with:
```
+----------------------------------+
| Signal Hunter (ALPHA)            |
| Status: Active [green dot]       |
| -------------------------------- |
| Signals Fired: 142               |
| Win Rate: 67.3%                  |
| Avg Signal Quality: 78/100       |
| Last Signal: AAPL (2m ago)       |
| Error Rate: 0.7%                 |
| CPU Usage: 2.1ms avg             |
+----------------------------------+
```

**Implementation:** SwiftUI `.popover()` or custom `NSPopover` on hover, with `.onHover` modifier

**Additional Features:**
1. **Agent Activity Timeline** — horizontal timeline showing when each agent fired signals (last 24h)
2. **Squadron Performance Comparison** — bar chart comparing squadron P&L contributions
3. **Agent Dependency Graph** — visual graph showing signal flow between agents (which agents feed which)
4. **Real-time Signal Stream** — live feed of signals flowing through SignalBus, filterable by squadron
5. **Agent Configuration Panel** — adjust agent parameters (thresholds, timeframes) without code changes
6. **Health Monitoring** — circuit breaker status, error counts, response times per agent

**Priority:** Medium
**Files affected:** `SquadronsDetailView.swift`, new `AgentTooltipView.swift`, new `AgentTimelineView.swift`, new `SquadronComparisonChart.swift`

---

## 7. Left Pane Collapse UX

### Problem
The collapse arrow is at the bottom of the left pane, which is unintuitive. User wants a modern hover-reveal mechanism integrated into the divider line.

### Design

**Behavior:**
1. **Expanded state (220px)**: Full left pane with section labels
2. **Hover over divider line**: A small chevron arrow (`chevron.left`) fades in at the vertical midpoint of the divider
3. **Click chevron**: Pane collapses to icon rail (52px) with smooth 200ms animation
4. **Collapsed state**: Only SF Symbol icons visible, no labels
5. **Hover over collapsed rail**: The chevron (`chevron.right`) appears on the divider to re-expand
6. **Keyboard shortcut**: `Cmd+B` toggles between states (already specified in design)

**Implementation:**
```swift
// Divider with hover-reveal arrow
ZStack {
    Rectangle()
        .fill(Color(white: 0.12))
        .frame(width: 1)

    if isHoveringDivider {
        Image(systemName: isCollapsed ? "chevron.right" : "chevron.left")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(.secondary)
            .padding(4)
            .background(Circle().fill(Color(white: 0.15)))
            .transition(.opacity.combined(with: .scale))
            .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { isCollapsed.toggle() } }
    }
}
.frame(width: 12)
.onHover { hovering in
    withAnimation(.easeInOut(duration: 0.15)) { isHoveringDivider = hovering }
}
```

**Remove** the bottom arrow entirely.

**Priority:** Medium
**Files affected:** `ContentView.swift`, `ContextPaneView.swift`, `TabBarView.swift`

---

## 8. Trade View (NEW)

### Architecture Decision
**IBKR-first, DAS Trader as optional add-on.** DAS Trader requires a paid subscription and has limited API access. IBKR provides everything needed for Level 2, orders, and positions. DAS Trader support will be a toggle in Settings that swaps the execution layer.

### Design

**Trade View Layout:**
```
+------------------------------------------------------+
| SYMBOL BAR: [AAPL ▼] [Bid: 189.50] [Ask: 189.52]   |
| [Mode: FULL AUTO ⚡] [Last: 189.51] [Vol: 12.3M]    |
+------------------------------------------------------+
| CHART (60%)           | LEVEL 2 BOOK (20%) | ORDER   |
| TradingView           | +-----------+      | PANEL   |
| with drawings         | | Bid  Ask  |      | (20%)   |
| and indicators        | | 189.50 52 |      |         |
|                       | | 189.48 55 |      | Qty:[10]|
|                       | | 189.45 60 |      | Type:LMT|
|                       | | --------- |      | Price:  |
|                       | | 189.52 48 |      | [BUY]   |
|                       | | 189.55 42 |      | [SELL]  |
|                       | | 189.58 38 |      | [SHORT] |
+------------------------------------------------------+
| TIME & SALES          | POSITIONS (open)              |
| [Time][Price][Size]   | AAPL +10 @ 185.20 P&L: +$43  |
| 14:32:01 189.51 200   | MSFT +5  @ 410.50 P&L: -$12  |
| 14:32:00 189.50 500   | TSLA +3  @ 245.00 P&L: +$67  |
+------------------------------------------------------+
| ORDER HISTORY (today)                                 |
| [Filled] BUY 10 AAPL @ 185.20 | 14:15:03            |
+------------------------------------------------------+
```

**Trading Modes:**
| Mode | Behavior | UI Indicator |
|------|----------|--------------|
| Manual | All orders require user click. AI only provides suggestions in AI pane. | Blue badge |
| Semi-Manual | AI suggests trades, user approves/rejects via notification. Small trades auto-execute. | Yellow badge |
| Full Auto | AI executes all trades autonomously via ECHO risk checks. User monitors. | Red lightning bolt |

**Mode stored in `AutonomyDial` on backend, synced to Swift via WebSocket.**

**Level 2 Data Architecture:**
```
IBKR TWS API (ib_async)
  → reqMktDepth(symbol, numRows=20)
  → depth updates via callback
  → Python formats to L2 update message
  → WebSocket binary frame to Swift
  → L2Store renders bid/ask depth table
```

New WebSocket message types:
- `L2_UPDATE` (type 12) — Level 2 order book snapshot
- `TIME_SALES` (type 13) — time and sales tick
- `POSITION_UPDATE` (type 14) — position change
- `ORDER_STATUS` (type 15) — order lifecycle update
- `CMD_SUBMIT_ORDER` (type 109) — user submits order
- `CMD_CANCEL_ORDER` (type 110) — user cancels order
- `CMD_SET_TRADING_MODE` (type 111) — change autonomy mode

**DAS Trader Fallback:**
- Settings toggle: "Execution Provider: IBKR (default) / DAS Trader"
- When DAS Trader selected, orders route through DAS API instead of IBKR
- If DAS subscription expires, auto-fallback to IBKR with user notification
- DAS connector: `cortex/connectors/das/client.py` (future, not MVP)

**Priority:** Critical (core trading functionality)
**Files affected:**
- Swift: new `TradeView.swift`, new `Level2View.swift`, new `OrderPanelView.swift`, new `TimeSalesView.swift`, new `PositionsView.swift`, new `TradeStore.swift`, new `Level2Store.swift`
- Python: new `cortex/feeds/level2.py`, new `cortex/feeds/time_sales.py`, modify `protocol.py`, modify `main.py`, modify `connectors/ibkr/client.py` (add L2 + order methods)
- Modify `AppTab.swift` (add Trade tab)

---

## 9. Simulation Mode (NEW)

### Architecture Decision
**Dual-mode simulation**: IBKR Paper Trading (when IBKR is available) + In-Process Simulation Engine (always available, faster iteration).

### Design

**Simulation Engine (`cortex-py/cortex/simulation/`)**

```
SimulationEngine
  ├── PaperPortfolio (fake $100K starting balance)
  ├── MarketReplay (historical or live-delayed data)
  ├── AgentRunner (all 58 agents run in simulation context)
  ├── LearningTracker (records what works)
  └── PerformanceAnalyzer (real-time metrics)
```

**Key Components:**

1. **PaperPortfolio** — in-memory portfolio with fake cash
   - Tracks positions, P&L, drawdown, win rate
   - Identical risk checks to live (ECHO squadron validates)
   - Commission simulation (IBKR fee schedule)

2. **MarketReplay** — feeds historical data to agents
   - Replays Polygon.io historical bars at configurable speed (1x, 10x, 100x)
   - Or uses live-delayed data (15-min delay, free tier)

3. **LearningTracker** — the brain of the simulation
   - Records every trade with full context: market regime, sector, catalyst, entry/exit timing
   - Clusters winning trades by pattern: what signal type, what time of day, what sector, what volatility
   - Identifies anti-patterns: what consistently loses money
   - Outputs learning summary that feeds back into agent parameters

4. **New GOLF Squadron Agents for Simulation:**
   - **Trade Historian**: Stores and indexes all simulation trades
   - **Pattern Learner**: Runs pattern mining on trade history (association rules)
   - **Strategy Optimizer**: Grid search over agent parameters, tracks Sharpe ratio by config
   - **Regime Detector**: Classifies market regimes and maps to optimal strategies

**Simulation UI (Swift):**
```
+--------------------------------------------------+
| SIMULATION DASHBOARD                              |
| Starting Capital: $100,000 | Mode: Full Auto     |
+--------------------------------------------------+
| EQUITY CURVE          | STATS                    |
| [chart rising/falling]| Total P&L: +$12,450      |
|                       | Win Rate: 63.2%           |
|                       | Sharpe: 1.85              |
|                       | Max DD: -4.3%             |
|                       | Trades: 342               |
|                       | Avg Win: $182             |
|                       | Avg Loss: -$95            |
+--------------------------------------------------+
| LEARNING INSIGHTS                                 |
| Best Sector: Tech (72% win rate)                 |
| Best Time: 10:00-11:00 AM (68% win rate)         |
| Worst Pattern: Reversal signals (41% win rate)    |
| Top Agent: Signal Hunter (contributes 34% of P&L)|
+--------------------------------------------------+
| RECENT TRADES (simulated)                        |
| [W] BUY AAPL +10 @ 185 → SELL @ 189 = +$40     |
| [L] BUY TSLA +3  @ 245 → SELL @ 242 = -$9      |
+--------------------------------------------------+
| [Start Simulation] [Pause] [Reset] [Speed: 10x] |
+--------------------------------------------------+
```

**How Learning Works:**
1. Run simulation for N days (backtest) or continuous (paper trading)
2. After each trade, record: `{signal_type, agent, symbol, sector, market_regime, time_of_day, vix_level, volume_ratio, catalyst, pnl, hold_time}`
3. Every 100 trades, Pattern Learner runs analysis:
   - Group winning trades by features
   - Identify statistically significant patterns (chi-squared test)
   - Output: "Momentum signals in Tech sector between 10-11 AM during bullish regime have 72% win rate"
4. Strategy Optimizer adjusts agent parameters based on learnings
5. Feed new parameters to agents via `intelligence.strategy_update` signal

**Priority:** Critical (de-risks live trading, enables self-improvement)
**Files affected:**
- Python: new `cortex/simulation/engine.py`, new `cortex/simulation/paper_portfolio.py`, new `cortex/simulation/market_replay.py`, new `cortex/simulation/learning_tracker.py`
- Python: new `cortex/squadrons/golf/trade_historian.py`, etc. (8 agents)
- Swift: new `SimulationView.swift`, new `SimulationStore.swift`, new `LearningInsightsView.swift`
- Modify `AppTab.swift` (add Simulation mode toggle within Trade view)

---

## 10. Cortex AI Contextual Awareness

### Current State
The AI pane (CortexAIPane) sends messages via WebSocket and receives streaming responses. Context injection exists but is limited.

### Enhancement Design

**Full Context Protocol:**
Every AI message will include rich context:
```json
{
  "type": "cmd_chat_message",
  "payload": {
    "message": "user question",
    "context": {
      "current_tab": "trade",
      "current_section": "positions",
      "selected_symbol": "AAPL",
      "portfolio_summary": {
        "nav": 52340.50,
        "daily_pnl": 340.20,
        "open_positions": 5,
        "win_rate": 0.634
      },
      "visible_data": {
        "positions": [...],
        "recent_signals": [...],
        "active_alerts": [...]
      },
      "market_context": {
        "spy_change": 0.42,
        "vix": 18.5,
        "market_regime": "bullish"
      },
      "simulation_active": false,
      "autonomy_level": "semi_auto"
    }
  }
}
```

**Per-View AI Capabilities:**

| View | AI Context | AI Can Do |
|------|-----------|-----------|
| War Room | Full portfolio, all signals, risk state | "Should I engage the kill switch?" → analyzes risk |
| Trade | Current symbol, L2 data, positions | "Good entry for AAPL?" → analyzes technicals + fundamentals |
| Scanner | Current filters, opportunities | "Find me short candidates" → adjusts scanner filters |
| Financials | Selected symbol, fundamentals | "Analyze TSLA earnings" → comprehensive research |
| Watchlist | Watchlist symbols, alerts | "Set alert when NVDA drops 5%" → creates alert |
| Squadrons | Agent health, signal history | "Why did Signal Hunter fire on AAPL?" → traces signal |
| Simulation | Simulation stats, learning insights | "What patterns are working?" → summarizes learnings |
| Settings | Current config | "Increase risk tolerance" → suggests parameter changes |

**Backend Enhancement:**
- `cortex/intelligence/chat.py`: Accept and parse rich context object
- Build system prompt dynamically based on current tab and visible data
- Claude receives full portfolio state on every message
- Response actions: AI can return structured actions (create alert, adjust filter, suggest trade) that the UI can execute

**Priority:** High
**Files affected:**
- Swift: `CortexAIPane.swift`, `ChatStore.swift` (enrich context payload)
- Python: `cortex/intelligence/chat.py` (parse context), `cortex/intelligence/prompts.py` (dynamic system prompt)

---

## 11. Cross-Cutting: Consistency & Polish

### Design System Tokens
Enforce these across ALL views:

```swift
// Colors
static let bgDeepest = Color(white: 0.06)
static let bgCard = Color(white: 0.08)
static let bgHover = Color(white: 0.10)
static let border = Color(white: 0.12)
static let borderHover = Color(white: 0.18)
static let accentPrimary = Color.cyan
static let accentSecondary = Color.blue
static let profit = Color.green
static let loss = Color.red
static let warning = Color.orange

// Typography
static let dataFont = Font.system(.body, design: .monospaced)
static let labelFont = Font.system(.caption)
static let headerFont = Font.system(.title3, weight: .bold)

// Spacing
static let cardRadius: CGFloat = 8
static let badgeRadius: CGFloat = 6
static let inputRadius: CGFloat = 12
static let cardPadding: CGFloat = 12
```

### Animations
- All value changes: `.animation(.spring(duration: 0.3), value: ...)`
- View transitions: `.transition(.move(edge: .leading).combined(with: .opacity))`
- Loading states: Shimmer effect on data placeholders
- Pulse effect on live/connected indicators

### Tab Bar Enhancement
Add new Trade tab to the navigation:
```
War Room | Markets | Scanner | Trade | Financials | Watchlist | Squadrons | Performance | Settings
```

---

## New WebSocket Message Types Summary

| Type ID | Name | Direction | Purpose |
|---------|------|-----------|---------|
| 9 | OPTION_CHAIN_DATA | Server→Client | Options chain response |
| 10 | PROFIT_CALCULATION | Server→Client | P&L calculator result |
| 11 | ALERT_TRIGGERED | Server→Client | Price alert notification |
| 12 | L2_UPDATE | Server→Client | Level 2 order book |
| 13 | TIME_SALES | Server→Client | Time and sales ticks |
| 14 | POSITION_UPDATE | Server→Client | Position change |
| 15 | ORDER_STATUS | Server→Client | Order lifecycle |
| 16 | SIMULATION_UPDATE | Server→Client | Simulation state |
| 17 | LEARNING_INSIGHT | Server→Client | Pattern learner output |
| 107 | CMD_GET_OPTION_CHAIN | Client→Server | Request option chain |
| 108 | CMD_CALCULATE_PROFIT | Client→Server | Request P&L calc |
| 109 | CMD_SUBMIT_ORDER | Client→Server | Submit trade order |
| 110 | CMD_CANCEL_ORDER | Client→Server | Cancel order |
| 111 | CMD_SET_TRADING_MODE | Client→Server | Change autonomy mode |
| 112 | CMD_START_SIMULATION | Client→Server | Start/stop simulation |
| 113 | CMD_ADD_WATCHLIST | Client→Server | Add to watchlist |
| 114 | CMD_CREATE_ALERT | Client→Server | Create price alert |

---

## Implementation Phases

### Phase A: Foundation Fixes (Priority: Critical)
1. Watchlist data flow fix + persistence
2. Left pane collapse UX
3. Markets view left pane sections
4. War Room signal feed fix
5. Design system tokens (CortexDesign.swift)

### Phase B: War Room + Squadrons (Priority: High)
6. War Room full redesign (3-column layout, risk dashboard)
7. Squadron view tooltips + timeline
8. Wire existing agents to live data feeds
9. AI contextual awareness enhancement

### Phase C: Trade View + Options (Priority: Critical)
10. Trade view with Level 2 data
11. Order panel + execution
12. Options profit calculator
13. Trading mode selector (Manual/Semi/Auto)

### Phase D: New Agents + Simulation (Priority: Critical)
14. GOLF Squadron (8 learning agents)
15. HOTEL Squadron (6 microstructure agents)
16. Simulation engine + paper portfolio
17. Learning tracker + pattern mining
18. Simulation UI

### Phase E: Polish + Integration (Priority: Medium)
19. Activity feed compact redesign
20. Alert system backend + UI
21. DAS Trader connector (optional)
22. Cross-view consistency audit
23. Performance optimization pass

---

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| IBKR L2 data rate limits | Medium | High | Rate limiter per CLAUDE.md, request only active symbol |
| BSM calculation accuracy | Low | Medium | Validate against known option prices, add IV smile adjustment |
| Agent learning overfits | Medium | High | Walk-forward validation, minimum 200 trade sample size |
| WebSocket message flood | Medium | Medium | BatchAccumulator already coalesces at 16.67ms |
| Swift app memory with L2 | Low | High | Ring buffer for L2 updates, max 20 levels |
| Simulation diverges from live | Medium | Medium | Use realistic commission + slippage models |

---

## Agent Count Summary

| Squadron | Current Agents | New Agents | Total |
|----------|---------------|------------|-------|
| ALPHA (Signal Intelligence) | 6 | 0 | 6 |
| BRAVO (Execution) | 7 | 0 | 7 |
| CHARLIE (Options) | 6 | 0 | 6 |
| DELTA (Intelligence) | 8 | 0 | 8 |
| ECHO (Risk Management) | 8 | 0 | 8 |
| FOXTROT (Tax & Crypto) | 9 | 0 | 9 |
| **GOLF (Adaptive Learning)** | 0 | **8** | **8** |
| **HOTEL (Microstructure)** | 0 | **6** | **6** |
| **Total** | **44** | **14** | **58** |
