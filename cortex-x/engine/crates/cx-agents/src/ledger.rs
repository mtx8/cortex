//! The context ledger — the mesh's shared, bounded memory of engine state.
//!
//! One bus-subscriber task keeps the rolling state current;
//! [`ContextLedger::render`] flattens it into the compact plaintext block that
//! is the ONLY thing any LLM ever sees. Invariants:
//! - No secrets, keys, URLs or raw config values ever enter the render.
//! - Every stored number is NaN-guarded on ingest or at render time.
//! - Memory is bounded: 30 thoughts, 20 signals, per-symbol maps only.
//! - Per-symbol features are computed on demand from the [`BarStore`],
//!   never cached (the store is the single source of bar truth).

use std::collections::{BTreeMap, VecDeque};
use std::sync::{Arc, RwLock};

use cx_core::events::{
    AccountSnapshot, AgentThought, EngineEvent, FeedStatus, GeoPulse, MacroSnapshot, Position,
    RegimeBoard, RegimeState, RiskStatus, StrategySignal,
};
use cx_core::store::BarStore;
use cx_core::types::{Interval, Severity};
use cx_core::Bus;
use cx_ta::{compute_features, detect_regime_with, Regime};

const MAX_THOUGHTS: usize = 30;
const MAX_SIGNALS: usize = 20;
const RENDER_THOUGHTS: usize = 12;
const RENDER_SIGNALS: usize = 10;
const RENDER_MAX_WORDS: usize = 2_000;
const FEATURE_LOOKBACK: usize = 120;
const DAY_MS: i64 = 86_400_000;
/// MERIDIAN render caps: the five forces (one spare), a handful of fired
/// chains, and the top asset impacts per chain — the section stays compact
/// whatever cx-intel publishes.
const RENDER_FORCES: usize = 6;
const RENDER_CHAINS: usize = 3;
const RENDER_CHAIN_ASSETS: usize = 3;
/// ENSEMBLE render cap: at most this many strategy weights.
const RENDER_WEIGHTS: usize = 12;
/// DESKS bound: at most this many "desk-*" squadrons keep a latest note.
const MAX_DESKS: usize = 6;
/// PLAYBOOK bound: at most this many strategies in the regime matrix.
const MAX_PLAYBOOK: usize = 12;
/// Regime buckets in the PLAYBOOK matrix, mirroring the fusion layer's
/// `regime_code` encoding: 0 trend-up, 1 trend-dn, 2 range, 3 high-vol.
const REGIME_BUCKETS: usize = 4;

/// Last trade price plus the first price seen this UTC day (session open).
#[derive(Debug, Clone, Copy)]
pub(crate) struct PriceState {
    pub last: f64,
    pub session_open: f64,
    day: i64,
}

/// Everything the mesh remembers. Cloneable so readers (copilot heuristics)
/// can snapshot without holding the lock while formatting.
#[derive(Default, Clone)]
pub(crate) struct LedgerState {
    pub account: Option<AccountSnapshot>,
    pub risk: Option<RiskStatus>,
    pub positions: BTreeMap<String, Position>,
    pub thoughts: VecDeque<AgentThought>,
    pub signals: VecDeque<StrategySignal>,
    pub macro_snap: Option<MacroSnapshot>,
    pub prices: BTreeMap<String, PriceState>,
    pub feeds: BTreeMap<String, FeedStatus>,
    pub fills_today: u32,
    fills_day: i64,
    /// Latest REGIMES board (cx-intel scanner); render shows breadth plus
    /// configured symbols only.
    pub regime_board: Option<RegimeBoard>,
    /// Latest MERIDIAN pulse (cx-intel); render caps forces/chains/assets.
    pub geo: Option<GeoPulse>,
    /// Latest fusion Hedge weights keyed by strategy name, from the "w_*"
    /// features of the most recent "fusion" signal. Finite values only.
    pub ensemble: BTreeMap<String, f64>,
    /// Regime-multiplier matrix accumulated from "fusion" signals: strategy
    /// -> multiplier per regime bucket. Fusion surfaces only the CURRENT
    /// bucket's "m_*" values (plus "regime_code" naming the bucket), so the
    /// matrix fills in over time as regimes rotate — latest value wins per
    /// (strategy, bucket). Finite values only; bounded to [`MAX_PLAYBOOK`].
    pub playbook: BTreeMap<String, [f64; REGIME_BUCKETS]>,
    /// Latest thought per asset-class desk, keyed by its "desk-*" squadron
    /// (desks throttle to notable changes, so this is the freshest reading
    /// each desk has published). Admission-bounded to [`MAX_DESKS`].
    pub desks: BTreeMap<String, AgentThought>,
}

pub(crate) struct ContextLedger {
    state: RwLock<LedgerState>,
    store: Arc<BarStore>,
    /// PALACE closet source: when attached, `render` includes a bounded
    /// "=== PALACE ===" section so the LLM sees institutional memory every
    /// cycle. None = a mesh without persistent memory (tests, no home dir).
    palace: Option<Arc<crate::palace::Palace>>,
}

impl ContextLedger {
    /// A ledger without persistent memory (the runtime always attaches the
    /// palace via [`Self::with_palace`]; tests mostly don't need one).
    #[cfg(test)]
    pub fn new(store: Arc<BarStore>) -> Arc<Self> {
        Self::with_palace(store, None)
    }

