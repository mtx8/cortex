//! Regime-adaptive online estimators: GARCH(1,1) volatility forecasting,
//! Kalman local-level+trend filtering, and two-sided CUSUM change-point
//! detection. Streaming structs in the [`crate::ind`] mold: `update` returns
//! `None` until warm, non-finite inputs are skipped (state does not advance
//! and the call returns the current output), NaN never propagates. Every
//! estimator here is validated in tests against hand-computed recursions or
//! synthetic references — math that cannot prove itself does not ship.

/// GARCH(1,1) online volatility forecaster, variance-targeted.
///
/// Recursion: `sigma2[t+1] = omega + alpha * r[t]^2 + beta * sigma2[t]` with
/// `omega = V_L * (1 - alpha - beta)` where `V_L` is the running long-run
/// sample variance of returns (population Welford, updated online — the
/// variance target tracks the data instead of being a fitted constant).
/// Order per return: fold the return into `V_L` first, then recurse. The
/// conditional variance is seeded with `V_L` once `warmup` returns have
/// been seen. Defaults: alpha = 0.09, beta = 0.89, warmup = 20.
#[derive(Debug, Clone)]
pub struct Garch11 {
    alpha: f64,
    beta: f64,
    warmup: usize,
    n: usize,
    mean: f64,
    m2: f64,
    var: Option<f64>,
}

impl Garch11 {
    pub fn new() -> Self {
        Self::with_params(0.09, 0.89, 20)
    }

    /// Custom parameters; enforces `alpha, beta >= 0` and `alpha + beta < 1`
    /// (falls back to the defaults otherwise) and `warmup >= 2`.
    pub fn with_params(alpha: f64, beta: f64, warmup: usize) -> Self {
        let ok = alpha.is_finite()
            && beta.is_finite()
            && alpha >= 0.0
            && beta >= 0.0
            && alpha + beta < 1.0;
        let (alpha, beta) = if ok { (alpha, beta) } else { (0.09, 0.89) };
        Self {
            alpha,
            beta,
            warmup: warmup.max(2),
            n: 0,
            mean: 0.0,
            m2: 0.0,
            var: None,
        }
    }

    /// Feed one return; returns the current 1-step-ahead vol forecast
    /// (stdev, return units) once warm.
    pub fn update(&mut self, ret: f64) -> Option<f64> {
        if ret.is_finite() {
            // Welford update of the long-run (population) sample variance.
            self.n += 1;
            let delta = ret - self.mean;
            self.mean += delta / self.n as f64;
            self.m2 += delta * (ret - self.mean);

            match self.var {
                None => {
                    if self.n >= self.warmup {
                        self.var = self.long_run_var();
                    }
                }
                Some(v) => {
                    let vl = self.long_run_var().unwrap_or(0.0);
                    let omega = vl * (1.0 - self.alpha - self.beta);
                    let next = omega + self.alpha * ret * ret + self.beta * v;
                    if next.is_finite() && next >= 0.0 {
                        self.var = Some(next);
                    }
                }
            }
        }
        self.vol()
    }

    /// Current 1-step-ahead vol forecast (stdev), `None` until warm.
    pub fn vol(&self) -> Option<f64> {
        self.var.map(|v| v.max(0.0).sqrt())
    }

    /// n-step-ahead vol forecast via the closed-form GARCH term structure:
    /// `sigma2[t+n] = V_L + (alpha+beta)^(n-1) * (sigma2[t+1] - V_L)`.
    /// `n` is clamped to >= 1; `None` until warm.
    pub fn forecast(&self, n: usize) -> Option<f64> {
        let v1 = self.var?;
        let vl = self.long_run_var()?;
        let persist = (self.alpha + self.beta).powi(n.max(1) as i32 - 1);
        let v = vl + persist * (v1 - vl);
        v.is_finite().then(|| v.max(0.0).sqrt())
    }

