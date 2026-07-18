//! The engine event vocabulary. Every event that crosses a squadron boundary
//! is one of these variants; the same JSON encoding streams to the macOS app.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::types::{AutonomyLevel, Interval, Liquidity, OrderType, Severity, Side, Tif, Venue};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Tick {
    pub symbol: String,
    pub ts_ms: i64,
    pub price: f64,
    pub size: f64,
    pub aggressor: Option<Side>,
    pub venue: Venue,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Bar {
    pub symbol: String,
    pub interval: Interval,
    /// Bucket-aligned open timestamp.
    pub ts_open_ms: i64,
    pub open: f64,
    pub high: f64,
    pub low: f64,
    pub close: f64,
    pub volume: f64,
    pub trade_count: u64,
    pub vwap: f64,
    /// False while the bar is still forming; true exactly once at rollover.
    pub complete: bool,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct BookTop {
    pub symbol: String,
    pub ts_ms: i64,
    pub bid_px: f64,
    pub bid_sz: f64,
    pub ask_px: f64,
    pub ask_sz: f64,
}

impl BookTop {
    pub fn mid(&self) -> f64 {
        (self.bid_px + self.ask_px) * 0.5
    }
    pub fn spread_bps(&self) -> f64 {
        let mid = self.mid();
        if mid > 0.0 {
            (self.ask_px - self.bid_px) / mid * 10_000.0
        } else {
            0.0
        }
    }
}

/// Who asked for an order. Auditability starts here: every fill traces back
/// to a source and a written rationale.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "kind", content = "name")]
pub enum OrderSource {
    Strategy(String),
    Agent(String),
    Manual,
    RiskFlatten,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OrderIntent {
    pub id: u64,
    pub symbol: String,
    pub side: Side,
    pub qty: f64,
    pub order_type: OrderType,
    pub limit_px: Option<f64>,
    /// Trigger price for `Stop` / `StopLimit` orders; `None` for market and
    /// limit orders.
    ///
    /// WIRE COMPAT: additive `#[serde(default)]` field — payloads without it
    /// still decode (None), so an old client's frame or a stored snapshot
    /// never breaks. Clients (Swift) treat it as optional-with-default.
    #[serde(default)]
    pub stop_px: Option<f64>,
    pub tif: Tif,
    /// True when this order only reduces an existing position. Reduce-only
    /// orders pass risk on a dedicated (more permissive) path.
    pub reduce_only: bool,
    pub source: OrderSource,
    pub rationale: String,
    pub ts_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "state")]
pub enum OrderStatus {
    PendingRisk,
    RejectedByRisk { reason: String },
    Accepted,
    Working,
    PartiallyFilled,
    Filled,
    Canceled { reason: String },
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OrderUpdate {
    pub order_id: u64,
    pub intent: OrderIntent,
    pub status: OrderStatus,
    pub filled_qty: f64,
    pub avg_fill_px: f64,
    pub ts_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Fill {
    pub order_id: u64,
    pub symbol: String,
    pub side: Side,
    pub qty: f64,
    pub px: f64,
    pub fee: f64,
    pub liquidity: Liquidity,
    pub venue: Venue,
    pub ts_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Position {
    pub symbol: String,
    /// Signed: positive long, negative short.
    pub qty: f64,
    pub avg_px: f64,
    pub mark_px: f64,
    pub unrealized_pnl: f64,
    pub realized_pnl: f64,
    pub ts_ms: i64,
}

impl Position {
    pub fn notional(&self) -> f64 {
        (self.qty * self.mark_px).abs()
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AccountSnapshot {
    pub equity: f64,
    pub cash: f64,
    pub gross_exposure: f64,
    pub net_exposure: f64,
    pub unrealized_pnl: f64,
    pub realized_pnl_day: f64,
    pub fees_paid: f64,
    pub open_orders: u32,
    pub daily_trades: u32,
    /// Peak-to-now drawdown fractions in [0, 1].
    pub drawdown_day: f64,
    pub drawdown_total: f64,
    pub ts_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RiskStatus {
    pub kill_switch: bool,
    pub kill_reason: Option<String>,
    pub autonomy: AutonomyLevel,
    /// Global caution in [0, 1]. Tighten-only: sizing multiplier is
    /// (1 - caution * max_shrink), never below the configured floor.
    pub caution: f64,
    pub caution_reasons: Vec<String>,
    /// Throttle in [0, 1] from the drawdown clocks; 1 = unthrottled.
    pub throttle: f64,
    pub breaches: Vec<String>,
    pub ts_ms: i64,
}

/// A structured thought from any AI agent — the visible stream of machine
/// reasoning that feeds both the UI and the shared context ledger.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AgentThought {
    pub agent: String,
    pub squadron: String,
    pub severity: Severity,
    pub text: String,
    pub tags: Vec<String>,
    /// Confidence in [0, 1].
    pub confidence: f64,
    pub symbol: Option<String>,
    pub ts_ms: i64,
}

/// A directional opinion from a strategy or agent. Fusion happens downstream;
/// a signal alone never places an order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StrategySignal {
    pub strategy: String,
    pub symbol: String,
    /// Direction in [-1, 1]: negative short, positive long, 0 flat.
    pub direction: f64,
    /// Conviction in [0, 1].
    pub conviction: f64,
    pub rationale: String,
    pub features: BTreeMap<String, f64>,
    pub ts_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct MacroSnapshot {
    /// Treasury par yields in percent, keyed "3m", "2y", "10y", "30y", ...
    pub yields: BTreeMap<String, f64>,
    pub spread_2s10s_bps: Option<f64>,
    pub spread_3m10s_bps: Option<f64>,
    pub curve_regime: String,
    /// ECB reference FX, keyed "EURUSD"-style.
    pub fx: BTreeMap<String, f64>,
    pub source: String,
    pub ts_ms: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum FeedHealth {
    Live,
    Degraded,
    SyntheticFallback,
    Down,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FeedStatus {
    pub feed: String,
    pub health: FeedHealth,
    pub detail: String,
    pub ts_ms: i64,
}

/// A tighten-only caution request from any agent. The risk engine applies it
/// through its CautionBook, which enforces the invariant: caution can only
/// shrink size, never grow it, never zero it, and always expires.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CautionUpdate {
    /// None tightens globally; Some(symbol) tightens one symbol.
    pub scope: Option<String>,
    /// Requested caution in [0, 1].
    pub value: f64,
    pub reason: String,
    pub agent: String,
    pub ts_ms: i64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OptionRight {
    Call,
    Put,
}

/// One option contract row. Greeks/IV come from the venue when present and
/// are back-filled by the engine's Black-Scholes solver when absent
/// (`greeks_source` says which).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OptionContract {
    pub symbol: String,
    pub right: OptionRight,
    pub strike: f64,
    /// Expiry as "YYYY-MM-DD".
    pub expiry: String,
    pub bid: f64,
    pub ask: f64,
    pub last: f64,
    pub volume: f64,
    pub open_interest: f64,
    pub iv: Option<f64>,
    pub delta: Option<f64>,
    pub gamma: Option<f64>,
    pub theta: Option<f64>,
    pub vega: Option<f64>,
    pub greeks_source: String,
}

/// A full (single-expiry) option chain for an underlying, served on demand
/// via `Command::GetOptionsChain`.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct OptionsChain {
    pub underlying: String,
    pub underlying_px: f64,
    /// All expiries the venue offers, "YYYY-MM-DD", ascending.
    pub expirations: Vec<String>,
    /// The expiry this payload carries contracts for.
    pub expiry: String,
    pub contracts: Vec<OptionContract>,
    /// Delayed data disclosure, e.g. "cboe delayed 15m".
    pub source: String,
    /// Venue's last-trade timestamp for the underlying, when provided —
    /// makes staleness visible (closed markets show the prior session).
    pub as_of: Option<String>,
    pub ts_ms: i64,
}

/// Per-strategy backtest statistics over stored history (Foundry).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct StrategyStats {
    pub strategy: String,
    pub symbol: String,
    pub interval: Interval,
    pub bars: u32,
    pub trades: u32,
    /// Fractions in [0,1]; None until at least one closed trade.
    pub win_rate: Option<f64>,
    pub profit_factor: Option<f64>,
    pub sharpe: Option<f64>,
    pub max_drawdown: Option<f64>,
    /// Mean per-trade return (fraction, fees included).
    pub expectancy: Option<f64>,
    /// Equity multiple risking 10% of equity per trade over the sample.
    pub equity_multiple: Option<f64>,
}

/// Monte Carlo forward projection from measured trade statistics.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SimProjection {
    pub basis: String,
    pub horizon_trades: u32,
    /// Equity multiples at the 5th/50th/95th percentile.
    pub p05: f64,
    pub p50: f64,
    pub p95: f64,
    /// Probability of losing half of equity within the horizon.
    pub risk_of_ruin: f64,
}

/// One replayed trade — the auditable grain behind every statistic:
/// timestamps and prices are the stored market history itself.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SimTrade {
    pub strategy: String,
    pub symbol: String,
    /// Buy = long trade, Sell = short trade.
    pub side: Side,
    pub entry_ts: i64,
    pub exit_ts: i64,
    pub entry_px: f64,
    pub exit_px: f64,
    /// Net return fraction (costs included).
    pub ret: f64,
}

/// Foundry output: strategy rules replayed over stored real history with
/// fees and slippage, plus projections. Statistics, not promises.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct SimReport {
    pub stats: Vec<StrategyStats>,
    /// Per-trade audit log (capped), newest last.
    pub trades: Vec<SimTrade>,
    pub projections: Vec<SimProjection>,
    pub best: Option<String>,
    pub note: String,
    pub ts_ms: i64,
}

// ---------------------------------------------------------------------------
// Intel squadron: COMPANY (supply-chain + fundamentals), REGIMES, MERIDIAN.
// ---------------------------------------------------------------------------

/// One business segment / product line of a company ("what it makes").
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Segment {
    pub name: String,
    pub note: String,
}

/// A supply-chain relation (supplier or customer). `symbol` is present when
/// the counterparty is itself a listed ticker — those are click-navigable.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Relation {
    pub symbol: Option<String>,
    pub name: String,
    /// What flows across the relation, e.g. "leading-edge wafer fabrication".
    pub via: String,
}

/// One recent SEC filing (EDGAR submissions), enough to link out to its
/// primary document on sec.gov. `filed` is "YYYY-MM-DD".
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Filing {
    /// Filing form type, e.g. "10-K", "10-Q", "8-K", "S-1", "DEF 14A".
    pub form: String,
    /// Filing date, "YYYY-MM-DD".
    pub filed: String,
    /// Direct link to the primary document on www.sec.gov.
    pub primary_doc_url: String,
}

/// Latest reported fundamentals extracted from SEC EDGAR XBRL company facts.
/// Everything optional: filings vary, and absence is more honest than zero.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
pub struct Fundamentals {
    pub revenue: Option<f64>,
    pub revenue_yoy: Option<f64>,
    pub gross_margin: Option<f64>,
    pub op_margin: Option<f64>,
    pub net_income: Option<f64>,
    pub net_margin: Option<f64>,
    pub eps: Option<f64>,
    pub assets: Option<f64>,
    pub liabilities: Option<f64>,
    pub equity: Option<f64>,
    pub ocf: Option<f64>,
    pub cash: Option<f64>,
    /// Latest cover-page common shares outstanding (dei
    /// `EntityCommonStockSharesOutstanding`). A SHARE COUNT, not dollars —
    /// market cap needs a live price and is left to the client.
    pub shares_outstanding: Option<f64>,
    /// Public float as a DOLLAR amount from the latest 10-K cover (dei
    /// `EntityPublicFloat`) — NOT a share count. Honestly a $ value.
    pub public_float_usd: Option<f64>,
    /// e.g. "FY" or "Q2"; `fiscal_year` e.g. "2026".
    pub period: String,
    pub fiscal_year: String,
}

/// Bloomberg-SPLC-class company intelligence card, served on demand via
/// `Command::GetCompany`. Sources are always disclosed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CompanyProfile {
    pub symbol: String,
    pub name: String,
    pub sector: String,
    pub industry: String,
    pub country: String,
    pub description: String,
    pub segments: Vec<Segment>,
    pub suppliers: Vec<Relation>,
    pub customers: Vec<Relation>,
    pub competitors: Vec<String>,
    pub fundamentals: Option<Fundamentals>,
    /// Recent SEC filings (newest first, capped ~12) from EDGAR submissions.
    ///
    /// WIRE COMPAT: additive `#[serde(default)]` field — payloads without it
    /// still decode (empty), and clients (Swift) must treat it as
    /// optional-with-default, never required.
    #[serde(default)]
    pub filings: Vec<Filing>,
    /// e.g. "curated graph (MTX Labs, 2026-07)" or "no curated graph".
    pub graph_source: String,
    /// e.g. "sec-edgar (10-K/10-Q)" or "unavailable".
    pub fundamentals_source: String,
    /// e.g. "sec-edgar submissions" or "unavailable".
    ///
    /// WIRE COMPAT: additive `#[serde(default)]` field — old payloads decode
    /// to "" and clients must treat it as optional-with-default.
    #[serde(default)]
    pub filings_source: String,
    pub ts_ms: i64,
}

