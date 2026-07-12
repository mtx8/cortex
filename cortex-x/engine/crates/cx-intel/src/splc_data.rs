//! Curated supply-chain graph — the hand-maintained SPLC dataset.
//! Source label: "curated graph (MTX Labs, 2026-07)". Honesty rule: this is
//! research seed data, not a live feed, and it says so in every profile.

use cx_core::events::CompanyProfile;

pub const GRAPH_SOURCE: &str = "curated graph (MTX Labs, 2026-07)";

/// Curated profile (graph half only — fundamentals arrive from EDGAR).
/// Returns None for symbols outside the curated set.
pub fn curated(symbol: &str) -> Option<CompanyProfile> {
    // Implemented by the company-intel build task (agent C): ~60 major
    // tickers with segments, suppliers, customers, competitors.
    let _ = symbol;
    None
}
