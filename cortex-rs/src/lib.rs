//! cortex_scanner — the CORTEX Rust core (PyO3 extension).
//!
//! Two responsibilities:
//!   1. `scanner`  — the existing vectorized technical scanner (RSI/MACD/momentum).
//!   2. geo core   — the geo-intelligence moat: a hardened anti-SSRF egress
//!                   chokepoint (`egress`), geospatial math + world chokepoints
//!                   (`geo`), maritime physical-alpha signals (`maritime`), and
//!                   feed-body normalization (`normalize`).
//!
//! Everything is exposed to the Python orchestrator (`cortex-py`) as one module.

use pyo3::prelude::*;

mod egress;
mod error;
mod geo;
mod maritime;
mod normalize;
mod scanner;

#[pymodule]
fn cortex_scanner(m: &Bound<'_, PyModule>) -> PyResult<()> {
    // Existing technical scanner.
    m.add_function(wrap_pyfunction!(scanner::scan_symbols, m)?)?;
    m.add_function(wrap_pyfunction!(scanner::scan_symbols_with_history, m)?)?;
    m.add_class::<scanner::ScanResult>()?;

    // Geo-intelligence core.
    egress::register(m)?;
    geo::register(m)?;
    maritime::register(m)?;
    normalize::register(m)?;

    m.add("__version__", env!("CARGO_PKG_VERSION"))?;
    Ok(())
}