/// One filing row for the dedicated FILINGS browser — richer than
/// [`Filing`] (which the COMPANY card carries as a cadence summary). Every
/// field is a plain string/number so the Swift mirror can decode it 1:1; a
/// field the source did not supply is "" / 0 / false, never a fabricated
/// value.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FilingEntry {
    /// Filing form type, e.g. "10-K", "10-Q/A", "8-K", "S-1", "DEF 14A".
    pub form: String,
    /// Filing date, "YYYY-MM-DD".
    pub filed: String,
    /// Period of report ("YYYY-MM-DD"); "" for forms with no reporting period.
    pub report_date: String,
    /// Dashed accession number, e.g. "0000320193-26-000005".
    pub accession: String,
    /// Primary document filename, e.g. "aapl-20251228.htm"; may be "".
    pub primary_doc: String,
    /// Direct link to the primary document on www.sec.gov; "" when unknown.
    pub primary_doc_url: String,
    /// Link to the filing's index page on www.sec.gov (always resolvable).
    pub filing_index_url: String,
    /// Human description (EDGAR primaryDocDescription, else the form's human
    /// name); may be "".
    pub description: String,
    /// 8-K item codes as a CSV, e.g. "2.02,9.01"; may be "".
    pub items: String,
    /// Primary document size in bytes (0 when the source did not report it).
    pub size: u64,
    /// True when the filing is XBRL-tagged (EDGAR isXBRL == 1).
    pub is_xbrl: bool,
}

