//! Maritime physical-alpha: AIS ship-type categorization and the supply-flow
//! signals CORTEX trades on — floating-storage index and chokepoint congestion.
//!
//! These functions front-run official EIA/API inventory prints by 1–7 days. They
//! are *leading indicators* that feed the strategic cycle; they never trigger
//! naked execution (that stays behind the kill switch + autonomy dial in Python).

use crate::geo::{chokepoint_at_inner, chokepoint_index_inner, CHOKEPOINTS};
use pyo3::prelude::*;
use pyo3::types::PyDict;

/// AIS ship-type code → broad category. Per ITU-R M.1371, 80–89 are tankers.
pub fn ship_category(ship_type: u32) -> &'static str {
    match ship_type {
        20..=29 => "wing-in-ground",
        30 => "fishing",
        31..=32 => "towing",
        36 => "sailing",
        37 => "pleasure",
        40..=49 => "high-speed",
        50 => "pilot",
        51 => "search-and-rescue",
        52 => "tug",
        55 => "law-enforcement",
        60..=69 => "passenger",
        70..=79 => "cargo",
        80..=89 => "tanker",
        90..=99 => "other",
        _ => "unknown",
    }
}

/// True for tankers (AIS ship-type 80–89) — the crude/products carriers.
pub fn is_tanker_inner(ship_type: u32) -> bool {
    (80..=89).contains(&ship_type)
}

// ---------------------------------------------------------------------------
// PyO3: Vessel
// ---------------------------------------------------------------------------

/// A single AIS vessel observation.
#[pyclass]
#[derive(Clone)]
pub struct Vessel {
    #[pyo3(get)]
    pub mmsi: u64,
    #[pyo3(get)]
    pub lat: f64,
    #[pyo3(get)]
    pub lon: f64,
    #[pyo3(get)]
    pub speed_knots: f64,
    #[pyo3(get)]
    pub heading: f64,
    #[pyo3(get)]
    pub ship_type: u32,
    #[pyo3(get)]
    pub name: String,
    #[pyo3(get)]
    pub draught: f64,
    #[pyo3(get)]
    pub timestamp_ms: i64,
}

#[pymethods]
impl Vessel {
    #[new]
    #[pyo3(signature = (mmsi, lat, lon, speed_knots=0.0, heading=0.0, ship_type=0, name=String::new(), draught=0.0, timestamp_ms=0))]
    #[allow(clippy::too_many_arguments)]
    fn new(
        mmsi: u64,
        lat: f64,
        lon: f64,
        speed_knots: f64,
        heading: f64,
        ship_type: u32,
        name: String,
        draught: f64,
        timestamp_ms: i64,
    ) -> Self {
        Vessel { mmsi, lat, lon, speed_knots, heading, ship_type, name, draught, timestamp_ms }
    }

    /// Broad AIS category ("tanker", "cargo", …).
    #[getter]
    fn category(&self) -> &'static str {
        ship_category(self.ship_type)
    }

    /// Is this a tanker (crude/products carrier)?
    #[getter]
    fn is_tanker(&self) -> bool {
        is_tanker_inner(self.ship_type)
    }

    /// Chokepoint the vessel currently sits in, if any.
    #[getter]
    fn chokepoint(&self) -> Option<String> {
        chokepoint_at_inner(self.lat, self.lon).map(|c| c.name.to_string())
    }

    fn __repr__(&self) -> String {
        format!(
            "Vessel(mmsi={}, {}, {:.3},{:.3}, {:.1}kn)",
            self.mmsi,
            ship_category(self.ship_type),
            self.lat,
            self.lon,
            self.speed_knots
        )
    }
}

// ---------------------------------------------------------------------------
// Physical-alpha signals
// ---------------------------------------------------------------------------

/// True if a tanker observation looks like *floating storage*: laden (drifting
/// loaded, i.e. low draught flag false), effectively stationary (< 0.5 kn), and
/// idle long enough (> 7 days) to be storing rather than transiting.
fn is_floating_storage(speed_knots: f64, hours_idle: f64, laden: bool) -> bool {
    laden && speed_knots < 0.5 && hours_idle > 168.0
}

/// FLOATING-STORAGE INDEX. Takes parallel arrays (one element per laden tanker
/// candidate) and returns a dict {count, total, index_score}. A rising index is
/// bearish crude / bullish VLCC day-rates. `index_score` is count normalised to
/// 0..100 against a configurable saturation (`saturation` candidates → 100).
#[pyfunction]
#[pyo3(signature = (speeds_knots, hours_idle, laden, saturation=120.0))]
pub fn floating_storage_index(
    py: Python<'_>,
    speeds_knots: Vec<f64>,
    hours_idle: Vec<f64>,
    laden: Vec<bool>,
    saturation: f64,
) -> PyResult<Py<PyDict>> {
    let n = speeds_knots.len().min(hours_idle.len()).min(laden.len());
    let mut count = 0usize;
    for i in 0..n {
        if is_floating_storage(speeds_knots[i], hours_idle[i], laden[i]) {
            count += 1;
        }
    }
    let sat = if saturation <= 0.0 { 1.0 } else { saturation };
    let index_score = ((count as f64 / sat) * 100.0).min(100.0);
    let d = PyDict::new(py);
    d.set_item("count", count)?;
    d.set_item("total", n)?;
    d.set_item("index_score", index_score)?;
    d.set_item("bias", if index_score >= 50.0 { "bearish_crude" } else { "neutral" })?;
    Ok(d.unbind())
}

