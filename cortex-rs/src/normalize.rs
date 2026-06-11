//! Response normalization: turn raw feed bodies (fetched through the guarded
//! egress) into typed objects the Python squadrons consume. Defensive parsing —
//! a malformed or partially-truncated body yields the rows it can, never a panic.

use crate::maritime::Vessel;
use pyo3::prelude::*;
use pyo3::types::PyDict;
use serde_json::Value;

/// A point geospatial event (earthquake, launch, generic OSINT hit).
#[pyclass]
#[derive(Clone)]
pub struct GeoEvent {
    #[pyo3(get)]
    pub source: String,
    #[pyo3(get)]
    pub kind: String,
    #[pyo3(get)]
    pub id: String,
    #[pyo3(get)]
    pub lat: f64,
    #[pyo3(get)]
    pub lon: f64,
    #[pyo3(get)]
    pub magnitude: f64,
    #[pyo3(get)]
    pub depth_km: f64,
    #[pyo3(get)]
    pub label: String,
    #[pyo3(get)]
    pub timestamp_ms: i64,
}

#[pymethods]
impl GeoEvent {
    fn to_dict<'py>(&self, py: Python<'py>) -> PyResult<Bound<'py, PyDict>> {
        let d = PyDict::new_bound(py);
        d.set_item("source", &self.source)?;
        d.set_item("kind", &self.kind)?;
        d.set_item("id", &self.id)?;
        d.set_item("lat", self.lat)?;
        d.set_item("lon", self.lon)?;
        d.set_item("magnitude", self.magnitude)?;
        d.set_item("depth_km", self.depth_km)?;
        d.set_item("label", &self.label)?;
        d.set_item("timestamp_ms", self.timestamp_ms)?;
        Ok(d)
    }

    fn __repr__(&self) -> String {
        format!("GeoEvent({} {} M{:.1} @ {:.3},{:.3})", self.source, self.kind, self.magnitude, self.lat, self.lon)
    }
}

fn as_f64(v: &Value) -> Option<f64> {
    v.as_f64().or_else(|| v.as_str().and_then(|s| s.parse().ok()))
}

/// Parse a USGS earthquakes GeoJSON FeatureCollection into GeoEvents. Geometry
/// coordinates are [lon, lat, depth_km]; properties carry mag/place/time(ms).
#[pyfunction]
pub fn parse_usgs_geojson(body: &str) -> PyResult<Vec<GeoEvent>> {
    let root: Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(e) => return Err(crate::error::GeoError::Parse(e.to_string()).into()),
    };
    let mut out = Vec::new();
    let Some(features) = root.get("features").and_then(|f| f.as_array()) else {
        return Ok(out);
    };
    for f in features {
        let coords = f
            .get("geometry")
            .and_then(|g| g.get("coordinates"))
            .and_then(|c| c.as_array());
        let (lon, lat, depth) = match coords {
            Some(c) if c.len() >= 2 => (
                as_f64(&c[0]).unwrap_or(f64::NAN),
                as_f64(&c[1]).unwrap_or(f64::NAN),
                c.get(2).and_then(as_f64).unwrap_or(0.0),
            ),
            _ => continue,
        };
        if lat.is_nan() || lon.is_nan() {
            continue;
        }
        let props = f.get("properties");
        let mag = props.and_then(|p| p.get("mag")).and_then(as_f64).unwrap_or(0.0);
        let place = props
            .and_then(|p| p.get("place"))
            .and_then(|p| p.as_str())
            .unwrap_or("")
            .to_string();
        let time = props
            .and_then(|p| p.get("time"))
            .and_then(|t| t.as_i64())
            .unwrap_or(0);
        let id = f.get("id").and_then(|i| i.as_str()).unwrap_or("").to_string();
        out.push(GeoEvent {
            source: "usgs".into(),
            kind: "earthquake".into(),
            id,
            lat,
            lon,
            magnitude: mag,
            depth_km: depth,
            label: place,
            timestamp_ms: time,
        });
    }
    Ok(out)
}

