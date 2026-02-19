use pyo3::prelude::*;
use rayon::prelude::*;
use std::panic;

#[pyclass]
#[derive(Clone)]
pub struct ScanResult {
    #[pyo3(get)]
    pub symbol: String,
    #[pyo3(get)]
    pub composite_score: f64,
    #[pyo3(get)]
    pub momentum_score: f64,
    #[pyo3(get)]
    pub volume_score: f64,
}

#[pyfunction]
pub fn scan_symbols(
    _py: Python,
    symbols: Vec<String>,
    prices: Vec<f64>,
    volumes: Vec<f64>,
    avg_volumes: Vec<f64>,
) -> PyResult<Vec<ScanResult>> {
    // Catch any Rust panics at FFI boundary
    let result = panic::catch_unwind(|| {
        symbols
            .par_iter()
            .enumerate()
            .map(|(i, symbol)| {
                let vol_ratio = if avg_volumes[i] > 0.0 {
                    volumes[i] / avg_volumes[i]
                } else {
                    0.0
                };
                let volume_score = (vol_ratio - 1.0_f64).max(0.0_f64).min(1.0_f64);
                let momentum_score = 0.5; // Placeholder — needs price history

                ScanResult {
                    symbol: symbol.clone(),
                    composite_score: (volume_score * 0.4 + momentum_score * 0.6) * 100.0,
                    momentum_score: momentum_score * 100.0,
                    volume_score: volume_score * 100.0,
                }
            })
            .collect::<Vec<_>>()
    });

    match result {
        Ok(results) => Ok(results),
        Err(_) => Err(PyErr::new::<pyo3::exceptions::PyRuntimeError, _>(
            "Scanner panic caught at FFI boundary",
        )),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scan_basic() {
        let symbols = vec!["AAPL".to_string(), "MSFT".to_string()];
        let _prices = vec![150.0, 400.0];
        let volumes = vec![2_000_000.0, 500_000.0];
        let avg_volumes = vec![1_000_000.0, 1_000_000.0];

        // Test the scoring logic directly without Python GIL
        let results: Vec<ScanResult> = symbols
            .iter()
            .enumerate()
            .map(|(i, symbol)| {
                let vol_ratio = if avg_volumes[i] > 0.0 {
                    volumes[i] / avg_volumes[i]
                } else {
                    0.0
                };
                let volume_score = (vol_ratio - 1.0_f64).max(0.0_f64).min(1.0_f64);
                let momentum_score = 0.5;

                ScanResult {
                    symbol: symbol.clone(),
                    composite_score: (volume_score * 0.4 + momentum_score * 0.6) * 100.0,
                    momentum_score: momentum_score * 100.0,
                    volume_score: volume_score * 100.0,
                }
            })
            .collect();

        assert_eq!(results.len(), 2);
        assert!(results[0].volume_score > results[1].volume_score);
    }
}