    pub fn with_palace(
        store: Arc<BarStore>,
        palace: Option<Arc<crate::palace::Palace>>,
    ) -> Arc<Self> {
        Arc::new(Self {
            state: RwLock::new(LedgerState::default()),
            store,
            palace,
        })
    }

    /// Subscribe (synchronously, so no startup events are missed by racing
    /// the spawn) and keep the ledger current forever. Lag drops are
    /// tolerated: the ledger is a rolling summary, not an audit log.
    pub fn spawn_ingest(self: &Arc<Self>, bus: &Bus) {
        let mut rx = bus.subscribe();
        let this = Arc::clone(self);
        tokio::spawn(async move {
            loop {
                match rx.recv().await {
                    Ok(ev) => this.apply(&ev),
                    Err(tokio::sync::broadcast::error::RecvError::Lagged(_)) => continue,
                    Err(_) => break,
                }
            }
        });
    }

    /// Fold one bus event into the rolling state. Pure state transition —
    /// never publishes, never blocks on IO.
    pub fn apply(&self, ev: &EngineEvent) {
        let mut st = self.state.write().unwrap_or_else(|p| p.into_inner());
        match ev {
            EngineEvent::Tick(t) => observe_price(&mut st, &t.symbol, t.price, t.ts_ms),
            EngineEvent::Bar(b) if b.complete && b.interval == Interval::M1 => {
                observe_price(&mut st, &b.symbol, b.close, b.ts_open_ms + b.interval.ms());
            }
            EngineEvent::Account(a) => st.account = Some(a.clone()),
            EngineEvent::Risk(r) => st.risk = Some(r.clone()),
            EngineEvent::Position(p) => {
                st.positions.insert(p.symbol.clone(), p.clone());
            }
            EngineEvent::Thought(t) => {
                if t.squadron.starts_with("desk-")
                    && (st.desks.contains_key(&t.squadron) || st.desks.len() < MAX_DESKS)
                {
                    st.desks.insert(t.squadron.clone(), t.clone());
                }
                st.thoughts.push_back(t.clone());
                while st.thoughts.len() > MAX_THOUGHTS {
                    st.thoughts.pop_front();
                }
            }
            EngineEvent::Signal(s) => {
                if s.strategy == "fusion" {
                    let weights: BTreeMap<String, f64> = s
                        .features
                        .iter()
                        .filter(|(k, v)| k.starts_with("w_") && v.is_finite())
                        .map(|(k, v)| (k["w_".len()..].to_string(), *v))
                        .collect();
                    if !weights.is_empty() {
                        st.ensemble = weights;
                    }
                    // PLAYBOOK: fold the current bucket's "m_*" multipliers
                    // into the matrix (regime_code names the bucket).
                    let bucket = s
                        .features
                        .get("regime_code")
                        .copied()
                        .filter(|v| {
                            v.is_finite() && (0.0..=3.0).contains(v) && v.fract() == 0.0
                        })
                        .map(|v| v as usize);
                    if let Some(bucket) = bucket {
                        for (k, v) in &s.features {
                            if !k.starts_with("m_") || !v.is_finite() {
                                continue;
                            }
                            let name = k["m_".len()..].to_string();
                            if !st.playbook.contains_key(&name)
                                && st.playbook.len() >= MAX_PLAYBOOK
                            {
                                continue;
                            }
                            st.playbook.entry(name).or_insert([1.0; REGIME_BUCKETS])
                                [bucket] = *v;
                        }
                    }
                }
                st.signals.push_back(s.clone());
                while st.signals.len() > MAX_SIGNALS {
                    st.signals.pop_front();
                }
            }
            EngineEvent::Macro(m) => st.macro_snap = Some(m.clone()),
            EngineEvent::RegimeMap(b) => st.regime_board = Some(b.clone()),
            EngineEvent::Geo(g) => st.geo = Some(g.clone()),
            EngineEvent::FeedStatus(f) => {
                st.feeds.insert(f.feed.clone(), f.clone());
            }
            EngineEvent::Fill(f) => {
                let day = f.ts_ms.div_euclid(DAY_MS);
                if st.fills_day != day {
                    st.fills_day = day;
                    st.fills_today = 0;
                }
                st.fills_today = st.fills_today.saturating_add(1);
            }
            _ => {}
        }
    }

    /// Ledger's view of the last trade price (fed by ticks / completed bars).
    pub fn last_price(&self, symbol: &str) -> Option<f64> {
        self.state
            .read()
            .unwrap_or_else(|p| p.into_inner())
            .prices
            .get(symbol)
            .map(|p| p.last)
    }

    /// Cheap clone of the whole state for lock-free formatting.
    pub fn snapshot(&self) -> LedgerState {
        self.state.read().unwrap_or_else(|p| p.into_inner()).clone()
    }

