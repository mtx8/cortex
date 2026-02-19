# CORTEX Platform Design

**Date**: 2026-02-19
**Status**: Approved by agent review teams
**Reviewed by**: Architecture, Data Pipeline, Risk Management, macOS App, Tax Strategy agent teams

---

## 1. Overview

CORTEX is a macOS-native autonomous AI trading platform with 44 agents organized into 6 squadrons. It trades stocks/options via Interactive Brokers and crypto via Coinbase, powered by Claude API for strategic intelligence.

**Goal**: Maximize returns legally with tax optimization.
**Starting capital**: $25K-$100K
**Autonomy**: Full autonomous with configurable dial (Full/Semi/Signal) and kill switch

---

## 2. System Architecture

```
CORTEX macOS App (Swift, SwiftUI + AppKit)
   |
   | WebSocket ws://127.0.0.1:8765/ws (MessagePack binary frames)
   | Single connection. Full duplex. No gRPC.
   |
CORTEX Core (Python, FastAPI + asyncio + uvloop)
   |
   +-- Orchestrator
   |     +-- SignalBus (asyncio.PriorityQueue) -- nervous system
   |     +-- TradePipeline (enforced execution sequence)
   |     +-- Scheduler (agent tick management)
   |
   +-- Claude Intelligence Engine
   |     +-- 5-minute strategic cycle ONLY. Never in execution hot path.
   |
   +-- Squadrons [ALPHA|BRAVO|CHARLIE|DELTA|ECHO|FOXTROT]
   |     +-- All inter-squadron communication via SignalBus only
   |
   +-- Connectors [IBKR|Coinbase|Polygon|UnusualWhales|Benzinga|EDGAR]
   |     +-- IBKR: position reconciliation on every reconnect
   |
   +-- Storage
   |     +-- QuestDB (time-series: ticks, OHLCV, options chains)
   |     +-- PostgreSQL 16 (trades, P&L, audit trail, tax lots)
   |     +-- SQLite (agent state, portfolio snapshots)
   |     +-- Redis 7 (cache, streams, real-time signal state)
   |
   +-- Scanner FFI
         +-- PyO3 bridge (GIL released, panic-caught)
               |
               +-- Rust Scanner Engine (.so via maturin)
                     +-- rayon parallel screener, pattern detection, volume analysis
```

### Key Architecture Decisions

1. **Monolith-first**: Single FastAPI process, all 44 agents as async tasks. Decompose later if needed.
2. **WebSocket only**: No gRPC for MVP. MessagePack encoding for binary efficiency.
3. **PyO3 FFI**: Rust scanner compiled as .so, loaded in-process. GIL released during Rust execution, panics caught at FFI boundary.
4. **Claude is the general, not the soldier**: 5-minute strategic cycle sets parameters. Agents execute rules-based logic in milliseconds. Claude never in execution hot path.
5. **Echo squadron has absolute override authority**: Hardcoded, not configurable. No signal source can bypass risk checks.

---

## 3. Squadron Structure (44 Agents)

### ALPHA Squadron - Signal Intelligence (6 agents)
| Agent | Purpose |
|-------|---------|
| Signal Hunter | RSI + MACD + volume threshold scanning |
| Pattern Recon | Chart pattern detection (flags, wedges, H&S) |
| Correlation Mapper + Sector Rotator | Statistical relationships + sector rotation (merged) |
| Volume Profiler | Relative volume vs 20-day average |
| Mean Reversion + Stat Arb | Mean reversion with statistical arbitrage |
| Gap Scanner | Pre-market gap detection |

### BRAVO Squadron - Execution (7 agents)
| Agent | Purpose |
|-------|---------|
| Order Sniper | Market + limit order execution |
| Spread Optimizer | Mid-price limit with fallback |
| Execution Quality Monitor | Slippage analysis, fill rate, venue performance (NEW - was Fill Monitor) |
| TWAP/VWAP | Time/volume-weighted execution |
| Dark Pool Router | Alternative venue routing |
| Iceberg Deployer | Large order concealment |

### CHARLIE Squadron - Options (6 agents)
| Agent | Purpose |
|-------|---------|
| Greeks Engine + IV Surface Mapper | Options pricing + volatility surface (shared state) |
| Options Flow Intelligence | Flow decode + sweep interception (merged) |
| Strategy Deployer | Multi-leg options strategy construction |
| Theta Harvester | Premium selling strategies |
| Gamma Scalper | Gamma exposure management |

