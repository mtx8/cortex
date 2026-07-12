# CORTEX X — APEX Upgrade Design

Date: 2026-07-12 · Status: approved for build (Principal pre-authorized full cycle)

## Goal

Make CORTEX X materially stronger than a Bloomberg-terminal workflow for one
operator: better predictive machinery, deeper company intelligence, explicit
market-regime awareness, and a Dalio-style geopolitical cause-effect engine —
in the existing flat-matte, hairline, ember-accent aesthetic, with a modern
toggleable shell.

Four pillars:

1. **Quant upgrade** — regime-adaptive, self-weighting signal engine.
2. **COMPANY** — Bloomberg-SPLC-style company intelligence: what it makes,
   who it buys from, who it sells to, live fundamentals.
3. **REGIMES** — market-wide bull/bear state board: entering / in / exiting.
4. **MERIDIAN** — the Dalio section (named): geopolitical events → causal
   chains → affected assets, plus Five Forces gauges.

Non-goals: real-money execution (stays paper), new brokers, any paid/keyed
data source (everything stays keyless), light mode, emoji.

## Honesty invariants (carried from the existing engine)

- Delayed/curated/heuristic data always labels itself (`source` fields).
- No fake stats: every number traces to a feed, a computation, or is absent.
- New agents feed **tighten-only** caution; nothing new can grow risk.
- LLM stays out of the hot path.

---

## Pillar 1 — Quant upgrade ("the most powerful algorithms")

All in `cx-ta` (pure, tested against closed-form/synthetic references) and
`cx-strategy`/`cortexd` (wiring). Deterministic; no RNG in live paths.

### 1a. New estimators (`cx-ta/src/quant2.rs`)

- **GARCH(1,1) online vol forecaster** — variance-targeted: ω derived from
  long-run sample variance with α=0.09, β=0.89 defaults; online update
  σ²ₜ = ω + α·r²ₜ₋₁ + β·σ²ₜ₋₁; exposes 1-step and n-step vol forecasts.
  Test: recursion matches hand-computed sequence; long-run variance
  convergence to targeted value.
- **Kalman local-level+trend filter** — 2-state (level, slope), scalar
  observation; steady-state gains from signal/noise ratio config. Exposes
  filtered level, slope, and slope/vol t-stat. Test: converges to true slope
  on synthetic linear ramp + noise; level tracks step change.
- **CUSUM / Page-Hinkley change-point detector** — two-sided CUSUM on
  vol-normalized returns; emits change-point flag + pages since last break.
  Test: fires on injected mean shift, silent on stationary noise.
- **EWMA correlation matrix** (`corr.rs`) — pairwise EWMA (λ=0.97) return
  correlation across the symbol set; exposes `avg_corr(symbol)` — the mean
  correlation of a symbol against current *held* portfolio symbols.

### 1b. Feature/regime integration

`compute_features` adds: `garch_vol`, `kalman_slope`, `kalman_tstat`,
`cusum_break` (bars since last change-point, capped). `detect_regime` gains a
change-point override: a fresh CUSUM break within 5 bars forces confidence
down (regime uncertainty is itself a signal).

### 1c. Fourth strategy: `kalman_trend` (`cx-strategy`)

Enters when |kalman_tstat| ≥ 2.0 **and** no CUSUM break in the last 10 bars;
direction = sign(slope); conviction maps t-stat 2→4 onto 0.35→0.9; exits on
t-stat sign flip or fresh change-point. Registered in `BUILT_INS`,
backtested in `cx-sim::decide` with the same pure rule.

### 1d. Self-weighting fusion (Hedge / multiplicative weights)

`fusion.rs` currently uses static weights (1.0 / 0.6 / 0.4). Replace with
**online Hedge**: each strategy keeps weight wᵢ, updated on every completed
M1 bar where it had an active signal: wᵢ ← wᵢ · exp(η · dirᵢ · r̂) with η=0.15,
r̂ = vol-normalized next-bar return clamped to ±3. Weights renormalized to
mean 1.0, floored at 0.15, capped at 3.0 — a bad strategy decays, a hot one
compounds, none ever dies or dominates. Weights persisted in the fusion book,
surfaced in each fused signal's `features` map (`w_momentum_x`, …) so the UI
can show the live ensemble weights. Test: synthetic feed where strategy A is
always right and B always wrong → A's weight rises to cap, B's decays to
floor; agreement factor unchanged.