    /// The compact structured plaintext block handed to the LLM (and the
    /// heuristic copilot). Capped at ~2000 words; numbers rounded sensibly;
    /// contains no secrets and no configuration.
    pub fn render(&self, symbols: &[String]) -> String {
        let st = self.snapshot();
        let mut out = String::with_capacity(4096);

        out.push_str("=== MARKET ===\n");
        for sym in symbols {
            let mut line = format!("- {sym}");
            match st.prices.get(sym) {
                Some(p) if p.last.is_finite() => {
                    line.push_str(&format!(" last {}", fmt_px(p.last)));
                    if p.session_open.is_finite() && p.session_open > 0.0 {
                        let chg = (p.last / p.session_open - 1.0) * 100.0;
                        if chg.is_finite() {
                            line.push_str(&format!(" ({chg:+.2}% session)"));
                        }
                    }
                }
                _ => line.push_str(" last n/a"),
            }
            let bars = self.store.recent(sym, Interval::M1, FEATURE_LOOKBACK);
            if bars.is_empty() {
                line.push_str(" | no bar history yet");
            } else {
                let feats = compute_features(&bars);
                let (regime, conf) = detect_regime_with(&feats, &bars);
                line.push_str(&format!(
                    " | regime {} conf {:.2}",
                    regime_label(regime),
                    fin(conf)
                ));
                if let Some(v) = feats.get("rsi_14") {
                    line.push_str(&format!(" rsi {:.1}", fin(*v)));
                }
                if let Some(v) = feats.get("trend_score") {
                    line.push_str(&format!(" trend {:+.2}", fin(*v)));
                }
                if let Some(v) = feats.get("bb_width") {
                    line.push_str(&format!(" bb_width {:.4}", fin(*v)));
                }
                if let Some(v) = feats.get("atr_14") {
                    line.push_str(&format!(" atr {}", fmt_px(*v)));
                }
                if let Some(v) = feats.get("vol_ewma") {
                    line.push_str(&format!(" vol_ewma {:.2e}", fin(*v)));
                }
            }
            line.push('\n');
            out.push_str(&line);
        }
        for fs in st.feeds.values() {
            out.push_str(&format!(
                "feed {}: {:?} — {}\n",
                fs.feed,
                fs.health,
                snip(&fs.detail, 80)
            ));
        }

        out.push_str("\n=== QUANT ===\n");
        out.push_str(
            "(hurst >0.5 trending / <0.5 mean-reverting; ou_hl = reversion half-life in M1 bars; \
             var95/es95 = 1-day loss fractions, sqrt-time scaled; ann_vol = EWMA annualized)\n",
        );
        for sym in symbols {
            let bars = self.store.recent(sym, Interval::M1, 600);
            if bars.len() < 64 {
                continue;
            }
            let closes: Vec<f64> = bars.iter().map(|b| b.close).collect();
            let rets: Vec<f64> = closes
                .windows(2)
                .filter(|w| w[0] > 0.0 && w[1] > 0.0)
                .map(|w| (w[1] / w[0]).ln())
                .collect();
            let mut line = format!("- {sym}");
            if let Some(h) = cx_ta::quant::hurst_exponent(&closes) {
                line.push_str(&format!(" hurst {h:.2}"));
            }
            if let Some(hl) = cx_ta::quant::ou_half_life(&closes) {
                line.push_str(&format!(" ou_hl {hl:.0}"));
            }
            if let Some(v) = cx_ta::quant::ewma_vol(&rets, 0.94) {
                line.push_str(&format!(" ann_vol {:.0}%", v * 525_600.0_f64.sqrt() * 100.0));
            }
            let day_scale = 1_440.0_f64.sqrt();
            if let Some(var) = cx_ta::quant::cornish_fisher_var(&rets, 0.95) {
                line.push_str(&format!(" var95 {:.2}%", var * day_scale * 100.0));
            }
            if let Some(es) = cx_ta::quant::expected_shortfall(&rets, 0.95) {
                line.push_str(&format!(" es95 {:.2}%", es * day_scale * 100.0));
            }
            line.push('\n');
            out.push_str(&line);
        }

        out.push_str("\n=== PORTFOLIO ===\n");
        match &st.account {
            Some(a) => out.push_str(&format!(
                "equity {} cash {} gross {} net {} uPnL {:+.2} rPnL_day {:+.2} open_orders {} trades_day {} fills_today {}\n",
                fmt_px(a.equity),
                fmt_px(a.cash),
                fmt_px(a.gross_exposure),
                fmt_px(a.net_exposure),
                fin(a.unrealized_pnl),
                fin(a.realized_pnl_day),
                a.open_orders,
                a.daily_trades,
                st.fills_today,
            )),
            None => out.push_str("no account snapshot yet\n"),
        }
        let open: Vec<&Position> = st
            .positions
            .values()
            .filter(|p| p.qty.abs() > 1e-12)
            .collect();
        if open.is_empty() {
            out.push_str("positions: none (flat)\n");
        } else {
            out.push_str("positions:\n");
            for p in open {
                out.push_str(&format!(
                    "- {} qty {:+.6} avg {} mark {} uPnL {:+.2}\n",
                    p.symbol,
                    fin(p.qty),
                    fmt_px(p.avg_px),
                    fmt_px(p.mark_px),
                    fin(p.unrealized_pnl),
                ));
            }
        }

        out.push_str("\n=== RISK ===\n");
        match &st.risk {
            Some(r) => {
                out.push_str(&format!(
                    "kill_switch {}{} | autonomy {:?} | caution {:.2}{} | throttle {:.2}",
                    if r.kill_switch { "ENGAGED" } else { "off" },
                    r.kill_reason
                        .as_deref()
                        .map(|s| format!(" ({})", snip(s, 80)))
                        .unwrap_or_default(),
                    r.autonomy,
                    fin(r.caution),
                    if r.caution_reasons.is_empty() {
                        String::new()
                    } else {
                        format!(" ({})", snip(&r.caution_reasons.join("; "), 160))
                    },
                    fin(r.throttle),
                ));
                if !r.breaches.is_empty() {
                    out.push_str(&format!(" | breaches: {}", snip(&r.breaches.join("; "), 160)));
                }
                out.push('\n');
            }
            None => out.push_str("no risk status yet\n"),
        }
        if let Some(a) = &st.account {
            out.push_str(&format!(
                "drawdown day {:.2}% total {:.2}%\n",
                fin(a.drawdown_day) * 100.0,
                fin(a.drawdown_total) * 100.0,
            ));
        }

        out.push_str("\n=== MACRO ===\n");
        match &st.macro_snap {
            Some(m) => {
                out.push_str("yields(%):");
                for (k, v) in &m.yields {
                    out.push_str(&format!(" {k} {:.2}", fin(*v)));
                }
                out.push('\n');
                if let Some(s) = m.spread_2s10s_bps {
                    out.push_str(&format!("2s10s {:+.1}bps ", fin(s)));
                }
                if let Some(s) = m.spread_3m10s_bps {
                    out.push_str(&format!("3m10s {:+.1}bps ", fin(s)));
                }
                out.push_str(&format!("curve {}\n", m.curve_regime));
                if m.fx.is_empty() {
                    out.push_str("fx: n/a\n");
                } else {
                    out.push_str("fx:");
                    for (k, v) in &m.fx {
                        out.push_str(&format!(" {k} {:.4}", fin(*v)));
                    }
                    out.push('\n');
                }
            }
            None => out.push_str("no macro snapshot yet\n"),
        }

        // REGIMES / MERIDIAN / ENSEMBLE only render when data exists: an
        // absent feed costs zero tokens and never shows a stale placeholder.
        if let Some(b) = &st.regime_board {
            out.push_str("\n=== REGIMES ===\n");
            let br = &b.breadth;
            out.push_str("breadth:");
            if let Some(p) = br.pct_above_200d {
                out.push_str(&format!(" {:.0}% above 200d", fin(p)));
            }
            if let Some(p) = br.pct_above_50d {
                out.push_str(&format!(" {:.0}% above 50d", fin(p)));
            }
            out.push_str(&format!(
                " | bulls {} bears {} entering_bull {} entering_bear {} (universe {})\n",
                br.bulls, br.bears, br.entering_bull, br.entering_bear, br.universe_size,
            ));
            for sym in symbols {
                if let Some(row) = b.rows.iter().find(|r| &r.symbol == sym) {
                    out.push_str(&format!(
                        "- {} {} dd {:.1}%\n",
                        row.symbol,
                        regime_state_label(row.state),
                        fin(row.drawdown_pct) * 100.0,
                    ));
                }
            }
        }

        if let Some(g) = &st.geo {
            if !g.forces.is_empty() || !g.chains.is_empty() {
                out.push_str("\n=== MERIDIAN ===\n");
                for f in g.forces.iter().take(RENDER_FORCES) {
                    out.push_str(&format!(
                        "- force {} {:.0} (7d {:+.1}) proxy: {}\n",
                        snip(&f.force, 32),
                        fin(f.value),
                        fin(f.trend_7d),
                        snip(&f.proxy, 60),
                    ));
                }
                for c in g.chains.iter().take(RENDER_CHAINS) {
                    let assets = c
                        .assets
                        .iter()
                        .take(RENDER_CHAIN_ASSETS)
                        .map(|a| {
                            format!(
                                "{}{}",
                                snip(&a.target, 24),
                                if a.direction >= 0 { "+" } else { "-" }
                            )
                        })
                        .collect::<Vec<_>>()
                        .join(", ");
                    out.push_str(&format!(
                        "FIRED: {} (intensity {:.1}){}\n",
                        snip(&c.title, 100),
                        fin(c.intensity),
                        if assets.is_empty() {
                            String::new()
                        } else {
                            format!(" -> {assets}")
                        },
                    ));
                }
            }
        }

        if !st.ensemble.is_empty() {
            out.push_str("\n=== ENSEMBLE ===\n");
            let weights = st
                .ensemble
                .iter()
                .take(RENDER_WEIGHTS)
                .map(|(name, w)| format!("{} {:.2}", snip(name, 32), fin(*w)))
                .collect::<Vec<_>>()
                .join(", ");
            out.push_str(&format!("strategy weights: {weights}\n"));
        }

        // PLAYBOOK: the learned regime-conditional multiplier matrix. Rows
        // still all-neutral (every bucket ~1.0) carry no information and
        // are skipped; the section renders only once something is learned.
        let learned: Vec<(&String, &[f64; REGIME_BUCKETS])> = st
            .playbook
            .iter()
            .filter(|(_, row)| row.iter().any(|m| (fin(*m) - 1.0).abs() >= 0.005))
            .collect();
        if !learned.is_empty() {
            out.push_str("\n=== PLAYBOOK ===\n");
            out.push_str(
                "(regime-conditional strategy multipliers; >1 = realized edge in that regime, <1 = realized drag)\n",
            );
            for (name, row) in learned {
                out.push_str(&format!(
                    "{}: trend-up {:.2} · trend-dn {:.2} · range {:.2} · high-vol {:.2}\n",
                    snip(name, 32),
                    fin(row[0]),
                    fin(row[1]),
                    fin(row[2]),
                    fin(row[3]),
                ));
            }
        }

        // DESKS: the latest note from each asset-class desk — one bounded
        // line per desk; omitted until a desk has actually spoken, costing
        // zero tokens while every desk is still silent.
        if !st.desks.is_empty() {
            out.push_str("\n=== DESKS ===\n");
            for (desk, t) in &st.desks {
                out.push_str(&format!(
                    "- {desk}{}: {}\n",
                    t.symbol
                        .as_deref()
                        .map(|s| format!(" {s}"))
                        .unwrap_or_default(),
                    snip(&t.text, 160),
                ));
            }
        }

        // PALACE: the compressed closet of the persistent verbatim memory —
        // bounded (~15 lines); omitted when absent or empty, costing zero
        // tokens until something has actually been remembered.
        if let Some(palace) = &self.palace {
            let closet = palace.render_closet();
            if !closet.is_empty() {
                out.push_str("\n=== PALACE ===\n");
                out.push_str(&closet);
            }
        }

        out.push_str("\n=== RECENT AGENT NOTES ===\n");
        if st.thoughts.is_empty() {
            out.push_str("none yet\n");
        } else {
            let skip = st.thoughts.len().saturating_sub(RENDER_THOUGHTS);
            for t in st.thoughts.iter().skip(skip) {
                out.push_str(&format!(
                    "- [{}] {}{}: {}\n",
                    sev_label(t.severity),
                    t.agent,
                    t.symbol
                        .as_deref()
                        .map(|s| format!(" {s}"))
                        .unwrap_or_default(),
                    snip(&t.text, 200),
                ));
            }
        }

        out.push_str("\n=== RECENT SIGNALS ===\n");
        if st.signals.is_empty() {
            out.push_str("none yet\n");
        } else {
            let skip = st.signals.len().saturating_sub(RENDER_SIGNALS);
            for s in st.signals.iter().skip(skip) {
                out.push_str(&format!(
                    "- {} {} dir {:+.2} conv {:.2}: {}\n",
                    s.strategy,
                    s.symbol,
                    fin(s.direction),
                    fin(s.conviction),
                    snip(&s.rationale, 160),
                ));
            }
        }

        cap_words(&out, RENDER_MAX_WORDS)
    }
}

