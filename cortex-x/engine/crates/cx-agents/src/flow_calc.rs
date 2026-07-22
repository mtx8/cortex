//! Pure microstructure math for the FLOW desk — no bus, no async, no IO.
//!
//! Every function is deterministic, NaN-safe (non-finite inputs are skipped,
//! never propagated), and operates over bounded slices the desk maintains: the
//! top-N of a [`BookDepth`], a rolling window of [`TapePrint`]s, and a bounded
//! ring of (price, cumulative-delta) samples. These are the testable primitives
//! behind every FLOW flag; [`crate::flow`] wires them to the bus and throttles.
//!
//! HONESTY: these are probabilistic microstructure edges, never certainties.
//! "squeeze_dynamics" is squeeze BEHAVIOR in the tape (thinning offers +
//! accelerating up-delta + rising price), NOT a short-interest prediction —
//! short interest is not present in Level-2 data.

use cx_core::events::{BookLevel, TapePrint};
use cx_core::types::Side;

/// Which side of the book an event sits on.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BookSide {
    Bid,
    Ask,
}

impl BookSide {
    pub fn label(self) -> &'static str {
        match self {
            BookSide::Bid => "bid",
            BookSide::Ask => "ask",
        }
    }
}

/// Coarse current order-flow pressure.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Pressure {
    Buyers,
    Sellers,
    Balanced,
}

impl Pressure {
    pub fn label(self) -> &'static str {
        match self {
            Pressure::Buyers => "buyers",
            Pressure::Sellers => "sellers",
            Pressure::Balanced => "balanced",
        }
    }
}

/// Which way a delta-vs-price divergence points.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Divergence {
    /// Price made a new high but cumulative delta did not confirm — elevated
    /// reversal risk to the DOWNSIDE (buying is exhausting).
    BearishExhaustion,
    /// Price made a new low but cumulative delta did not confirm — elevated
    /// reversal risk to the UPSIDE (selling is exhausting).
    BullishExhaustion,
}

/// One (price, session-cumulative-delta) sample, captured on each recompute;
/// the divergence detector compares the current sample against a bounded ring.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DeltaSample {
    pub px: f64,
    pub cum_delta: f64,
}

/// An absorption read: heavy same-side aggression met by resting size so price
/// barely moved (a big passive absorber on the opposite book side).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AbsorptionRead {
    /// The book side doing the ABSORBING (opposite the aggressor).
    pub side: BookSide,
    /// The aggressor whose flow was absorbed.
    pub aggressor: Side,
    /// Absorbed aggressive volume over the window.
    pub volume: f64,
    /// Signed price move over the window (fraction).
    pub price_move: f64,
}

/// A sweep read: a tight burst of same-side aggressive prints clearing multiple
/// distinct price levels.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct SweepRead {
    pub aggressor: Side,
    pub levels: usize,
    pub volume: f64,
    pub span_ms: i64,
}

// ---- order-book imbalance ---------------------------------------------------

/// Sum of the finite, positive sizes in the top `top_n` levels of one side.
pub fn sum_top_sizes(levels: &[BookLevel], top_n: usize) -> f64 {
    levels
        .iter()
        .take(top_n)
        .map(|l| l.sz)
        .filter(|s| s.is_finite() && *s > 0.0)
        .sum()
}

/// Depth-weighted order-book imbalance over the top `top_n` levels, in
/// [-1, 1]: (bidΣ - askΣ) / (bidΣ + askΣ). >0 bid-heavy, <0 ask-heavy. Returns
/// 0.0 for an empty/degenerate book (NaN-safe).
pub fn order_book_imbalance(bids: &[BookLevel], asks: &[BookLevel], top_n: usize) -> f64 {
    let b = sum_top_sizes(bids, top_n);
    let a = sum_top_sizes(asks, top_n);
    let denom = b + a;
    if !denom.is_finite() || denom <= 0.0 {
        return 0.0;
    }
    ((b - a) / denom).clamp(-1.0, 1.0)
}

// ---- cumulative volume delta ------------------------------------------------