### 1e. Correlation-aware sizing (`cortexd/pipeline.rs`)

Position size gets a diversification multiplier: `1 / (1 + avg_corr⁺)` where
avg_corr⁺ = max(0, EWMA correlation of candidate vs. current book). Fully
NaN-safe, only ever ≤ 1 (tighten-only, consistent with ECHO philosophy).

### 1f. Foundry walk-forward honesty

`cx-sim` adds out-of-sample split: first 70% of bars = "train" stats, last
30% = "test" stats; leaderboard gains `oos_expectancy` and flags strategies
whose edge collapses out-of-sample. Best-pick uses OOS expectancy when ≥10
OOS trades.

---

## Pillar 2 — COMPANY (Bloomberg SPLC-class company intelligence)

New crate **`cx-intel`** (squadron: "intel"; bus-only; depends on cx-core +
cx-ta). Module `company.rs` + embedded dataset `splc_data.rs`.

### Data sources (all keyless)

- **SEC EDGAR** (`data.sec.gov`, added to egress allowlist; requires
  User-Agent header — use `cortex-x/1.0 contact-via-github`):
  - `files/company_tickers.json` (on sec.gov) → ticker→CIK map, cached 24h.
  - `api/xbrl/companyfacts/CIK{10}.json` → us-gaap facts. Extract latest
    annual + quarterly: Revenues, NetIncomeLoss, GrossProfit,
    OperatingIncomeLoss, Assets, Liabilities, StockholdersEquity, EPS,
    CashAndCashEquivalents, OperatingCashFlow. Compute margins, YoY growth.
  - Source label: `sec-edgar (10-K/10-Q)`.
- **Curated supply-chain graph** — embedded, ~60 major tickers (megacaps +
  watchlist defaults): segments/products, key suppliers, key customers,
  competitors, sector, country. Each relation carries a short `via` note
  (e.g. NVDA → TSMC: "leading-edge wafer fabrication"). Source label:
  `curated graph (MTX Labs, 2026-07)` — honest about being hand-curated.

### Engine surface

- Event `EngineEvent::Company(CompanyProfile)`; command
  `Command::GetCompany { symbol }` (on-demand, like options chains).
- `CompanyProfile { symbol, name, sector, industry, country, description,
  segments: [Segment{name, note}], suppliers: [Relation], customers:
  [Relation], competitors: [String], fundamentals: Fundamentals?, graph_source,
  fundamentals_source, ts_ms }`,
  `Relation { symbol?: String, name: String, via: String }`,
  `Fundamentals { revenue, revenue_yoy, gross_margin, op_margin, net_income,
  net_margin, eps, assets, liabilities, equity, ocf, cash, period, fiscal_year }`
  (all Option<f64> except period/year strings; NaN-firewalled).
- Non-US / non-curated / crypto symbols: profile returns what exists (crypto
  gets a minimal asset card, honest "no supply-chain graph curated" state).

### UI — `CompanyView` (new center mode `company`)

Bloomberg-SPLC-style three-column board:

```
[ SUPPLIERS ]        [ THE COMPANY ]          [ CUSTOMERS / SERVES ]
supplier cards   →   name · ticker · live px  →   customer cards
(via notes)          sector · country             (via notes)
                     WHAT IT MAKES: segment chips
                     FUNDAMENTALS: rev/margins/eps grid (mono digits)
                     COMPETITORS strip
```

Cards are `.panel()` hairline cards; relation cards with a known ticker are
clickable → re-selects that symbol and re-loads the board (graph walking, the
single best Bloomberg-beating interaction). Ember highlights the focused
company only. Sources footnoted in `dim`.

---

## Pillar 3 — REGIMES (bull/bear state board)

`cx-intel/src/regimes.rs`. Universe = configured symbols + default liquid
US equity universe (~40 megacaps/ETFs, config-overridable `universe = []`).
D1 bars via existing Yahoo backfill path, refreshed every 6h (equities) and
existing crypto D1 bars.

### Classifier (per symbol, D1)

State machine on: drawdown from 252-day high, run-up from 252-day low,
50/200 SMA relation, kalman slope sign, 20-day slope of 200 SMA.