/// Fold a trade price into the per-symbol session state; the session open
/// resets on the UTC-day boundary. Non-finite / non-positive prices are
/// dropped (NaN-safe ingest).
fn observe_price(st: &mut LedgerState, symbol: &str, px: f64, ts_ms: i64) {
    if !(px.is_finite() && px > 0.0) {
        return;
    }
    let day = ts_ms.div_euclid(DAY_MS);
    let e = st.prices.entry(symbol.to_string()).or_insert(PriceState {
        last: px,
        session_open: px,
        day,
    });
    if e.day != day {
        e.day = day;
        e.session_open = px;
    }
    e.last = px;
}

// ---- shared formatting helpers (crate-wide) --------------------------------

/// Non-finite reads as 0.0 so `format!` never prints NaN/inf.
pub(crate) fn fin(v: f64) -> f64 {
    if v.is_finite() {
        v
    } else {
        0.0
    }
}

/// Price-ish formatting: "n/a" when non-finite, 2dp above 1, 5dp below.
pub(crate) fn fmt_px(v: f64) -> String {
    if !v.is_finite() {
        return "n/a".into();
    }
    if v.abs() >= 1.0 {
        format!("{v:.2}")
    } else {
        format!("{v:.5}")
    }
}

/// Quantity without trailing zero noise ("0.500000" -> "0.5").
pub(crate) fn fmt_qty(v: f64) -> String {
    if !v.is_finite() {
        return "n/a".into();
    }
    let s = format!("{v:.6}");
    let s = s.trim_end_matches('0').trim_end_matches('.');
    if s.is_empty() || s == "-" {
        "0".into()
    } else {
        s.to_string()
    }
}