/// Aggressor-signed size of one print: buy +sz, sell -sz, unknown 0. Non-finite
/// or non-positive sizes contribute 0 (honest, never guessed).
pub fn signed_size(print: &TapePrint) -> f64 {
    if !(print.sz.is_finite() && print.sz > 0.0) {
        return 0.0;
    }
    match print.aggressor {
        Some(Side::Buy) => print.sz,
        Some(Side::Sell) => -print.sz,
        None => 0.0,
    }
}

/// Cumulative volume delta over a window: Σ aggressor-signed size.
pub fn window_delta(window: &[TapePrint]) -> f64 {
    let d: f64 = window.iter().map(signed_size).sum();
    if d.is_finite() {
        d
    } else {
        0.0
    }
}

/// Signed-volume velocity (delta per second) over the last `span_ms`, measured
/// relative to `ref_ms` (the newest print's timestamp, so delayed feeds window
/// against their OWN clock). 0.0 when the span is non-positive.
pub fn delta_rate(window: &[TapePrint], ref_ms: i64, span_ms: i64) -> f64 {
    if span_ms <= 0 {
        return 0.0;
    }
    let cutoff = ref_ms - span_ms;
    let signed: f64 = window
        .iter()
        .filter(|p| p.ts_ms >= cutoff && p.ts_ms <= ref_ms)
        .map(signed_size)
        .sum();
    let r = signed / (span_ms as f64 / 1000.0);
    if r.is_finite() {
        r
    } else {
        0.0
    }
}

/// Gross (unsigned) traded-volume rate over the last `span_ms` — the scale used
/// to make the pressure epsilon symbol-agnostic. 0.0 when span is non-positive.
pub fn gross_rate(window: &[TapePrint], ref_ms: i64, span_ms: i64) -> f64 {
    if span_ms <= 0 {
        return 0.0;
    }
    let cutoff = ref_ms - span_ms;
    let gross: f64 = window
        .iter()
        .filter(|p| p.ts_ms >= cutoff && p.ts_ms <= ref_ms)
        .map(|p| signed_size(p).abs())
        .sum();
    let r = gross / (span_ms as f64 / 1000.0);
    if r.is_finite() {
        r
    } else {
        0.0
    }
}

// ---- pressure classifier ----------------------------------------------------

/// Classify current pressure from the (bounded) OBI and the signed-delta
/// velocity. `obi_band` is the OBI neutral zone; `rate_eps` is the minimum
/// |delta_rate| (in volume/sec) that counts as directional. The two votes are
/// summed: agreement (or a lone strong vote) decides; genuine disagreement or
/// two neutrals read as balanced. NaN inputs vote neutral.
pub fn classify_pressure(obi: f64, delta_rate: f64, obi_band: f64, rate_eps: f64) -> Pressure {
    let ob: i32 = if !obi.is_finite() {
        0
    } else if obi > obi_band {
        1
    } else if obi < -obi_band {
        -1
    } else {
        0
    };
    let dr: i32 = if !delta_rate.is_finite() {
        0
    } else if delta_rate > rate_eps {
        1
    } else if delta_rate < -rate_eps {
        -1
    } else {
        0
    };
    match (ob + dr).signum() {
        1 => Pressure::Buyers,
        -1 => Pressure::Sellers,
        _ => Pressure::Balanced,
    }
}

// ---- absorption -------------------------------------------------------------

