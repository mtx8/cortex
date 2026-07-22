//! # cx-risk — the ECHO squadron
//!
//! Every order intent faces [`RiskEngine::evaluate`] before execution;
//! nothing bypasses it. Every check is tighten-only: risk machinery can
//! shrink or reject an order, never grow one.
//!
//! Invariants:
//! - `evaluate` is fully synchronous through `&self` (interior mutability
//!   only) so async order paths call it inline without awaiting.
//! - Caution is tighten-only: for a fixed intent, any caution state yields
//!   qty <= the zero-caution qty, and never zero while max_shrink < 1.
//! - The drawdown clocks hold the ONLY autonomous kill trigger (a drawdown
//!   past 1.25x its limit).
//! - Reduce-only exits are never shrunk or blocked by caution/throttle:
//!   the risk-off path must stay open exactly when the clocks are darkest.

mod caution;
mod clocks;

use std::sync::{Arc, Mutex};

use serde::{Deserialize, Serialize};

use cx_core::config::RiskConfig;
use cx_core::events::{OrderIntent, OrderSource, RiskStatus};
use cx_core::portfolio::PortfolioView;
use cx_core::time::now_ms;
use cx_core::types::{AutonomyLevel, OrderType};
use cx_core::KillSwitch;

use caution::CautionBook;
use clocks::DrawdownClocks;

/// Matches `PortfolioView::open_position_count`'s notion of "flat".
const POS_EPS: f64 = 1e-12;
/// Approved quantities land on this grid.
const QTY_GRID: f64 = 1e-8;
/// Adverse-stop distance for the single-trade loss bound (2% ~ 2x ATR proxy).
const LOSS_STOP_PCT: f64 = 0.02;

/// The verdict on one order intent. Approved qty may be smaller than
/// requested; every modification leaves a human-readable note.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "decision", rename_all = "snake_case")]
pub enum RiskDecision {
    Approved { qty: f64, notes: Vec<String> },
    Rejected { reason: String },
}

impl RiskDecision {
    pub fn is_approved(&self) -> bool {
        matches!(self, RiskDecision::Approved { .. })
    }
}

fn rejected(reason: impl Into<String>) -> RiskDecision {
    RiskDecision::Rejected {
        reason: reason.into(),
    }
}

/// Pre-trade gate + caution book + drawdown clocks. Holds no position state
/// of its own: portfolio truth arrives per-call as a [`PortfolioView`].
#[derive(Debug)]
pub struct RiskEngine {
    cfg: RiskConfig,
    kill: Arc<KillSwitch>,
    cautions: Mutex<CautionBook>,
    clocks: Mutex<DrawdownClocks>,
}

impl RiskEngine {
    pub fn new(cfg: RiskConfig, kill: Arc<KillSwitch>) -> Self {
        let book = CautionBook::new(cfg.caution_ttl_secs);
        Self {
            cfg,
            kill,
            cautions: Mutex::new(book),
            clocks: Mutex::new(DrawdownClocks::new()),
        }
    }