### DELTA Squadron - Intelligence (8 agents)
| Agent | Purpose |
|-------|---------|
| EDGAR Sentinel | SEC filing detection via RSS (10-K, 10-Q, 8-K, 13-F) |
| News Interceptor | Benzinga WebSocket + Polygon news |
| Geopolitical Radar | Geopolitical event monitoring |
| Social Pulse | Social media sentiment |
| Congress Tracker | Congressional trade tracking (Quiver Quant) |
| Earnings Oracle | Earnings calendar + IV crush detection |
| Insider Decoder | Insider transaction analysis |
| Activist Tracker | Activist investor filing detection |

### ECHO Squadron - Risk Management (8 agents)
| Agent | Purpose |
|-------|---------|
| Risk Guardian | Master controller, runs pre-trade checks |
| Drawdown Shield | Portfolio drawdown monitoring + throttling |
| Correlation Watch | Prevents over-concentration in correlated positions |
| VaR Calculator | Real-time Value at Risk (historical simulation) |
| Black Swan Sentinel | Extreme market condition detection |
| Kill Switch Commander | Emergency halt state machine |
| Position Sizer | Kelly/fixed-fractional/vol-adjusted sizing (NEW) |

### FOXTROT Squadron - Tax & Crypto (9 agents)
| Agent | Purpose |
|-------|---------|
| Harvest Bot | Tax-loss harvesting (continuous + year-end + emergency) |
| Wash Sale Guard | 61-day window wash sale prevention, cross-exchange |
| Gain Timer | Holding period tracking (short-term vs long-term) |
| Entity Optimizer | Entity structure recommendations |
| DeFi Yield Hunter | Staking + LP yield with tax-aware execution |
| Crypto Arb Bot | Cross-exchange arbitrage with cost basis tracking |
| Crypto Momentum Scanner | Crypto-specific momentum signals |
| Quarterly Tax Optimizer | Estimated quarterly payment + safe harbor (NEW) |
| Section 475 Advisor | Mark-to-market election analysis (NEW) |

---

## 4. Data Sources & Connectors

| Source | Protocol | Purpose | Cost |
|--------|----------|---------|------|
| IBKR TWS API | Socket (ib_async) | Stocks/options execution, L2, real-time quotes | $30-150/mo data subs |
| Coinbase Advanced Trade | REST + WebSocket (JWT auth) | Crypto execution + streaming | Free |
| Polygon.io | WebSocket + REST | Equities/options/crypto streaming, historical | ~$200/mo options tier |
| Unusual Whales | REST polling (15s) | Options flow, sweeps, dark pool prints | $100-300/mo |
| Benzinga | WebSocket | Real-time news (fastest for trading signals) | $100-200/mo |
| SEC EDGAR | RSS + XBRL REST | SEC filings (10-K, 10-Q, 8-K, 13-F) | Free |
| Quiver Quant | REST | Congress trades, insider transactions | $50-100/mo |
| Finnhub | WebSocket | Supplementary news + earnings calendar | Free tier available |

### IBKR Connection Architecture
- IB Gateway running headless (not TWS GUI)
- `ib_async` library for async Python integration
- Position reconciliation on every reconnect
- 3 client IDs: market data (45 msg/sec), orders (45 msg/sec), historical (6 req/min)
- LaunchAgent plist for auto-start

### Data Flow
```
Polygon/IBKR/Coinbase WebSocket
   --> Redis Streams (raw ingestion, MAXLEN capped)
   --> Rust Scanner (via Redis consumer group, writes scored results)
   --> QuestDB (via ILP port 9009, time-series persistence)
   --> Agent consumer groups (each squadron reads relevant streams)
   --> SignalBus (inter-agent signals, in-memory PriorityQueue)
   --> TradePipeline (mandatory execution sequence)
   --> Broker execution (IBKR/Coinbase)
```

---

## 5. Storage Layer

| Store | Technology | Data | Access Pattern |
|-------|-----------|------|----------------|
| Time-series | QuestDB 8 (ILP ingest, SQL query) | Ticks, OHLCV, options chains | High write (1.6M rows/sec), range queries |
| Trades & Tax | PostgreSQL 16 + pgvector | Orders, trades, P&L, tax lots, audit trail | ACID, relational joins, tax reporting |
| Agent state | SQLite (WAL mode) | Agent status, config, health | Low volume, crash recovery |
| Real-time | Redis 7 (Streams + Hashes) | Quotes, signals, positions, rate limits | Sub-ms reads, pub/sub, stream consumers |

---

## 6. Risk Management Framework

