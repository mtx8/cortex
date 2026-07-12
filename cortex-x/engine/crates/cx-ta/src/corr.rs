//! EWMA (lambda = 0.97) pairwise return-correlation tracking across a symbol
//! set, built for correlation-aware position sizing: how crowded is a
//! candidate against the symbols already held?
//!
//! Asynchronous-clock design: symbols post completed-bar returns on their own
//! clocks (crypto runs 24/7, equities keep RTH), so there is no global "bar
//! close" to batch on. [`EwmaCorr::update`] therefore uses
//! most-recent-observation pairing — a pair's EWMA moments update only when
//! BOTH symbols have posted a NEW return since that pair's last update, each
//! return consumed at most once per pair. A slow symbol pairs each of its
//! returns with the fast symbol's latest; symbols that never overlap simply
//! never form a pair and read `None` (honest absence, never a fabricated
//! correlation). Moments are zero-mean RiskMetrics style (returns are
//! near-zero-mean at bar horizon); cov and both variances update on the same
//! paired sequence with the same decay, so Cauchy-Schwarz bounds the
//! correlation to [-1, 1] by construction. NaN-safe throughout.

use std::collections::BTreeMap;

/// Decay for the pairwise EWMA return moments.
const DEFAULT_LAMBDA: f64 = 0.97;
/// Paired observations required before a correlation is trusted.
const MIN_PAIR_OBS: u32 = 10;

#[derive(Debug, Clone, Copy)]
struct SymState {
    last_ret: f64,
    epoch: u64,
}

#[derive(Debug, Clone, Copy, Default)]
struct PairState {
    cov: f64,
    var_a: f64,
    var_b: f64,
    obs: u32,
    /// Epoch of each side's return at the pair's last update; a side must
    /// move past this before the pair may update again.
    epoch_a: u64,
    epoch_b: u64,
}

/// Streaming EWMA correlation matrix over a dynamic symbol set.
#[derive(Debug, Clone)]
pub struct EwmaCorr {
    lambda: f64,
    syms: BTreeMap<String, SymState>,
    /// Keyed by lexicographically ordered symbol pair.
    pairs: BTreeMap<(String, String), PairState>,
}

impl EwmaCorr {
    pub fn new() -> Self {
        Self::with_lambda(DEFAULT_LAMBDA)
    }

    /// Custom decay in (0.5, 1); falls back to 0.97 otherwise.
    pub fn with_lambda(lambda: f64) -> Self {
        let lambda = if lambda.is_finite() && (0.5..1.0).contains(&lambda) {
            lambda
        } else {
            DEFAULT_LAMBDA
        };
        Self {
            lambda,
            syms: BTreeMap::new(),
            pairs: BTreeMap::new(),
        }
    }

    /// Record one completed-bar return for `symbol`. Non-finite returns are
    /// skipped entirely (no state advances). O(number of symbols).
    pub fn update(&mut self, symbol: &str, ret: f64) {
        if !ret.is_finite() {
            return;
        }
        let epoch = {
            let st = self
                .syms
                .entry(symbol.to_string())
                .or_insert(SymState { last_ret: ret, epoch: 0 });
            st.epoch += 1;
            st.last_ret = ret;
            st.epoch
        };
        // Snapshot the counterparties, then fold this return into every pair
        // where both sides have fresh (not-yet-consumed) returns.
        let others: Vec<(String, f64, u64)> = self
            .syms
            .iter()
            .filter(|(s, _)| s.as_str() != symbol)
            .map(|(s, st)| (s.clone(), st.last_ret, st.epoch))
            .collect();
        for (other, other_ret, other_epoch) in others {
            let sym_is_a = symbol < other.as_str();
            let key = if sym_is_a {
                (symbol.to_string(), other.clone())
            } else {
                (other.clone(), symbol.to_string())
            };
            let p = self.pairs.entry(key).or_default();
            let (my_seen, their_seen) = if sym_is_a {
                (p.epoch_a, p.epoch_b)
            } else {
                (p.epoch_b, p.epoch_a)
            };
            if epoch <= my_seen || other_epoch <= their_seen {
                continue;
            }
            let (ra, rb) = if sym_is_a {
                (ret, other_ret)
            } else {
                (other_ret, ret)
            };
            if p.obs == 0 {
                p.cov = ra * rb;
                p.var_a = ra * ra;
                p.var_b = rb * rb;
            } else {
                let l = self.lambda;
                p.cov = l * p.cov + (1.0 - l) * ra * rb;
                p.var_a = l * p.var_a + (1.0 - l) * ra * ra;
                p.var_b = l * p.var_b + (1.0 - l) * rb * rb;
            }
            p.obs = p.obs.saturating_add(1);
            if sym_is_a {
                p.epoch_a = epoch;
                p.epoch_b = other_epoch;
            } else {
                p.epoch_a = other_epoch;
                p.epoch_b = epoch;
            }
        }
    }

