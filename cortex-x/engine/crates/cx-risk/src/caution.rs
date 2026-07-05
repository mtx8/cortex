//! Tighten-only caution book. Entries only ever SHRINK downstream sizing:
//! `caution_for` returns a value in [0, 1] which the engine maps to a
//! multiplier in [1 - max_shrink, 1]. TTL-bounded and capacity-bounded so a
//! chatty caution source can neither grow memory nor permanently wedge sizing.

use std::collections::VecDeque;

/// Hard cap on live entries; oldest evicted first.
const MAX_ENTRIES: usize = 512;

#[derive(Debug, Clone)]
struct CautionEntry {
    /// None = global scope (applies to every symbol).
    scope: Option<String>,
    /// Clamped to [0, 1] at insert.
    value: f64,
    reason: String,
    /// Unix ms; the entry is live while `now < expires_at`.
    expires_at: i64,
}

#[derive(Debug)]
pub(crate) struct CautionBook {
    entries: VecDeque<CautionEntry>,
    ttl_ms: i64,
}

impl CautionBook {
    pub(crate) fn new(ttl_secs: u64) -> Self {
        Self {
            entries: VecDeque::new(),
            ttl_ms: i64::try_from(ttl_secs)
                .unwrap_or(i64::MAX)
                .saturating_mul(1_000),
        }
    }

    /// Non-finite values are ignored; finite values clamp into [0, 1].
    pub(crate) fn set(&mut self, scope: Option<&str>, value: f64, reason: &str, now: i64) {
        if !value.is_finite() {
            return;
        }
        self.entries.retain(|e| e.expires_at > now);
        self.entries.push_back(CautionEntry {
            scope: scope.map(str::to_string),
            value: value.clamp(0.0, 1.0),
            reason: reason.to_string(),
            expires_at: now.saturating_add(self.ttl_ms),
        });
        while self.entries.len() > MAX_ENTRIES {
            self.entries.pop_front();
        }
    }

    /// Max of global and symbol-scoped live entries; 0 when none.
    pub(crate) fn caution_for(&self, symbol: &str, now: i64) -> f64 {
        self.live(now)
            .filter(|e| e.scope.as_deref().is_none_or(|s| s == symbol))
            .map(|e| e.value)
            .fold(0.0, f64::max)
    }

    /// Max over ALL live entries — the headline number in `RiskStatus`.
    pub(crate) fn global_max(&self, now: i64) -> f64 {
        self.live(now).map(|e| e.value).fold(0.0, f64::max)
    }

    /// Live reasons, deduped, insertion order.
    pub(crate) fn reasons(&self, now: i64) -> Vec<String> {
        let mut out: Vec<String> = Vec::new();
        for e in self.live(now) {
            if !out.iter().any(|r| r == &e.reason) {
                out.push(e.reason.clone());
            }
        }
        out
    }

    fn live(&self, now: i64) -> impl Iterator<Item = &CautionEntry> + '_ {
        self.entries.iter().filter(move |e| e.expires_at > now)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ttl_expiry_and_scope_isolation() {
        let mut book = CautionBook::new(60);
        book.set(Some("BTC-USD"), 0.8, "geo", 1_000);
        assert!((book.caution_for("BTC-USD", 30_000) - 0.8).abs() < 1e-12);
        // expires_at = 61_000; liveness requires now < expires_at.
        assert_eq!(book.caution_for("BTC-USD", 61_000), 0.0);
        // Symbol scope never bleeds into other symbols.
        assert_eq!(book.caution_for("ETH-USD", 30_000), 0.0);
    }

    #[test]
    fn global_scope_applies_to_all_symbols() {
        let mut book = CautionBook::new(60);
        book.set(None, 0.5, "macro", 0);
        book.set(Some("BTC-USD"), 0.2, "sym", 0);
        assert!((book.caution_for("BTC-USD", 1) - 0.5).abs() < 1e-12);
        assert!((book.caution_for("ETH-USD", 1) - 0.5).abs() < 1e-12);
        assert!((book.global_max(1) - 0.5).abs() < 1e-12);
    }

    #[test]
    fn non_finite_ignored_and_values_clamped() {
        let mut book = CautionBook::new(60);
        book.set(None, f64::NAN, "nan", 0);
        book.set(None, f64::INFINITY, "inf", 0);
        assert_eq!(book.global_max(1), 0.0);
        book.set(None, 7.5, "over", 0);
        assert!((book.global_max(1) - 1.0).abs() < 1e-12);
        book.set(Some("X"), -3.0, "under", 0);
        assert_eq!(book.caution_for("X", 1), 1.0); // global 1.0 still wins
    }

    #[test]
    fn capacity_evicts_oldest() {
        let mut book = CautionBook::new(3_600);
        book.set(None, 1.0, "oldest", 0);
        for _ in 0..512 {
            book.set(Some("X"), 0.1, "spam", 1);
        }
        // The 513th insert evicted the oldest (global 1.0) entry.
        assert!((book.global_max(2) - 0.1).abs() < 1e-12);
    }

    #[test]
    fn reasons_dedup_live_only() {
        let mut book = CautionBook::new(60);
        book.set(None, 0.3, "geo", 0);
        book.set(Some("BTC-USD"), 0.4, "geo", 0);
        book.set(Some("ETH-USD"), 0.2, "vol", 0);
        assert_eq!(book.reasons(1), vec!["geo".to_string(), "vol".to_string()]);
    }
}