### Risk Parameters (Defaults for $25K-$100K)
| Parameter | Default |
|-----------|---------|
| Max position size | 5% of NAV ($1,250-$5,000) |
| Max single trade loss | $500 (2% of $25K) |
| Max concurrent positions | 15 |
| Max daily trades | 50 |
| Daily drawdown throttle | 5% (reduce position sizes 50%) |
| Daily drawdown halt | 7% (stop new positions) |
| Weekly drawdown halt | 10% |
| Total drawdown kill switch | 20% |
| Max net delta (options) | 30% of NAV |
| Max gamma (options) | 5% of NAV |
| Max vega (options) | 3% of NAV |
| Gamma hard stop DTE | 0 DTE (no new positions expiring today) |
| Max crypto allocation | 15% of portfolio |
| Crypto target volatility | 20% (vol-adjusted sizing) |
| Naked short options | HARD BLOCKED (non-configurable) |

### Kill Switch — 7-Phase Sequence
1. **HALT** (sync, <1ms): Set in-memory flag, block all new orders
2. **CANCEL**: Cancel all pending/open orders across IBKR + Coinbase
3. **CLOSE EQUITY**: Close stock/ETF positions (market orders with 2% limit protection)
4. **CLOSE OPTIONS**: Close options (leg-by-leg for spreads, market for singles)
5. **CLOSE CRYPTO**: Close crypto via Coinbase API
6. **PERSIST**: Write final state to all databases
7. **AWAIT**: Manual human action required to resume (except API failure triggers)

### Pre-Trade Risk Checks (10 categories, all must pass, <10ms)
1. System state (kill switch, market hours, API connectivity)
2. Drawdown state (daily/weekly/total halt checks)
3. Position sizing (max size, min size, options premium)
4. Portfolio concentration (asset class, sector, correlation)
5. Concurrent positions and trade limits
6. Options Greeks (delta, gamma, vega, naked short block)
7. Crypto-specific (whitelist, vol-adjusted size, liquidity)
8. VaR validation (post-trade VaR simulation)
9. Black Swan composite score
10. Stop loss required

### Authority Chain (Hardcoded, Not Configurable)
```
Level 1: Kill Switch Commander (ABSOLUTE HALT)
Level 2: Risk Guardian (HARD BLOCK)
Level 3: Black Swan Sentinel (MARKET CONDITION BLOCK)
Level 4: Drawdown Shield (P&L THROTTLE)
Level 5: Correlation Watch + VaR Calculator (ADVISORY WITH BLOCK)
Level 6: Alpha Squadron (SIGNAL ONLY - zero override authority)
Level 7: Bravo Squadron (EXECUTION ONLY - zero override authority)
```

### Black Swan Detection Signals
- VIX > 25: monitor. VIX > 30: throttle 50%. VIX > 40: halt.
- Market circuit breaker (Level 1/2/3) detection
- Bid-ask spread widening > 5x normal
- Order book depth < 20% of 30-day average
- Flash crash: price drop > 3% in < 60 seconds on major indices

---

## 7. Tax Optimization Strategy

### Cost Basis Methods
- **Equities**: FIFO (IRS default, lowest audit risk)
- **Crypto**: HIFO (Highest-In-First-Out via specific identification, maximizes basis)

### Tax-Loss Harvesting Thresholds
- **Primary**: Unrealized loss > 7% AND > $500
- **Year-end** (Dec 1-15 equities, Dec 1-28 crypto): Loss > 3% AND > $200
- **Emergency** (daily drawdown > 3%): Harvest all losses > $300

### Wash Sale Prevention
- 61-day window (30 before + day of sale + 30 after)
- Cross-exchange tracking (IBKR + Coinbase)
- Options on same underlying count as substantially identical
- Per-symbol mutex prevents race conditions across 44 agents
- Feature flag `CRYPTO_WASH_SALE_ENABLED = false` (ready for future legislation)

### Tax Reporting Integration
1. **TaxBit** (primary): Crypto + equity combined, Form 8949, Schedule D
2. **TradeLog**: IBKR equity/options wash sale specialist
3. **Koinly**: DeFi protocol support (750+ protocols)

---

## 8. macOS App Architecture (Swift)

### Technology
- SwiftUI + AppKit hybrid, macOS 14+ (Sonoma), Apple Silicon only
- `@Observable` framework (not Combine, not TCA) for keypath-level view invalidation
- NavigationSplitView with sidebar navigation
- WebSocket client as Swift Actor with MessagePack encoding
- BatchAccumulator coalescing updates at 16.67ms intervals (60fps)

