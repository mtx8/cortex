//! cx-ta — streaming technical analysis.
//!
//! Pure and synchronous: no async, no bus, no IO. Consumes
//! [`cx_core::events::Bar`] slices (or raw streaming samples via [`ind`]);
//! all math is NaN-safe — non-finite inputs are skipped, never propagated.

pub mod bs;
pub mod quant;
pub mod ind;

use std::collections::BTreeMap;

use cx_core::events::Bar;

use ind::{Atr, Bollinger, Donchian, Ema, Macd, RollingZscore, Rsi, VwapSession};

/// RiskMetrics-style decay for the EWMA of squared 1-bar returns.
const VOL_EWMA_LAMBDA: f64 = 0.94;
/// |trend_score| at or above this reads as trending in [`detect_regime`].
const TREND_THRESHOLD: f64 = 0.3;
/// Minimum vol-EWMA history before the top-decile HighVol test is meaningful.
const MIN_VOL_HISTORY: usize = 20;
/// HighVol additionally requires current vol above median * this factor, so
/// a constant-vol series never reads as HighVol just for tying its own max.
const HIGH_VOL_MEDIAN_FACTOR: f64 = 1.25;

/// Streaming feature snapshot over a bar slice. Emits a key only when its
/// indicator is warm — a slice shorter than the window omits the key.
///
/// Keys: "close","ret_1","ema_9","ema_21","ema_50","rsi_14","macd",
/// "macd_signal","macd_hist","atr_14","bb_upper","bb_mid","bb_lower",
/// "bb_width","donchian_hi","donchian_lo","zscore_20","vwap","vol_ewma",
/// "trend_score".
///
/// - `vol_ewma`: EWMA of squared 1-bar returns, annualization-free.
/// - `trend_score` in [-1, 1]: half vol-normalized ema_9/ema_21/ema_50
///   alignment, half vol-normalized ema_9 slope, tanh-squashed.
pub fn compute_features(bars: &[Bar]) -> BTreeMap<String, f64> {
    let mut ema9 = Ema::new(9);
    let mut ema21 = Ema::new(21);
    let mut ema50 = Ema::new(50);
    let mut rsi14 = Rsi::new(14);
    let mut macd = Macd::new(12, 26, 9);
    let mut atr14 = Atr::new(14);
    let mut boll = Bollinger::new(20, 2.0);
    let mut donchian = Donchian::new(20);
    let mut zscore = RollingZscore::new(20);
    let mut vwap = VwapSession::new();

    let mut last_close: Option<f64> = None;
    let mut prev_close: Option<f64> = None;
    let mut vol: Option<f64> = None;
    let mut trend: Option<f64> = None;

    let mut v9 = None;
    let mut v21 = None;
    let mut v50 = None;
    let mut v_rsi = None;
    let mut v_macd = None;
    let mut v_atr = None;
    let mut v_boll = None;
    let mut v_don = None;
    let mut v_z = None;
    let mut v_vwap = None;

    for b in bars {
        // (high, low)-fed indicators guard their own inputs.
        v_atr = atr14.update(b.high, b.low, b.close);
        v_don = donchian.update(b.high, b.low);

        if !b.close.is_finite() {
            continue;
        }
        let c = b.close;

        if let Some(pc) = last_close {
            if pc.abs() > f64::EPSILON {
                let r = c / pc - 1.0;
                let r2 = r * r;
                vol = Some(match vol {
                    Some(v) => VOL_EWMA_LAMBDA * v + (1.0 - VOL_EWMA_LAMBDA) * r2,
                    None => r2,
                });
            }
        }
        prev_close = last_close;
        last_close = Some(c);

        let prev_e9 = v9;
        v9 = ema9.update(c);
        v21 = ema21.update(c);
        v50 = ema50.update(c);
        v_rsi = rsi14.update(c);
        v_macd = macd.update(c);
        v_boll = boll.update(c);
        v_z = zscore.update(c);
        let px = if b.vwap.is_finite() && b.vwap > 0.0 {
            b.vwap
        } else {
            c
        };
        v_vwap = vwap.update(px, b.volume);

        if let (Some(e9), Some(e21), Some(e50), Some(v)) = (v9, v21, v50, vol) {
            let sv = v.max(0.0).sqrt().max(1e-12);
            let denom = e50.abs().max(f64::EPSILON) * sv;
            let align = 0.5 * (((e9 - e21) / denom).tanh() + ((e21 - e50) / denom).tanh());
            let slope = match prev_e9 {
                Some(p) if p.abs() > f64::EPSILON => (((e9 - p) / p) / sv).tanh(),
                _ => 0.0,
            };
            trend = Some((0.5 * align + 0.5 * slope).clamp(-1.0, 1.0));
        }
    }

    let mut out = BTreeMap::new();
    if let Some(c) = last_close {
        out.insert("close".into(), c);
        if let Some(pc) = prev_close {
            if pc.abs() > f64::EPSILON {
                out.insert("ret_1".into(), c / pc - 1.0);
            }
        }
    }
    if let Some(v) = v9 {
        out.insert("ema_9".into(), v);
    }
    if let Some(v) = v21 {
        out.insert("ema_21".into(), v);
    }
    if let Some(v) = v50 {
        out.insert("ema_50".into(), v);
    }
    if let Some(v) = v_rsi {
        out.insert("rsi_14".into(), v);
    }
    if let Some(m) = v_macd {
        out.insert("macd".into(), m.macd);
        out.insert("macd_signal".into(), m.signal);
        out.insert("macd_hist".into(), m.hist);
    }
    if let Some(v) = v_atr {
        out.insert("atr_14".into(), v);
    }
    if let Some(b) = v_boll {
        out.insert("bb_upper".into(), b.upper);
        out.insert("bb_mid".into(), b.mid);
        out.insert("bb_lower".into(), b.lower);
        out.insert("bb_width".into(), b.width);
    }
    if let Some(d) = v_don {
        out.insert("donchian_hi".into(), d.upper);
        out.insert("donchian_lo".into(), d.lower);
    }
    if let Some(v) = v_z {
        out.insert("zscore_20".into(), v);
    }
    if let Some(v) = v_vwap {
        out.insert("vwap".into(), v);
    }
    if let Some(v) = vol {
        out.insert("vol_ewma".into(), v);
    }
    if let Some(t) = trend {
        out.insert("trend_score".into(), t);
    }
    out
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Regime {
    TrendingUp,
    TrendingDown,
    Ranging,
    HighVol,
}

/// Classify the slice's current regime with confidence in [0, 1].
///
/// HighVol wins when the latest vol-EWMA sits in the top decile of its own
/// history within the slice AND clearly above the median (guards the
/// degenerate constant-vol series). Otherwise `trend_score` decides:
/// >= 0.3 TrendingUp, <= -0.3 TrendingDown, else Ranging.
pub fn detect_regime(bars: &[Bar]) -> (Regime, f64) {
    let vols = vol_series(bars);
    if vols.len() >= MIN_VOL_HISTORY {
        if let Some(&now) = vols.last() {
            let mut sorted = vols.clone();
            sorted.sort_unstable_by(f64::total_cmp);
            let p90 = percentile(&sorted, 0.90);
            let median = percentile(&sorted, 0.50);
            if now >= p90 && now > median * HIGH_VOL_MEDIAN_FACTOR {
                let rank =
                    sorted.iter().filter(|v| **v <= now).count() as f64 / sorted.len() as f64;
                let conf = ((rank - 0.9) / 0.1).clamp(0.0, 1.0);
                return (Regime::HighVol, conf);
            }
        }
    }
    match compute_features(bars).get("trend_score") {
        Some(&t) if t >= TREND_THRESHOLD => (Regime::TrendingUp, t.abs().clamp(0.0, 1.0)),
        Some(&t) if t <= -TREND_THRESHOLD => (Regime::TrendingDown, t.abs().clamp(0.0, 1.0)),
        Some(&t) => (Regime::Ranging, (1.0 - t.abs()).clamp(0.0, 1.0)),
        None => (Regime::Ranging, 0.0),
    }
}

/// Per-bar vol-EWMA history over the slice (valid closes only).
fn vol_series(bars: &[Bar]) -> Vec<f64> {
    let mut out = Vec::new();
    let mut prev: Option<f64> = None;
    let mut vol: Option<f64> = None;
    for b in bars {
        if !b.close.is_finite() {
            continue;
        }
        if let Some(p) = prev {
            if p.abs() > f64::EPSILON {
                let r = b.close / p - 1.0;
                let r2 = r * r;
                let v = match vol {
                    Some(v) => VOL_EWMA_LAMBDA * v + (1.0 - VOL_EWMA_LAMBDA) * r2,
                    None => r2,
                };
                vol = Some(v);
                out.push(v);
            }
        }
        prev = Some(b.close);
    }
    out
}

/// Nearest-rank percentile of a sorted, finite slice; 0.0 when empty.
fn percentile(sorted: &[f64], q: f64) -> f64 {
    if sorted.is_empty() {
        return 0.0;
    }
    let idx = ((sorted.len() - 1) as f64 * q.clamp(0.0, 1.0)).round() as usize;
    sorted[idx.min(sorted.len() - 1)]
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::types::Interval;

    fn bar(i: i64, open: f64, high: f64, low: f64, close: f64, volume: f64) -> Bar {
        Bar {
            symbol: "BTC-USD".into(),
            interval: Interval::M1,
            ts_open_ms: i * 60_000,
            open,
            high,
            low,
            close,
            volume,
            trade_count: 1,
            vwap: close,
            complete: true,
        }
    }

    fn bars_from_closes(closes: &[f64]) -> Vec<Bar> {
        closes
            .iter()
            .enumerate()
            .map(|(i, &c)| {
                let h = c * 1.001;
                let l = c * 0.999;
                bar(i as i64, c, h, l, c, 1.0)
            })
            .collect()
    }

    const ALL_KEYS: [&str; 20] = [
        "close",
        "ret_1",
        "ema_9",
        "ema_21",
        "ema_50",
        "rsi_14",
        "macd",
        "macd_signal",
        "macd_hist",
        "atr_14",
        "bb_upper",
        "bb_mid",
        "bb_lower",
        "bb_width",
        "donchian_hi",
        "donchian_lo",
        "zscore_20",
        "vwap",
        "vol_ewma",
        "trend_score",
    ];

    #[test]
    fn compute_features_emits_all_keys_when_warm() {
        let closes: Vec<f64> = (0..80).map(|i| 100.0 * 1.01f64.powi(i)).collect();
        let feats = compute_features(&bars_from_closes(&closes));
        for key in ALL_KEYS {
            assert!(feats.contains_key(key), "missing key {key}");
        }
        for (k, v) in &feats {
            assert!(v.is_finite(), "non-finite value for {k}");
        }
        let t = feats["trend_score"];
        assert!((-1.0..=1.0).contains(&t));
        assert!(t > 0.5, "steady uptrend should score strongly, got {t}");
    }

    #[test]
    fn compute_features_omits_unwarm_keys() {
        let closes: Vec<f64> = (0..10).map(|i| 100.0 + i as f64).collect();
        let feats = compute_features(&bars_from_closes(&closes));
        for key in ["close", "ret_1", "ema_9", "vwap", "vol_ewma"] {
            assert!(feats.contains_key(key), "missing key {key}");
        }
        for key in [
            "ema_21",
            "ema_50",
            "rsi_14",
            "macd",
            "macd_signal",
            "macd_hist",
            "atr_14",
            "bb_upper",
            "bb_mid",
            "bb_lower",
            "bb_width",
            "donchian_hi",
            "donchian_lo",
            "zscore_20",
            "trend_score",
        ] {
            assert!(!feats.contains_key(key), "unexpected key {key}");
        }
    }

    #[test]
    fn compute_features_survives_nan_bars() {
        let mut closes: Vec<f64> = (0..80).map(|i| 100.0 * 1.005f64.powi(i)).collect();
        closes[10] = f64::NAN;
        closes[40] = f64::INFINITY;
        let feats = compute_features(&bars_from_closes(&closes));
        for (k, v) in &feats {
            assert!(v.is_finite(), "non-finite value for {k}");
        }
        assert!(feats.contains_key("close"));
    }

    #[test]
    fn compute_features_empty_slice_is_empty() {
        assert!(compute_features(&[]).is_empty());
    }

    #[test]
    fn ret_1_matches_last_two_closes() {
        let closes = [100.0, 101.0, 103.02];
        let feats = compute_features(&bars_from_closes(&closes));
        assert!((feats["ret_1"] - 0.02).abs() < 1e-12);
        assert!((feats["close"] - 103.02).abs() < 1e-12);
    }

    #[test]
    fn regime_trending_up_and_down() {
        let up: Vec<f64> = (0..80).map(|i| 100.0 * 1.01f64.powi(i)).collect();
        let (regime, conf) = detect_regime(&bars_from_closes(&up));
        assert_eq!(regime, Regime::TrendingUp);
        assert!((0.0..=1.0).contains(&conf));
        assert!(conf >= TREND_THRESHOLD);

        let down: Vec<f64> = (0..80).map(|i| 100.0 * 0.99f64.powi(i)).collect();
        let (regime, conf) = detect_regime(&bars_from_closes(&down));
        assert_eq!(regime, Regime::TrendingDown);
        assert!((0.0..=1.0).contains(&conf));
    }

    #[test]
    fn regime_ranging_on_choppy_series() {
        let closes: Vec<f64> = (0..80)
            .map(|i| if i % 2 == 0 { 100.0 } else { 101.0 })
            .collect();
        let (regime, conf) = detect_regime(&bars_from_closes(&closes));
        assert_eq!(regime, Regime::Ranging);
        assert!((0.0..=1.0).contains(&conf));
    }

    #[test]
    fn regime_high_vol_on_late_vol_spike() {
        let mut closes: Vec<f64> = (0..60)
            .map(|i| if i % 2 == 0 { 100.0 } else { 100.01 })
            .collect();
        let mut px = 100.0;
        for i in 0..12 {
            px *= if i % 2 == 0 { 1.05 } else { 0.95 };
            closes.push(px);
        }
        let (regime, conf) = detect_regime(&bars_from_closes(&closes));
        assert_eq!(regime, Regime::HighVol);
        assert!((0.0..=1.0).contains(&conf));
        assert!(conf > 0.5);
    }

    #[test]
    fn regime_short_slice_is_low_confidence_ranging() {
        let closes = [100.0, 101.0, 102.0];
        let (regime, conf) = detect_regime(&bars_from_closes(&closes));
        assert_eq!(regime, Regime::Ranging);
        assert_eq!(conf, 0.0);
    }

    #[test]
    fn constant_vol_series_never_reads_high_vol() {
        // Every return identical -> vol history constant -> the top-decile
        // test alone would fire; the median guard must block it.
        let closes: Vec<f64> = (0..80).map(|i| 100.0 * 1.01f64.powi(i)).collect();
        let (regime, _) = detect_regime(&bars_from_closes(&closes));
        assert_ne!(regime, Regime::HighVol);
    }
}