pub(crate) fn sev_label(s: Severity) -> &'static str {
    match s {
        Severity::Info => "info",
        Severity::Insight => "insight",
        Severity::Warning => "warning",
        Severity::Critical => "critical",
    }
}

pub(crate) fn regime_label(r: Regime) -> &'static str {
    match r {
        Regime::TrendingUp => "trending_up",
        Regime::TrendingDown => "trending_down",
        Regime::Ranging => "ranging",
        Regime::HighVol => "high_vol",
    }
}

/// Snake-case label for a REGIMES-board secular state (matches the wire
/// serde rename, so LLM text and UI payloads use one vocabulary).
pub(crate) fn regime_state_label(s: RegimeState) -> &'static str {
    match s {
        RegimeState::Bull => "bull",
        RegimeState::EnteringBull => "entering_bull",
        RegimeState::Correction => "correction",
        RegimeState::EnteringBear => "entering_bear",
        RegimeState::Bear => "bear",
        RegimeState::Recovery => "recovery",
    }
}

/// Char-bounded snippet; appends an ellipsis when cut.
pub(crate) fn snip(s: &str, max_chars: usize) -> String {
    if s.chars().count() <= max_chars {
        s.to_string()
    } else {
        let mut out: String = s.chars().take(max_chars).collect();
        out.push('…');
        out
    }
}

