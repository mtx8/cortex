# CORTEX Mega-Enhancement Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Implement 12 major enhancements to transform CORTEX into a professional-grade autonomous trading command center with Trade View, Simulation Mode, Options Calculator, 2 new agent squadrons, and comprehensive UI/UX improvements.

**Architecture:** 5 implementation phases targeting Swift macOS app (SwiftUI + @Observable) and Python backend (FastAPI + asyncio). All communication over JSON WebSocket at ws://127.0.0.1:8765/ws. New features follow the established MessageRouter + Store pattern in Swift and the SignalBus + BaseAgent pattern in Python.

**Tech Stack:** Swift 5.9+/SwiftUI/@Observable, Python 3.12+/FastAPI/asyncio, orjson WebSocket protocol, Claude API (Anthropic SDK), Polygon.io, IBKR (ib_async), Black-Scholes-Merton options pricing

**Design doc:** `docs/plans/2026-02-20-mega-enhancement-design.md`

---

## Phase A: Foundation Fixes (Priority: Critical)

These are bug fixes and UX improvements that unblock everything else.

### Task 1: Design System Tokens

**Files:**
- Create: `cortex-app/Sources/CortexCore/CortexDesign.swift`

**Step 1: Create CortexDesign with all design tokens**

```swift
// cortex-app/Sources/CortexCore/CortexDesign.swift
import SwiftUI

public enum CortexDesign {
    // Background
    public static let bgDeepest = Color(white: 0.06)
    public static let bgCard = Color(white: 0.08)
    public static let bgHover = Color(white: 0.10)
    public static let bgElevated = Color(white: 0.12)

    // Borders
    public static let border = Color(white: 0.12)
    public static let borderHover = Color(white: 0.18)

    // Accent
    public static let accentPrimary = Color.cyan
    public static let accentSecondary = Color.blue

    // Semantic
    public static let profit = Color.green
    public static let loss = Color.red
    public static let warning = Color.orange
    public static let neutral = Color(white: 0.5)

    // Typography
    public static let dataFont = Font.system(.body, design: .monospaced)
    public static let labelFont = Font.system(.caption)
    public static let headerFont = Font.system(.title3, weight: .bold)
    public static let kpiFont = Font.system(size: 24, weight: .bold, design: .monospaced)

    // Spacing
    public static let cardRadius: CGFloat = 8
    public static let badgeRadius: CGFloat = 6
    public static let inputRadius: CGFloat = 12
    public static let cardPadding: CGFloat = 12

    // Shared card style
    public static func cardBackground() -> some View {
        RoundedRectangle(cornerRadius: cardRadius)
            .fill(bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: cardRadius)
                    .strokeBorder(border, lineWidth: 1)
            )
    }
}
```

**Step 2: Commit**

```bash
git add cortex-app/Sources/CortexCore/CortexDesign.swift
git commit -m "feat: add CortexDesign system tokens for consistent styling"
```

---

### Task 2: Fix Watchlist — Add to Watchlist + Persistence

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Stores/WatchlistStore.swift`
- Modify: `cortex-app/Sources/CortexCore/Views/WatchlistView.swift`

**Step 1: Add persistence and addSymbol method to WatchlistStore**

In `WatchlistStore.swift`, add:
- `UserDefaults` persistence for watchlist symbols
- `addSymbol(_:)` public method
- `removeSymbol(_:)` public method
- Load saved symbols on init

Key changes:
```swift
// Add to WatchlistStore
private static let persistenceKey = "cortex_watchlist_symbols"

public init() {
    // Load persisted symbols, fallback to defaults
    let saved = UserDefaults.standard.stringArray(forKey: Self.persistenceKey)
    let symbols = saved ?? Self.defaultSymbols
    items = symbols.map { WatchlistItem(symbol: $0, price: 0) }
}

public func addSymbol(_ symbol: String) {
    guard !items.contains(where: { $0.symbol == symbol }) else { return }
    items.append(WatchlistItem(symbol: symbol, price: 0))
    persist()
}

public func removeSymbol(_ symbol: String) {
    items.removeAll { $0.symbol == symbol }
    persist()
}

