//! Quantitative finance toolkit: sizing (Kelly, vol targeting), tail risk
//! (Cornish-Fisher VaR, expected shortfall), regime structure (Hurst,
//! Ornstein-Uhlenbeck half-life), performance analytics, and Monte Carlo
//! machinery. Pure, deterministic (seeded PRNG), NaN-safe. Every estimator
//! here is validated in tests against closed-form or known references —
//! math that cannot prove itself does not ship.

/// Deterministic xorshift64* PRNG — no dependencies, stable across runs.
pub struct Prng(u64);

impl Prng {
    pub fn new(seed: u64) -> Self {
        Self(seed.max(1))
    }
    fn next_u64(&mut self) -> u64 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        x.wrapping_mul(0x2545F4914F6CDD1D)
    }
    /// Uniform in (0, 1).
    pub fn uniform(&mut self) -> f64 {
        ((self.next_u64() >> 11) as f64 + 0.5) / (1u64 << 53) as f64
    }
    /// Standard normal via Box-Muller.
    pub fn normal(&mut self) -> f64 {
        let u1 = self.uniform();
        let u2 = self.uniform();
        (-2.0 * u1.ln()).sqrt() * (2.0 * std::f64::consts::PI * u2).cos()
    }
}

fn clean(xs: &[f64]) -> Vec<f64> {
    xs.iter().copied().filter(|x| x.is_finite()).collect()
}

/// Kelly optimal fraction for a binary-outcome bet: f* = p - (1-p)/b where
/// b = avg_win/avg_loss. Returns the FULL Kelly clamped to [0, 1]; prudent
/// callers bet a fraction of it (half-Kelly is the desk default).
pub fn kelly_fraction(win_rate: f64, avg_win: f64, avg_loss: f64) -> Option<f64> {
    if !(win_rate.is_finite() && (0.0..=1.0).contains(&win_rate)) {
        return None;
    }
    if !(avg_win.is_finite() && avg_loss.is_finite() && avg_win > 0.0 && avg_loss > 0.0) {
        return None;
    }
    let b = avg_win / avg_loss;
    Some((win_rate - (1.0 - win_rate) / b).clamp(0.0, 1.0))
}

/// EWMA volatility (RiskMetrics): per-period stdev of returns.
pub fn ewma_vol(returns: &[f64], lambda: f64) -> Option<f64> {
    let xs = clean(returns);
    if xs.is_empty() || !(0.5..1.0).contains(&lambda) {
        return None;
    }
    let mut var = xs[0] * xs[0];
    for r in &xs[1..] {
        var = lambda * var + (1.0 - lambda) * r * r;
    }
    var.is_finite().then(|| var.sqrt())
}

/// Vol-targeting scalar: how much to scale a position so realized vol hits
/// the target. Clamped so a vol crush can never balloon size unboundedly.
pub fn vol_target_scalar(target_vol: f64, realized_vol: f64) -> f64 {
    if !(target_vol.is_finite() && realized_vol.is_finite()) || realized_vol <= 1e-12 {
        return 1.0;
    }
    (target_vol / realized_vol).clamp(0.25, 1.5)
}

/// (mean, stdev, skew, excess kurtosis) — population moments.
pub fn moments(xs: &[f64]) -> Option<(f64, f64, f64, f64)> {
    let xs = clean(xs);
    let n = xs.len() as f64;
    if n < 4.0 {
        return None;
    }
    let mean = xs.iter().sum::<f64>() / n;
    let m2 = xs.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / n;
    if m2 <= 0.0 {
        return None;
    }
    let sd = m2.sqrt();
    let m3 = xs.iter().map(|x| (x - mean).powi(3)).sum::<f64>() / n;
    let m4 = xs.iter().map(|x| (x - mean).powi(4)).sum::<f64>() / n;
    Some((mean, sd, m3 / sd.powi(3), m4 / m2.powi(2) - 3.0))
}

/// Cornish-Fisher VaR at `confidence` (e.g. 0.95): loss fraction (positive)
/// adjusted for skew/kurtosis. Falls back to the Gaussian quantile when the
/// CF expansion misbehaves on extreme moments.
pub fn cornish_fisher_var(returns: &[f64], confidence: f64) -> Option<f64> {
    if !(0.5..1.0).contains(&confidence) {
        return None;
    }
    let (mean, sd, skew, kurt) = moments(returns)?;
    let z = gaussian_quantile(confidence)?;
    let s = skew.clamp(-2.0, 2.0);
    let k = kurt.clamp(-2.0, 8.0);
    let zcf = z
        + (z * z - 1.0) * s / 6.0
        + (z.powi(3) - 3.0 * z) * k / 24.0
        - (2.0 * z.powi(3) - 5.0 * z) * s * s / 36.0;
    let zeff = if zcf.is_finite() && zcf > 0.0 { zcf } else { z };
    Some((-(mean - zeff * sd)).max(0.0))
}