    /// The gate. Checks run in a fixed order; each one appends a note when
    /// it modifies the order and a reason when it blocks it.
    ///
    /// `stop_distance` is the per-share adverse move to the order's ACTUAL exit
    /// (the ATR trail: `trail_atr_mult × ATR`), when known and warm. The
    /// single-trade loss bound sizes against it so the advertised max-loss holds
    /// at the real stop, not a fixed 2% that understates high-vol names. `None`
    /// (cold ATR, or callers that don't track it) falls back to `LOSS_STOP_PCT`.
    pub fn evaluate(
        &self,
        intent: &OrderIntent,
        view: &PortfolioView,
        last_px: f64,
        stop_distance: Option<f64>,
    ) -> RiskDecision {
        let mut notes: Vec<String> = Vec::new();

        // 1. Kill switch: absolute, except reduce-only flatten/manual exits.
        if self.kill.is_engaged() {
            let exempt = intent.reduce_only
                && matches!(
                    intent.source,
                    OrderSource::RiskFlatten | OrderSource::Manual
                );
            if !exempt {
                return rejected("kill switch engaged");
            }
            notes.push("kill switch engaged: reduce-only exit exemption".into());
        }

        // 2. Input sanity — NaN-safe on everything network-derived.
        if !intent.qty.is_finite() || intent.qty <= 0.0 {
            return rejected("qty must be finite and > 0");
        }
        if !last_px.is_finite() || last_px <= 0.0 {
            return rejected("last price unavailable or invalid");
        }
        if intent.order_type == OrderType::Limit {
            match intent.limit_px {
                Some(px) if px.is_finite() && px > 0.0 => {}
                _ => return rejected("limit order requires finite limit_px > 0"),
            }
        }

        let pos = view.position_qty(&intent.symbol);
        if !pos.is_finite() {
            return rejected("portfolio position is non-finite");
        }
        let side_sign = intent.side.sign();
        let mut qty = intent.qty;

        if intent.reduce_only {
            // 3. Reduce-only fast path: must genuinely reduce, clamps to the
            //    position, then skips every sizing check — exits stay open.
            if pos.abs() <= POS_EPS {
                return rejected("reduce-only with no open position");
            }
            if side_sign * pos > 0.0 {
                return rejected("reduce-only order would increase the position");
            }
            if qty > pos.abs() {
                qty = pos.abs();
                notes.push(format!("reduce-only qty clamped to position size {qty}"));
            }
        } else {
            // 4. Single-order notional cap (collar vs decision price is
            //    enforced upstream against a real quote stream).
            let notional = qty * last_px;
            if notional > self.cfg.max_order_notional {
                return rejected(format!(
                    "order notional {notional:.2} exceeds max_order_notional {:.2}",
                    self.cfg.max_order_notional
                ));
            }

            // 5. Position cap: resulting |position notional| <= pct * equity.
            let equity = if view.equity.is_finite() {
                view.equity.max(0.0)
            } else {
                0.0
            };
            let cap_qty = (self.cfg.max_position_pct * equity / last_px).max(0.0);
            let fit_raw = (cap_qty - side_sign * pos).max(0.0);
            let fit_qty = if fit_raw.is_finite() { fit_raw } else { 0.0 };
            if qty > fit_qty {
                if fit_qty < 0.10 * intent.qty {
                    return rejected(format!(
                        "position cap: fit qty {fit_qty:.8} < 10% of requested {:.8}",
                        intent.qty
                    ));
                }
                qty = fit_qty;
                notes.push(format!("position cap clamped qty to {qty:.8}"));
            }

            // 6. Concurrent-position budget applies only to NEW symbols.
            let opens_new = pos.abs() <= POS_EPS;
            if opens_new && view.open_position_count() >= self.cfg.max_concurrent_positions {
                return rejected(format!(
                    "max concurrent positions ({}) reached",
                    self.cfg.max_concurrent_positions
                ));
            }

            // 7. Daily trade budget.
            if view.daily_trades >= self.cfg.max_daily_trades {
                return rejected(format!(
                    "daily trade cap ({}) reached",
                    self.cfg.max_daily_trades
                ));
            }

            // 8. Single-trade loss bound at the ACTUAL adverse stop. The real
            // exit is the ATR trail, so bound size by the per-share loss AT THAT
            // stop distance; a warm ATR (via `stop_distance`) makes the max-loss
            // guarantee honest for high-vol names where trail_atr_mult×ATR > 2%.
            // Falls back to LOSS_STOP_PCT of price when ATR isn't warm.
            let (per_share_loss, stop_label) = match stop_distance {
                Some(d) if d.is_finite() && d > 0.0 => (d, "ATR trail".to_string()),
                _ => (LOSS_STOP_PCT * last_px, format!("{:.0}% stop", LOSS_STOP_PCT * 100.0)),
            };
            let loss_qty = self.cfg.max_single_trade_loss / per_share_loss;
            if loss_qty.is_finite() && qty > loss_qty {
                qty = loss_qty.max(0.0);
                notes.push(format!(
                    "loss bound clamped qty to {qty:.8} (max loss {:.2} at {stop_label})",
                    self.cfg.max_single_trade_loss,
                ));
            }

            // 9. Tighten-only caution: multiplier in [1 - max_shrink, 1].
            let caution = self.caution_for(&intent.symbol);
            let floor = (1.0 - self.cfg.caution_max_shrink).clamp(0.0, 1.0);
            let mut mult = 1.0 - caution * self.cfg.caution_max_shrink;
            if !mult.is_finite() {
                mult = floor;
            }
            mult = mult.clamp(floor, 1.0);
            if mult < 1.0 {
                qty *= mult;
                notes.push(format!("caution {caution:.3} shrank qty x{mult:.4}"));
            }

            // 10. Drawdown throttle: shrink new risk, halt at zero.
            let throttle = self.throttle();
            if throttle <= 0.0 {
                return rejected("drawdown halt");
            }
            if throttle < 1.0 {
                qty *= throttle;
                notes.push(format!("drawdown throttle shrank qty x{throttle:.4}"));
            }
        }

        // Final grid rounding; anything that rounds away is a rejection.
        // A reduce-only qty never rounds past the position it closes.
        let mut qty = (qty / QTY_GRID).round() * QTY_GRID;
        if intent.reduce_only {
            qty = qty.min(pos.abs());
        }
        if !qty.is_finite() || qty <= 0.0 {
            return rejected("qty rounds to zero");
        }
        RiskDecision::Approved { qty, notes }
    }