/// Parse a Digitraffic (meri.digitraffic.fi) AIS *locations* GeoJSON
/// FeatureCollection into Vessels. Each feature: top-level `mmsi`,
/// geometry.coordinates [lon, lat], properties { sog, cog, heading,
/// timestampExternal }. Ship type/draught are not in the locations endpoint —
/// they default to 0 and are enriched from the vessels-metadata endpoint in
/// Python. Tolerant of AISStream-style bodies (mmsi/lat/lon in properties).
#[pyfunction]
pub fn parse_digitraffic_ais(body: &str) -> PyResult<Vec<Vessel>> {
    let root: Value = match serde_json::from_str(body) {
        Ok(v) => v,
        Err(e) => return Err(crate::error::GeoError::Parse(e.to_string()).into()),
    };
    let mut out = Vec::new();
    let Some(features) = root.get("features").and_then(|f| f.as_array()) else {
        return Ok(out);
    };
    for f in features {
        let props = f.get("properties");
        // mmsi may be top-level or in properties.
        let mmsi = f
            .get("mmsi")
            .and_then(|m| m.as_u64())
            .or_else(|| props.and_then(|p| p.get("mmsi")).and_then(|m| m.as_u64()))
            .unwrap_or(0);
        if mmsi == 0 {
            continue;
        }
        let coords = f
            .get("geometry")
            .and_then(|g| g.get("coordinates"))
            .and_then(|c| c.as_array());
        let (lon, lat) = match coords {
            Some(c) if c.len() >= 2 => (
                as_f64(&c[0]).unwrap_or(f64::NAN),
                as_f64(&c[1]).unwrap_or(f64::NAN),
            ),
            _ => continue,
        };
        if lat.is_nan() || lon.is_nan() {
            continue;
        }
        let sog = props.and_then(|p| p.get("sog")).and_then(as_f64).unwrap_or(0.0);
        let heading = props
            .and_then(|p| p.get("heading"))
            .and_then(as_f64)
            .or_else(|| props.and_then(|p| p.get("cog")).and_then(as_f64))
            .unwrap_or(0.0);
        let ship_type = props
            .and_then(|p| p.get("shipType").or_else(|| p.get("ship_type")))
            .and_then(|t| t.as_u64())
            .unwrap_or(0) as u32;
        let draught = props.and_then(|p| p.get("draught")).and_then(as_f64).unwrap_or(0.0);
        let name = props
            .and_then(|p| p.get("name"))
            .and_then(|n| n.as_str())
            .unwrap_or("")
            .to_string();
        let ts = props
            .and_then(|p| p.get("timestampExternal").or_else(|| p.get("timestamp")))
            .and_then(|t| t.as_i64())
            .unwrap_or(0);
        out.push(Vessel {
            mmsi,
            lat,
            lon,
            speed_knots: sog,
            heading,
            ship_type,
            name,
            draught,
            timestamp_ms: ts,
        });
    }
    Ok(out)
}

pub fn register(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_class::<GeoEvent>()?;
    m.add_function(wrap_pyfunction!(parse_usgs_geojson, m)?)?;
    m.add_function(wrap_pyfunction!(parse_digitraffic_ais, m)?)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_usgs_feature() {
        let body = r#"{"type":"FeatureCollection","features":[
          {"type":"Feature","id":"abc",
           "properties":{"mag":4.2,"place":"100km S of Nowhere","time":1700000000000},
           "geometry":{"type":"Point","coordinates":[-122.5,38.1,7.3]}}]}"#;
        let evs = parse_usgs_geojson(body).unwrap();
        assert_eq!(evs.len(), 1);
        assert_eq!(evs[0].id, "abc");
        assert!((evs[0].magnitude - 4.2).abs() < 1e-9);
        assert!((evs[0].lat - 38.1).abs() < 1e-9);
        assert!((evs[0].depth_km - 7.3).abs() < 1e-9);
    }

    #[test]
    fn parses_digitraffic_vessel() {
        let body = r#"{"type":"FeatureCollection","features":[
          {"mmsi":230123456,"type":"Feature",
           "geometry":{"type":"Point","coordinates":[24.95,60.17]},
           "properties":{"sog":12.4,"cog":210.0,"heading":205,"shipType":80,"timestampExternal":1700000000000}}]}"#;
        let vs = parse_digitraffic_ais(body).unwrap();
        assert_eq!(vs.len(), 1);
        assert_eq!(vs[0].mmsi, 230123456);
        assert!((vs[0].speed_knots - 12.4).abs() < 1e-9);
        assert_eq!(vs[0].ship_type, 80);
    }

    #[test]
    fn malformed_body_is_empty_not_panic() {
        assert!(parse_usgs_geojson("not json").is_err());
        assert!(parse_usgs_geojson(r#"{"features":"oops"}"#).unwrap().is_empty());
        assert!(parse_digitraffic_ais(r#"{}"#).unwrap().is_empty());
    }
}
