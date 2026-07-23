//! cx-intel — the intelligence squadron: COMPANY (supply-chain graph +
//! EDGAR fundamentals), REGIMES (bull/bear state board + breadth),
//! MERIDIAN (Dalio-style geopolitical cause-effect engine), and NEWS
//! (company/market headlines + filing-cadence earnings estimates).
//!
//! Bus-only IO like every squadron: depends on cx-core (+ pure cx-ta math),
//! publishes `EngineEvent::{Company, RegimeMap, Geo, Scan, News}` and
//! tighten-only cautions. All REST leaves through the hardened `Egress`
//! chokepoint.

pub mod causal_rules;
pub mod company;
pub mod filings;
pub mod meridian;
pub mod news;
pub mod regimes;
pub mod scanner;
pub mod short_interest;
pub mod splc_data;

use std::sync::Arc;

use cx_core::config::Config;
use cx_core::egress::Egress;
use cx_core::events::EngineEvent;
use cx_core::store::BarStore;
use cx_core::Bus;

/// Spawn the intel squadron's background tasks (REGIMES scanner + MERIDIAN
/// poller + SCANNER + NEWS poller). COMPANY is on-demand — dispatch
/// [`serve_company`] from the command loop instead.
pub fn start(
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    cfg: Config,
    short_interest: Arc<short_interest::ShortInterestStore>,
) {
    if cfg.intel.enable_regimes {
        regimes::spawn_scanner(Arc::clone(&bus), Arc::clone(&store), cfg.clone());
    }
    if cfg.intel.enable_meridian {
        meridian::spawn_poller(Arc::clone(&bus), cfg.clone());
    }
    if cfg.intel.enable_scanner {
        scanner::spawn_scanner(
            Arc::clone(&bus),
            Arc::clone(&store),
            cfg.clone(),
            Arc::clone(&short_interest),
        );
    }
    // FINRA short-interest refresh feeds the scanner AND the on-demand company
    // profile, so keep it warm whenever either consumer is enabled.
    if cfg.intel.enable_scanner || cfg.intel.enable_company {
        short_interest::spawn_refresh(Arc::clone(&short_interest));
    }
    if cfg.intel.enable_news {
        news::spawn_poller(Arc::clone(&bus), cfg.clone());
    }
}

/// Handle `Command::GetCompany`: build the profile (curated graph + EDGAR
/// fundamentals, each degrading independently) and publish it. Never errors
/// outward — an unfetchable side is disclosed in the profile's source labels.
pub fn serve_company(
    bus: Arc<Bus>,
    symbol: String,
    enabled: bool,
    short_interest: Arc<short_interest::ShortInterestStore>,
) {
    tokio::spawn(async move {
        if !enabled {
            // Still answer: a silent request leaves the client's loading
            // state hanging forever. Disclose the disabled state instead.
            bus.publish(EngineEvent::Company(company::disabled_profile(&symbol)));
            return;
        }
        let egress = Egress::new();
        let mut profile = company::fetch_company(&egress, &symbol).await;
        // Overlay real FINRA short interest (keyless) so Statistics can show a
        // true short % of float / days-to-cover; a symbol not in the snapshot
        // leaves the fields None (UI "—").
        if let Some(reading) = short_interest.get(&symbol) {
            company::apply_short_interest(&mut profile, &reading);
        }
        bus.publish(EngineEvent::Company(profile));
    });
}

/// Handle `Command::GetFilings`: browse a filer's SEC EDGAR filings (submissions
/// list, or a full-text search when `text` is set). Spawns, resolves the query,
/// fetches through the hardened egress, and publishes exactly one
/// `EngineEvent::Filings`. Never errors outward — an unresolved query or a
/// failed/degraded fetch is disclosed in the report's `note`.
pub fn serve_filings(bus: Arc<Bus>, query: String, form_filter: String, text: String) {
    filings::serve_filings(bus, query, form_filter, text);
}