/// A dedicated SEC EDGAR FILINGS report for one filer, served on demand via
/// `Command::GetFilings`. Sources are always disclosed; an unresolved query
/// or a failed fetch yields an empty list plus an honest `note`, never an
/// error. Answered on demand like COMPANY — never part of the snapshot.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct FilingsReport {
    /// The original query as asked (ticker, company name, or raw CIK).
    pub query: String,
    /// Zero-padded 10-digit CIK, e.g. "0000320193"; "" when unresolved.
    pub cik: String,
    /// Filer legal name, e.g. "Apple Inc."; "" when unresolved.
    pub name: String,
    /// Resolved ticker, e.g. "AAPL"; "" when unknown.
    pub ticker: String,
    pub filings: Vec<FilingEntry>,
    /// e.g. "SEC EDGAR submissions (data.sec.gov)" or
    /// "SEC EDGAR full-text (efts.sec.gov)".
    pub source: String,
    /// "" on success, else an honest explanation ("ticker not found in SEC
    /// map", "submissions fetch failed", ...).
    pub note: String,
    pub ts_ms: i64,
}

/// Secular market state of one symbol, classified on daily bars.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum RegimeState {
    Bull,
    EnteringBull,
    Correction,
    EnteringBear,
    Bear,
    Recovery,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegimeRow {
    pub symbol: String,
    pub state: RegimeState,
    /// Drawdown from the 252d high, fraction in [0, 1].
    pub drawdown_pct: f64,
    /// Run-up from the 252d low, fraction >= 0.
    pub runup_pct: f64,
    pub days_in_state: u32,
    /// (SMA50 - SMA200) / SMA200, when both exist.
    pub dist_50_200_pct: Option<f64>,
    pub last_close: f64,
}