private func persist() {
    let symbols = items.map(\.symbol)
    UserDefaults.standard.set(symbols, forKey: Self.persistenceKey)
}
```

**Step 2: Add "Add to Watchlist" button in WatchlistView and wire from other views**

Add a text field + button at the top of `WatchlistView` for manual symbol addition. The `addSymbol` method can also be called from Scanner, Markets, or Financials views.

**Step 3: Commit**

```bash
git add cortex-app/Sources/CortexCore/Stores/WatchlistStore.swift cortex-app/Sources/CortexCore/Views/WatchlistView.swift
git commit -m "fix: watchlist persistence and addSymbol/removeSymbol methods"
```

---

### Task 3: Left Pane Hover-Reveal Collapse

**Files:**
- Modify: `cortex-app/Sources/CortexApp/ContentView.swift`
- Modify: `cortex-app/Sources/CortexCore/Views/Navigation/ContextPaneView.swift`

**Step 1: Replace bottom collapse arrow with divider hover-reveal**

In `ContentView.swift`, replace the plain `Divider()` between the context pane and main content with a custom divider that shows a chevron on hover:

```swift
// Replace the Divider between context pane and content
ZStack {
    Rectangle()
        .fill(Color(white: 0.12))
        .frame(width: 1)

    // Hover-reveal collapse chevron
    if isHoveringDivider {
        Button(action: {
            withAnimation(.easeInOut(duration: 0.2)) {
                if contextPaneMode == .hidden {
                    contextPaneMode = .full
                } else if contextPaneMode == .full {
                    contextPaneMode = .iconOnly
                } else {
                    contextPaneMode = .full
                }
            }
        }) {
            Image(systemName: contextPaneMode == .iconOnly || contextPaneMode == .hidden
                  ? "chevron.right" : "chevron.left")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .padding(5)
                .background(Circle().fill(Color(white: 0.15)))
        }
        .buttonStyle(.plain)
        .transition(.opacity.combined(with: .scale))
    }
}
.frame(width: 12)
.contentShape(Rectangle())
.onHover { hovering in
    withAnimation(.easeInOut(duration: 0.15)) { isHoveringDivider = hovering }
}
```

Add `@State private var isHoveringDivider: Bool = false` to ContentView.

**Step 2: Remove the bottom collapse button from ContextPaneView if it exists**

**Step 3: Commit**

```bash
git add cortex-app/Sources/CortexApp/ContentView.swift cortex-app/Sources/CortexCore/Views/Navigation/ContextPaneView.swift
git commit -m "feat: hover-reveal divider arrow for left pane collapse"
```

---

### Task 4: Add Trade Tab to Navigation

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Views/Navigation/AppTab.swift`
- Modify: `cortex-app/Sources/CortexApp/ContentView.swift`

**Step 1: Add .trade case to AppTab enum**

Insert `case trade = "Trade"` after `scanner` in the AppTab enum. Add icon (`"chart.bar.doc.horizontal"`), shortcut (`"4"`), and sections:
```swift
case .trade:
    return [
        ("chart.line.uptrend.xyaxis", "Chart & L2"),
        ("list.bullet.rectangle", "Positions"),
        ("clock.arrow.circlepath", "Orders"),
        ("play.circle", "Simulation"),
    ]
```

Renumber shortcuts for tabs after trade (financials=5, watchlist=6, etc.)

**Step 2: Add .trade route in ContentView.contentForTab()**

```swift
case .trade:
    TradeView(environment: environment)
```

(TradeView will be created in Phase C, use a placeholder Text("Trade View — Coming Soon") for now)

**Step 3: Commit**

```bash
git add cortex-app/Sources/CortexCore/Views/Navigation/AppTab.swift cortex-app/Sources/CortexApp/ContentView.swift
git commit -m "feat: add Trade tab to navigation with placeholder view"
```

---