/// Detect absorption: over `window`, one aggressor side dominates the traded
/// volume (share >= `dominance`) yet price barely moved at all — `|price_move|
/// <= flat_pct`, in EITHER direction — so a large passive absorber is resting
/// on the opposite book side. The magnitude is bounded on BOTH sides so a large
/// move either way reads as momentum/overwhelm, never as a "held"-price
/// absorber. Needs at least `min_prints` finite-priced prints. NaN-safe.
///
/// Buy-dominant flow that held price flat => absorption at the ASK.
/// Sell-dominant flow that held price flat => absorption at the BID.
pub fn detect_absorption(
    window: &[TapePrint],
    flat_pct: f64,
    dominance: f64,
    min_prints: usize,
) -> Option<AbsorptionRead> {
    let priced: Vec<&TapePrint> = window
        .iter()
        .filter(|p| p.px.is_finite() && p.px > 0.0)
        .collect();
    if priced.len() < min_prints.max(1) {
        return None;
    }
    let first_px = priced.first()?.px;
    let last_px = priced.last()?.px;
    if !(first_px.is_finite() && first_px > 0.0) {
        return None;
    }
    let price_move = last_px / first_px - 1.0;
    if !price_move.is_finite() {
        return None;
    }

    let mut buy_vol = 0.0;
    let mut sell_vol = 0.0;
    for p in &priced {
        let s = signed_size(p);
        if s > 0.0 {
            buy_vol += s;
        } else {
            sell_vol += -s;
        }
    }
    let total = buy_vol + sell_vol;
    if !(total.is_finite() && total > 0.0) {
        return None;
    }

    if buy_vol / total >= dominance && price_move.abs() <= flat_pct {
        Some(AbsorptionRead {
            side: BookSide::Ask,
            aggressor: Side::Buy,
            volume: buy_vol,
            price_move,
        })
    } else if sell_vol / total >= dominance && price_move.abs() <= flat_pct {
        Some(AbsorptionRead {
            side: BookSide::Bid,
            aggressor: Side::Sell,
            volume: sell_vol,
            price_move,
        })
    } else {
        None
    }
}

// ---- sweep ------------------------------------------------------------------

/// Detect a sweep: a tight (`span <= max_span_ms`) burst of `>= min_prints`
/// prints that are overwhelmingly one aggressor (share >= `dominance`) and walk
/// price through `>= min_levels` distinct levels in that side's direction
/// (buys up, sells down). NaN-safe; returns None on any guard failure.
pub fn detect_sweep(
    burst: &[TapePrint],
    min_levels: usize,
    min_prints: usize,
    max_span_ms: i64,
    dominance: f64,
) -> Option<SweepRead> {
    let priced: Vec<&TapePrint> = burst
        .iter()
        .filter(|p| p.px.is_finite() && p.px > 0.0)
        .collect();
    if priced.len() < min_prints.max(2) {
        return None;
    }
    let span = priced.last()?.ts_ms - priced.first()?.ts_ms;
    if span < 0 || span > max_span_ms {
        return None;
    }

    let mut buy_vol = 0.0;
    let mut sell_vol = 0.0;
    for p in &priced {
        let s = signed_size(p);
        if s > 0.0 {
            buy_vol += s;
        } else {
            sell_vol += -s;
        }
    }
    let total = buy_vol + sell_vol;
    if !(total.is_finite() && total > 0.0) {
        return None;
    }
    let (aggressor, volume) = if buy_vol / total >= dominance {
        (Side::Buy, buy_vol)
    } else if sell_vol / total >= dominance {
        (Side::Sell, sell_vol)
    } else {
        return None;
    };

    // Distinct price levels touched by the burst.
    let mut pxs: Vec<f64> = priced.iter().map(|p| p.px).collect();
    pxs.sort_by(f64::total_cmp);
    pxs.dedup_by(|a, b| (*a - *b).abs() <= f64::EPSILON * a.abs().max(1.0));
    let levels = pxs.len();
    if levels < min_levels.max(2) {
        return None;
    }

    // Price must have progressed in the aggressor's direction across the burst.
    let progressed = match aggressor {
        Side::Buy => priced.last()?.px > priced.first()?.px,
        Side::Sell => priced.last()?.px < priced.first()?.px,
    };
    if !progressed {
        return None;
    }

    Some(SweepRead {
        aggressor,
        levels,
        volume,
        span_ms: span,
    })
}

// ---- delta-vs-price divergence ---------------------------------------------

