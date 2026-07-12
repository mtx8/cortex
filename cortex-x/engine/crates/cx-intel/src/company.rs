//! COMPANY: merge the curated supply-chain graph with live SEC EDGAR
//! fundamentals into one `CompanyProfile`.
//!
//! EDGAR endpoints (keyless, UA identifies the client):
//!   https://www.sec.gov/files/company_tickers.json         ticker -> CIK
//!   https://data.sec.gov/api/xbrl/companyfacts/CIK{10}.json  us-gaap facts
//!
//! Both sides degrade independently: no curated entry -> honest
//! "no curated graph"; EDGAR unreachable/unknown ticker -> fundamentals
//! stay None with `fundamentals_source: "unavailable"`.

use cx_core::egress::Egress;
use cx_core::events::CompanyProfile;
use cx_core::time::now_ms;

use crate::splc_data;

/// Build the full profile for `symbol`. Infallible by design: always returns
/// a profile, with source labels disclosing exactly what was available.
pub async fn fetch_company(egress: &Egress, symbol: &str) -> CompanyProfile {
    let symbol = symbol.trim().to_uppercase();
    let mut profile = splc_data::curated(&symbol).unwrap_or_else(|| minimal_profile(&symbol));

    if is_equity(&symbol) {
        match fetch_fundamentals(egress, &symbol).await {
            Ok(Some(f)) => {
                profile.fundamentals = Some(f);
                profile.fundamentals_source = "sec-edgar (10-K/10-Q)".into();
            }
            Ok(None) => profile.fundamentals_source = "unavailable (not an SEC filer)".into(),
            Err(e) => {
                tracing::warn!(symbol = %symbol, error = %e, "edgar fetch failed");
                profile.fundamentals_source = "unavailable (fetch failed)".into();
            }
        }
    }
    profile.ts_ms = now_ms();
    profile
}

fn is_equity(symbol: &str) -> bool {
    !symbol.contains('-')
}

/// Honest fallback card when a symbol has no curated graph entry.
fn minimal_profile(symbol: &str) -> CompanyProfile {
    let crypto = symbol.contains('-');
    CompanyProfile {
        symbol: symbol.to_string(),
        name: symbol.to_string(),
        sector: if crypto { "digital assets".into() } else { String::new() },
        industry: String::new(),
        country: String::new(),
        description: if crypto {
            "Crypto asset — supply-chain analysis does not apply.".into()
        } else {
            String::new()
        },
        segments: Vec::new(),
        suppliers: Vec::new(),
        customers: Vec::new(),
        competitors: Vec::new(),
        fundamentals: None,
        graph_source: "no curated graph".into(),
        fundamentals_source: "unavailable".into(),
        ts_ms: 0,
    }
}

/// Latest annual + quarterly fundamentals from EDGAR company facts.
/// `Ok(None)` when the ticker is not in the SEC map.
pub async fn fetch_fundamentals(
    _egress: &Egress,
    _symbol: &str,
) -> Result<Option<cx_core::events::Fundamentals>, cx_core::error::CxError> {
    // Implemented by the company-intel build task (agent C): CIK lookup with
    // 24h in-process cache, companyfacts fetch, us-gaap tag extraction,
    // margin/YoY computation, strict NaN firewall.
    Ok(None)
}