### Views
1. **War Room Dashboard**: Portfolio KPIs, squadron grid, opportunities, scanner preview, activity feed
2. **Squadrons View**: All 44 agents with status, tasks, win rates, autonomy controls
3. **AI Intelligence Chat**: Claude-powered with portfolio context, quick prompts, context panel
4. **Scanner View**: Composite scoring table, category breakdown, ticker drill-down
5. **Menu Bar Widget**: P&L ticker (1Hz), positions, squadron health, quick kill switch
6. **Quick Trade Panel**: Floating NSPanel (non-activating, stays visible via ⌘T)

### Keyboard Shortcuts
- ⌘K: Kill switch (global, works even when app not frontmost)
- ⌘T: Quick trade panel
- ⌘1-6: Jump to squadron views
- ⌘I: Open AI chat

### Kill Switch UX
- Full-screen red overlay (NSWindow at screen saver z-level)
- Instant activation (no confirmation dialog)
- Shows phase progress
- Manual disengage button to resume

### Performance Architecture
```
WebSocket binary frame (~200 bytes avg)
  --> Actor WebSocketClient (background thread)
  --> Actor MessageRouter (background thread)
  --> BatchAccumulator (coalesce for 16.67ms)
  --> @MainActor flush (one mutation per display frame)
  --> @Observable stores (keypath tracking)
  --> SwiftUI views (only affected rows re-render)
  --> 60fps maintained with 44 agents streaming
```

### Swift Package Dependencies
- grpc-swift 2.x (for future RPC if needed)
- MessagePack.swift (WebSocket codec)
- Swift Charts (built-in, GPU-accelerated)
- KeychainAccess (API key storage)
- swift-log (structured logging)

---

## 9. Claude Intelligence Engine

### Two-Tier Architecture
```
Tier 1 (Slow, Claude-powered): Strategic analysis
  - Runs on a 5-minute cycle
  - Claude reads: market context, news, portfolio state, risk status
  - Outputs: strategy parameters, risk thresholds, agent configuration
  - Example: "AAPL earnings in 2 days, reduce gamma, bias to puts"

Tier 2 (Fast, rules-based): Execution
  - Runs in milliseconds
  - Agents execute based on Tier 1 parameters + real-time data
  - Zero LLM calls in the execution path
  - Example: Signal Hunter fires when RSI < 30 AND volume > 2x
```

### Chat Intelligence
- Full portfolio context injection into every Claude conversation
- Claude can trigger agent actions via structured tool output
- Quick prompts: "Scan for opportunities", "Risk report", "Tax impact", "What would you trade?"
- Side panel shows related opportunities when discussing a ticker

---

## 10. Mandatory Trade Execution Pipeline

Every trade, regardless of source, must flow through this exact sequence:

```
Signal Source (ALPHA/CHARLIE/DELTA)
  --> SignalBus.publish(ENTRY_SIGNAL)
  --> ECHO.PositionSizer computes size
  --> ECHO.RiskGuardian runs all 10 pre-trade checks
  --> If approved: SignalBus.publish(POSITION_SIZE)
  --> FOXTROT.WashSaleGuard checks (100ms timeout)
  --> FOXTROT.GainTimer checks tax lot implications
  --> BRAVO.OrderSniper executes via IBKR/Coinbase
  --> SignalBus.publish(ORDER_FILLED)
  --> ECHO updates portfolio VaR
  --> FOXTROT updates tax lot tracking
  --> PostgreSQL audit trail written
  --> Swift UI receives stream update
```

---

## 11. MVP Build Sequence (4 Weeks)

### Week 1: Infrastructure (No agents, no trading)
- Python project structure with all 6 squadron packages
- SignalBus + TradePipeline (with stage stubs)
- Storage: QuestDB schema, PostgreSQL schema, SQLite agent state, Redis config
- IBKR connector: connect, reconnect, position reconciliation, paper trading
- WebSocket server (FastAPI) with MessagePack protocol
- Swift app skeleton: connects to WebSocket, basic War Room layout
- Kill switch end-to-end: ⌘K --> WebSocket --> ECHO --> close all --> halt
- Claude Intelligence Engine: strategic cycle, prompt builder, response parser

### Week 2: First Squadrons Live (ALPHA + ECHO core)
- ECHO: Risk Guardian (pre-trade checks), Position Sizer, Kill Switch Commander
- ALPHA: Signal Hunter, Volume Profiler, Gap Scanner
- Polygon.io connector for real-time price data
- Wire: ALPHA --> SignalBus --> TradePipeline --> ECHO --> IBKR paper trading
- Audit trail end-to-end
- Swift War Room: real-time P&L, agent status, signal feed

