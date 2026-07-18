//! The LIVE hard-limit guard — a real-money backstop that sits ON TOP of the
//! RiskEngine, inside the IBKR adapter's `place()` path.
//!
//! It is deliberately paranoid and NaN-safe: three caps
//! (`max_live_order_notional`, `max_live_position_notional`,
//! `max_live_daily_loss`) that the RiskEngine's percentage-of-equity sizing
//! can never relax. Exits (reduce-only) are never blocked — mirroring the
//! RiskEngine, the risk-off path must stay open exactly when the guard is
//! darkest. Once the live realized day loss breaches its cap the guard HALTS:
//! new orders are refused (exits still pass) and the adapter flattens.

use std::sync::Mutex;

use cx_core::config::BrokerConfig;
use cx_core::events::OrderIntent;

const DAY_MS: i64 = 86_400_000;

/// The three live caps, lifted from [`BrokerConfig`]. Validated finite > 0 at
/// config load, but re-checked NaN-safely on every comparison here too.
#[derive(Debug, Clone, Copy)]
pub struct LiveLimits {
    pub max_order_notional: f64,
    pub max_position_notional: f64,
    pub max_daily_loss: f64,
}

impl LiveLimits {
    pub fn from_cfg(cfg: &BrokerConfig) -> Self {
        Self {
            max_order_notional: cfg.max_live_order_notional,
            max_position_notional: cfg.max_live_position_notional,
            max_daily_loss: cfg.max_live_daily_loss,
        }
    }
}

/// The verdict on one live order.
#[derive(Debug, Clone, PartialEq)]
pub enum LiveVerdict {
    Allow,
    Reject(String),
}

impl LiveVerdict {
    pub fn is_allowed(&self) -> bool {
        matches!(self, LiveVerdict::Allow)
    }
}

/// The pure limit check. `price` is the last known mark for the symbol;
/// `live_pos_qty` is the adapter's tracked signed live position. Reduce-only
/// exits are always allowed (subject only to being an exit) — they reduce
/// risk. New risk faces the order- and position-notional caps.
pub fn eval_live_order(
    limits: &LiveLimits,
    halted: bool,
    price: f64,
    intent: &OrderIntent,
    live_pos_qty: f64,
) -> LiveVerdict {
    // Halt blocks NEW orders; reduce-only exits must still get out.
    if halted && !intent.reduce_only {
        return LiveVerdict::Reject("live daily-loss halt engaged: new orders blocked".into());
    }
    // Reduce-only exits are never blocked by the notional caps — the same
    // rule the RiskEngine applies to its reduce-only fast path.
    if intent.reduce_only {
        return LiveVerdict::Allow;
    }

    if !(intent.qty.is_finite() && intent.qty > 0.0) {
        return LiveVerdict::Reject("live guard: order qty is not finite > 0".into());
    }
    // Price a notional off the limit price when the order carries one, else
    // the mark. A missing/invalid price fails CLOSED (reject) — never live.
    let px = intent
        .limit_px
        .filter(|p| p.is_finite() && *p > 0.0)
        .unwrap_or(price);
    if !(px.is_finite() && px > 0.0) {
        return LiveVerdict::Reject("live guard: no valid price to size the order notional".into());
    }

    let order_notional = intent.qty * px;
    if !(order_notional.is_finite()) || order_notional > limits.max_order_notional {
        return LiveVerdict::Reject(format!(
            "live order notional {order_notional:.2} exceeds max_live_order_notional {:.2}",
            limits.max_order_notional
        ));
    }

    let signed = intent.side.sign() * intent.qty;
    let resulting = live_pos_qty + signed;
    let resulting_notional = resulting.abs() * px;
    if !(resulting_notional.is_finite()) || resulting_notional > limits.max_position_notional {
        return LiveVerdict::Reject(format!(
            "resulting live position notional {resulting_notional:.2} exceeds \
             max_live_position_notional {:.2}",
            limits.max_position_notional
        ));
    }

    LiveVerdict::Allow
}

