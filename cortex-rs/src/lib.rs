use pyo3::prelude::*;

mod scanner;

#[pymodule]
fn cortex_scanner(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(scanner::scan_symbols, m)?)?;
    m.add_class::<scanner::ScanResult>()?;
    Ok(())
}