/// Cross-sectional market breadth over the scanned universe.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Breadth {
    pub pct_above_200d: Option<f64>,
    pub pct_above_50d: Option<f64>,
    pub bulls: u32,
    pub bears: u32,
    pub entering_bull: u32,
    pub entering_bear: u32,
    pub universe_size: u32,
}

/// The REGIMES board: every scanned symbol's bull/bear state + breadth.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct RegimeBoard {
    pub rows: Vec<RegimeRow>,
    pub breadth: Breadth,
    pub source: String,
    pub ts_ms: i64,
}

/// One geopolitical news event (GDELT), deduped and theme-bucketed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GeoEvent {
    pub title: String,
    pub source_domain: String,
    pub url: String,
    /// GDELT average tone: negative = grim, positive = calm.
    pub tone: f64,
    pub theme: String,
    pub countries: Vec<String>,
    pub ts_ms: i64,
}

/// One of Dalio's five forces, gauged 0-100 from a disclosed proxy.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ForceGauge {
    pub force: String,
    pub value: f64,
    /// 7-day change in gauge points (signed).
    pub trend_7d: f64,
    /// The honest label of what actually drives the number.
    pub proxy: String,
}

/// An asset touched by a causal chain. `direction`: +1 up-pressure,
/// -1 down-pressure.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AssetImpact {
    /// Ticker when listed ("XOM") or an asset class label ("crude oil").
    pub target: String,
    pub direction: i32,
    pub note: String,
}

/// A fired Dalio-style transmission chain: event theme -> mechanism steps
/// -> asset pressure, with the evidence that fired it.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct CausalChain {
    pub rule_id: String,
    pub title: String,
    pub steps: Vec<String>,
    pub assets: Vec<AssetImpact>,
    /// Firing intensity (article-count z-score vs 30d baseline), >= threshold.
    pub intensity: f64,
    pub evidence: Vec<GeoEvent>,
}

/// MERIDIAN pulse: forces, fired chains, and the raw event feed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct GeoPulse {
    pub forces: Vec<ForceGauge>,
    pub chains: Vec<CausalChain>,
    pub events: Vec<GeoEvent>,
    pub source: String,
    pub ts_ms: i64,
}