/// Detect a delta-vs-price divergence: the current sample makes a NEW price
/// extreme (by at least `min_extreme_frac`) versus the recent `history`, but
/// cumulative delta fails to confirm it (a new high on non-higher delta, or a
/// new low on non-lower delta). This is exhaustion / elevated reversal RISK —
/// never a certainty. Needs non-empty history; NaN-safe.
pub fn detect_divergence(
    history: &[DeltaSample],
    current: DeltaSample,
    min_extreme_frac: f64,
) -> Option<Divergence> {
    if !(current.px.is_finite() && current.px > 0.0 && current.cum_delta.is_finite()) {
        return None;
    }
    let valid: Vec<&DeltaSample> = history
        .iter()
        .filter(|s| s.px.is_finite() && s.px > 0.0 && s.cum_delta.is_finite())
        .collect();
    if valid.is_empty() {
        return None;
    }

    // Prior price high and its delta; prior price low and its delta.
    let prior_high = valid
        .iter()
        .copied()
        .max_by(|a, b| a.px.total_cmp(&b.px))?;
    let prior_low = valid
        .iter()
        .copied()
        .min_by(|a, b| a.px.total_cmp(&b.px))?;

    if current.px >= prior_high.px * (1.0 + min_extreme_frac)
        && current.cum_delta <= prior_high.cum_delta
    {
        return Some(Divergence::BearishExhaustion);
    }
    if current.px <= prior_low.px * (1.0 - min_extreme_frac)
        && current.cum_delta >= prior_low.cum_delta
    {
        return Some(Divergence::BullishExhaustion);
    }
    None
}

// ---- squeeze dynamics -------------------------------------------------------

/// Detect squeeze BEHAVIOR in the tape: offers thinning (`ask_now` below
/// `ask_ref * thin_frac`), up-delta accelerating (`rate_now > rate_prev > 0`),
/// and price rising (`price_now > price_ref`). All three, NaN-safe.
///
/// HONEST: this is a description of tape behavior, NOT a short-interest
/// prediction — short interest is not present in Level-2 data. The desk and
/// ledger both label it as behavior, never as a squeeze call.
pub fn detect_squeeze_dynamics(
    ask_now: f64,
    ask_ref: f64,
    rate_now: f64,
    rate_prev: f64,
    price_now: f64,
    price_ref: f64,
    thin_frac: f64,
) -> bool {
    let finite = ask_now.is_finite()
        && ask_ref.is_finite()
        && rate_now.is_finite()
        && rate_prev.is_finite()
        && price_now.is_finite()
        && price_ref.is_finite();
    if !finite || ask_ref <= 0.0 || price_ref <= 0.0 {
        return false;
    }
    let thinning = ask_now < ask_ref * thin_frac;
    let accelerating_up = rate_now > 0.0 && rate_now > rate_prev;
    let rising = price_now > price_ref;
    thinning && accelerating_up && rising
}

#[cfg(test)]
mod tests {
    use super::*;

    fn level(px: f64, sz: f64) -> BookLevel {
        BookLevel::agg(px, sz, 0)
    }

    fn print(px: f64, sz: f64, aggressor: Option<Side>, ts_ms: i64) -> TapePrint {
        TapePrint {
            symbol: "BTC-USD".into(),
            px,
            sz,
            aggressor,
            ts_ms,
            is_live: true,
        }
    }

    // ---- OBI ----------------------------------------------------------------

    #[test]
    fn obi_sign_bounds_and_nan_safety() {
        // Bid-heavy -> positive; ask-heavy -> negative; balanced -> ~0.
        let bids = vec![level(100.0, 6.0), level(99.0, 4.0)];
        let asks = vec![level(101.0, 2.0), level(102.0, 2.0)];
        let obi = order_book_imbalance(&bids, &asks, 10);
        // bidΣ=10, askΣ=4 -> (10-4)/14 = 0.4286
        assert!((obi - (6.0 / 14.0)).abs() < 1e-12, "{obi}");
        assert!(obi > 0.0);
        // Flip the books -> exact negation.
        assert!((order_book_imbalance(&asks, &bids, 10) + obi).abs() < 1e-12);
        // Balanced.
        let flat = vec![level(100.0, 5.0)];
        assert_eq!(order_book_imbalance(&flat, &flat, 10), 0.0);
        // Bounded to [-1, 1] with one-sided books.
        assert!((order_book_imbalance(&bids, &[], 10) - 1.0).abs() < 1e-12);
        assert!((order_book_imbalance(&[], &asks, 10) + 1.0).abs() < 1e-12);
        // Empty / non-finite -> 0.0, never NaN.
        assert_eq!(order_book_imbalance(&[], &[], 10), 0.0);
        let junk = vec![level(f64::NAN, f64::NAN), level(100.0, -5.0)];
        assert_eq!(order_book_imbalance(&junk, &junk, 10), 0.0);
    }