    /// Long-run (population) sample variance of all returns seen so far.
    pub fn long_run_var(&self) -> Option<f64> {
        (self.n > 0).then(|| (self.m2 / self.n as f64).max(0.0))
    }
}

impl Default for Garch11 {
    fn default() -> Self {
        Self::new()
    }
}

/// Filtered state of [`KalmanTrend`].
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct KalmanState {
    /// Filtered local level (price units).
    pub level: f64,
    /// Filtered slope (price units per bar).
    pub slope: f64,
    /// slope / slope-stdev — the trend's own significance test.
    pub tstat: f64,
}

/// Observation noise is fixed at 1: only the signal/noise RATIO shapes the
/// gains, so the filter is scale-free in the observed series.
const KALMAN_OBS_R: f64 = 1.0;
/// Diffuse initial state covariance (level snaps to the first observation).
const KALMAN_INIT_P: f64 = 1e4;
/// Slope process noise as a fraction of level process noise: the slope is
/// the smooth state, the level absorbs the fast moves.
const KALMAN_SLOPE_Q_RATIO: f64 = 0.1;
/// Decay of the EWMA innovation-variance scale that calibrates the t-stat.
const KALMAN_SCALE_LAMBDA: f64 = 0.94;

/// Kalman local-level + trend filter (2-state: level, slope; scalar
/// observation), gains iterated from a signal/noise ratio.
///
/// Model: `level[t+1] = level[t] + slope[t] + w_l`, `slope[t+1] = slope[t] +
/// w_s`, `y[t] = level[t] + v` with `Var(v) = 1`, `Var(w_l) = snr^2`,
/// `Var(w_s) = 0.1 * snr^2`. The full covariance recursion is run each bar,
/// so gains converge to their steady state on their own. Because the real
/// observation noise is unknown, the slope stdev is re-scaled by an EWMA of
/// `innovation^2 / S` (the standardized innovation variance), making the
/// t-stat honest regardless of the series' scale.
#[derive(Debug, Clone)]
pub struct KalmanTrend {
    q_level: f64,
    q_slope: f64,
    warmup: usize,
    seen: usize,
    level: f64,
    slope: f64,
    p00: f64,
    p01: f64,
    p11: f64,
    scale: f64,
}

impl KalmanTrend {
    /// `snr` = process-noise stdev / observation-noise stdev per bar.
    /// Non-finite or non-positive ratios fall back to 0.1. Warm after 20
    /// observations.
    pub fn new(snr: f64) -> Self {
        let snr = if snr.is_finite() && snr > 0.0 { snr } else { 0.1 };
        let q = snr * snr * KALMAN_OBS_R;
        Self {
            q_level: q,
            q_slope: q * KALMAN_SLOPE_Q_RATIO,
            warmup: 20,
            seen: 0,
            level: 0.0,
            slope: 0.0,
            p00: KALMAN_INIT_P,
            p01: 0.0,
            p11: KALMAN_INIT_P,
            scale: 0.0,
        }
    }

    /// Feed one observation (e.g. a close); returns the filtered state once
    /// warm.
    pub fn update(&mut self, y: f64) -> Option<KalmanState> {
        if y.is_finite() {
            if self.seen == 0 {
                self.level = y;
                self.slope = 0.0;
                self.seen = 1;
            } else {
                // Predict.
                let level_p = self.level + self.slope;
                let slope_p = self.slope;
                let p00 = self.p00 + 2.0 * self.p01 + self.p11 + self.q_level;
                let p01 = self.p01 + self.p11;
                let p11 = self.p11 + self.q_slope;
                // Update.
                let innov = y - level_p;
                let s = p00 + KALMAN_OBS_R;
                let k0 = p00 / s;
                let k1 = p01 / s;
                self.level = level_p + k0 * innov;
                self.slope = slope_p + k1 * innov;
                self.p00 = (1.0 - k0) * p00;
                self.p01 = (1.0 - k0) * p01;
                self.p11 = p11 - k1 * p01;
                let ratio = innov * innov / s;
                self.scale = if self.seen == 1 {
                    ratio
                } else {
                    KALMAN_SCALE_LAMBDA * self.scale + (1.0 - KALMAN_SCALE_LAMBDA) * ratio
                };
                self.seen += 1;
            }
        }
        self.state()
    }