/// One SCANNER row: cross-sectional percentile scores (0-100, ranked
/// against the rest of the scan universe on the same cycle) plus the raw
/// readings behind them. Absent data is None — never a fake zero.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScanRow {
    pub symbol: String,
    /// "equity" | "crypto".
    pub asset_class: String,
    /// Weighted blend of the percentile scores (documented in cx-intel).
    pub composite: f64,
    pub momentum: f64,
    pub trend: f64,
    pub breakout: f64,
    pub meanrev: f64,
    pub vol_state: f64,
    pub rsi_14: Option<f64>,
    pub zscore_20: Option<f64>,
    pub kalman_tstat: Option<f64>,
    /// Simple returns over ~1w/1m/3m of D1 bars.
    pub ret_1w: Option<f64>,
    pub ret_1m: Option<f64>,
    pub ret_3m: Option<f64>,
    /// Fraction below the 252d high (0 = at the high).
    pub dist_52w_high: Option<f64>,
    /// Latest volume vs its 20d average (1.0 = normal).
    pub vol_surge: Option<f64>,
    pub regime: Option<RegimeState>,
    /// Event flags: "new 52w high", "golden cross", "volume spike",
    /// "breakout setup", "oversold bounce", "vol expansion".
    pub flags: Vec<String>,
    pub last_close: f64,
}

/// One SCANNER alert: a flag that TRANSITIONED ON for `symbol` on this scan
/// cycle (absent on the previous cycle, present now). Steady-state flags
/// never re-alert — one alert per transition.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScanAlert {
    pub symbol: String,
    /// One of the [`ScanRow`] flag strings.
    pub flag: String,
    pub ts_ms: i64,
}

/// The SCANNER board, republished every scan cycle.
///
/// WIRE COMPAT: `alerts` and `weights_used` are additive, `#[serde(default)]`
/// fields — payloads without them still decode (empty), and clients (Swift)
/// must treat them as optional-with-default, never required.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScanBoard {
    pub rows: Vec<ScanRow>,
    /// Flags that transitioned ON this cycle vs the previous one; empty on
    /// the first cycle (nothing to diff) and whenever no flag changed.
    #[serde(default)]
    pub alerts: Vec<ScanAlert>,
    /// The composite weights this board was actually ranked with (post
    /// regime shift + hard clamp + renormalization), keyed
    /// w_trend / w_momentum / w_breakout / w_vol_state / w_meanrev.
    #[serde(default)]
    pub weights_used: BTreeMap<String, f64>,
    pub source: String,
    pub ts_ms: i64,
}

/// One market/company headline, deduped by title. `symbol` names the
/// configured equity whose company/per-symbol query surfaced it; None marks a
/// general markets query.
///
/// WIRE COMPAT: `source_name` is an additive, `#[serde(default)]` field —
/// payloads without it still decode (None), and clients (Swift) must treat it
/// as optional. It is the human display outlet ("Reuters", "CNBC", "Yahoo
/// Finance") when a feed names its source; `source_domain` is always the real
/// article/outlet domain. GDELT items leave `source_name` None (the domain is
/// their only honest attribution).
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewsItem {
    pub symbol: Option<String>,
    pub title: String,
    pub source_domain: String,
    /// Display attribution ("Reuters", "CNBC", "Yahoo Finance"); None when the
    /// source names no outlet (GDELT) — the UI falls back to `source_domain`.
    #[serde(default)]
    pub source_name: Option<String>,
    pub url: String,
    /// GDELT average tone (negative = grim, positive = calm); RSS/Atom feeds
    /// carry no tone and record a neutral 0.0, the same rule as absent tone.
    pub tone: f64,
    pub ts_ms: i64,
}

/// One configured equity's earnings-calendar row, ESTIMATED from its SEC
/// EDGAR filing cadence. `next_estimate` is arithmetic, not a confirmed
/// date — `basis` discloses that on every row.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct EarningsRow {
    pub symbol: String,
    /// Most recent periodic (10-Q/10-K) filing date, "YYYY-MM-DD".
    pub last_report: String,
    /// `last_report` + 91 days, "YYYY-MM-DD".
    pub next_estimate: String,
    /// e.g. "estimated from filing cadence (not confirmed)".
    pub basis: String,
}

/// The NEWS board: deduped company/market headlines plus filing-cadence
/// earnings estimates. Sources are always disclosed.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct NewsBoard {
    pub items: Vec<NewsItem>,
    pub earnings: Vec<EarningsRow>,
    pub source: String,
    pub ts_ms: i64,
}

/// On-demand history answer (`Command::GetHistory`): one symbol, one
/// interval, the whole series in a single frame so ad-hoc searched tickers
/// can chart without being part of the configured feed set.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct HistorySlice {
    pub symbol: String,
    pub interval: Interval,
    pub bars: Vec<Bar>,
    pub source: String,
    pub ts_ms: i64,
}

/// Answer to an `AskAi` command — the copilot channel.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct AiAnswer {
    pub request_id: String,
    pub question: String,
    pub answer: String,
    pub model: String,
    pub ts_ms: i64,
}