    #[test]
    fn obi_respects_top_n() {
        // Only the top level counts when top_n = 1.
        let bids = vec![level(100.0, 1.0), level(99.0, 100.0)];
        let asks = vec![level(101.0, 1.0), level(102.0, 100.0)];
        assert_eq!(order_book_imbalance(&bids, &asks, 1), 0.0);
    }

    // ---- cumulative delta + rate --------------------------------------------

    #[test]
    fn cum_delta_signs_the_aggressor_and_ignores_unknown() {
        let tape = vec![
            print(100.0, 2.0, Some(Side::Buy), 0),
            print(100.1, 1.0, Some(Side::Sell), 100),
            print(100.2, 5.0, None, 200), // unknown -> 0 contribution
            print(100.3, 3.0, Some(Side::Buy), 300),
        ];
        // +2 -1 +0 +3 = +4
        assert!((window_delta(&tape) - 4.0).abs() < 1e-12);
        // Non-finite sizes contribute nothing.
        let dirty = vec![print(100.0, f64::NAN, Some(Side::Buy), 0), print(100.0, -1.0, Some(Side::Sell), 0)];
        assert_eq!(window_delta(&dirty), 0.0);
    }

    #[test]
    fn delta_rate_windows_against_the_reference_clock() {
        // Newest print at ts=10_000; a 2s window keeps only ts in [8000,10000].
        let tape = vec![
            print(100.0, 10.0, Some(Side::Buy), 1_000), // outside 2s window
            print(100.0, 4.0, Some(Side::Sell), 9_000), // inside
            print(100.0, 1.0, Some(Side::Buy), 10_000), // inside
        ];
        let ref_ms = 10_000;
        // inside signed = -4 + 1 = -3 over 2s -> -1.5 /s
        assert!((delta_rate(&tape, ref_ms, 2_000) - (-1.5)).abs() < 1e-12);
        // gross = 4 + 1 = 5 over 2s -> 2.5 /s
        assert!((gross_rate(&tape, ref_ms, 2_000) - 2.5).abs() < 1e-12);
        // Non-positive span is guarded.
        assert_eq!(delta_rate(&tape, ref_ms, 0), 0.0);
    }

    // ---- pressure -----------------------------------------------------------

    #[test]
    fn pressure_from_obi_and_delta_rate() {
        // Both bullish -> buyers.
        assert_eq!(classify_pressure(0.4, 5.0, 0.15, 1.0), Pressure::Buyers);
        // Both bearish -> sellers.
        assert_eq!(classify_pressure(-0.4, -5.0, 0.15, 1.0), Pressure::Sellers);
        // A lone strong OBI vote decides when the rate is within its epsilon.
        assert_eq!(classify_pressure(0.5, 0.2, 0.15, 1.0), Pressure::Buyers);
        // Genuine disagreement -> balanced.
        assert_eq!(classify_pressure(0.4, -5.0, 0.15, 1.0), Pressure::Balanced);
        // Both inside their neutral zones -> balanced.
        assert_eq!(classify_pressure(0.05, 0.2, 0.15, 1.0), Pressure::Balanced);
        // NaN votes neutral.
        assert_eq!(classify_pressure(f64::NAN, f64::NAN, 0.15, 1.0), Pressure::Balanced);
    }

    // ---- absorption ---------------------------------------------------------

    #[test]
    fn absorption_fires_on_flat_price_heavy_one_sided_volume() {
        // Heavy BUY aggression, price essentially flat -> absorption at the ask.
        let mut tape = Vec::new();
        for i in 0..10 {
            tape.push(print(100.0, 5.0, Some(Side::Buy), i * 100));
        }
        // one small sell so dominance is a real ratio, not trivially 1.0
        tape.push(print(100.0, 1.0, Some(Side::Sell), 1_000));
        let a = detect_absorption(&tape, 0.001, 0.7, 6).expect("absorption");
        assert_eq!(a.side, BookSide::Ask);
        assert_eq!(a.aggressor, Side::Buy);
        assert!(a.volume >= 50.0);

        // Mirror: heavy SELL aggression, price flat -> absorption at the bid.
        let mut sells = Vec::new();
        for i in 0..10 {
            sells.push(print(100.0, 5.0, Some(Side::Sell), i * 100));
        }
        let b = detect_absorption(&sells, 0.001, 0.7, 6).expect("bid absorption");
        assert_eq!(b.side, BookSide::Bid);
        assert_eq!(b.aggressor, Side::Sell);
    }

