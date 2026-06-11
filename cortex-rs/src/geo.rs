//! Geospatial primitives + the world's maritime chokepoints.
//!
//! Pure, allocation-light math (great-circle distance, bbox/radius containment)
//! plus a curated table of the oil-flow chokepoints whose congestion CORTEX
//! trades on. Exposed to Python via PyO3.

use pyo3::prelude::*;
use pyo3::types::PyDict;

const EARTH_RADIUS_KM: f64 = 6371.0088;

/// Great-circle (haversine) distance between two lat/lon points, in kilometres.
pub fn haversine_km_inner(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    let (p1, p2) = (lat1.to_radians(), lat2.to_radians());
    let dlat = (lat2 - lat1).to_radians();
    let dlon = (lon2 - lon1).to_radians();
    let a = (dlat / 2.0).sin().powi(2) + p1.cos() * p2.cos() * (dlon / 2.0).sin().powi(2);
    2.0 * EARTH_RADIUS_KM * a.sqrt().asin()
}

/// A maritime chokepoint: name, centre, an effective radius for the geofence,
/// and the approximate crude/products throughput in million barrels/day (mb/d),
/// used to weight the supply-disruption premium when the zone congests.
pub struct Chokepoint {
    pub name: &'static str,
    pub lat: f64,
    pub lon: f64,
    pub radius_km: f64,
    pub throughput_mbd: f64,
}

/// The chokepoints that move oil. Throughput figures are public EIA estimates.
pub const CHOKEPOINTS: &[Chokepoint] = &[
    Chokepoint { name: "Strait of Hormuz",   lat: 26.57, lon: 56.25,  radius_km: 90.0,  throughput_mbd: 20.5 },
    Chokepoint { name: "Strait of Malacca",  lat: 2.50,  lon: 101.50, radius_km: 160.0, throughput_mbd: 16.0 },
    Chokepoint { name: "Suez Canal / SUMED", lat: 30.50, lon: 32.35,  radius_km: 120.0, throughput_mbd: 9.2 },
    Chokepoint { name: "Bab el-Mandeb",      lat: 12.58, lon: 43.33,  radius_km: 70.0,  throughput_mbd: 4.2 },
    Chokepoint { name: "Turkish Straits",    lat: 41.10, lon: 29.07,  radius_km: 55.0,  throughput_mbd: 3.7 },
    Chokepoint { name: "Strait of Gibraltar",lat: 35.97, lon: -5.60,  radius_km: 45.0,  throughput_mbd: 3.0 },
    Chokepoint { name: "Panama Canal",       lat: 9.10,  lon: -79.70, radius_km: 70.0,  throughput_mbd: 1.0 },
    Chokepoint { name: "Danish Straits",     lat: 55.70, lon: 12.70,  radius_km: 80.0,  throughput_mbd: 3.2 },
    Chokepoint { name: "Cape of Good Hope",  lat: -34.36,lon: 18.47,  radius_km: 120.0, throughput_mbd: 5.8 },
];

/// First chokepoint whose geofence contains the point, if any.
pub fn chokepoint_at_inner(lat: f64, lon: f64) -> Option<&'static Chokepoint> {
    CHOKEPOINTS
        .iter()
        .find(|c| haversine_km_inner(lat, lon, c.lat, c.lon) <= c.radius_km)
}

// ---------------------------------------------------------------------------
// PyO3 surface
// ---------------------------------------------------------------------------

/// Great-circle distance in kilometres.
#[pyfunction]
pub fn haversine_km(lat1: f64, lon1: f64, lat2: f64, lon2: f64) -> f64 {
    haversine_km_inner(lat1, lon1, lat2, lon2)
}

/// True if (lat, lon) lies within `radius_km` of (clat, clon).
#[pyfunction]
pub fn within_radius_km(lat: f64, lon: f64, clat: f64, clon: f64, radius_km: f64) -> bool {
    haversine_km_inner(lat, lon, clat, clon) <= radius_km
}

/// Axis-aligned bbox containment. bbox = (min_lat, min_lon, max_lat, max_lon).
#[pyfunction]
pub fn bbox_contains(min_lat: f64, min_lon: f64, max_lat: f64, max_lon: f64, lat: f64, lon: f64) -> bool {
    lat >= min_lat && lat <= max_lat && lon >= min_lon && lon <= max_lon
}

/// Name of the chokepoint containing the point, or None.
#[pyfunction]
pub fn chokepoint_at(lat: f64, lon: f64) -> Option<String> {
    chokepoint_at_inner(lat, lon).map(|c| c.name.to_string())
}

/// The full chokepoint table as a list of dicts (for the globe / diagnostics).
#[pyfunction]
pub fn chokepoints(py: Python<'_>) -> PyResult<Vec<Py<PyDict>>> {
    let mut out = Vec::with_capacity(CHOKEPOINTS.len());
    for c in CHOKEPOINTS {
        let d = PyDict::new_bound(py);
        d.set_item("name", c.name)?;
        d.set_item("lat", c.lat)?;
        d.set_item("lon", c.lon)?;
        d.set_item("radius_km", c.radius_km)?;
        d.set_item("throughput_mbd", c.throughput_mbd)?;
        out.push(d.unbind());
    }
    Ok(out)
}

pub fn register(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(haversine_km, m)?)?;
    m.add_function(wrap_pyfunction!(within_radius_km, m)?)?;
    m.add_function(wrap_pyfunction!(bbox_contains, m)?)?;
    m.add_function(wrap_pyfunction!(chokepoint_at, m)?)?;
    m.add_function(wrap_pyfunction!(chokepoints, m)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn haversine_known_distance() {
        // London ↔ Paris ≈ 343 km.
        let d = haversine_km_inner(51.5074, -0.1278, 48.8566, 2.3522);
        assert!((d - 343.0).abs() < 5.0, "got {d}");
    }

    #[test]
    fn haversine_zero() {
        assert!(haversine_km_inner(10.0, 20.0, 10.0, 20.0) < 1e-6);
    }

    #[test]
    fn hormuz_geofence_hits() {
        // A point in the Strait of Hormuz shipping lane.
        assert_eq!(chokepoint_at_inner(26.6, 56.3).map(|c| c.name), Some("Strait of Hormuz"));
    }

    #[test]
    fn open_ocean_is_no_chokepoint() {
        // Mid-Pacific.
        assert!(chokepoint_at_inner(0.0, -140.0).is_none());
    }
}