/// Word-capped copy that preserves whitespace/layout (newlines survive).
pub(crate) fn cap_words(s: &str, max_words: usize) -> String {
    let mut out = String::with_capacity(s.len());
    let mut words = 0usize;
    for tok in s.split_inclusive(char::is_whitespace) {
        if !tok.trim().is_empty() {
            words += 1;
            if words > max_words {
                out.push_str("…[truncated]");
                break;
            }
        }
        out.push_str(tok);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::{
        AssetImpact, Bar, Breadth, CausalChain, ForceGauge, RegimeRow, Tick,
    };
    use cx_core::types::Venue;

    fn regime_map() -> EngineEvent {
        EngineEvent::RegimeMap(RegimeBoard {
            rows: vec![
                RegimeRow {
                    symbol: "BTC-USD".into(),
                    state: RegimeState::Correction,
                    drawdown_pct: 0.125,
                    runup_pct: 0.03,
                    days_in_state: 4,
                    dist_50_200_pct: Some(-0.01),
                    last_close: 104.0,
                },
                RegimeRow {
                    symbol: "DOGE-USD".into(), // not configured: must not render
                    state: RegimeState::Bear,
                    drawdown_pct: 0.4,
                    runup_pct: 0.0,
                    days_in_state: 30,
                    dist_50_200_pct: None,
                    last_close: 0.05,
                },
            ],
            breadth: Breadth {
                pct_above_200d: Some(62.0),
                pct_above_50d: Some(48.0),
                bulls: 120,
                bears: 40,
                entering_bull: 8,
                entering_bear: 5,
                universe_size: 200,
            },
            source: "test".into(),
            ts_ms: 1_000_000,
        })
    }

    fn geo_pulse() -> EngineEvent {
        EngineEvent::Geo(GeoPulse {
            forces: vec![
                ForceGauge {
                    force: "debt".into(),
                    value: 62.0,
                    trend_7d: 3.1,
                    proxy: "2s10s inversion depth".into(),
                },
                ForceGauge {
                    force: "external_order".into(),
                    value: 71.0,
                    trend_7d: -1.4,
                    proxy: "conflict article z-score".into(),
                },
            ],
            chains: vec![CausalChain {
                rule_id: "oil-shock".into(),
                title: "Gulf escalation squeezes crude supply".into(),
                steps: vec!["escalation".into(), "supply risk".into()],
                assets: vec![
                    AssetImpact {
                        target: "crude oil".into(),
                        direction: 1,
                        note: "supply premium".into(),
                    },
                    AssetImpact {
                        target: "airlines".into(),
                        direction: -1,
                        note: "fuel cost".into(),
                    },
                ],
                intensity: 2.4,
                evidence: vec![],
            }],
            events: vec![],
            source: "test".into(),
            ts_ms: 1_000_000,
        })
    }

    fn fusion_signal() -> EngineEvent {
        let mut features = BTreeMap::new();
        features.insert("w_momentum_x".to_string(), 1.4);
        features.insert("w_meanrev_z".to_string(), 0.3);
        features.insert("w_bad".to_string(), f64::NAN); // must be dropped
        features.insert("blend_dir".to_string(), 0.5); // non-weight: ignored
        EngineEvent::Signal(StrategySignal {
            strategy: "fusion".into(),
            symbol: "BTC-USD".into(),
            direction: 0.5,
            conviction: 0.6,
            rationale: "blend".into(),
            features,
            ts_ms: 1_000_000,
        })
    }

    fn fusion_playbook_signal(code: Option<f64>, mults: &[(&str, f64)]) -> EngineEvent {
        let mut features = BTreeMap::new();
        if let Some(c) = code {
            features.insert("regime_code".to_string(), c);
        }
        for (name, m) in mults {
            features.insert(format!("m_{name}"), *m);
        }
        EngineEvent::Signal(StrategySignal {
            strategy: "fusion".into(),
            symbol: "BTC-USD".into(),
            direction: 0.1,
            conviction: 0.5,
            rationale: "blend".into(),
            features,
            ts_ms: 1_000_000,
        })
    }

    #[test]
    fn intel_sections_render_from_synthetic_events() {
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        ledger.apply(&regime_map());
        ledger.apply(&geo_pulse());
        ledger.apply(&fusion_signal());

        let out = ledger.render(&["BTC-USD".to_string()]);
        // REGIMES: breadth + configured rows only.
        assert!(out.contains("=== REGIMES ==="), "{out}");
        assert!(out.contains("62% above 200d 48% above 50d"), "{out}");
        assert!(
            out.contains("bulls 120 bears 40 entering_bull 8 entering_bear 5 (universe 200)"),
            "{out}"
        );
        assert!(out.contains("- BTC-USD correction dd 12.5%"), "{out}");
        assert!(!out.contains("DOGE-USD"), "unconfigured row leaked: {out}");
        // MERIDIAN: forces + fired chain with top asset impacts.
        assert!(out.contains("=== MERIDIAN ==="), "{out}");
        assert!(out.contains("- force debt 62 (7d +3.1) proxy: 2s10s inversion depth"), "{out}");
        assert!(out.contains("- force external_order 71 (7d -1.4)"), "{out}");
        assert!(
            out.contains(
                "FIRED: Gulf escalation squeezes crude supply (intensity 2.4) -> crude oil+, airlines-"
            ),
            "{out}"
        );
        // ENSEMBLE: weight names stripped of the w_ prefix, NaN dropped.
        assert!(out.contains("=== ENSEMBLE ==="), "{out}");
        assert!(
            out.contains("strategy weights: meanrev_z 0.30, momentum_x 1.40"),
            "{out}"
        );
        assert!(!out.contains("bad"), "NaN weight leaked: {out}");
        assert!(!out.contains("blend_dir 0.5,"), "non-weight feature leaked: {out}");
    }

    #[test]
    fn intel_sections_omitted_when_absent() {
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        // A non-fusion signal must not populate the ensemble either.
        let mut features = BTreeMap::new();
        features.insert("w_momentum_x".to_string(), 1.0);
        ledger.apply(&EngineEvent::Signal(StrategySignal {
            strategy: "momentum_x".into(),
            symbol: "BTC-USD".into(),
            direction: 1.0,
            conviction: 0.5,
            rationale: "x".into(),
            features,
            ts_ms: 1,
        }));
        let out = ledger.render(&["BTC-USD".to_string()]);
        assert!(!out.contains("=== REGIMES ==="), "{out}");
        assert!(!out.contains("=== MERIDIAN ==="), "{out}");
        assert!(!out.contains("=== ENSEMBLE ==="), "{out}");
        assert!(!out.contains("=== PLAYBOOK ==="), "{out}");
    }

    #[test]
    fn playbook_renders_and_accumulates_across_buckets() {
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        // Range bucket first ...
        ledger.apply(&fusion_playbook_signal(
            Some(2.0),
            &[("momentum_x", 0.5), ("meanrev_z", 1.6)],
        ));
        // ... then the regime rotates to trend-up: earlier range values
        // must survive, the new bucket fills in.
        ledger.apply(&fusion_playbook_signal(
            Some(0.0),
            &[("momentum_x", 1.4), ("meanrev_z", 1.0)],
        ));
        let out = ledger.render(&["BTC-USD".to_string()]);
        assert!(out.contains("=== PLAYBOOK ==="), "{out}");
        assert!(
            out.contains(
                "momentum_x: trend-up 1.40 · trend-dn 1.00 · range 0.50 · high-vol 1.00"
            ),
            "{out}"
        );
        assert!(
            out.contains(
                "meanrev_z: trend-up 1.00 · trend-dn 1.00 · range 1.60 · high-vol 1.00"
            ),
            "{out}"
        );
    }

    #[test]
    fn playbook_omitted_without_learned_multipliers() {
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        // All-neutral multipliers carry no information: no section.
        ledger.apply(&fusion_playbook_signal(Some(1.0), &[("momentum_x", 1.0)]));
        let out = ledger.render(&["BTC-USD".to_string()]);
        assert!(!out.contains("=== PLAYBOOK ==="), "{out}");
        // m_* without a regime_code names no bucket: ignored entirely.
        ledger.apply(&fusion_playbook_signal(None, &[("momentum_x", 1.7)]));
        // Junk buckets and non-finite multipliers are dropped on ingest.
        ledger.apply(&fusion_playbook_signal(Some(7.0), &[("momentum_x", 1.7)]));
        ledger.apply(&fusion_playbook_signal(Some(f64::NAN), &[("momentum_x", 1.7)]));
        ledger.apply(&fusion_playbook_signal(Some(3.0), &[("kalman_trend", f64::NAN)]));
        let out = ledger.render(&["BTC-USD".to_string()]);
        assert!(!out.contains("=== PLAYBOOK ==="), "{out}");
    }

    #[test]
    fn playbook_is_bounded() {
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        for i in 0..(MAX_PLAYBOOK + 10) {
            ledger.apply(&fusion_playbook_signal(
                Some(0.0),
                &[(&format!("s{i:03}"), 1.5)],
            ));
        }
        let st = ledger.snapshot();
        assert!(st.playbook.len() <= MAX_PLAYBOOK, "{}", st.playbook.len());
    }

    fn desk_thought(squadron: &str, symbol: Option<&str>, text: &str) -> EngineEvent {
        EngineEvent::Thought(AgentThought {
            agent: squadron.into(),
            squadron: squadron.into(),
            severity: Severity::Insight,
            text: text.into(),
            tags: vec![squadron.into()],
            confidence: 0.7,
            symbol: symbol.map(String::from),
            ts_ms: 1_000_000,
        })
    }

    #[test]
    fn desks_section_renders_latest_note_per_desk() {
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        // No desk has spoken: no section, zero tokens.
        assert!(!ledger.render(&[]).contains("=== DESKS ==="));

        ledger.apply(&desk_thought("desk-crypto", None, "weekend liquidity window"));
        ledger.apply(&desk_thought("desk-options", Some("AAPL"), "IV spike: 1.80x realized"));
        // The newest note per desk wins.
        ledger.apply(&desk_thought(
            "desk-crypto",
            Some("BTC-USD"),
            "vol regime shift: normal -> high",
        ));
        // Non-desk squadrons never enter the section.
        ledger.apply(&desk_thought("analysis", Some("BTC-USD"), "rsi crossing"));

        let out = ledger.render(&[]);
        assert!(out.contains("=== DESKS ==="), "{out}");
        assert!(
            out.contains("- desk-crypto BTC-USD: vol regime shift: normal -> high"),
            "{out}"
        );
        assert!(
            out.contains("- desk-options AAPL: IV spike: 1.80x realized"),
            "{out}"
        );
        // The superseded note survives only in RECENT AGENT NOTES — the
        // DESKS section keeps exactly one (fresh) line per desk.
        assert!(
            !out.contains("- desk-crypto: weekend liquidity window"),
            "stale desk line kept: {out}"
        );
        assert!(!out.contains("- analysis BTC-USD: rsi"), "non-desk squadron leaked: {out}");
    }

    #[test]
    fn desks_section_is_bounded() {
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        for i in 0..(MAX_DESKS + 4) {
            ledger.apply(&desk_thought(&format!("desk-x{i:02}"), None, "note"));
        }
        let st = ledger.snapshot();
        assert!(st.desks.len() <= MAX_DESKS, "{}", st.desks.len());
        // Known desks keep updating even at the bound.
        ledger.apply(&desk_thought("desk-x00", None, "fresh reading"));
        let st = ledger.snapshot();
        assert_eq!(st.desks["desk-x00"].text, "fresh reading");
    }

    #[test]
    fn palace_section_renders_when_attached_and_is_omitted_otherwise() {
        let store = Arc::new(BarStore::new());
        // No palace attached: no section, ever.
        let bare = ContextLedger::new(Arc::clone(&store));
        assert!(!bare.render(&[]).contains("=== PALACE ==="));

        // Attached but empty: still omitted (zero tokens until memory exists).
        let dir = crate::palace::test_dir("ledger");
        let palace = crate::palace::Palace::open(dir.clone()).unwrap();
        let ledger = ContextLedger::with_palace(Arc::clone(&store), Some(Arc::clone(&palace)));
        assert!(!ledger.render(&[]).contains("=== PALACE ==="));

        // With memory: the closet renders room counts + newest heads.
        palace.remember("decisions", "strategist", "we sized down into CPI", vec![], 1);
        palace.remember("NVDA", "regime", "regime shift ranging -> trending_up", vec![], 2);
        let out = ledger.render(&[]);
        assert!(out.contains("=== PALACE ==="), "{out}");
        assert!(out.contains("- decisions: 1 — we sized down into CPI"), "{out}");
        assert!(out.contains("- NVDA: 1 — regime shift ranging -> trending_up"), "{out}");
        let _ = std::fs::remove_dir_all(dir);
    }

    #[test]
    fn session_open_resets_on_utc_day_roll() {
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        let tick = |px: f64, ts: i64| {
            EngineEvent::Tick(Tick {
                symbol: "BTC-USD".into(),
                ts_ms: ts,
                price: px,
                size: 0.1,
                aggressor: None,
                venue: Venue::Coinbase,
            })
        };
        ledger.apply(&tick(100.0, 10_000));
        ledger.apply(&tick(110.0, 20_000));
        let st = ledger.snapshot();
        let p = st.prices.get("BTC-USD").unwrap();
        assert_eq!(p.session_open, 100.0);
        assert_eq!(p.last, 110.0);
        // Next UTC day: session open resets to the first price of the day.
        ledger.apply(&tick(120.0, DAY_MS + 1_000));
        let st = ledger.snapshot();
        let p = st.prices.get("BTC-USD").unwrap();
        assert_eq!(p.session_open, 120.0);
        assert_eq!(p.last, 120.0);
    }

    #[test]
    fn non_finite_prices_are_dropped() {
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        ledger.apply(&EngineEvent::Tick(Tick {
            symbol: "BTC-USD".into(),
            ts_ms: 1,
            price: f64::NAN,
            size: 0.1,
            aggressor: None,
            venue: Venue::Coinbase,
        }));
        assert!(ledger.last_price("BTC-USD").is_none());
    }

    #[test]
    fn incomplete_bars_do_not_move_last_price() {
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        ledger.apply(&EngineEvent::Bar(Bar {
            symbol: "BTC-USD".into(),
            interval: Interval::M1,
            ts_open_ms: 0,
            open: 1.0,
            high: 1.0,
            low: 1.0,
            close: 1.0,
            volume: 1.0,
            trade_count: 1,
            vwap: 1.0,
            complete: false,
        }));
        assert!(ledger.last_price("BTC-USD").is_none());
    }

    #[test]
    fn cap_words_preserves_layout_and_truncates() {
        let text = "one two\nthree four five";
        assert_eq!(cap_words(text, 10), text);
        let capped = cap_words(text, 3);
        assert!(capped.contains("one two\nthree"));
        assert!(capped.ends_with("…[truncated]"));
        assert!(!capped.contains("five"));
    }

    #[test]
    fn fmt_helpers_are_nan_safe() {
        assert_eq!(fmt_px(f64::NAN), "n/a");
        assert_eq!(fmt_qty(0.5), "0.5");
        assert_eq!(fmt_qty(2.0), "2");
        assert_eq!(fin(f64::INFINITY), 0.0);
    }
}