#[derive(Debug)]
struct GuardState {
    halted: bool,
    /// The adapter's latest view of the live realized+unrealized day PnL.
    day_pnl: f64,
    /// UTC day index the day clock belongs to.
    utc_day: i64,
}

/// Stateful wrapper around [`eval_live_order`] that also owns the daily-loss
/// halt latch and rolls it at the UTC day boundary.
#[derive(Debug)]
pub struct LiveGuard {
    limits: LiveLimits,
    state: Mutex<GuardState>,
}

impl LiveGuard {
    pub fn new(limits: LiveLimits, now_ms: i64) -> Self {
        Self {
            limits,
            state: Mutex::new(GuardState {
                halted: false,
                day_pnl: 0.0,
                utc_day: now_ms.div_euclid(DAY_MS),
            }),
        }
    }

    pub fn limits(&self) -> LiveLimits {
        self.limits
    }

    pub fn is_halted(&self) -> bool {
        self.lock().halted
    }

    /// Check one order against the caps under the CURRENT halt state.
    pub fn check(&self, price: f64, intent: &OrderIntent, live_pos_qty: f64) -> LiveVerdict {
        eval_live_order(&self.limits, self.is_halted(), price, intent, live_pos_qty)
    }

    /// Feed the adapter's latest live day PnL (a running total, from IBKR).
    /// Rolls the day at a UTC boundary (clearing the halt + baseline), then
    /// latches the halt if the loss has reached the cap. Returns true when
    /// THIS update newly engaged the halt — the caller flattens on a true.
    pub fn on_day_pnl(&self, day_pnl: f64, ts_ms: i64) -> bool {
        let mut s = self.lock();
        let day = ts_ms.div_euclid(DAY_MS);
        if day != s.utc_day {
            s.utc_day = day;
            s.halted = false;
            s.day_pnl = 0.0;
        }
        if day_pnl.is_finite() {
            s.day_pnl = day_pnl;
        }
        let breach = s.day_pnl <= -self.limits.max_daily_loss;
        let newly = breach && !s.halted;
        if breach {
            s.halted = true;
        }
        newly
    }