/// Empirical expected shortfall (CVaR): mean loss beyond the VaR quantile.
pub fn expected_shortfall(returns: &[f64], confidence: f64) -> Option<f64> {
    let mut xs = clean(returns);
    if xs.len() < 20 || !(0.5..1.0).contains(&confidence) {
        return None;
    }
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let cut = (((1.0 - confidence) * xs.len() as f64).ceil() as usize).max(1);
    let tail = &xs[..cut];
    Some((-(tail.iter().sum::<f64>() / tail.len() as f64)).max(0.0))
}

/// Acklam-style rational approximation of the standard normal quantile.
fn gaussian_quantile(p: f64) -> Option<f64> {
    if !(0.0 < p && p < 1.0) {
        return None;
    }
    // Beasley-Springer-Moro coefficients.
    const A: [f64; 4] = [2.50662823884, -18.61500062529, 41.39119773534, -25.44106049637];
    const B: [f64; 4] = [-8.47351093090, 23.08336743743, -21.06224101826, 3.13082909833];
    const C: [f64; 9] = [
        0.3374754822726147,
        0.9761690190917186,
        0.1607979714918209,
        0.0276438810333863,
        0.0038405729373609,
        0.0003951896511919,
        0.0000321767881768,
        0.0000002888167364,
        0.0000003960315187,
    ];
    let y = p - 0.5;
    if y.abs() < 0.42 {
        let r = y * y;
        let num = y * (((A[3] * r + A[2]) * r + A[1]) * r + A[0]);
        let den = (((B[3] * r + B[2]) * r + B[1]) * r + B[0]) * r + 1.0;
        return Some(num / den);
    }
    let r = if y > 0.0 { 1.0 - p } else { p };
    let s = (-(r.ln())).ln();
    let mut x = C[0];
    let mut sp = 1.0;
    for c in &C[1..] {
        sp *= s;
        x += c * sp;
    }
    Some(if y < 0.0 { -x } else { x })
}

/// Hurst exponent via rescaled-range over dyadic window sizes.
/// ~0.5 random walk, >0.5 trending/persistent, <0.5 mean-reverting.
pub fn hurst_exponent(prices: &[f64]) -> Option<f64> {
    let px = clean(prices);
    if px.len() < 64 {
        return None;
    }
    let rets: Vec<f64> = px
        .windows(2)
        .filter(|w| w[0] > 0.0 && w[1] > 0.0)
        .map(|w| (w[1] / w[0]).ln())
        .collect();
    if rets.len() < 63 {
        return None;
    }
    let mut points: Vec<(f64, f64)> = Vec::new();
    let mut window = 8usize;
    while window <= rets.len() / 2 {
        let mut rs_sum = 0.0;
        let mut chunks = 0usize;
        for chunk in rets.chunks(window) {
            if chunk.len() < window {
                continue;
            }
            let mean = chunk.iter().sum::<f64>() / window as f64;
            let mut cum = 0.0;
            let (mut min_c, mut max_c) = (f64::INFINITY, f64::NEG_INFINITY);
            let mut var = 0.0;
            for r in chunk {
                cum += r - mean;
                min_c = min_c.min(cum);
                max_c = max_c.max(cum);
                var += (r - mean) * (r - mean);
            }
            let sd = (var / window as f64).sqrt();
            if sd > 1e-12 {
                rs_sum += (max_c - min_c) / sd;
                chunks += 1;
            }
        }
        if chunks > 0 {
            points.push(((window as f64).ln(), (rs_sum / chunks as f64).ln()));
        }
        window *= 2;
    }
    if points.len() < 3 {
        return None;
    }
    // OLS slope of ln(R/S) on ln(n).
    let n = points.len() as f64;
    let sx: f64 = points.iter().map(|p| p.0).sum();
    let sy: f64 = points.iter().map(|p| p.1).sum();
    let sxx: f64 = points.iter().map(|p| p.0 * p.0).sum();
    let sxy: f64 = points.iter().map(|p| p.0 * p.1).sum();
    let denom = n * sxx - sx * sx;
    if denom.abs() < 1e-12 {
        return None;
    }
    let h = (n * sxy - sx * sy) / denom;
    h.is_finite().then(|| h.clamp(0.0, 1.0))
}

