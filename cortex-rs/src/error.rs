//! Error types for the geo-intelligence core. Mirrors omniscient's `OsintError`
//! (secret-free, stable, never leaks the full URL/query — which can carry an API
//! key) but converts cleanly to a Python exception at the PyO3 boundary instead
//! of serializing to a JS IPC string.

use pyo3::exceptions::PyValueError;
use pyo3::PyErr;

#[derive(Debug, thiserror::Error)]
pub enum GeoError {
    #[error("invalid url")]
    InvalidUrl,
    #[error("scheme must be https")]
    BadScheme,
    #[error("host not allowed: {0}")]
    HostNotAllowed(String),
    #[error("request failed: {0}")]
    Request(String),
    #[error("response too large (cap {0} bytes)")]
    TooLarge(usize),
    #[error("parse error: {0}")]
    Parse(String),
}

/// At the FFI boundary a GeoError becomes a Python `ValueError`. The message is
/// always the stable, secret-free `Display` — never the raw transport error,
/// which can embed the full URL (and thus a key) on connect/redirect failures.
impl From<GeoError> for PyErr {
    fn from(e: GeoError) -> PyErr {
        PyValueError::new_err(e.to_string())
    }
}