    /// EWMA correlation of a symbol pair in [-1, 1]. `None` until the pair
    /// has [`MIN_PAIR_OBS`] paired observations, for a symbol paired with
    /// itself, or when a variance is degenerate.
    pub fn pair_corr(&self, a: &str, b: &str) -> Option<f64> {
        if a == b {
            return None;
        }
        let key = if a < b {
            (a.to_string(), b.to_string())
        } else {
            (b.to_string(), a.to_string())
        };
        let p = self.pairs.get(&key)?;
        if p.obs < MIN_PAIR_OBS {
            return None;
        }
        let denom = (p.var_a * p.var_b).sqrt();
        if !denom.is_finite() || denom < 1e-18 {
            return None;
        }
        let c = p.cov / denom;
        c.is_finite().then(|| c.clamp(-1.0, 1.0))
    }

    /// Mean EWMA correlation of `candidate` against the held symbols —
    /// the crowding read used by correlation-aware sizing. Pairs without
    /// enough shared history are skipped (never guessed); `None` when no
    /// usable pair exists. `candidate` itself is excluded from `held`.
    pub fn avg_corr(&self, candidate: &str, held: &[String]) -> Option<f64> {
        let mut sum = 0.0;
        let mut n = 0usize;
        for h in held {
            if h == candidate {
                continue;
            }
            if let Some(c) = self.pair_corr(candidate, h) {
                sum += c;
                n += 1;
            }
        }
        (n > 0).then(|| sum / n as f64)
    }
}

impl Default for EwmaCorr {
    fn default() -> Self {
        Self::new()
    }
}