| State | Rule (primary) |
|---|---|
| `bull` | px within 10% of 252d high AND 50>200 AND 200 rising |
| `entering_bull` | px ≥ +20% off 252d low AND 50 crossed above 200 within 40 bars, not yet `bull` |
| `correction` | drawdown 10–20% from 252d high |
| `entering_bear` | drawdown 20–25% from high (classic threshold just crossed, within 40 bars) OR 50 crossed below 200 within 40 bars with drawdown ≥ 15% |
| `bear` | drawdown ≥ 20% sustained (>40 bars) OR ≥ 25% |
| `recovery` | in bear-range drawdown but +15% off low with rising kalman slope |

Emits `EngineEvent::RegimeMap(RegimeBoard)` every scan (30 min cadence +
on-demand via `sync`): `RegimeBoard { rows: [RegimeRow], breadth:
Breadth, ts_ms }`, `RegimeRow { symbol, state, drawdown_pct, runup_pct,
days_in_state, dist_50_200_pct, last_close }`, `Breadth { pct_above_200d,
pct_above_50d, bulls, bears, entering_bear, entering_bull, universe_size }`.
Breadth < 30% above 200d feeds a **tighten-only** global caution (0.2,
"breadth deterioration") — regime awareness protects capital automatically.

### UI — `RegimesView` (new center mode `regimes`)

Kanban-style board: five columns (ENTERING BULL · BULL · CORRECTION ·
ENTERING BEAR · BEAR — recovery rows shown inside BEAR column with an ember
"recovery" chip). Row = ticker, drawdown/run-up %, mini state facts. Top
strip: breadth gauges (% above 200d / 50d, counts). Clicking a row selects
the symbol and jumps to its chart; ⌥-click opens COMPANY. State colors:
text-only semantic (up/down/dim) — no colored card fills (design law).

---

## Pillar 4 — MERIDIAN (the Dalio section)

> Name: **MERIDIAN** — the lines that connect the world. Dalio-style
> cause-effect machine: geopolitical events in, transmission chains out.

`cx-intel/src/meridian.rs` + static rulebook `causal_rules.rs`.

### Data source (keyless)

**GDELT 2.0 DOC API** (`api.gdeltproject.org`, added to egress allowlist),
polled every 15 min, one query per force-theme (bounded, byte-capped):
armed conflict, sanctions/trade war, energy/OPEC, central banks/inflation,
sovereign debt, elections/instability, tech export controls, natural
disasters/climate. Each article: title, source, url, tone (GDELT avg tone),
theme bucket, country tags, ts. Deduped by normalized title, ring-buffered
(cap 200).

### The Dalio machine