/// A bounded parameter update for one strategy's tunable recipe, produced by
/// the AUTORESEARCH loop. Advisory by contract: consumers MUST clamp every
/// value to their own compiled-in hard bounds before applying — an event on
/// the bus can suggest a parameter, never force an out-of-bounds one.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ParamUpdate {
    pub strategy: String,
    /// Tunable key -> requested value (e.g. "z_entry" -> 1.75).
    pub params: BTreeMap<String, f64>,
    /// Who produced the update (e.g. "autoresearch").
    pub source: String,
    /// The written justification — every adoption is auditable.
    pub rationale: String,
    pub ts_ms: i64,
}

/// Everything that can cross the bus. `type`-tagged so the Swift client can
/// switch on one field.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum EngineEvent {
    Tick(Tick),
    Bar(Bar),
    BookTop(BookTop),
    OrderIntent(OrderIntent),
    OrderUpdate(OrderUpdate),
    Fill(Fill),
    Position(Position),
    Account(AccountSnapshot),
    Risk(RiskStatus),
    Thought(AgentThought),
    Signal(StrategySignal),
    Macro(MacroSnapshot),
    FeedStatus(FeedStatus),
    Caution(CautionUpdate),
    OptionsChain(OptionsChain),
    Sim(SimReport),
    AiAnswer(AiAnswer),
    ParamUpdate(ParamUpdate),
    Company(CompanyProfile),
    Filings(FilingsReport),
    RegimeMap(RegimeBoard),
    Geo(GeoPulse),
    Scan(ScanBoard),
    News(NewsBoard),
    History(HistorySlice),
}

impl EngineEvent {
    /// Coarse priority: critical events must never be starved by ticks.
    pub fn is_critical(&self) -> bool {
        matches!(
            self,
            EngineEvent::Risk(_)
                | EngineEvent::OrderUpdate(_)
                | EngineEvent::Fill(_)
                | EngineEvent::OrderIntent(_)
                | EngineEvent::Caution(_)
        )
    }

    pub fn kind(&self) -> &'static str {
        match self {
            EngineEvent::Tick(_) => "tick",
            EngineEvent::Bar(_) => "bar",
            EngineEvent::BookTop(_) => "book_top",
            EngineEvent::OrderIntent(_) => "order_intent",
            EngineEvent::OrderUpdate(_) => "order_update",
            EngineEvent::Fill(_) => "fill",
            EngineEvent::Position(_) => "position",
            EngineEvent::Account(_) => "account",
            EngineEvent::Risk(_) => "risk",
            EngineEvent::Thought(_) => "thought",
            EngineEvent::Signal(_) => "signal",
            EngineEvent::Macro(_) => "macro",
            EngineEvent::FeedStatus(_) => "feed_status",
            EngineEvent::Caution(_) => "caution",
            EngineEvent::OptionsChain(_) => "options_chain",
            EngineEvent::Sim(_) => "sim",
            EngineEvent::AiAnswer(_) => "ai_answer",
            EngineEvent::ParamUpdate(_) => "param_update",
            EngineEvent::Company(_) => "company",
            EngineEvent::Filings(_) => "filings",
            EngineEvent::RegimeMap(_) => "regime_map",
            EngineEvent::Geo(_) => "geo",
            EngineEvent::Scan(_) => "scan",
            EngineEvent::News(_) => "news",
            EngineEvent::History(_) => "history",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn param_update_is_type_tagged_and_not_critical() {
        let mut params = BTreeMap::new();
        params.insert("z_entry".to_string(), 1.75);
        let ev = EngineEvent::ParamUpdate(ParamUpdate {
            strategy: "meanrev_z".into(),
            params,
            source: "autoresearch".into(),
            rationale: "OOS expectancy +32% over incumbent".into(),
            ts_ms: 1,
        });
        assert_eq!(ev.kind(), "param_update");
        assert!(!ev.is_critical(), "param updates must never starve ticks");
        let json = serde_json::to_string(&ev).unwrap();
        assert!(json.contains("\"type\":\"param_update\""));
        let back: EngineEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ev);
    }