    /// Current filtered state, `None` until warm.
    pub fn state(&self) -> Option<KalmanState> {
        (self.seen >= self.warmup).then(|| {
            let slope_sd = (self.p11 * self.scale).max(1e-18).sqrt();
            KalmanState {
                level: self.level,
                slope: self.slope,
                tstat: self.slope / slope_sd,
            }
        })
    }
}

/// `bars_since_break` saturates here: "no break in recent memory".
pub const CUSUM_CAP: u32 = 500;

/// Two-sided CUSUM change-point detector on standardized returns.
///
/// Each return is standardized as `z = (r - mu) / sigma` against EWMA
/// running mean and vol (lambda = 0.94, using the PRE-update estimates so a
/// shift cannot normalize itself away), then accumulated Page-style:
/// `S+ = max(0, S+ + z - k)`, `S- = max(0, S- - z - k)`. Either side
/// exceeding `h` flags a change-point and resets both sides. Subtracting the
/// running mean makes this a true change-point test — a steady drift is the
/// baseline, not a perpetual "break". Defaults k = 0.5, h = 8.0 (high
/// threshold: silence on stationary noise is part of the contract).
#[derive(Debug, Clone)]
pub struct Cusum {
    k: f64,
    h: f64,
    lambda: f64,
    warmup: usize,
    n_obs: usize,
    mean: f64,
    var: f64,
    s_pos: f64,
    s_neg: f64,
    since: u32,
}

impl Cusum {
    pub fn new() -> Self {
        Self::with_params(0.5, 8.0)
    }

    /// Custom drift allowance `k` and decision threshold `h` (both must be
    /// finite and positive; falls back to the defaults otherwise).
    pub fn with_params(k: f64, h: f64) -> Self {
        let ok = k.is_finite() && h.is_finite() && k > 0.0 && h > 0.0;
        let (k, h) = if ok { (k, h) } else { (0.5, 8.0) };
        Self {
            k,
            h,
            lambda: 0.94,
            warmup: 20,
            n_obs: 0,
            mean: 0.0,
            var: 0.0,
            s_pos: 0.0,
            s_neg: 0.0,
            since: CUSUM_CAP,
        }
    }

    /// Feed one return; returns bars since the last break (capped at
    /// [`CUSUM_CAP`], `CUSUM_CAP` when no break has ever fired) once warm.
    pub fn update(&mut self, ret: f64) -> Option<u32> {
        if ret.is_finite() {
            if self.n_obs > 0 {
                let sd = self.var.max(0.0).sqrt();
                if self.n_obs >= self.warmup {
                    self.since = self.since.saturating_add(1).min(CUSUM_CAP);
                    if sd > 1e-12 {
                        let z = (ret - self.mean) / sd;
                        self.s_pos = (self.s_pos + z - self.k).max(0.0);
                        self.s_neg = (self.s_neg - z - self.k).max(0.0);
                        if self.s_pos > self.h || self.s_neg > self.h {
                            self.s_pos = 0.0;
                            self.s_neg = 0.0;
                            self.since = 0;
                        }
                    }
                }
                let dev = ret - self.mean;
                self.mean += (1.0 - self.lambda) * dev;
                self.var = self.lambda * self.var + (1.0 - self.lambda) * dev * dev;
            } else {
                self.mean = ret;
            }
            self.n_obs += 1;
        }
        self.bars_since_break()
    }

    /// Bars since the last change-point (capped), `None` until warm.
    pub fn bars_since_break(&self) -> Option<u32> {
        (self.n_obs >= self.warmup).then_some(self.since)
    }
}

impl Default for Cusum {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::quant::Prng;