### Week 3: Execution + Options Foundation
- BRAVO: Order Sniper, Spread Optimizer
- CHARLIE: Greeks Engine + IV Surface Mapper, Options Flow Intelligence (Unusual Whales)
- Rust scanner: symbol screener, composite scoring via PyO3
- Switch to live trading with $500/trade hard cap for testing
- FOXTROT: Wash Sale Guard (blocking only), Harvest Bot (identification only)

### Week 4: Intelligence + Full Autonomy
- DELTA: News Interceptor (Benzinga), Earnings Oracle
- Autonomy dial: Full/Semi/Signal configurable per-squadron
- FOXTROT: Gain Timer, Crypto Arb Bot (Coinbase connector)
- ⌘T Quick Trade UI
- Performance dashboard: agent win rates, slippage, P&L by squadron

### Post-MVP Backlog
- Dark Pool Router, Iceberg Deployer
- DELTA: Geopolitical Radar, Social Pulse, Congress Tracker, Insider Decoder, Activist Tracker
- FOXTROT: Entity Optimizer, DeFi Yield Hunter, Quarterly Tax Optimizer, Section 475 Advisor
- Charlie: Strategy Deployer, Gamma Scalper, Theta Harvester
- TradingView integration (charting overlay)
- ML model training (replace Claude judgment with trained models for specific patterns)

---

## 12. Technology Stack Summary

| Layer | Technology | Why |
|-------|-----------|-----|
| macOS App | Swift 5.9+, SwiftUI, AppKit | Native performance, @Observable, Apple Silicon optimized |
| Backend | Python 3.12+, FastAPI, uvloop | Async-first, rich financial library ecosystem |
| Scanner | Rust, rayon, PyO3 | SIMD-accelerated screening at native speed |
| AI | Claude API (Anthropic SDK) | 200K context, best reasoning for financial analysis |
| Time-series DB | QuestDB 8 | 1.6M rows/sec on Apple Silicon, SQL with time extensions |
| Relational DB | PostgreSQL 16 + pgvector | ACID for trades/tax, vector search for analysis similarity |
| Agent state | SQLite (WAL mode) | Lightweight, crash-safe, zero config |
| Cache/Streams | Redis 7 | Sub-ms reads, Streams for data fan-out, rate limiting |
| Broker (equity) | Interactive Brokers TWS API | Direct market access, options, L2 data |
| Broker (crypto) | Coinbase Advanced Trade API | Best regulated crypto exchange for programmatic trading |
| Market data | Polygon.io | Unlimited streaming, historical, options snapshots |
| Options flow | Unusual Whales | Sweeps, dark pool, flow sentiment |
| News | Benzinga | Fastest WebSocket news for trading signals |
| SEC filings | EDGAR RSS + XBRL | Free, near-real-time filing detection |
| Tax reporting | TaxBit + TradeLog | Combined crypto + equity Form 8949 / Schedule D |

---

## 13. Key Python Dependencies

```
fastapi, uvicorn[standard], uvloop
ib_async (IBKR), coinbase-advanced-py (Coinbase)
websockets, httpx (HTTP client)
redis[hiredis] (cache/streams), asyncpg (PostgreSQL), duckdb (backup analytics)
pydantic v2, pydantic-settings
anthropic (Claude API)
aiolimiter (rate limiting), orjson (fast JSON)
structlog (structured logging), beartype (runtime type checking)
spacy (NLP for news ticker extraction)
lxml (XBRL/XML parsing), PyJWT + cryptography (Coinbase auth)
```

## 14. Key Rust Dependencies

```
tokio (async runtime), tokio-tungstenite (WebSocket)
redis (streams), questdb-rs (ILP writer)
serde + serde_json, rayon (parallel iteration)
pyo3 (Python FFI), anyhow (error handling)
tracing + tracing-subscriber (structured logging)
```

---

## 15. Non-Negotiable Safety Rules

1. No signal source can bypass the pre-trade risk check
2. Kill Switch Phase 1 is synchronous and in-memory only
3. Naked short options are blocked in code, not config
4. Authority chain is hardcoded, not configurable
5. Recovery from kill switch requires human action
6. Audit log is append-only, written to two locations
7. Claude never executes trades directly - only sets strategy parameters
8. Position reconciliation runs on every IBKR reconnect
9. Every order has a UUID generated before broker submission (idempotency)
10. All API keys in Keychain (macOS) / secrets.toml (backend), never in code