    #[test]
    fn news_event_is_type_tagged_and_not_critical() {
        let ev = EngineEvent::News(NewsBoard {
            items: vec![NewsItem {
                symbol: Some("NVDA".into()),
                title: "Blackwell demand outruns supply".into(),
                source_domain: "www.reuters.com".into(),
                source_name: Some("Reuters".into()),
                url: "https://example.com/a".into(),
                tone: -1.5,
                ts_ms: 1,
            }],
            earnings: vec![EarningsRow {
                symbol: "NVDA".into(),
                last_report: "2026-05-28".into(),
                next_estimate: "2026-08-27".into(),
                basis: "estimated from filing cadence (not confirmed)".into(),
            }],
            source: "gdelt 2.0 + sec edgar submissions".into(),
            ts_ms: 2,
        });
        assert_eq!(ev.kind(), "news");
        assert!(!ev.is_critical(), "news must never starve ticks");
        let json = serde_json::to_string(&ev).unwrap();
        assert!(json.contains("\"type\":\"news\""));
        assert!(json.contains("\"source_name\":\"Reuters\""));
        let back: EngineEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ev);
    }

    #[test]
    fn news_item_source_name_is_additive_and_defaults_none() {
        // A pre-`source_name` frame (the multi-source news engine's field is
        // additive) must still decode — old engines' stored boards and older
        // clients never break, and the field reads back None.
        let old = r#"{"type":"news","items":[{"symbol":null,
            "title":"markets steady","source_domain":"example.com",
            "url":"https://example.com/x","tone":0.0,"ts_ms":3}],
            "earnings":[],"source":"gdelt 2.0","ts_ms":4}"#;
        let ev: EngineEvent = serde_json::from_str(old).unwrap();
        let EngineEvent::News(board) = &ev else {
            panic!("decoded wrong variant");
        };
        assert_eq!(board.items[0].source_name, None);

        // A populated outlet round-trips.
        let item = NewsItem {
            symbol: None,
            title: "chip stocks weaken".into(),
            source_domain: "www.reuters.com".into(),
            source_name: Some("Reuters".into()),
            url: "https://news.google.com/rss/articles/abc".into(),
            tone: 0.0,
            ts_ms: 5,
        };
        let json = serde_json::to_string(&item).unwrap();
        let back: NewsItem = serde_json::from_str(&json).unwrap();
        assert_eq!(back, item);
    }

    #[test]
    fn scan_board_new_fields_are_additive_and_default() {
        // A pre-alerts/weights payload (no `alerts`, no `weights_used`)
        // must still decode — the fields are additive with defaults, so an
        // old engine's frame or a stored snapshot never breaks a client.
        let old = r#"{"type":"scan","rows":[],"source":"cortex scan","ts_ms":7}"#;
        let ev: EngineEvent = serde_json::from_str(old).unwrap();
        let EngineEvent::Scan(board) = &ev else {
            panic!("decoded wrong variant");
        };
        assert!(board.alerts.is_empty());
        assert!(board.weights_used.is_empty());
        assert!(!ev.is_critical(), "scan boards must never starve ticks");

        // Populated new fields round-trip.
        let mut weights_used = BTreeMap::new();
        weights_used.insert("w_trend".to_string(), 0.30);
        let ev = EngineEvent::Scan(ScanBoard {
            rows: vec![],
            alerts: vec![ScanAlert {
                symbol: "NVDA".into(),
                flag: "breakout setup".into(),
                ts_ms: 8,
            }],
            weights_used,
            source: "cortex scan".into(),
            ts_ms: 8,
        });
        let json = serde_json::to_string(&ev).unwrap();
        assert!(json.contains("\"type\":\"scan\""));
        assert!(json.contains("\"flag\":\"breakout setup\""));
        let back: EngineEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ev);
    }

    #[test]
    fn company_profile_new_fields_are_additive_and_default() {
        // A pre-filings CompanyProfile frame (no `filings`, no
        // `filings_source`, and a `fundamentals` lacking the dei fields) must
        // still decode — every added field is additive with a default, so an
        // old engine's frame or a stored snapshot never breaks a client.
        let old = r#"{"type":"company","symbol":"NVDA","name":"NVIDIA Corporation",
            "sector":"Technology","industry":"Semiconductors","country":"United States",
            "description":"","segments":[],"suppliers":[],"customers":[],"competitors":[],
            "fundamentals":{"revenue":1.0,"revenue_yoy":null,"gross_margin":null,
              "op_margin":null,"net_income":null,"net_margin":null,"eps":null,"assets":null,
              "liabilities":null,"equity":null,"ocf":null,"cash":null,"period":"FY",
              "fiscal_year":"2024"},
            "graph_source":"curated graph","fundamentals_source":"unavailable","ts_ms":5}"#;
        let ev: EngineEvent = serde_json::from_str(old).unwrap();
        let EngineEvent::Company(p) = &ev else {
            panic!("decoded wrong variant");
        };
        assert!(p.filings.is_empty());
        assert_eq!(p.filings_source, "");
        let f = p.fundamentals.as_ref().unwrap();
        // Missing dei fields decode to None (serde treats absent Options).
        assert_eq!(f.shares_outstanding, None);
        assert_eq!(f.public_float_usd, None);
        assert!(!ev.is_critical(), "company profiles must never starve ticks");

        // Populated new fields round-trip.
        let ev = EngineEvent::Company(CompanyProfile {
            symbol: "NVDA".into(),
            name: "NVIDIA Corporation".into(),
            sector: "Technology".into(),
            industry: "Semiconductors".into(),
            country: "United States".into(),
            description: String::new(),
            segments: vec![],
            suppliers: vec![],
            customers: vec![],
            competitors: vec![],
            fundamentals: Some(Fundamentals {
                revenue: Some(391_035_000_000.0),
                shares_outstanding: Some(15_115_823_000.0),
                public_float_usd: Some(2_600_000_000_000.0),
                period: "FY".into(),
                fiscal_year: "2024".into(),
                ..Default::default()
            }),
            filings: vec![Filing {
                form: "10-K".into(),
                filed: "2026-02-26".into(),
                primary_doc_url:
                    "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000012/nvda-20260126.htm"
                        .into(),
            }],
            graph_source: "curated graph".into(),
            fundamentals_source: "sec-edgar (10-K/20-F)".into(),
            filings_source: "sec-edgar submissions".into(),
            ts_ms: 6,
        });
        let json = serde_json::to_string(&ev).unwrap();
        assert!(json.contains("\"type\":\"company\""));
        assert!(json.contains("\"public_float_usd\":2600000000000.0"));
        assert!(json.contains("\"filings_source\":\"sec-edgar submissions\""));
        let back: EngineEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ev);
    }

    #[test]
    fn filings_event_is_type_tagged_and_not_critical() {
        let ev = EngineEvent::Filings(FilingsReport {
            query: "AAPL".into(),
            cik: "0000320193".into(),
            name: "Apple Inc.".into(),
            ticker: "AAPL".into(),
            filings: vec![FilingEntry {
                form: "10-K".into(),
                filed: "2026-02-15".into(),
                report_date: "2025-12-28".into(),
                accession: "0000320193-26-000005".into(),
                primary_doc: "aapl-20251228.htm".into(),
                primary_doc_url:
                    "https://www.sec.gov/Archives/edgar/data/320193/000032019326000005/aapl-20251228.htm"
                        .into(),
                filing_index_url:
                    "https://www.sec.gov/Archives/edgar/data/320193/000032019326000005/0000320193-26-000005-index.htm"
                        .into(),
                description: "Annual report".into(),
                items: String::new(),
                size: 1_200_000,
                is_xbrl: true,
            }],
            source: "SEC EDGAR submissions (data.sec.gov)".into(),
            note: String::new(),
            ts_ms: 9,
        });
        assert_eq!(ev.kind(), "filings");
        assert!(!ev.is_critical(), "filings reports must never starve ticks");
        let json = serde_json::to_string(&ev).unwrap();
        assert!(json.contains("\"type\":\"filings\""));
        // snake_case field names the Swift mirror decodes 1:1.
        assert!(json.contains("\"report_date\":\"2025-12-28\""));
        assert!(json.contains("\"is_xbrl\":true"));
        assert!(json.contains("\"filing_index_url\""));
        let back: EngineEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ev);
    }

    #[test]
    fn order_intent_stop_px_is_additive_and_defaults_none() {
        // A pre-stop OrderIntent frame (no `stop_px`) must still decode —
        // the field is additive with a default, so an old client's order or a
        // stored snapshot never breaks a new engine.
        let old = r#"{"id":7,"symbol":"BTC-USD","side":"buy","qty":1.0,
            "order_type":"market","limit_px":null,"tif":"gtc","reduce_only":false,
            "source":{"kind":"manual"},"rationale":"","ts_ms":1}"#;
        let intent: OrderIntent = serde_json::from_str(old).unwrap();
        assert_eq!(intent.stop_px, None);

        // A populated stop order round-trips with a snake_case "stop_px".
        let stop = OrderIntent {
            id: 8,
            symbol: "BTC-USD".into(),
            side: Side::Sell,
            qty: 2.0,
            order_type: OrderType::StopLimit,
            limit_px: Some(95.0),
            stop_px: Some(96.0),
            tif: Tif::Gtc,
            reduce_only: true,
            source: OrderSource::Manual,
            rationale: "protective stop".into(),
            ts_ms: 2,
        };
        let json = serde_json::to_string(&stop).unwrap();
        assert!(json.contains("\"stop_px\":96.0"));
        assert!(json.contains("\"order_type\":\"stop_limit\""));
        let back: OrderIntent = serde_json::from_str(&json).unwrap();
        assert_eq!(back, stop);
    }

    #[test]
    fn event_json_is_type_tagged() {
        let ev = EngineEvent::Tick(Tick {
            symbol: "BTC-USD".into(),
            ts_ms: 1,
            price: 50_000.0,
            size: 0.1,
            aggressor: Some(Side::Buy),
            venue: Venue::Coinbase,
        });
        let json = serde_json::to_string(&ev).unwrap();
        assert!(json.contains("\"type\":\"tick\""));
        let back: EngineEvent = serde_json::from_str(&json).unwrap();
        assert_eq!(back, ev);
    }
}