    #[test]
    fn garch_recursion_matches_hand_computed() {
        // warmup = 2, alpha = 0.09, beta = 0.89, returns fed in order.
        let mut g = Garch11::with_params(0.09, 0.89, 2);
        assert_eq!(g.update(0.01), None);
        // After [0.01, -0.02]: population variance = 2.25e-4, seeds sigma2.
        let v = g.update(-0.02).unwrap();
        assert!((v - 2.25e-4_f64.sqrt()).abs() < 1e-12, "seed vol {v}");
        // r = 0.03: V_L of [0.01,-0.02,0.03] = 4.2222...e-4 (population),
        // omega = V_L * 0.02, sigma2 = omega + 0.09*0.03^2 + 0.89*2.25e-4.
        let vl3 = (0.01f64 - 0.02 + 0.03) / 3.0; // mean = 0.0066667
        let vl3 = ((0.01 - vl3).powi(2) + (-0.02 - vl3).powi(2) + (0.03 - vl3).powi(2)) / 3.0;
        let sig3 = vl3 * 0.02 + 0.09 * 0.03 * 0.03 + 0.89 * 2.25e-4;
        let v = g.update(0.03).unwrap();
        assert!((v - sig3.sqrt()).abs() < 1e-12, "vol {v} vs {}", sig3.sqrt());
        // r = -0.01: mean = 0.0025, V_L = 3.6875e-4.
        let m4 = (0.01f64 - 0.02 + 0.03 - 0.01) / 4.0;
        let vl4 = ((0.01 - m4).powi(2)
            + (-0.02 - m4).powi(2)
            + (0.03 - m4).powi(2)
            + (-0.01 - m4).powi(2))
            / 4.0;
        assert!((vl4 - 3.6875e-4).abs() < 1e-12);
        let sig4 = vl4 * 0.02 + 0.09 * 1e-4 + 0.89 * sig3;
        let v = g.update(-0.01).unwrap();
        assert!((v - sig4.sqrt()).abs() < 1e-12, "vol {v} vs {}", sig4.sqrt());
        assert!((g.long_run_var().unwrap() - vl4).abs() < 1e-12);
        // n-step term structure: sigma2[t+n] = V_L + 0.98^(n-1)*(sigma2 - V_L).
        let f3 = g.forecast(3).unwrap();
        let expect = vl4 + 0.98f64.powi(2) * (sig4 - vl4);
        assert!((f3 - expect.sqrt()).abs() < 1e-12, "forecast {f3}");
        // 1-step forecast equals the current conditional vol.
        assert!((g.forecast(1).unwrap() - sig4.sqrt()).abs() < 1e-12);
    }

    #[test]
    fn garch_converges_to_long_run_variance() {
        // IID returns with sigma = 0.02: the long-run target tracks the
        // sample variance and distant forecasts collapse onto it.
        let mut rng = Prng::new(21);
        let mut g = Garch11::new();
        let mut last = None;
        for _ in 0..20_000 {
            last = g.update(rng.normal() * 0.02);
        }
        let vl = g.long_run_var().unwrap();
        assert!((vl - 4e-4).abs() / 4e-4 < 0.05, "long-run var {vl}");
        // (alpha+beta)^999 ~ 1.7e-9: the far forecast IS the target.
        let far = g.forecast(1000).unwrap();
        assert!((far - vl.sqrt()).abs() < 1e-6, "far forecast {far}");
        // The conditional 1-step vol hovers near the true 0.02.
        let v = last.unwrap();
        assert!((v - 0.02).abs() < 0.01, "1-step vol {v}");
    }

    #[test]
    fn garch_skips_nan() {
        let mut g = Garch11::with_params(0.09, 0.89, 2);
        g.update(0.01);
        let v = g.update(-0.02).unwrap();
        // Non-finite input: state does not advance, output unchanged.
        assert_eq!(g.update(f64::NAN), Some(v));
        assert_eq!(g.update(f64::INFINITY), Some(v));
        assert_eq!(g.vol(), Some(v));
    }

