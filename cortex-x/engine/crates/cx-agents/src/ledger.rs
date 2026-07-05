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
    AccountSnapshot, AgentThought, EngineEvent, FeedStatus, MacroSnapshot, Position, RiskStatus,
    StrategySignal,
};
use cx_core::store::BarStore;
use cx_core::types::{Interval, Severity};
use cx_core::Bus;
use cx_ta::{compute_features, detect_regime, Regime};

const MAX_THOUGHTS: usize = 30;
const MAX_SIGNALS: usize = 20;
const RENDER_THOUGHTS: usize = 12;
const RENDER_SIGNALS: usize = 10;
const RENDER_MAX_WORDS: usize = 2_000;
const FEATURE_LOOKBACK: usize = 120;
const DAY_MS: i64 = 86_400_000;

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
}

pub(crate) struct ContextLedger {
    state: RwLock<LedgerState>,
    store: Arc<BarStore>,
}

impl ContextLedger {
    pub fn new(store: Arc<BarStore>) -> Arc<Self> {
        Arc::new(Self {
            state: RwLock::new(LedgerState::default()),
            store,
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
                st.thoughts.push_back(t.clone());
                while st.thoughts.len() > MAX_THOUGHTS {
                    st.thoughts.pop_front();
                }
            }
            EngineEvent::Signal(s) => {
                st.signals.push_back(s.clone());
                while st.signals.len() > MAX_SIGNALS {
                    st.signals.pop_front();
                }
            }
            EngineEvent::Macro(m) => st.macro_snap = Some(m.clone()),
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
                let (regime, conf) = detect_regime(&bars);
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
    use cx_core::events::{Bar, Tick};
    use cx_core::types::Venue;

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
