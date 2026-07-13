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
    /// e.g. "curated graph (MTX Labs, 2026-07)" or "no curated graph".
    pub graph_source: String,
    /// e.g. "sec-edgar (10-K/10-Q)" or "unavailable".
    pub fundamentals_source: String,
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

/// The SCANNER board, republished every scan cycle.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct ScanBoard {
    pub rows: Vec<ScanRow>,
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
    Company(CompanyProfile),
    RegimeMap(RegimeBoard),
    Geo(GeoPulse),
    Scan(ScanBoard),
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
            EngineEvent::Company(_) => "company",
            EngineEvent::RegimeMap(_) => "regime_map",
            EngineEvent::Geo(_) => "geo",
            EngineEvent::Scan(_) => "scan",
            EngineEvent::History(_) => "history",
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

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