### Task 5: Fix War Room Signal Feed

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Views/WarRoomView.swift`

**Step 1: Wire SignalFeedStore into War Room view**

The `SignalFeedStore` already exists and receives signals via `MessageRouter` (case "signal_fired"). The War Room needs to display these signals instead of showing "No signals".

In `WarRoomView.swift`, replace the empty signal section with:
```swift
// Signal feed section
if environment.signalFeed.recentSignals.isEmpty {
    VStack(spacing: 8) {
        Image(systemName: "antenna.radiowaves.left.and.right")
            .font(.system(size: 24))
            .foregroundStyle(.secondary)
            .symbolEffect(.pulse)
        Text("Waiting for market signals...")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
} else {
    ScrollView {
        LazyVStack(spacing: 6) {
            ForEach(environment.signalFeed.recentSignals) { signal in
                SignalRow(signal: signal)
            }
        }
        .padding(8)
    }
}
```

**Step 2: Reduce activity feed max height**

Constrain the activity feed section: `.frame(maxHeight: 200)`

**Step 3: Commit**

```bash
git add cortex-app/Sources/CortexCore/Views/WarRoomView.swift
git commit -m "fix: wire SignalFeedStore into War Room, reduce activity feed size"
```

---

## Phase B: War Room + Squadrons Enhancement

### Task 6: War Room 3-Column Layout Redesign

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Views/WarRoomView.swift`
- Modify: `cortex-app/Sources/CortexCore/Views/Components/KPIBar.swift`
- Create: `cortex-app/Sources/CortexCore/Views/Components/RiskDashboardView.swift`

**Step 1: Redesign KPIBar with sparklines**

Add mini sparkline charts behind KPI values using Swift Charts. Each KPI card shows:
- Value with animated count transition
- 7-day trend sparkline
- Color: green for positive, red for negative

**Step 2: Create RiskDashboardView**

New component showing:
- Drawdown gauge (circular progress)
- VaR display
- Kill switch status indicator with animated pulse

**Step 3: Restructure War Room into 3-column grid**

```
KPI Bar (full width)
[Squadron Status | Signal Feed | Risk Dashboard]
Activity Feed (compact, max 200px)
```

Use `LazyVGrid` with adaptive columns.

**Step 4: Commit**

```bash
git add cortex-app/Sources/CortexCore/Views/WarRoomView.swift cortex-app/Sources/CortexCore/Views/Components/KPIBar.swift cortex-app/Sources/CortexCore/Views/Components/RiskDashboardView.swift
git commit -m "feat: War Room 3-column redesign with risk dashboard and sparklines"
```

---

### Task 7: Squadron View Tooltips + Enhancement

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Views/SquadronsDetailView.swift`

**Step 1: Add .onHover tooltip to each agent card**

Use `.popover(isPresented:)` triggered by `.onHover` modifier. Tooltip shows:
- Agent name and squadron
- Status with colored indicator
- Signal count, win rate, error rate
- Last signal time (relative, e.g., "2m ago")
- Average processing time

**Step 2: Add squadron performance comparison chart**

Below the agent grid, add a horizontal bar chart comparing squadron P&L contributions using Swift Charts.

**Step 3: Add GOLF and HOTEL squadron sections (placeholder)**

Add sections for the new squadrons in the view. They'll show "Not yet deployed" until Phase D.

**Step 4: Commit**

```bash
git add cortex-app/Sources/CortexCore/Views/SquadronsDetailView.swift
git commit -m "feat: squadron tooltips, performance chart, and new squadron sections"
```

---

### Task 8: Enhance AI Contextual Awareness

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Stores/ChatStore.swift`
- Modify: `cortex-py/cortex/intelligence/chat.py`
- Modify: `cortex-py/cortex/intelligence/prompts.py`

**Step 1: Enrich context payload in ChatStore.sendMessage()**

When sending a chat message, include full context:
```swift
let context: [String: Any] = [
    "current_tab": currentTab?.rawValue ?? "",
    "current_section": currentSection ?? "",
    "selected_symbol": selectedSymbol ?? "",
    // portfolio, positions, etc. already injected on backend
]
```

**Step 2: Update Python chat.py to use enriched context in system prompt**

Build a dynamic system prompt that adapts to the current tab. When on Trade view, emphasize technical analysis. When on Squadrons, emphasize agent health. When on Simulation, emphasize learning insights.

**Step 3: Commit**

```bash
git add cortex-app/Sources/CortexCore/Stores/ChatStore.swift cortex-py/cortex/intelligence/chat.py cortex-py/cortex/intelligence/prompts.py
git commit -m "feat: enriched AI context awareness across all views"
```

---

## Phase C: Trade View + Options Calculator

### Task 9: Backend — New WebSocket Message Types

**Files:**
- Modify: `cortex-py/cortex/api/protocol.py`

**Step 1: Add new message types for Trade View**

Add to `MessageType` enum:
```python
# Trade View
L2_UPDATE = "l2_update"
TIME_SALES = "time_sales"
POSITION_UPDATE = "position_update"
ORDER_STATUS = "order_status"
CMD_SUBMIT_ORDER = "cmd_submit_order"
CMD_CANCEL_ORDER = "cmd_cancel_order"
CMD_SET_TRADING_MODE = "cmd_set_trading_mode"

# Options
OPTION_CHAIN_DATA = "option_chain_data"
PROFIT_CALCULATION = "profit_calculation"
CMD_GET_OPTION_CHAIN = "cmd_get_option_chain"
CMD_CALCULATE_PROFIT = "cmd_calculate_profit"

# Watchlist & Alerts
ALERT_TRIGGERED = "alert_triggered"
CMD_ADD_WATCHLIST = "cmd_add_watchlist"
CMD_CREATE_ALERT = "cmd_create_alert"

# Simulation
SIMULATION_UPDATE = "simulation_update"
LEARNING_INSIGHT = "learning_insight"
CMD_START_SIMULATION = "cmd_start_simulation"
```

**Step 2: Add tests for new message types**

**Step 3: Commit**

```bash
git add cortex-py/cortex/api/protocol.py cortex-py/tests/api/
git commit -m "feat: add WebSocket message types for Trade, Options, Simulation"
```

---

### Task 10: Backend — Level 2 Data Feed

**Files:**
- Create: `cortex-py/cortex/feeds/level2.py`
- Create: `cortex-py/tests/feeds/test_level2.py`

**Step 1: Write failing tests**

Test L2BookSnapshot, L2Update, Level2Feed class with mock IBKR data.

**Step 2: Implement Level2Feed**

```python
class Level2Feed:
    """Streams Level 2 order book data from IBKR via ib_async."""

    def __init__(self, ibkr_manager, broadcaster, rate_limiter):
        self._ibkr = ibkr_manager
        self._broadcaster = broadcaster
        self._rate_limiter = rate_limiter
        self._active_symbol = None
        self._book = {"bids": [], "asks": []}

    async def subscribe(self, symbol: str, num_rows: int = 20):
        """Request L2 market depth for symbol via IBKR."""
        ...

    async def unsubscribe(self):
        """Stop L2 data for current symbol."""
        ...
```

**Step 3: Run tests, commit**

---

### Task 11: Backend — Options Pricing Calculator

**Files:**
- Create: `cortex-py/cortex/calculators/__init__.py`
- Create: `cortex-py/cortex/calculators/options_pricing.py`
- Create: `cortex-py/tests/calculators/test_options_pricing.py`

**Step 1: Write failing tests for BSM calculator**

Test cases: ATM call, deep ITM put, Greeks calculation, P&L matrix generation.

**Step 2: Implement Black-Scholes-Merton calculator**

```python
import math
from scipy.stats import norm

class OptionsPricing:
    @staticmethod
    def black_scholes(S, K, T, r, sigma, option_type="call"):
        """Calculate option price using BSM model."""
        d1 = (math.log(S/K) + (r + sigma**2/2)*T) / (sigma*math.sqrt(T))
        d2 = d1 - sigma*math.sqrt(T)
        if option_type == "call":
            return S*norm.cdf(d1) - K*math.exp(-r*T)*norm.cdf(d2)
        else:
            return K*math.exp(-r*T)*norm.cdf(-d2) - S*norm.cdf(-d1)

    @staticmethod
    def greeks(S, K, T, r, sigma, option_type="call"):
        """Calculate all Greeks."""
        ...

    @staticmethod
    def profit_matrix(legs, price_range, date_range):
        """Calculate P&L surface for multi-leg strategy."""
        ...
```

**Step 3: Run tests, commit**

---

### Task 12: Backend — Options Data Feed

**Files:**
- Create: `cortex-py/cortex/feeds/options.py`
- Create: `cortex-py/tests/feeds/test_options.py`

**Step 1: Write tests for option chain fetching**

**Step 2: Implement OptionsFeed**

Fetches option chains from Polygon.io (primary) or IBKR (when connected). Returns structured chain data with strikes, expiries, bid/ask, IV, Greeks.

**Step 3: Run tests, commit**

---

### Task 13: Backend — Wire Trade + Options into main.py

**Files:**
- Modify: `cortex-py/cortex/main.py`

**Step 1: Add Level2Feed, OptionsFeed, OptionsPricing to create_app_components()**

**Step 2: Add WebSocket handlers for new message types**

Handle: CMD_SUBMIT_ORDER, CMD_CANCEL_ORDER, CMD_SET_TRADING_MODE, CMD_GET_OPTION_CHAIN, CMD_CALCULATE_PROFIT

**Step 3: Commit**

---

### Task 14: Swift — TradeStore + Level2Store

**Files:**
- Create: `cortex-app/Sources/CortexCore/Stores/TradeStore.swift`
- Create: `cortex-app/Sources/CortexCore/Stores/Level2Store.swift`
- Modify: `cortex-app/Sources/CortexCore/AppEnvironment.swift`
- Modify: `cortex-app/Sources/CortexApp/MessageRouter.swift`

**Step 1: Create TradeStore**

```swift
@MainActor @Observable
public final class TradeStore {
    public var positions: [TradePosition] = []
    public var orders: [TradeOrder] = []
    public var tradingMode: TradingMode = .manual
    public var activeSymbol: String = "AAPL"
    public var webSocket: WebSocketClient?

    public enum TradingMode: String { case manual, semiManual, fullAuto }

    public func submitOrder(symbol: String, side: String, quantity: Int, type: String, price: Double?) { ... }
    public func cancelOrder(orderId: String) { ... }
    public func setTradingMode(_ mode: TradingMode) { ... }
}
```

**Step 2: Create Level2Store**

```swift
@MainActor @Observable
public final class Level2Store {
    public var bids: [Level2Row] = []
    public var asks: [Level2Row] = []
    public var timeSales: [TimeSalesTick] = []
    public var activeSymbol: String = ""
}
```

**Step 3: Add to AppEnvironment and wire in MessageRouter**

Route `l2_update`, `time_sales`, `position_update`, `order_status` messages.

**Step 4: Commit**

---

### Task 15: Swift — Trade View UI

**Files:**
- Create: `cortex-app/Sources/CortexCore/Views/TradeView.swift`
- Create: `cortex-app/Sources/CortexCore/Views/Components/Level2View.swift`
- Create: `cortex-app/Sources/CortexCore/Views/Components/OrderPanelView.swift`
- Create: `cortex-app/Sources/CortexCore/Views/Components/TimeSalesView.swift`

**Step 1: Build TradeView with layout**

4-panel layout: Chart (60%), Level 2 (20%), Order Panel (20%), bottom: Time & Sales + Positions

**Step 2: Build Level2View**

Dual-column bid/ask table with color-coded depth bars.

**Step 3: Build OrderPanelView**

Quantity input, order type selector (Market/Limit/Stop), Buy/Sell/Short buttons with trading mode indicator.

**Step 4: Build TimeSalesView**

Scrolling tick-by-tick feed with price, size, time.

**Step 5: Replace placeholder in ContentView**

**Step 6: Commit**

---

### Task 16: Swift — Options Profit Calculator View

**Files:**
- Create: `cortex-app/Sources/CortexCore/Stores/OptionsStore.swift`
- Create: `cortex-app/Sources/CortexCore/Views/Components/OptionChainView.swift`
- Create: `cortex-app/Sources/CortexCore/Views/Components/ProfitCalculatorView.swift`
- Modify: `cortex-app/Sources/CortexCore/Views/FinancialsView.swift`

**Step 1: Create OptionsStore**

Manages option chain data, selected contracts, P&L calculation results.

**Step 2: Build OptionChainView**

Sortable table: Strike | Bid | Ask | Volume | OI | IV | Delta
Calls on left, puts on right. Click to select legs.

**Step 3: Build ProfitCalculatorView**

Interactive P&L chart using Swift Charts. X-axis: underlying price. Y-axis: P&L.
Sliders for date-to-expiration and price range.
Shows: max profit, max loss, breakevens.

**Step 4: Wire into FinancialsView as a new section**

When "Options Analysis" is selected in left pane, show OptionChainView + ProfitCalculatorView.

**Step 5: Commit**

---

## Phase D: New Agent Squadrons + Simulation

### Task 17: GOLF Squadron — Adaptive Learning Agents

**Files:**
- Create: `cortex-py/cortex/squadrons/golf/__init__.py`
- Create: `cortex-py/cortex/squadrons/golf/trade_historian.py`
- Create: `cortex-py/cortex/squadrons/golf/pattern_learner.py`
- Create: `cortex-py/cortex/squadrons/golf/strategy_optimizer.py`
- Create: `cortex-py/cortex/squadrons/golf/regime_detector.py`
- Create: `cortex-py/cortex/squadrons/golf/performance_tracker.py`
- Create: `cortex-py/cortex/squadrons/golf/drawdown_analyzer.py`
- Create: `cortex-py/cortex/squadrons/golf/sector_momentum.py`
- Create: `cortex-py/cortex/squadrons/golf/correlation_tracker.py`
- Tests: `cortex-py/tests/squadrons/golf/`

For each agent: write failing test → implement → verify pass → commit.

Key agent: **Pattern Learner** — records winning trade features, runs statistical analysis every 100 trades, identifies patterns with >60% win rate, emits `intelligence.strategy_update` signal.

**Step 1-8: Implement each agent (TDD for each)**

**Step 9: Register all GOLF agents in main.py**

**Step 10: Commit**

---

### Task 18: HOTEL Squadron — Market Microstructure Agents

**Files:**
- Create: `cortex-py/cortex/squadrons/hotel/__init__.py`
- Create: `cortex-py/cortex/squadrons/hotel/spread_analyzer.py`
- Create: `cortex-py/cortex/squadrons/hotel/depth_reader.py`
- Create: `cortex-py/cortex/squadrons/hotel/tick_analyzer.py`
- Create: `cortex-py/cortex/squadrons/hotel/price_level_mapper.py`
- Create: `cortex-py/cortex/squadrons/hotel/execution_optimizer.py`
- Create: `cortex-py/cortex/squadrons/hotel/latency_monitor.py`
- Tests: `cortex-py/tests/squadrons/hotel/`

**Step 1-6: Implement each agent (TDD)**

**Step 7: Register all HOTEL agents in main.py**

**Step 8: Commit**

---

### Task 19: Simulation Engine — Core

**Files:**
- Create: `cortex-py/cortex/simulation/__init__.py`
- Create: `cortex-py/cortex/simulation/engine.py`
- Create: `cortex-py/cortex/simulation/paper_portfolio.py`
- Create: `cortex-py/cortex/simulation/market_replay.py`
- Tests: `cortex-py/tests/simulation/`

**Step 1: Write failing tests for PaperPortfolio**

Test: create portfolio with $100K, execute buy, sell, track P&L, commissions, drawdown.

**Step 2: Implement PaperPortfolio**

```python
class PaperPortfolio:
    def __init__(self, starting_capital: float = 100_000.0):
        self.cash = starting_capital
        self.positions: dict[str, PaperPosition] = {}
        self.trades: list[PaperTrade] = []
        self.starting_capital = starting_capital

    @property
    def nav(self) -> float: ...
    @property
    def daily_pnl(self) -> float: ...
    @property
    def total_pnl(self) -> float: ...

    def buy(self, symbol, quantity, price, commission=0.0) -> PaperTrade: ...
    def sell(self, symbol, quantity, price, commission=0.0) -> PaperTrade: ...
```

**Step 3: Write tests for SimulationEngine**

**Step 4: Implement SimulationEngine**

```python
class SimulationEngine:
    def __init__(self, bus, portfolio, agents, broadcaster):
        ...

    async def start(self, mode="paper"):
        """Start simulation — runs all agents with paper portfolio."""
        ...

    async def stop(self):
        """Stop simulation, emit final stats."""
        ...

    @property
    def stats(self) -> dict: ...
```

**Step 5: Run tests, commit**

---

### Task 20: Simulation — Learning Tracker

**Files:**
- Create: `cortex-py/cortex/simulation/learning_tracker.py`
- Tests: `cortex-py/tests/simulation/test_learning_tracker.py`

**Step 1: Write failing tests**

Test: record trades, analyze patterns, identify winning features, generate insights.

**Step 2: Implement LearningTracker**

Records every trade with full context. Every 100 trades, runs pattern analysis:
- Group winning trades by features (signal type, sector, time of day, market regime)
- Chi-squared test for statistical significance
- Output: JSON learning insights

**Step 3: Run tests, commit**

---

### Task 21: Wire Simulation into Backend

**Files:**
- Modify: `cortex-py/cortex/main.py`

**Step 1: Add SimulationEngine to create_app_components()**

**Step 2: Handle CMD_START_SIMULATION WebSocket message**

**Step 3: Broadcast SIMULATION_UPDATE and LEARNING_INSIGHT messages**

**Step 4: Commit**

---

### Task 22: Swift — Simulation View

**Files:**
- Create: `cortex-app/Sources/CortexCore/Stores/SimulationStore.swift`
- Create: `cortex-app/Sources/CortexCore/Views/SimulationView.swift`
- Modify: `cortex-app/Sources/CortexApp/MessageRouter.swift`
- Modify: `cortex-app/Sources/CortexCore/AppEnvironment.swift`

**Step 1: Create SimulationStore**

Tracks: equity curve, stats, learning insights, is running.

**Step 2: Build SimulationView**

Layout: Equity curve chart, stats grid, learning insights panel, recent trades, controls (Start/Pause/Reset/Speed).

**Step 3: Wire into MessageRouter**

Route: `simulation_update`, `learning_insight`.

**Step 4: Wire into Trade view as "Simulation" section**

**Step 5: Commit**

---

## Phase E: Polish + Alerts

### Task 23: Alert System

**Files:**
- Create: `cortex-py/cortex/feeds/alerts.py`
- Create: `cortex-py/tests/feeds/test_alerts.py`
- Create: `cortex-app/Sources/CortexCore/Stores/AlertStore.swift`
- Modify: `cortex-app/Sources/CortexCore/Views/WatchlistView.swift`

**Step 1: Backend alert engine**

Monitors price thresholds. When triggered, sends ALERT_TRIGGERED message.

**Step 2: Swift AlertStore + UI**

Alert CRUD in WatchlistView. Types: Price Above, Price Below, % Change.

**Step 3: Commit**

---

### Task 24: Markets View Left Pane Sections Fix

**Files:**
- Modify: `cortex-app/Sources/CortexCore/Views/ChartView.swift`

**Step 1: Wire selectedSection to switch chart content**

When "Indices" is selected, show SPY. When "Crypto" is selected, show BTC-USD. When user clicks a specific symbol in a section, load that chart.

**Step 2: Add section content (Favorites list, Indices list, etc.)**

**Step 3: Commit**

---

### Task 25: Cross-View Consistency Pass

**Files:**
- All view files in `cortex-app/Sources/CortexCore/Views/`

**Step 1: Replace hardcoded colors with CortexDesign tokens**

Find and replace all `Color(white: 0.06)`, `Color(white: 0.08)`, etc. with `CortexDesign.bgDeepest`, `CortexDesign.bgCard`, etc.

**Step 2: Ensure all data values use monospaced font**

**Step 3: Ensure all animations use consistent spring timing**

**Step 4: Commit**

---

### Task 26: Full Test Suite + Build Verification

**Step 1: Run Python tests**

```bash
cd cortex-py && python -m pytest tests/ -v --tb=short
```

**Step 2: Run Swift build**

```bash
cd cortex-app && swift build
```

**Step 3: Fix any failures**

**Step 4: Final commit**

---

## Execution Order Summary

| Phase | Tasks | Est. Effort | Dependencies |
|-------|-------|-------------|--------------|
| A (Foundation) | 1-5 | Small | None |
| B (War Room + Squadrons) | 6-8 | Medium | Phase A |
| C (Trade + Options) | 9-16 | Large | Phase A, Tasks 9 first |
| D (Agents + Simulation) | 17-22 | Large | Phase A |
| E (Polish) | 23-26 | Medium | All above |

**Phases B, C, D can run in parallel** after Phase A completes. Phase E runs last.