    #[test]
    fn absorption_stays_quiet_when_price_follows_or_flow_is_two_sided() {
        // Heavy buying that DID lift price a full 1% is not absorption.
        let mut trending = Vec::new();
        for i in 0..10 {
            let px = 100.0 * (1.0 + 0.001 * i as f64);
            trending.push(print(px, 5.0, Some(Side::Buy), i * 100));
        }
        assert_eq!(detect_absorption(&trending, 0.0008, 0.7, 6), None);
        // Balanced two-sided flow at a flat price: no dominant absorber.
        let mut balanced = Vec::new();
        for i in 0..10 {
            let side = if i % 2 == 0 { Side::Buy } else { Side::Sell };
            balanced.push(print(100.0, 5.0, Some(side), i * 100));
        }
        assert_eq!(detect_absorption(&balanced, 0.001, 0.7, 6), None);
        // Too few prints: refused.
        assert_eq!(detect_absorption(&trending[..3], 0.01, 0.5, 6), None);
    }

    #[test]
    fn absorption_ignores_a_large_favorable_move_as_momentum_not_held() {
        // Feeds with inferred/lagged aggressor signs can label heavy SELL
        // aggression while price still RALLIES (or heavy BUY aggression while
        // price DROPS). That is momentum/overwhelm, NOT passive absorption at a
        // "held" price — the magnitude is bounded on BOTH sides, so a large move
        // in EITHER direction must stay quiet.
        //
        // Sell-dominant flow riding a large UP move: must not fire absorption:bid.
        let sells_up: Vec<TapePrint> = (0..10)
            .map(|i| print(100.0 * (1.0 + 0.001 * i as f64), 5.0, Some(Side::Sell), i * 100))
            .collect();
        assert_eq!(detect_absorption(&sells_up, 0.0008, 0.7, 6), None);
        // Buy-dominant flow riding a large DOWN move: must not fire absorption:ask.
        let buys_down: Vec<TapePrint> = (0..10)
            .map(|i| print(100.0 * (1.0 - 0.001 * i as f64), 5.0, Some(Side::Buy), i * 100))
            .collect();
        assert_eq!(detect_absorption(&buys_down, 0.0008, 0.7, 6), None);
    }

    // ---- sweep --------------------------------------------------------------

    #[test]
    fn sweep_fires_on_a_multi_level_one_sided_burst() {
        // Six buy prints walking 100.0 -> 100.5 inside 500ms.
        let burst: Vec<TapePrint> = (0..6)
            .map(|i| print(100.0 + i as f64 * 0.1, 2.0, Some(Side::Buy), i * 100))
            .collect();
        let s = detect_sweep(&burst, 4, 4, 1_500, 0.8).expect("sweep");
        assert_eq!(s.aggressor, Side::Buy);
        assert_eq!(s.levels, 6);
        assert!(s.span_ms <= 1_500);

        // A downward sell sweep.
        let down: Vec<TapePrint> = (0..6)
            .map(|i| print(100.0 - i as f64 * 0.1, 2.0, Some(Side::Sell), i * 100))
            .collect();
        assert_eq!(detect_sweep(&down, 4, 4, 1_500, 0.8).unwrap().aggressor, Side::Sell);
    }