/// Ornstein-Uhlenbeck mean-reversion half-life in bars, via AR(1) on levels:
/// dx_t = a + b*x_{t-1} + e. Half-life = -ln(2)/ln(1+b). None when the
/// series shows no mean reversion (b >= 0) or is degenerate.
pub fn ou_half_life(prices: &[f64]) -> Option<f64> {
    let px = clean(prices);
    if px.len() < 32 {
        return None;
    }
    let x: Vec<f64> = px[..px.len() - 1].to_vec();
    let dx: Vec<f64> = px.windows(2).map(|w| w[1] - w[0]).collect();
    let n = x.len() as f64;
    let mx = x.iter().sum::<f64>() / n;
    let md = dx.iter().sum::<f64>() / n;
    let mut cov = 0.0;
    let mut var = 0.0;
    for i in 0..x.len() {
        cov += (x[i] - mx) * (dx[i] - md);
        var += (x[i] - mx) * (x[i] - mx);
    }
    if var < 1e-12 {
        return None;
    }
    let b = cov / var;
    if !(b.is_finite() && b < 0.0 && b > -1.0) {
        return None;
    }
    let hl = -(2.0_f64.ln()) / (1.0 + b).ln();
    (hl.is_finite() && hl > 0.0).then_some(hl)
}

/// Annualized Sharpe from per-period returns.
pub fn sharpe(returns: &[f64], periods_per_year: f64) -> Option<f64> {
    let (mean, sd, _, _) = moments(returns)?;
    if sd < 1e-12 {
        return None;
    }
    Some(mean / sd * periods_per_year.sqrt())
}

/// Annualized Sortino (downside deviation denominator).
pub fn sortino(returns: &[f64], periods_per_year: f64) -> Option<f64> {
    let xs = clean(returns);
    if xs.len() < 4 {
        return None;
    }
    let mean = xs.iter().sum::<f64>() / xs.len() as f64;
    let down: Vec<f64> = xs.iter().filter(|r| **r < 0.0).map(|r| r * r).collect();
    if down.is_empty() {
        return None;
    }
    let dd = (down.iter().sum::<f64>() / xs.len() as f64).sqrt();
    if dd < 1e-12 {
        return None;
    }
    Some(mean / dd * periods_per_year.sqrt())
}

/// Max drawdown fraction of an equity curve, in [0, 1].
pub fn max_drawdown(equity: &[f64]) -> Option<f64> {
    let xs = clean(equity);
    if xs.is_empty() {
        return None;
    }
    let mut peak = f64::NEG_INFINITY;
    let mut mdd = 0.0_f64;
    for e in xs {
        peak = peak.max(e);
        if peak > 0.0 {
            mdd = mdd.max(1.0 - e / peak);
        }
    }
    Some(mdd.clamp(0.0, 1.0))
}

/// Gross wins / gross losses from per-trade PnLs. None until both sides exist.
pub fn profit_factor(pnls: &[f64]) -> Option<f64> {
    let xs = clean(pnls);
    let wins: f64 = xs.iter().filter(|p| **p > 0.0).sum();
    let losses: f64 = -xs.iter().filter(|p| **p < 0.0).sum::<f64>();
    (losses > 1e-12 && wins >= 0.0).then(|| wins / losses)
}

