//! The MERIDIAN rulebook: hand-written Dalio-style transmission chains.
//! A rule fires when its theme's 24h article intensity z-scores above
//! threshold; the chain then names the mechanism and the pressured assets.
//! Curated and labeled as such — no fake precision.

/// One static rule: theme bucket -> chain title, mechanism steps, and
/// (target, direction, note) asset pressures.
pub struct CausalRule {
    pub rule_id: &'static str,
    pub theme: &'static str,
    pub title: &'static str,
    pub steps: &'static [&'static str],
    /// (target ticker-or-class, +1 up / -1 down, note)
    pub assets: &'static [(&'static str, i32, &'static str)],
}

/// Fire threshold: 24h article-count z-score vs the 30-day baseline.
pub const FIRE_Z: f64 = 1.5;

/// The full rulebook (~25 rules across the eight MERIDIAN themes).
pub fn rules() -> &'static [CausalRule] {
    // Implemented by the meridian build task (agent D).
    &[]
}