    /// `None` scope = global (applies to every symbol). Non-finite values
    /// are ignored; finite values clamp into [0, 1]. TTL from config.
    pub fn set_caution(&self, scope: Option<&str>, value: f64, reason: &str) {
        self.cautions
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .set(scope, value, reason, now_ms());
    }

    /// Max of global and symbol-scoped unexpired caution, in [0, 1].
    pub fn caution_for(&self, symbol: &str) -> f64 {
        self.cautions
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .caution_for(symbol, now_ms())
    }

    /// Feed the drawdown clocks one equity mark. Returns a description on
    /// state transitions (throttle began / halt / kill); past a hard breach
    /// (1.25x a drawdown limit) it engages the kill switch.
    pub fn on_equity(&self, equity: f64, ts_ms: i64) -> Option<String> {
        self.clocks
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .on_equity(equity, ts_ms, &self.cfg, &self.kill)
    }

    /// Drawdown throttle in [0, 1]; 1 = unthrottled, 0 = halted.
    pub fn throttle(&self) -> f64 {
        self.clocks
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .throttle(&self.cfg)
    }

    pub fn status(&self, autonomy: AutonomyLevel) -> RiskStatus {
        let now = now_ms();
        let (caution, caution_reasons) = {
            let book = self.cautions.lock().unwrap_or_else(|p| p.into_inner());
            (book.global_max(now), book.reasons(now))
        };
        let (throttle, breaches) = {
            let clocks = self.clocks.lock().unwrap_or_else(|p| p.into_inner());
            (clocks.throttle(&self.cfg), clocks.breaches(&self.cfg))
        };
        RiskStatus {
            kill_switch: self.kill.is_engaged(),
            kill_reason: self.kill.reason(),
            autonomy,
            caution,
            caution_reasons,
            throttle,
            breaches,
            ts_ms: now,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::types::{Side, Tif};

    fn cfg() -> RiskConfig {
        RiskConfig::default()
    }

    fn engine_with(cfg: RiskConfig) -> RiskEngine {
        RiskEngine::new(cfg, Arc::new(KillSwitch::new()))
    }

    fn engine() -> RiskEngine {
        engine_with(cfg())
    }

    fn intent(side: Side, qty: f64) -> OrderIntent {
        OrderIntent {
            id: 1,
            symbol: "BTC-USD".into(),
            side,
            qty,
            order_type: OrderType::Market,
            limit_px: None,
            stop_px: None,
            tif: Tif::Ioc,
            reduce_only: false,
            source: OrderSource::Strategy("test".into()),
            rationale: "test".into(),
            ts_ms: 0,
        }
    }

    fn reduce(side: Side, qty: f64) -> OrderIntent {
        OrderIntent {
            reduce_only: true,
            source: OrderSource::Manual,
            ..intent(side, qty)
        }
    }

    fn view_flat() -> PortfolioView {
        PortfolioView {
            equity: 100_000.0,
            cash: 100_000.0,
            ..Default::default()
        }
    }

    fn view_with(symbol: &str, qty: f64, mark: f64) -> PortfolioView {
        let mut v = view_flat();
        v.positions.insert(symbol.into(), (qty, mark));
        v
    }

    fn approved_qty(d: &RiskDecision) -> f64 {
        match d {
            RiskDecision::Approved { qty, .. } => *qty,
            RiskDecision::Rejected { reason } => panic!("expected approval, got: {reason}"),
        }
    }

    fn reject_reason(d: &RiskDecision) -> String {
        match d {
            RiskDecision::Rejected { reason } => reason.clone(),
            RiskDecision::Approved { qty, .. } => panic!("expected rejection, got qty {qty}"),
        }
    }

    // -- kill switch ------------------------------------------------------

    #[test]
    fn kill_blocks_entries_but_passes_manual_reduce_only() {
        let kill = Arc::new(KillSwitch::new());
        let eng = RiskEngine::new(cfg(), kill.clone());
        kill.engage("test");

        let d = eng.evaluate(&intent(Side::Buy, 1.0), &view_flat(), 100.0, None);
        assert!(reject_reason(&d).contains("kill switch"));

        let v = view_with("BTC-USD", 5.0, 100.0);
        let d = eng.evaluate(&reduce(Side::Sell, 5.0), &v, 100.0, None);
        assert_eq!(approved_qty(&d), 5.0);

        let mut flatten = reduce(Side::Sell, 2.0);
        flatten.source = OrderSource::RiskFlatten;
        assert!(eng.evaluate(&flatten, &v, 100.0, None).is_approved());

        // Reduce-only from a strategy is NOT exempt under kill.
        let mut strat = reduce(Side::Sell, 2.0);
        strat.source = OrderSource::Strategy("x".into());
        assert!(!eng.evaluate(&strat, &v, 100.0, None).is_approved());

        // Non-reduce-only manual is NOT exempt either.
        let mut manual = intent(Side::Sell, 2.0);
        manual.source = OrderSource::Manual;
        assert!(!eng.evaluate(&manual, &v, 100.0, None).is_approved());
    }

    // -- input sanity ------------------------------------------------------

    #[test]
    fn sanity_rejections() {
        let eng = engine();
        let v = view_flat();
        for bad_qty in [f64::NAN, f64::INFINITY, 0.0, -1.0] {
            assert!(!eng
                .evaluate(&intent(Side::Buy, bad_qty), &v, 100.0, None)
                .is_approved());
        }
        for bad_px in [f64::NAN, f64::INFINITY, 0.0, -100.0] {
            assert!(!eng
                .evaluate(&intent(Side::Buy, 1.0), &v, bad_px, None)
                .is_approved());
        }
        let mut lim = intent(Side::Buy, 1.0);
        lim.order_type = OrderType::Limit;
        for bad in [None, Some(f64::NAN), Some(0.0), Some(-5.0)] {
            lim.limit_px = bad;
            assert!(!eng.evaluate(&lim, &v, 100.0, None).is_approved());
        }
        lim.limit_px = Some(99.5);
        assert!(eng.evaluate(&lim, &v, 100.0, None).is_approved());
    }

    #[test]
    fn nan_equity_rejects_new_entries() {
        let eng = engine();
        let mut v = view_flat();
        v.equity = f64::NAN;
        assert!(!eng
            .evaluate(&intent(Side::Buy, 1.0), &v, 100.0, None)
            .is_approved());
    }

    // -- reduce-only path --------------------------------------------------

    #[test]
    fn reduce_only_must_reduce_and_clamps_to_position() {
        let eng = engine();
        // No position at all.
        let d = eng.evaluate(&reduce(Side::Sell, 1.0), &view_flat(), 100.0, None);
        assert!(reject_reason(&d).contains("no open position"));
        // Same direction as the position: would increase.
        let v = view_with("BTC-USD", 5.0, 100.0);
        let d = eng.evaluate(&reduce(Side::Buy, 1.0), &v, 100.0, None);
        assert!(reject_reason(&d).contains("increase"));
        // Oversized exit clamps to |position| with a note.
        let d = eng.evaluate(&reduce(Side::Sell, 8.0), &v, 100.0, None);
        match &d {
            RiskDecision::Approved { qty, notes } => {
                assert_eq!(*qty, 5.0);
                assert!(notes.iter().any(|n| n.contains("clamped to position")));
            }
            _ => panic!("expected approval"),
        }
        // Short position closes with a buy.
        let v = view_with("BTC-USD", -5.0, 100.0);
        let d = eng.evaluate(&reduce(Side::Buy, 3.0), &v, 100.0, None);
        assert_eq!(approved_qty(&d), 3.0);
    }

    #[test]
    fn reduce_only_bypasses_caution_and_drawdown_halt() {
        // Exits must survive the darkest state: max caution + halted clocks.
        let eng = engine();
        eng.set_caution(Some("BTC-USD"), 1.0, "max caution");
        eng.on_equity(100_000.0, 0);
        eng.on_equity(96_900.0, 1); // day dd 3.1% >= 3% limit -> halt
        assert_eq!(eng.throttle(), 0.0);

        let d = eng.evaluate(&intent(Side::Buy, 1.0), &view_flat(), 100.0, None);
        assert!(reject_reason(&d).contains("drawdown halt"));

        let v = view_with("BTC-USD", 8.0, 100.0);
        let d = eng.evaluate(&reduce(Side::Sell, 8.0), &v, 100.0, None);
        assert_eq!(approved_qty(&d), 8.0);
    }

    // -- sizing checks -----------------------------------------------------

    #[test]
    fn order_notional_cap_rejects() {
        let eng = engine(); // cap 25_000
        let d = eng.evaluate(&intent(Side::Buy, 300.0), &view_flat(), 100.0, None);
        assert!(reject_reason(&d).contains("notional"));
    }

    #[test]
    fn position_cap_clamps_and_rejects() {
        // equity 100k, pct 10% -> cap qty 100 at px 100.
        let eng = engine();
        let d = eng.evaluate(&intent(Side::Buy, 150.0), &view_flat(), 100.0, None);
        match &d {
            RiskDecision::Approved { qty, notes } => {
                assert!((qty - 100.0).abs() < 1e-9);
                assert!(notes.iter().any(|n| n.contains("position cap")));
            }
            _ => panic!("expected clamped approval"),
        }
        // Existing 90 -> fit 10 >= 10% of 50: clamp.
        let v = view_with("BTC-USD", 90.0, 100.0);
        let d = eng.evaluate(&intent(Side::Buy, 50.0), &v, 100.0, None);
        assert!((approved_qty(&d) - 10.0).abs() < 1e-9);
        // Existing 99 -> fit 1 < 10% of 50: reject.
        let v = view_with("BTC-USD", 99.0, 100.0);
        let d = eng.evaluate(&intent(Side::Buy, 50.0), &v, 100.0, None);
        assert!(reject_reason(&d).contains("position cap"));
        // Opposite side has room: selling from +90 is fine.
        let v = view_with("BTC-USD", 90.0, 100.0);
        let d = eng.evaluate(&intent(Side::Sell, 50.0), &v, 100.0, None);
        assert_eq!(approved_qty(&d), 50.0);
    }

    #[test]
    fn concurrent_position_cap_blocks_new_symbols_only() {
        let mut c = cfg();
        c.max_concurrent_positions = 2;
        let eng = engine_with(c);
        let mut v = view_flat();
        v.positions.insert("ETH-USD".into(), (1.0, 100.0));
        v.positions.insert("SOL-USD".into(), (1.0, 100.0));
        // New symbol blocked.
        let d = eng.evaluate(&intent(Side::Buy, 1.0), &v, 100.0, None);
        assert!(reject_reason(&d).contains("concurrent"));
        // Adding to an existing symbol still allowed.
        let mut add = intent(Side::Buy, 1.0);
        add.symbol = "ETH-USD".into();
        assert!(eng.evaluate(&add, &v, 100.0, None).is_approved());
    }

    #[test]
    fn daily_trade_cap_rejects() {
        let eng = engine();
        let mut v = view_flat();
        v.daily_trades = cfg().max_daily_trades;
        let d = eng.evaluate(&intent(Side::Buy, 1.0), &v, 100.0, None);
        assert!(reject_reason(&d).contains("daily trade cap"));
    }

    #[test]
    fn loss_bound_clamps() {
        // Push the other caps out of the way so the loss bound binds:
        // max loss 500 at 2% stop, px 100 -> max qty 250.
        let mut c = cfg();
        c.max_order_notional = 1e9;
        c.max_position_pct = 1.0;
        let eng = engine_with(c);
        let d = eng.evaluate(&intent(Side::Buy, 400.0), &view_flat(), 100.0, None);
        match &d {
            RiskDecision::Approved { qty, notes } => {
                assert!((qty - 250.0).abs() < 1e-9);
                assert!(notes.iter().any(|n| n.contains("loss bound")));
            }
            _ => panic!("expected clamped approval"),
        }
    }

    #[test]
    fn loss_bound_uses_atr_stop_when_provided() {
        // The real exit is wider than the 2% fallback: an ATR stop of $5/share
        // at px 100 (vs $2 for the 2% proxy) → max loss 500 / 5 = 100 shares,
        // TIGHTER than the 250 the 2% fallback allows. Proves the advertised
        // max-loss holds at the ACTUAL stop for a high-vol name.
        let mut c = cfg();
        c.max_order_notional = 1e9;
        c.max_position_pct = 1.0;
        let eng = engine_with(c);
        let d = eng.evaluate(&intent(Side::Buy, 400.0), &view_flat(), 100.0, Some(5.0));
        match &d {
            RiskDecision::Approved { qty, notes } => {
                assert!((qty - 100.0).abs() < 1e-9, "atr stop should clamp to 100, got {qty}");
                assert!(notes.iter().any(|n| n.contains("ATR trail")));
            }
            _ => panic!("expected clamped approval"),
        }
    }

    // -- caution -----------------------------------------------------------

    #[test]
    fn tighten_only_property_holds_for_any_caution_state() {
        let base =
            approved_qty(&engine().evaluate(&intent(Side::Buy, 10.0), &view_flat(), 100.0, None));
        assert_eq!(base, 10.0);
        for c in [
            0.0,
            0.05,
            0.3,
            0.6,
            0.9,
            1.0,
            7.5,
            -3.0,
            f64::NAN,
            f64::INFINITY,
            f64::NEG_INFINITY,
        ] {
            for scope in [None, Some("BTC-USD")] {
                let eng = engine();
                eng.set_caution(scope, c, "test");
                let q =
                    approved_qty(&eng.evaluate(&intent(Side::Buy, 10.0), &view_flat(), 100.0, None));
                assert!(
                    q <= base + 1e-12,
                    "caution {c} ({scope:?}) grew qty: {q} > {base}"
                );
                assert!(q > 0.0, "caution {c} ({scope:?}) zeroed qty");
            }
        }
    }

    #[test]
    fn caution_floor_never_zeroes_sizing() {
        // caution 1.0 with max_shrink 0.95 -> multiplier exactly 0.05.
        let eng = engine();
        eng.set_caution(None, 1.0, "worst case");
        let q = approved_qty(&eng.evaluate(&intent(Side::Buy, 10.0), &view_flat(), 100.0, None));
        assert!((q - 0.5).abs() < 1e-9);
    }

    #[test]
    fn caution_for_is_max_of_global_and_symbol() {
        let eng = engine();
        eng.set_caution(None, 0.5, "global");
        eng.set_caution(Some("BTC-USD"), 0.2, "sym");
        assert!((eng.caution_for("BTC-USD") - 0.5).abs() < 1e-12);
        assert!((eng.caution_for("ETH-USD") - 0.5).abs() < 1e-12);
        eng.set_caution(Some("BTC-USD"), 0.9, "sym worse");
        assert!((eng.caution_for("BTC-USD") - 0.9).abs() < 1e-12);
        assert!((eng.caution_for("ETH-USD") - 0.5).abs() < 1e-12);
    }

    #[test]
    fn caution_ttl_expires_at_engine_level() {
        let mut c = cfg();
        c.caution_ttl_secs = 0; // expires immediately
        let eng = engine_with(c);
        eng.set_caution(None, 0.9, "flash");
        assert_eq!(eng.caution_for("BTC-USD"), 0.0);
        let q = approved_qty(&eng.evaluate(&intent(Side::Buy, 10.0), &view_flat(), 100.0, None));
        assert_eq!(q, 10.0);
    }

    // -- drawdown clocks ---------------------------------------------------

    #[test]
    fn throttle_curve_is_monotone_nonincreasing() {
        let eng = engine(); // day limit 3%
        assert_eq!(eng.throttle(), 1.0); // before any equity mark
        eng.on_equity(100_000.0, 0);
        let mut last = eng.throttle();
        assert_eq!(last, 1.0);
        for eq in [
            99_500.0, 99_000.0, 98_500.0, 98_200.0, 98_000.0, 97_500.0, 97_200.0, 97_000.0,
            96_900.0,
        ] {
            eng.on_equity(eq, 1);
            let t = eng.throttle();
            assert!(t <= last + 1e-12, "throttle grew as drawdown deepened");
            assert!((0.0..=1.0).contains(&t));
            last = t;
        }
        assert_eq!(last, 0.0);
    }

    #[test]
    fn throttle_curve_hits_the_spec_points() {
        let eng = engine();
        eng.on_equity(100_000.0, 0);
        eng.on_equity(98_500.0, 1); // dd = half-limit -> unthrottled
        assert!((eng.throttle() - 1.0).abs() < 1e-9);
        eng.on_equity(98_000.0, 2); // dd 2% of a 3% limit -> 2/3
        assert!((eng.throttle() - 2.0 / 3.0).abs() < 1e-9);
        eng.on_equity(97_000.0, 3); // dd at the limit -> halted
        assert_eq!(eng.throttle(), 0.0);
        let d = eng.evaluate(&intent(Side::Buy, 1.0), &view_flat(), 100.0, None);
        assert!(reject_reason(&d).contains("drawdown halt"));
    }

    #[test]
    fn throttle_shrinks_approved_qty_with_note() {
        let eng = engine();
        eng.on_equity(100_000.0, 0);
        eng.on_equity(98_000.0, 1); // throttle 2/3
        let d = eng.evaluate(&intent(Side::Buy, 9.0), &view_flat(), 100.0, None);
        match &d {
            RiskDecision::Approved { qty, notes } => {
                assert!((qty - 6.0).abs() < 1e-6);
                assert!(notes.iter().any(|n| n.contains("throttle")));
            }
            _ => panic!("expected throttled approval"),
        }
    }

    #[test]
    fn on_equity_reports_transitions_and_engages_kill_past_hard_breach() {
        let kill = Arc::new(KillSwitch::new());
        let eng = RiskEngine::new(cfg(), kill.clone());
        assert!(eng.on_equity(100_000.0, 0).is_none());
        assert!(eng.on_equity(99_000.0, 1).is_none()); // dd 1% < half-limit
        let began = eng.on_equity(98_000.0, 2); // throttle begins
        assert!(began.unwrap().contains("throttle began"));
        assert!(eng.on_equity(97_900.0, 3).is_none()); // still throttling
        let halt = eng.on_equity(97_000.0, 4);
        assert!(halt.unwrap().contains("halt"));
        assert!(!kill.is_engaged());
        // day dd 4% > 3% * 1.25 -> the only autonomous kill trigger.
        let killed = eng.on_equity(96_000.0, 5);
        assert!(killed.unwrap().contains("hard breach"));
        assert!(kill.is_engaged());
        assert!(kill.reason().unwrap().contains("hard breach"));
        // Steady state: no repeated transition chatter.
        assert!(eng.on_equity(95_900.0, 6).is_none());
    }

    #[test]
    fn day_clock_resets_on_utc_day_change_but_total_persists() {
        let eng = engine();
        eng.on_equity(100_000.0, 0);
        eng.on_equity(97_000.0, 1); // day dd 3% -> halted
        assert_eq!(eng.throttle(), 0.0);
        // Next UTC day: day peak resets; total dd 3% < half of the 10% limit.
        eng.on_equity(97_000.0, 86_400_000 + 1);
        assert_eq!(eng.throttle(), 1.0);
        // Day after: the day clock restarts AT 94k (day dd 0) but the total
        // clock still binds -> total dd 6% in [5%, 10%) -> throttle 0.8.
        eng.on_equity(94_000.0, 2 * 86_400_000 + 1);
        assert!((eng.throttle() - 0.8).abs() < 1e-9);
    }

    #[test]
    fn non_finite_equity_marks_are_ignored() {
        let eng = engine();
        eng.on_equity(100_000.0, 0);
        assert!(eng.on_equity(f64::NAN, 1).is_none());
        assert!(eng.on_equity(f64::INFINITY, 1).is_none());
        assert!(eng.on_equity(-5.0, 1).is_none());
        assert!(eng.on_equity(0.0, 1).is_none());
        assert_eq!(eng.throttle(), 1.0);
    }

    // -- final rounding ----------------------------------------------------

    #[test]
    fn dust_qty_rounds_to_rejection() {
        let eng = engine();
        let d = eng.evaluate(&intent(Side::Buy, 4e-9), &view_flat(), 100.0, None);
        assert!(reject_reason(&d).contains("rounds to zero"));
    }

    // -- status ------------------------------------------------------------

    #[test]
    fn status_reports_kill_caution_throttle_breaches() {
        let kill = Arc::new(KillSwitch::new());
        let eng = RiskEngine::new(cfg(), kill.clone());
        eng.set_caution(None, 0.4, "geo tension");
        eng.on_equity(100_000.0, 0);
        eng.on_equity(98_000.0, 1); // throttling
        let s = eng.status(AutonomyLevel::SemiAuto);
        assert!(!s.kill_switch);
        assert_eq!(s.autonomy, AutonomyLevel::SemiAuto);
        assert!((s.caution - 0.4).abs() < 1e-12);
        assert_eq!(s.caution_reasons, vec!["geo tension".to_string()]);
        assert!(s.throttle > 0.0 && s.throttle < 1.0);
        assert!(s.breaches.iter().any(|b| b.contains("throttle band")));
        assert!(s.ts_ms > 0);

        kill.engage("operator drill");
        let s = eng.status(AutonomyLevel::Manual);
        assert!(s.kill_switch);
        assert_eq!(s.kill_reason.as_deref(), Some("operator drill"));
    }

    #[test]
    fn decision_json_is_tagged() {
        let d = RiskDecision::Approved {
            qty: 1.5,
            notes: vec!["n".into()],
        };
        let json = serde_json::to_string(&d).unwrap();
        assert!(json.contains("\"decision\":\"approved\""));
        let back: RiskDecision = serde_json::from_str(&json).unwrap();
        assert_eq!(back, d);
    }
}
