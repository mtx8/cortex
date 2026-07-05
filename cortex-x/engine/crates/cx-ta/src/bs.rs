//! Black-Scholes pricing, greeks, and implied volatility. Pure math, fully
//! NaN-safe: any non-finite/degenerate input yields None rather than a
//! poisoned number. Rates are continuous, time in years, vol annualized.

/// Abramowitz-Stegun-quality normal CDF via erf; adequate for pricing UI
/// and agent context (abs err < 1.5e-7).
fn norm_cdf(x: f64) -> f64 {
    0.5 * (1.0 + erf(x / std::f64::consts::SQRT_2))
}

fn norm_pdf(x: f64) -> f64 {
    (-0.5 * x * x).exp() / (2.0 * std::f64::consts::PI).sqrt()
}

fn erf(x: f64) -> f64 {
    // Abramowitz & Stegun 7.1.26.
    let sign = if x < 0.0 { -1.0 } else { 1.0 };
    let x = x.abs();
    let t = 1.0 / (1.0 + 0.3275911 * x);
    let y = 1.0
        - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t
            + 0.254829592)
            * t
            * (-x * x).exp();
    sign * y
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Greeks {
    pub price: f64,
    pub delta: f64,
    pub gamma: f64,
    /// Per calendar day (already divided by 365).
    pub theta: f64,
    /// Per 1 vol point (already divided by 100).
    pub vega: f64,
}

fn valid(spot: f64, strike: f64, t_years: f64, vol: f64) -> bool {
    spot.is_finite()
        && strike.is_finite()
        && t_years.is_finite()
        && vol.is_finite()
        && spot > 0.0
        && strike > 0.0
        && t_years > 0.0
        && vol > 0.0
}

/// Black-Scholes price + greeks for a European option.
/// `is_call`: call vs put. `rate`: continuous risk-free (e.g. 0.043).
pub fn greeks(
    is_call: bool,
    spot: f64,
    strike: f64,
    t_years: f64,
    vol: f64,
    rate: f64,
) -> Option<Greeks> {
    if !valid(spot, strike, t_years, vol) || !rate.is_finite() {
        return None;
    }
    let sqrt_t = t_years.sqrt();
    let d1 = ((spot / strike).ln() + (rate + 0.5 * vol * vol) * t_years) / (vol * sqrt_t);
    let d2 = d1 - vol * sqrt_t;
    let disc = (-rate * t_years).exp();
    let (price, delta) = if is_call {
        (
            spot * norm_cdf(d1) - strike * disc * norm_cdf(d2),
            norm_cdf(d1),
        )
    } else {
        (
            strike * disc * norm_cdf(-d2) - spot * norm_cdf(-d1),
            norm_cdf(d1) - 1.0,
        )
    };
    let gamma = norm_pdf(d1) / (spot * vol * sqrt_t);
    let theta_year = -(spot * norm_pdf(d1) * vol) / (2.0 * sqrt_t)
        - if is_call {
            rate * strike * disc * norm_cdf(d2)
        } else {
            -rate * strike * disc * norm_cdf(-d2)
        };
    let vega = spot * norm_pdf(d1) * sqrt_t;
    let out = Greeks {
        price,
        delta,
        gamma,
        theta: theta_year / 365.0,
        vega: vega / 100.0,
    };
    [out.price, out.delta, out.gamma, out.theta, out.vega]
        .iter()
        .all(|v| v.is_finite())
        .then_some(out)
}

/// Implied vol from a market price: Newton with bisection fallback.
/// Returns vol in (0.001, 5.0) or None when the price is outside
/// no-arbitrage bounds or inputs are degenerate.
pub fn implied_vol(
    is_call: bool,
    market_px: f64,
    spot: f64,
    strike: f64,
    t_years: f64,
    rate: f64,
) -> Option<f64> {
    if !market_px.is_finite() || market_px <= 0.0 || !valid(spot, strike, t_years, 0.2) {
        return None;
    }
    let disc = (-rate * t_years).exp();
    let intrinsic = if is_call {
        (spot - strike * disc).max(0.0)
    } else {
        (strike * disc - spot).max(0.0)
    };
    let upper_bound = if is_call { spot } else { strike * disc };
    if market_px < intrinsic - 1e-9 || market_px > upper_bound + 1e-9 {
        return None;
    }

    let mut vol: f64 = 0.3;
    for _ in 0..24 {
        let g = greeks(is_call, spot, strike, t_years, vol, rate)?;
        let diff = g.price - market_px;
        if diff.abs() < 1e-6 {
            return Some(vol.clamp(0.001, 5.0));
        }
        let vega_raw = g.vega * 100.0;
        if vega_raw < 1e-10 {
            break;
        }
        let next = vol - diff / vega_raw;
        if !next.is_finite() {
            break;
        }
        vol = next.clamp(0.001, 5.0);
    }

    // Bisection fallback: price is monotone in vol.
    let (mut lo, mut hi) = (0.001_f64, 5.0_f64);
    for _ in 0..80 {
        let mid = 0.5 * (lo + hi);
        let px = greeks(is_call, spot, strike, t_years, mid, rate)?.price;
        if (px - market_px).abs() < 1e-6 {
            return Some(mid);
        }
        if px > market_px {
            hi = mid;
        } else {
            lo = mid;
        }
    }
    let mid = 0.5 * (lo + hi);
    ((0.001..=5.0).contains(&mid)).then_some(mid)
}