    #[test]
    fn sweep_stays_quiet_without_burst_progression_or_dominance() {
        // Same side but price oscillates on one level -> not a sweep.
        let flat: Vec<TapePrint> = (0..6)
            .map(|i| print(100.0, 2.0, Some(Side::Buy), i * 100))
            .collect();
        assert_eq!(detect_sweep(&flat, 4, 4, 1_500, 0.8), None);
        // Multi-level but two-sided flow -> no dominant aggressor.
        let mixed: Vec<TapePrint> = (0..6)
            .map(|i| {
                let side = if i % 2 == 0 { Side::Buy } else { Side::Sell };
                print(100.0 + i as f64 * 0.1, 2.0, Some(side), i * 100)
            })
            .collect();
        assert_eq!(detect_sweep(&mixed, 4, 4, 1_500, 0.8), None);
        // Too slow (span exceeds the burst cap) -> not a sweep.
        let slow: Vec<TapePrint> = (0..6)
            .map(|i| print(100.0 + i as f64 * 0.1, 2.0, Some(Side::Buy), i * 1_000))
            .collect();
        assert_eq!(detect_sweep(&slow, 4, 4, 1_500, 0.8), None);
    }

    // ---- divergence ---------------------------------------------------------

    #[test]
    fn divergence_on_new_high_with_unconfirming_delta() {
        // Prior high 100.0 carried cum_delta +50. A new high on LOWER delta is
        // bearish exhaustion.
        let hist = vec![
            DeltaSample { px: 100.0, cum_delta: 50.0 },
            DeltaSample { px: 98.0, cum_delta: 20.0 },
        ];
        let cur = DeltaSample { px: 101.0, cum_delta: 30.0 };
        assert_eq!(
            detect_divergence(&hist, cur, 0.002),
            Some(Divergence::BearishExhaustion)
        );
        // A new high that delta DOES confirm is not a divergence.
        let confirming = DeltaSample { px: 101.0, cum_delta: 80.0 };
        assert_eq!(detect_divergence(&hist, confirming, 0.002), None);
        // Mirror: new low on non-lower (higher) delta -> bullish exhaustion.
        let lows = vec![DeltaSample { px: 100.0, cum_delta: -50.0 }];
        let new_low = DeltaSample { px: 99.0, cum_delta: -20.0 };
        assert_eq!(
            detect_divergence(&lows, new_low, 0.002),
            Some(Divergence::BullishExhaustion)
        );
    }

    #[test]
    fn divergence_needs_a_real_new_extreme_and_is_nan_safe() {
        let hist = vec![DeltaSample { px: 100.0, cum_delta: 50.0 }];
        // Only a trivial tick above the prior high (below min_extreme_frac): no.
        let tick = DeltaSample { px: 100.0001, cum_delta: 30.0 };
        assert_eq!(detect_divergence(&hist, tick, 0.002), None);
        // Empty history and non-finite inputs are refused.
        assert_eq!(detect_divergence(&[], DeltaSample { px: 101.0, cum_delta: 1.0 }, 0.002), None);
        assert_eq!(
            detect_divergence(&hist, DeltaSample { px: f64::NAN, cum_delta: 1.0 }, 0.002),
            None
        );
    }

    // ---- squeeze dynamics ---------------------------------------------------

    #[test]
    fn squeeze_dynamics_needs_all_three_conditions() {
        // Offers thinned to 40% of ref, up-delta accelerating, price rising.
        assert!(detect_squeeze_dynamics(4.0, 10.0, 5.0, 3.0, 101.0, 100.0, 0.6));
        // Offers NOT thinning -> false.
        assert!(!detect_squeeze_dynamics(9.0, 10.0, 5.0, 3.0, 101.0, 100.0, 0.6));
        // Up-delta not accelerating (rate falling) -> false.
        assert!(!detect_squeeze_dynamics(4.0, 10.0, 2.0, 3.0, 101.0, 100.0, 0.6));
        // Delta accelerating but NEGATIVE (down-delta) -> false.
        assert!(!detect_squeeze_dynamics(4.0, 10.0, -1.0, -3.0, 101.0, 100.0, 0.6));
        // Price not rising -> false.
        assert!(!detect_squeeze_dynamics(4.0, 10.0, 5.0, 3.0, 99.0, 100.0, 0.6));
        // NaN / degenerate refs -> false, never a panic.
        assert!(!detect_squeeze_dynamics(4.0, f64::NAN, 5.0, 3.0, 101.0, 100.0, 0.6));
        assert!(!detect_squeeze_dynamics(4.0, 0.0, 5.0, 3.0, 101.0, 100.0, 0.6));
    }
}