/// CHOKEPOINT CONGESTION. Given parallel vessel arrays, geofence each into a
/// world chokepoint and return per-chokepoint {name, vessel_count, tanker_count,
/// avg_speed_knots, throughput_mbd, congestion_score}. A high count + low avg
/// speed = a queue forming = supply-disruption premium into crude. Only
/// chokepoints with at least one vessel are returned.
#[pyfunction]
pub fn chokepoint_congestion(
    py: Python<'_>,
    lats: Vec<f64>,
    lons: Vec<f64>,
    speeds_knots: Vec<f64>,
    ship_types: Vec<u32>,
) -> PyResult<Vec<Py<PyDict>>> {
    let n = lats
        .len()
        .min(lons.len())
        .min(speeds_knots.len())
        .min(ship_types.len());

    // Accumulators indexed parallel to CHOKEPOINTS.
    let mut counts = vec![0usize; CHOKEPOINTS.len()];
    let mut tankers = vec![0usize; CHOKEPOINTS.len()];
    let mut speed_sum = vec![0.0f64; CHOKEPOINTS.len()];

    for i in 0..n {
        if let Some(idx) = chokepoint_index_inner(lats[i], lons[i]) {
            counts[idx] += 1;
            speed_sum[idx] += speeds_knots[i];
            if is_tanker_inner(ship_types[i]) {
                tankers[idx] += 1;
            }
        }
    }

    let mut out = Vec::new();
    for (idx, c) in CHOKEPOINTS.iter().enumerate() {
        if counts[idx] == 0 {
            continue;
        }
        let avg_speed = speed_sum[idx] / counts[idx] as f64;
        // Congestion rises with vessel count and falls with avg transit speed,
        // weighted by the chokepoint's oil throughput (a queue at Hormuz matters
        // far more than at Panama). Bounded to 0..100.
        let speed_factor = (1.0 - (avg_speed / 12.0)).clamp(0.0, 1.0); // 12 kn ≈ free transit
        let density = (counts[idx] as f64 / 25.0).min(1.0); // 25 vessels ≈ saturated
        let weight = (c.throughput_mbd / 20.5).min(1.0); // Hormuz = 1.0
        let congestion_score = (density * 0.5 + speed_factor * 0.5) * weight * 100.0;

        let d = PyDict::new(py);
        d.set_item("name", c.name)?;
        d.set_item("vessel_count", counts[idx])?;
        d.set_item("tanker_count", tankers[idx])?;
        d.set_item("avg_speed_knots", avg_speed)?;
        d.set_item("throughput_mbd", c.throughput_mbd)?;
        d.set_item("congestion_score", congestion_score)?;
        out.push(d.unbind());
    }
    Ok(out)
}

/// Broad AIS category for a ship-type code.
#[pyfunction]
pub fn ship_type_category(ship_type: u32) -> String {
    ship_category(ship_type).to_string()
}

/// True for tanker ship-types (80–89).
#[pyfunction]
pub fn is_tanker(ship_type: u32) -> bool {
    is_tanker_inner(ship_type)
}

pub fn register(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<Vessel>()?;
    m.add_function(wrap_pyfunction!(floating_storage_index, m)?)?;
    m.add_function(wrap_pyfunction!(chokepoint_congestion, m)?)?;
    m.add_function(wrap_pyfunction!(ship_type_category, m)?)?;
    m.add_function(wrap_pyfunction!(is_tanker, m)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn tanker_categorization() {
        assert!(is_tanker_inner(80));
        assert!(is_tanker_inner(89));
        assert!(!is_tanker_inner(70)); // cargo
        assert_eq!(ship_category(80), "tanker");
        assert_eq!(ship_category(70), "cargo");
        assert_eq!(ship_category(60), "passenger");
    }

    #[test]
    fn floating_storage_thresholds() {
        // laden + drifting + idle 10 days = storage; moving or short-idle is not.
        assert!(is_floating_storage(0.2, 240.0, true));
        assert!(!is_floating_storage(5.0, 240.0, true)); // moving
        assert!(!is_floating_storage(0.2, 24.0, true)); // only 1 day idle
        assert!(!is_floating_storage(0.2, 240.0, false)); // ballast, not laden
    }
}
