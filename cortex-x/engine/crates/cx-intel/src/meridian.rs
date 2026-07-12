//! MERIDIAN — the Dalio section. Geopolitical events (GDELT 2.0 DOC API,
//! keyless) -> theme buckets -> Five Forces gauges + fired causal chains.
//! Publishes `EngineEvent::Geo`; elevated external-conflict feeds a
//! tighten-only global caution, the same channel the macro sentinel uses.

use std::sync::Arc;

use cx_core::config::Config;
use cx_core::egress::Egress;
use cx_core::events::{EngineEvent, GeoPulse};
use cx_core::Bus;

/// Spawn the periodic GDELT poller (cadence `intel.gdelt_poll_secs`).
pub fn spawn_poller(bus: Arc<Bus>, cfg: Config) {
    tokio::spawn(async move {
        let cadence = std::time::Duration::from_secs(cfg.intel.gdelt_poll_secs.max(300));
        let egress = Egress::new();
        let mut state = MeridianState::default();
        loop {
            match poll(&egress, &mut state).await {
                Some(pulse) => bus.publish(EngineEvent::Geo(pulse)),
                None => tracing::debug!("meridian: no pulse this cycle"),
            }
            tokio::time::sleep(cadence).await;
        }
    });
}

/// Rolling MERIDIAN state: per-theme article baselines, tone EWMAs, event
/// ring, macro inputs for the debt/money force.
#[derive(Default)]
pub struct MeridianState {
    // Implemented by the meridian build task (agent D).
}

/// One poll cycle: query GDELT per theme, dedupe, update gauges, fire rules.
/// None when every fetch failed (degradation is silent but logged).
pub async fn poll(egress: &Egress, state: &mut MeridianState) -> Option<GeoPulse> {
    // Implemented by the meridian build task (agent D).
    let _ = (egress, state);
    None
}