    /// Clear the halt latch (e.g. operator reset). The next `on_day_pnl` that
    /// still shows a breach re-engages it.
    pub fn clear_halt(&self) {
        self.lock().halted = false;
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, GuardState> {
        self.state.lock().unwrap_or_else(|p| p.into_inner())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::OrderSource;
    use cx_core::types::{OrderType, Side, Tif};

    fn limits() -> LiveLimits {
        LiveLimits {
            max_order_notional: 2_000.0,
            max_position_notional: 5_000.0,
            max_daily_loss: 500.0,
        }
    }

    fn intent(side: Side, qty: f64, reduce_only: bool) -> OrderIntent {
        OrderIntent {
            id: 0,
            symbol: "AAPL".into(),
            side,
            qty,
            order_type: OrderType::Market,
            limit_px: None,
            stop_px: None,
            tif: Tif::Ioc,
            reduce_only,
            source: OrderSource::Strategy("test".into()),
            rationale: "test".into(),
            ts_ms: 0,
        }
    }

    #[test]
    fn order_notional_cap_rejects_over_limit() {
        // 30 * 100 = 3000 > 2000.
        let v = eval_live_order(&limits(), false, 100.0, &intent(Side::Buy, 30.0, false), 0.0);
        match v {
            LiveVerdict::Reject(r) => assert!(r.contains("max_live_order_notional"), "{r}"),
            LiveVerdict::Allow => panic!("expected order-notional rejection"),
        }
        // 15 * 100 = 1500 <= 2000 and no existing position -> allowed.
        assert!(eval_live_order(&limits(), false, 100.0, &intent(Side::Buy, 15.0, false), 0.0)
            .is_allowed());
    }

    #[test]
    fn position_notional_cap_rejects_when_result_too_large() {
        // Each ticket 1500 (< order cap 2000), but stacking to 60 shares would
        // be 6000 > 5000 position cap.
        let v = eval_live_order(&limits(), false, 100.0, &intent(Side::Buy, 15.0, false), 45.0);
        match v {
            LiveVerdict::Reject(r) => assert!(r.contains("max_live_position_notional"), "{r}"),
            LiveVerdict::Allow => panic!("expected position-notional rejection"),
        }
        // Adding to 30 -> 45 shares = 4500 <= 5000 -> allowed.
        assert!(
            eval_live_order(&limits(), false, 100.0, &intent(Side::Buy, 15.0, false), 30.0)
                .is_allowed()
        );
    }

    #[test]
    fn reduce_only_exits_are_never_blocked_by_caps_or_halt() {
        // A huge reduce-only sell against a long is allowed even though its
        // notional dwarfs the caps — exits reduce risk.
        let v = eval_live_order(&limits(), false, 100.0, &intent(Side::Sell, 1000.0, true), 900.0);
        assert!(v.is_allowed(), "reduce-only exit must pass the notional caps");
        // And it still passes while HALTED — flatten must work under halt.
        let v = eval_live_order(&limits(), true, 100.0, &intent(Side::Sell, 1000.0, true), 900.0);
        assert!(v.is_allowed(), "reduce-only exit must pass under halt");
    }

    #[test]
    fn halt_blocks_new_orders_only() {
        // New entry rejected under halt...
        let v = eval_live_order(&limits(), true, 100.0, &intent(Side::Buy, 1.0, false), 0.0);
        match v {
            LiveVerdict::Reject(r) => assert!(r.contains("halt"), "{r}"),
            LiveVerdict::Allow => panic!("halt must block new orders"),
        }
    }

    #[test]
    fn nan_price_and_qty_fail_closed() {
        for bad_px in [f64::NAN, f64::INFINITY, 0.0, -100.0] {
            assert!(!eval_live_order(&limits(), false, bad_px, &intent(Side::Buy, 1.0, false), 0.0)
                .is_allowed());
        }
        for bad_qty in [f64::NAN, f64::INFINITY, 0.0, -5.0] {
            assert!(
                !eval_live_order(&limits(), false, 100.0, &intent(Side::Buy, bad_qty, false), 0.0)
                    .is_allowed()
            );
        }
    }

    #[test]
    fn limit_price_prices_the_notional_when_present() {
        // A marketless limit order sizes off its own limit price, not the mark.
        let mut i = intent(Side::Buy, 15.0, false);
        i.order_type = OrderType::Limit;
        i.limit_px = Some(200.0); // 15 * 200 = 3000 > 2000 cap
        let v = eval_live_order(&limits(), false, 1.0, &i, 0.0);
        assert!(!v.is_allowed(), "must size off the limit price (3000 > 2000)");
    }

    #[test]
    fn daily_loss_halt_latches_and_flattens_once() {
        let g = LiveGuard::new(limits(), 0);
        assert!(!g.is_halted());
        // Small loss: no halt.
        assert!(!g.on_day_pnl(-200.0, 1));
        assert!(!g.is_halted());
        // Breach: newly halted (true), and a new entry is now rejected.
        assert!(g.on_day_pnl(-500.0, 2), "first breach must report newly-halted");
        assert!(g.is_halted());
        assert!(!g.check(100.0, &intent(Side::Buy, 1.0, false), 0.0).is_allowed());
        // Re-report of the same breach does NOT re-fire the flatten.
        assert!(!g.on_day_pnl(-600.0, 3), "an already-halted breach must not re-fire");
        // Exit still allowed under halt.
        assert!(g.check(100.0, &intent(Side::Sell, 1.0, true), 5.0).is_allowed());
    }

    #[test]
    fn halt_clears_on_new_utc_day() {
        let g = LiveGuard::new(limits(), 0);
        assert!(g.on_day_pnl(-600.0, 1)); // halt engaged
        assert!(g.is_halted());
        // Next UTC day: clocks reset, halt clears, fresh PnL is small.
        assert!(!g.on_day_pnl(-10.0, DAY_MS + 1));
        assert!(!g.is_halted());
        assert!(g.check(100.0, &intent(Side::Buy, 1.0, false), 0.0).is_allowed());
    }
}