    #[test]
    fn kalman_exact_ramp_recovers_slope() {
        // y = 10 + 0.5t, no noise: slope must converge to 0.5 and the
        // t-stat must scream (innovations vanish, so slope-sd collapses).
        let mut kf = KalmanTrend::new(0.1);
        let mut last = None;
        for t in 0..300 {
            last = kf.update(10.0 + 0.5 * t as f64);
        }
        let s = last.unwrap();
        assert!((s.slope - 0.5).abs() < 1e-3, "slope {}", s.slope);
        assert!(s.tstat > 2.0, "tstat {}", s.tstat);
        assert!((s.level - (10.0 + 0.5 * 299.0)).abs() < 0.5, "level {}", s.level);
    }

    #[test]
    fn kalman_converges_on_noisy_ramp() {
        let mut rng = Prng::new(17);
        let mut kf = KalmanTrend::new(0.1);
        let mut last = None;
        for t in 0..1000 {
            last = kf.update(100.0 + 0.5 * t as f64 + rng.normal() * 0.5);
        }
        let s = last.unwrap();
        assert!((s.slope - 0.5).abs() < 0.1, "slope {}", s.slope);
        assert!(s.tstat > 2.0, "tstat {}", s.tstat);
    }

    #[test]
    fn kalman_tracks_level_step_change() {
        let mut kf = KalmanTrend::new(0.1);
        for _ in 0..300 {
            kf.update(100.0);
        }
        let mut last = None;
        for _ in 0..100 {
            last = kf.update(110.0);
        }
        let s = last.unwrap();
        assert!((s.level - 110.0).abs() < 1.0, "level {}", s.level);
    }

    #[test]
    fn kalman_skips_nan_and_warms_late() {
        let mut kf = KalmanTrend::new(0.1);
        for t in 0..10 {
            assert_eq!(kf.update(t as f64), None, "warm too early");
        }
        let mut last = None;
        for t in 10..40 {
            last = kf.update(t as f64);
        }
        let s = last.unwrap();
        let after_nan = kf.update(f64::NAN).unwrap();
        assert_eq!(s, after_nan, "NaN advanced the filter");
    }

    #[test]
    fn cusum_fires_on_mean_shift() {
        // 500 stationary bars, then a +3-sigma mean shift: must break fast.
        let mut rng = Prng::new(33);
        let mut c = Cusum::new();
        for _ in 0..500 {
            c.update(rng.normal() * 0.01);
        }
        assert_eq!(c.bars_since_break(), Some(CUSUM_CAP), "false alarm pre-shift");
        let mut last = None;
        for _ in 0..30 {
            last = c.update(0.03 + rng.normal() * 0.01);
        }
        let since = last.unwrap();
        assert!(since < 30, "no break after mean shift (since {since})");
    }

    #[test]
    fn cusum_silent_on_stationary_noise() {
        let mut rng = Prng::new(7);
        let mut c = Cusum::new();
        let mut last = None;
        for _ in 0..2000 {
            last = c.update(rng.normal() * 0.01);
        }
        assert_eq!(last.unwrap(), CUSUM_CAP, "fired on stationary noise");
    }

    #[test]
    fn cusum_steady_drift_is_baseline_not_break() {
        // Constant positive returns = a trend, not a change-point: the
        // running-mean adjustment must absorb it.
        let mut c = Cusum::new();
        let mut last = None;
        for _ in 0..500 {
            last = c.update(0.001);
        }
        assert_eq!(last.unwrap(), CUSUM_CAP);
    }

    #[test]
    fn cusum_warmup_and_nan() {
        let mut c = Cusum::new();
        for i in 0..19 {
            assert_eq!(c.update(0.001 * (i % 3) as f64), None, "warm too early");
        }
        assert!(c.update(0.001).is_some());
        let before = c.bars_since_break();
        assert_eq!(c.update(f64::NAN), before, "NaN advanced the detector");
    }
}