/// Diversification multiplier for position sizing: `1 / (1 + max(0,
/// avg_corr))`, clamped to [0.5, 1.0] and defaulting to 1.0 on missing or
/// non-finite input. Tighten-only by construction — this can shrink a
/// position for crowding, it can NEVER grow one (negative correlation is a
/// bonus we decline to spend).
pub fn diversification_scalar(avg_corr: Option<f64>) -> f64 {
    match avg_corr {
        Some(c) if c.is_finite() => (1.0 / (1.0 + c.max(0.0))).clamp(0.5, 1.0),
        _ => 1.0,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::quant::Prng;

    #[test]
    fn perfectly_correlated_pair_reads_one() {
        let mut ec = EwmaCorr::new();
        let mut rng = Prng::new(2);
        for _ in 0..300 {
            let r = rng.normal() * 0.01;
            ec.update("AAA", r);
            ec.update("BBB", r);
        }
        let c = ec.pair_corr("AAA", "BBB").unwrap();
        assert!(c > 0.99, "corr {c}");
        // Symmetric lookup.
        assert_eq!(ec.pair_corr("BBB", "AAA"), Some(c));
    }

    #[test]
    fn anti_correlated_pair_reads_minus_one() {
        let mut ec = EwmaCorr::new();
        let mut rng = Prng::new(4);
        for _ in 0..300 {
            let r = rng.normal() * 0.01;
            ec.update("AAA", r);
            ec.update("BBB", -r);
        }
        let c = ec.pair_corr("AAA", "BBB").unwrap();
        assert!(c < -0.99, "corr {c}");
    }

    #[test]
    fn independent_pair_reads_near_zero() {
        let mut ec = EwmaCorr::new();
        let mut rng = Prng::new(6);
        for _ in 0..2000 {
            ec.update("AAA", rng.normal() * 0.01);
            ec.update("BBB", rng.normal() * 0.01);
        }
        let c = ec.pair_corr("AAA", "BBB").unwrap();
        assert!(c.abs() < 0.25, "corr {c}");
    }

    #[test]
    fn different_bar_clocks_still_pair() {
        // BBB posts a bar every third AAA bar; the pair updates on BBB's
        // clock using AAA's latest return — still reads the co-movement.
        let mut ec = EwmaCorr::new();
        let mut rng = Prng::new(8);
        for i in 0..300 {
            let r = rng.normal() * 0.01;
            ec.update("AAA", r);
            if i % 3 == 0 {
                ec.update("BBB", r);
            }
        }
        let c = ec.pair_corr("AAA", "BBB").unwrap();
        assert!(c > 0.99, "corr {c}");
    }

    #[test]
    fn pair_gated_until_min_observations() {
        let mut ec = EwmaCorr::new();
        for i in 0..(MIN_PAIR_OBS as usize - 1) {
            let r = 0.01 * ((i % 5) as f64 - 2.0);
            ec.update("AAA", r);
            ec.update("BBB", r);
        }
        assert_eq!(ec.pair_corr("AAA", "BBB"), None);
        assert_eq!(ec.pair_corr("AAA", "AAA"), None, "self pair must be None");
        assert_eq!(ec.pair_corr("AAA", "ZZZ"), None, "unknown symbol");
    }

    #[test]
    fn nan_updates_are_ignored() {
        let mut ec = EwmaCorr::new();
        let mut rng = Prng::new(10);
        for _ in 0..100 {
            let r = rng.normal() * 0.01;
            ec.update("AAA", r);
            ec.update("BBB", r);
        }
        let before = ec.pair_corr("AAA", "BBB").unwrap();
        ec.update("AAA", f64::NAN);
        ec.update("BBB", f64::INFINITY);
        ec.update("CCC", f64::NAN);
        assert_eq!(ec.pair_corr("AAA", "BBB"), Some(before));
        assert_eq!(ec.pair_corr("AAA", "CCC"), None);
        assert!(before.is_finite());
    }

    #[test]
    fn avg_corr_averages_over_held_book() {
        let mut ec = EwmaCorr::new();
        let mut rng = Prng::new(12);
        for _ in 0..300 {
            let r = rng.normal() * 0.01;
            ec.update("AAA", r);
            ec.update("BBB", r); // corr +1 with AAA
            ec.update("CCC", -r); // corr -1 with AAA
        }
        let held = vec!["BBB".to_string(), "CCC".to_string()];
        let avg = ec.avg_corr("AAA", &held).unwrap();
        assert!(avg.abs() < 0.01, "avg {avg}");
        let only_b = vec!["BBB".to_string()];
        assert!(ec.avg_corr("AAA", &only_b).unwrap() > 0.99);
        // Unknown held symbols are skipped, not guessed.
        let unknown = vec!["ZZZ".to_string()];
        assert_eq!(ec.avg_corr("AAA", &unknown), None);
        assert_eq!(ec.avg_corr("AAA", &[]), None);
        // Candidate never correlates with itself.
        let self_only = vec!["AAA".to_string()];
        assert_eq!(ec.avg_corr("AAA", &self_only), None);
    }

    #[test]
    fn diversification_scalar_is_tighten_only() {
        // The sizing multiplier can NEVER grow a position: <= 1 everywhere,
        // floored at 0.5, and 1.0 on missing/garbage input.
        let mut c = -2.0;
        while c <= 2.0 {
            let s = diversification_scalar(Some(c));
            assert!((0.5..=1.0).contains(&s), "scalar {s} at corr {c}");
            c += 0.1;
        }
        assert_eq!(diversification_scalar(None), 1.0);
        assert_eq!(diversification_scalar(Some(f64::NAN)), 1.0);
        assert_eq!(diversification_scalar(Some(f64::INFINITY)), 1.0);
        assert_eq!(diversification_scalar(Some(0.0)), 1.0);
        assert_eq!(diversification_scalar(Some(-0.8)), 1.0);
        assert_eq!(diversification_scalar(Some(1.0)), 0.5);
        assert!((diversification_scalar(Some(0.5)) - 1.0 / 1.5).abs() < 1e-12);
        // Beyond-1 garbage still floors at 0.5.
        assert_eq!(diversification_scalar(Some(5.0)), 0.5);
    }
}