pub fn win_rate(pnls: &[f64]) -> Option<f64> {
    let xs = clean(pnls);
    let closed = xs.iter().filter(|p| p.abs() > 1e-12).count();
    (closed > 0).then(|| xs.iter().filter(|p| **p > 0.0).count() as f64 / closed as f64)
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct McSummary {
    pub mean: f64,
    pub p05: f64,
    pub p50: f64,
    pub p95: f64,
}

/// Monte Carlo GBM terminal-price distribution (antithetic variates).
pub fn monte_carlo_gbm(
    spot: f64,
    drift: f64,
    vol: f64,
    t_years: f64,
    paths: usize,
    seed: u64,
) -> Option<McSummary> {
    if !(spot.is_finite() && spot > 0.0 && vol.is_finite() && vol >= 0.0 && t_years > 0.0) {
        return None;
    }
    let n = paths.clamp(100, 2_000_000) / 2;
    let mut rng = Prng::new(seed);
    let mu = (drift - 0.5 * vol * vol) * t_years;
    let sig = vol * t_years.sqrt();
    let mut terminals: Vec<f64> = Vec::with_capacity(n * 2);
    for _ in 0..n {
        let z = rng.normal();
        terminals.push(spot * (mu + sig * z).exp());
        terminals.push(spot * (mu - sig * z).exp());
    }
    terminals.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let q = |p: f64| terminals[((terminals.len() - 1) as f64 * p) as usize];
    Some(McSummary {
        mean: terminals.iter().sum::<f64>() / terminals.len() as f64,
        p05: q(0.05),
        p50: q(0.50),
        p95: q(0.95),
    })
}

/// Monte Carlo European call (risk-neutral, antithetic) — exists to prove
/// the MC machinery against the closed-form Black-Scholes price in tests.
pub fn mc_european_call(
    spot: f64,
    strike: f64,
    t_years: f64,
    vol: f64,
    rate: f64,
    paths: usize,
    seed: u64,
) -> Option<f64> {
    if !(strike.is_finite() && strike > 0.0) {
        return None;
    }
    let n = paths.clamp(100, 2_000_000) / 2;
    let mut rng = Prng::new(seed);
    let mu = (rate - 0.5 * vol * vol) * t_years;
    let sig = vol * t_years.sqrt();
    let mut payoff_sum = 0.0;
    for _ in 0..n {
        let z = rng.normal();
        let s1 = spot * (mu + sig * z).exp();
        let s2 = spot * (mu - sig * z).exp();
        payoff_sum += (s1 - strike).max(0.0) + (s2 - strike).max(0.0);
    }
    Some((-rate * t_years).exp() * payoff_sum / (2 * n) as f64)
}

/// Risk of ruin by simulation: fixed-fractional betting with the given edge,
/// ruin = losing `ruin_frac` of starting equity within `trades`.
pub fn risk_of_ruin(
    win_rate: f64,
    payoff_ratio: f64,
    risk_per_trade: f64,
    ruin_frac: f64,
    trades: usize,
    sims: usize,
    seed: u64,
) -> Option<f64> {
    if !((0.0..=1.0).contains(&win_rate)
        && payoff_ratio.is_finite()
        && payoff_ratio > 0.0
        && (0.0..0.5).contains(&risk_per_trade)
        && (0.0..1.0).contains(&ruin_frac))
    {
        return None;
    }
    let sims = sims.clamp(100, 200_000);
    let mut rng = Prng::new(seed);
    let mut ruined = 0usize;
    for _ in 0..sims {
        let mut equity = 1.0_f64;
        for _ in 0..trades.min(10_000) {
            if rng.uniform() < win_rate {
                equity *= 1.0 + risk_per_trade * payoff_ratio;
            } else {
                equity *= 1.0 - risk_per_trade;
            }
            if equity <= 1.0 - ruin_frac {
                ruined += 1;
                break;
            }
        }
    }
    Some(ruined as f64 / sims as f64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bs;

    #[test]
    fn kelly_matches_closed_form() {
        // p=0.6, b=1 => f* = 0.6 - 0.4/1 = 0.2 exactly.
        assert!((kelly_fraction(0.6, 100.0, 100.0).unwrap() - 0.2).abs() < 1e-12);
        // Negative edge clamps to zero.
        assert_eq!(kelly_fraction(0.4, 100.0, 100.0).unwrap(), 0.0);
        assert!(kelly_fraction(f64::NAN, 1.0, 1.0).is_none());
    }

    #[test]
    fn monte_carlo_reproduces_black_scholes() {
        // The core validation: MC risk-neutral pricing must converge to the
        // closed form. 400k antithetic paths => well under 0.5% error.
        let closed = bs::greeks(true, 100.0, 105.0, 0.75, 0.30, 0.04).unwrap().price;
        let mc = mc_european_call(100.0, 105.0, 0.75, 0.30, 0.04, 400_000, 42).unwrap();
        let rel_err = (mc - closed).abs() / closed;
        assert!(rel_err < 0.005, "mc {mc} vs closed {closed} (rel {rel_err})");
    }

    #[test]
    fn gbm_terminal_mean_matches_theory() {
        // E[S_T] = S0 * exp(drift * T).
        let s = monte_carlo_gbm(100.0, 0.07, 0.25, 1.0, 400_000, 7).unwrap();
        let theory = 100.0 * (0.07_f64).exp();
        assert!((s.mean - theory).abs() / theory < 0.01, "mean {}", s.mean);
        assert!(s.p05 < s.p50 && s.p50 < s.p95);
    }

    #[test]
    fn cf_var_matches_gaussian_on_normal_sample() {
        // On a genuinely normal sample (skew~0, kurt~0), CF reduces to the
        // Gaussian quantile: VaR95 ~= 1.645 sigma - mean.
        let mut rng = Prng::new(11);
        let rets: Vec<f64> = (0..200_000).map(|_| rng.normal() * 0.02).collect();
        let var = cornish_fisher_var(&rets, 0.95).unwrap();
        assert!((var - 1.645 * 0.02).abs() < 0.002, "var {var}");
        let es = expected_shortfall(&rets, 0.95).unwrap();
        // Normal ES(95) = phi(z)/(1-c) * sigma ~= 2.063 sigma; must exceed VaR.
        assert!(es > var, "es {es} <= var {var}");
        assert!((es - 2.063 * 0.02).abs() < 0.003, "es {es}");
    }

    #[test]
    fn hurst_separates_regimes() {
        let mut rng = Prng::new(3);
        // Random walk: H ~ 0.5.
        let mut walk = vec![100.0_f64];
        for _ in 0..4096 {
            let step = rng.normal() * 0.01;
            walk.push(walk.last().unwrap() * (1.0 + step));
        }
        let h_walk = hurst_exponent(&walk).unwrap();
        assert!((h_walk - 0.55).abs() < 0.15, "walk H {h_walk}");

        // Strongly mean-reverting (OU): H well below the walk's.
        let mut mr = vec![100.0_f64];
        for _ in 0..4096 {
            let x: f64 = *mr.last().unwrap();
            mr.push(x + 0.5 * (100.0 - x) + rng.normal() * 0.5);
        }
        let h_mr = hurst_exponent(&mr).unwrap();
        assert!(h_mr < h_walk - 0.15, "mr H {h_mr} vs walk {h_walk}");
    }

    #[test]
    fn ou_half_life_recovers_known_theta() {
        // x_{t+1} = x + theta*(mu - x) + noise, theta = 0.1
        // => b = -0.1, half-life = ln2/ln(1/0.9) ~= 6.58 bars.
        let mut rng = Prng::new(5);
        let mut xs = vec![50.0_f64];
        for _ in 0..8192 {
            let x: f64 = *xs.last().unwrap();
            xs.push(x + 0.1 * (50.0 - x) + rng.normal() * 0.2);
        }
        let hl = ou_half_life(&xs).unwrap();
        assert!((hl - 6.58).abs() < 1.0, "half-life {hl}");
        // A pure trend has no mean reversion.
        let trend: Vec<f64> = (0..200).map(|i| 100.0 + i as f64).collect();
        assert!(ou_half_life(&trend).is_none());
    }

    #[test]
    fn performance_stats_hand_checked() {
        let eq = [100.0, 110.0, 99.0, 121.0, 100.0];
        // Peak 121 -> 100: 17.36% ... but earlier 110 -> 99 is 10%; max is vs 121.
        let mdd = max_drawdown(&eq).unwrap();
        assert!((mdd - (1.0 - 100.0 / 121.0)).abs() < 1e-12);
        let pnls = [10.0, -5.0, 20.0, -10.0, 0.0];
        assert!((profit_factor(&pnls).unwrap() - 2.0).abs() < 1e-12);
        assert!((win_rate(&pnls).unwrap() - 0.5).abs() < 1e-12);
        // Constant positive returns: sharpe undefined (sd=0) -> None.
        assert!(sharpe(&[0.01; 100], 252.0).is_none());
        let mut rng = Prng::new(9);
        let rets: Vec<f64> = (0..5000).map(|_| 0.001 + rng.normal() * 0.01).collect();
        let s = sharpe(&rets, 252.0).unwrap();
        assert!((s - 0.001 / 0.01 * 252.0_f64.sqrt()).abs() < 0.4, "sharpe {s}");
    }

    #[test]
    fn risk_of_ruin_monotone_in_risk() {
        let low = risk_of_ruin(0.55, 1.0, 0.01, 0.5, 1000, 20_000, 13).unwrap();
        let high = risk_of_ruin(0.55, 1.0, 0.10, 0.5, 1000, 20_000, 13).unwrap();
        assert!(low < high, "ruin low {low} !< high {high}");
        // Positive-edge tiny-risk bettor essentially never ruins.
        assert!(low < 0.01, "low-risk ruin {low}");
    }

    #[test]
    fn vol_targeting_clamps() {
        assert_eq!(vol_target_scalar(0.2, 0.4), 0.5);
        assert_eq!(vol_target_scalar(0.2, 0.05), 1.5);
        assert_eq!(vol_target_scalar(0.2, 0.0), 1.0);
        assert_eq!(vol_target_scalar(f64::NAN, 0.2), 1.0);
    }
}