1. **Five Forces gauges** (Dalio's Changing World Order forces), each 0–100
   with 7-day trend, computed honestly from available data:
   - *Debt & money* — yield-curve regime + 2s10s level (existing macro).
   - *Internal order* — EWMA of GDELT tone on elections/instability themes.
   - *External order* — EWMA of tone on conflict/sanctions themes.
   - *Nature* — disaster-theme article intensity vs 30-day baseline.
   - *Technology* — tech-export-control/AI-race theme intensity.
   Gauge source labels state the proxy ("GDELT tone EWMA", "UST curve").
2. **Causal chains** — static rulebook mapping (theme, country-bloc,
   tone-direction) → transmission chain → affected assets with direction:
   e.g. `sanctions[RU/energy] → supply restriction → crude ↑ → energy eq ↑,
   airlines ↓, EUR ↓`. ~25 hand-written rules (curated, labeled). A rule
   *fires* when its theme's 24h article count z-scores ≥ 1.5 vs 30-day
   baseline; fired chains carry intensity + the 3 strongest headlines as
   evidence.
3. **Caution bridge** — external-order gauge ≥ 75 → tighten-only global
   caution 0.25 ("MERIDIAN: external conflict elevated"), same channel the
   macro sentinel already uses.

Emits `EngineEvent::Geo(GeoPulse)` every poll: `GeoPulse { forces:
[ForceGauge], chains: [CausalChain], events: [GeoEvent], ts_ms }` with
`ForceGauge { force, value, trend_7d, proxy }`, `CausalChain { rule_id,
title, steps: [String], assets: [AssetImpact{symbol_or_class, direction,
note}], intensity, evidence: [GeoEvent] }`, `GeoEvent { title, source_domain,
url, tone, theme, countries, ts_ms }`.

### UI — `MeridianView` (new center mode `meridian`)

Three-pane inside the center area:
- **Left: FORCES** — five vertical gauges (4px bars, ember fill, bone
  values, 7d trend arrows), each with proxy label in `dim`.
- **Center: THE MACHINE** — fired causal chains as connected step cards
  (event → mechanism → asset impacts with ▲/▼ in up/down colors), sorted by
  intensity; evidence headlines expandable per chain. Empty state: "no
  elevated transmissions — the machine is quiet."
- **Right: SIGNAL FEED** — GDELT event stream with theme + tone chips,
  country tags; click opens article URL in browser.

---

## Shell upgrade (toggleable panels + icon rail + navigation)

`RootView` rework:

- **Icon rail** (far left, 48pt, ink background, hairline right border) —
  GINEXUS-style SF Symbols, 15pt, `dim` → `ember` when active, 6pt radius
  ember-tint selection square. Sections (top→bottom):
  `chart.xyaxis.line` TERMINAL · `building.2` COMPANY · `square.grid.3x3`
  OPTIONS · `hammer` FOUNDRY · `waveform.path.ecg` REGIMES · `globe`
  MERIDIAN. Bottom of rail: panel toggles `sidebar.left`, `sidebar.right`,
  `rectangle.bottomthird.inset.filled` + connection dot.
- **Toggleable panels** — `@AppStorage`-persisted booleans
  (`showWatchlist`, `showIntelligence`, `showDeck`); animated with the
  sanctioned easing (0.22,1,0.36,1); keyboard shortcuts ⌘⇧L / ⌘⇧R / ⌘⇧B,
  and ⌘1…⌘6 for sections. Widths stay fixed (220/340/280) but panels
  collapse fully; IntelligencePanel's duplicated internal width removed.
- **CenterMode** extends to `chart · company · options · foundry · regimes ·
  meridian`; CenterModeBar replaced by the icon rail (mode bar removed).
- Watchlist rows gain a small `building.2` affordance on hover (equities)
  → COMPANY. Chart header symbol click → COMPANY.
- New state in AppModel: `company: CompanyProfile?`, `companyLoading`,
  `regimeBoard: RegimeBoard?`, `geoPulse: GeoPulse?` + frame decoding.
- ChartColors stay (muted overlay hues are sanctioned by DESIGN.md).

## Wire contract additions (source of truth for both sides)

New `EngineEvent` variants (serde `type` tags): `company`, `regime_map`,
`geo`. New `Command`: `{"cmd":"get_company","symbol":"NVDA"}`. Snapshot
gains `regimes: RegimeBoard?`, `geo: GeoPulse?` (company stays on-demand).
None of the new events are `is_critical` (droppable under backpressure).

## Config additions (`[intel]` in secrets.toml, all defaulted)

`universe: Vec<String>` (default 40-name list), `gdelt_poll_secs` (900),
`regime_scan_secs` (1800), `enable_meridian` / `enable_regimes` /
`enable_company` (true). Egress allowlist adds: `data.sec.gov`,
`www.sec.gov`, `api.gdeltproject.org`.

## Build order & ownership

1. **Me (integrator):** wire contract — cx-core events/commands/config,
   egress allowlist, cx-intel crate skeleton, cortexd wiring, Swift
   Models/AppModel/CenterMode stubs. Everything compiles with stub data.
2. **Parallel Rust agents:** A = cx-ta quant2/corr + features/regime integ;
   B = kalman_trend strategy + Hedge fusion + pipeline sizing + cx-sim
   walk-forward; C = cx-intel company+EDGAR+SPLC dataset; D = cx-intel
   regimes+meridian+GDELT+rulebook.
3. **Parallel Swift agents:** E = shell (icon rail, toggles, shortcuts);
   F = CompanyView + RegimesView + MeridianView.
4. **Me:** integration, full test run, adversarial review fan-out, fixes,
   docs, commit.

## Testing

Every new estimator vs closed-form/synthetic reference (house rule).
Classifier: fixture bar series per state. Meridian: rulebook firing on
synthetic article sets; tone EWMA math. Parsers (EDGAR, GDELT): real-shape
fixture JSON, malformed-input rejection. Swift: decode tests for the three
new frames + CenterMode/shell state tests. Zero-network unit tests
throughout (fixtures only); live fetch behind the existing Egress.