/// Year fraction from now (unix ms) to an expiry date "YYYY-MM-DD" assuming
/// a 16:00 US-eastern-ish close encoded as 21:00 UTC. Good enough for
/// display greeks on delayed data.
pub fn years_to_expiry(now_ms: i64, expiry: &str) -> Option<f64> {
    let mut parts = expiry.split('-');
    let y: i64 = parts.next()?.parse().ok()?;
    let m: i64 = parts.next()?.parse().ok()?;
    let d: i64 = parts.next()?.parse().ok()?;
    if !(1970..=2100).contains(&y) || !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    // Days since epoch via civil-from-days inverse (Howard Hinnant's algo).
    let yy = if m <= 2 { y - 1 } else { y };
    let era = if yy >= 0 { yy } else { yy - 399 } / 400;
    let yoe = yy - era * 400;
    let doy = (153 * (if m > 2 { m - 3 } else { m + 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let expiry_ms = days * 86_400_000 + 21 * 3_600_000;
    let dt_ms = expiry_ms - now_ms;
    if dt_ms <= 0 {
        return None;
    }
    Some(dt_ms as f64 / (365.0 * 86_400_000.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn call_price_matches_reference() {
        // S=100 K=100 t=1y vol=20% r=5%: canonical BS call ~10.4506.
        let g = greeks(true, 100.0, 100.0, 1.0, 0.20, 0.05).unwrap();
        assert!((g.price - 10.4506).abs() < 0.002, "price {}", g.price);
        assert!((g.delta - 0.6368).abs() < 0.002);
    }

    #[test]
    fn put_call_parity() {
        let c = greeks(true, 250.0, 240.0, 0.25, 0.35, 0.04).unwrap();
        let p = greeks(false, 250.0, 240.0, 0.25, 0.35, 0.04).unwrap();
        let parity = c.price - p.price - (250.0 - 240.0 * (-0.04_f64 * 0.25).exp());
        assert!(parity.abs() < 1e-6, "parity {parity}");
    }

    #[test]
    fn implied_vol_roundtrip() {
        let px = greeks(true, 100.0, 110.0, 0.5, 0.45, 0.03).unwrap().price;
        let iv = implied_vol(true, px, 100.0, 110.0, 0.5, 0.03).unwrap();
        assert!((iv - 0.45).abs() < 1e-3, "iv {iv}");
    }

    #[test]
    fn degenerate_inputs_are_none() {
        assert!(greeks(true, f64::NAN, 100.0, 1.0, 0.2, 0.05).is_none());
        assert!(greeks(true, 100.0, 100.0, -1.0, 0.2, 0.05).is_none());
        assert!(implied_vol(true, -5.0, 100.0, 100.0, 1.0, 0.05).is_none());
        // Below intrinsic: impossible price.
        assert!(implied_vol(true, 1.0, 100.0, 50.0, 0.5, 0.05).is_none());
    }

    #[test]
    fn expiry_year_fraction() {
        // 2026-07-05 00:00 UTC -> 2026-08-21 21:00 UTC ~ 47.875 days.
        let now_ms = 1_783_209_600_000_i64; // 2026-07-05T00:00:00Z
        let t = years_to_expiry(now_ms, "2026-08-21").unwrap();
        assert!((t * 365.0 - 47.875).abs() < 0.01, "days {}", t * 365.0);
        assert!(years_to_expiry(now_ms, "2020-01-01").is_none());
        assert!(years_to_expiry(now_ms, "garbage").is_none());
    }
}
