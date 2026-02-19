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
    #[pyo3(get)]
    pub rsi: f64,
    #[pyo3(get)]
    pub macd_histogram: f64,
    #[pyo3(get)]
    pub trend_score: f64,
}

// ---------------------------------------------------------------------------
// Pure technical-indicator functions
// ---------------------------------------------------------------------------

/// Standard RSI over `period` bars.
/// Expects at least `period + 1` prices (most-recent last).
pub fn compute_rsi(prices: &[f64], period: usize) -> f64 {
    if prices.len() <= period {
        return 50.0_f64; // neutral when insufficient data
    }

    let mut avg_gain = 0.0_f64;
    let mut avg_loss = 0.0_f64;

    // Seed with the first `period` changes
    for i in 1..=period {
        let delta = prices[i] - prices[i - 1];
        if delta > 0.0_f64 {
            avg_gain += delta;
        } else {
            avg_loss += delta.abs();
        }
    }
    avg_gain /= period as f64;
    avg_loss /= period as f64;

    // Smooth through the remaining bars
    for i in (period + 1)..prices.len() {
        let delta = prices[i] - prices[i - 1];
        let gain = if delta > 0.0_f64 { delta } else { 0.0_f64 };
        let loss = if delta < 0.0_f64 { delta.abs() } else { 0.0_f64 };

        avg_gain = (avg_gain * (period as f64 - 1.0_f64) + gain) / period as f64;
        avg_loss = (avg_loss * (period as f64 - 1.0_f64) + loss) / period as f64;
    }

    if avg_loss == 0.0_f64 {
        return 100.0_f64;
    }
    let rs = avg_gain / avg_loss;
    100.0_f64 - (100.0_f64 / (1.0_f64 + rs))
}

/// Exponential moving average over `period` bars.
/// Returns the EMA value at the end of the series.
pub fn compute_ema(prices: &[f64], period: usize) -> f64 {
    if prices.is_empty() {
        return 0.0_f64;
    }
    if prices.len() <= period {
        // Fall back to simple average when not enough data
        return prices.iter().sum::<f64>() / prices.len() as f64;
    }

    let k = 2.0_f64 / (period as f64 + 1.0_f64);

    // Seed with SMA of the first `period` prices
    let sma: f64 = prices[..period].iter().sum::<f64>() / period as f64;
    let mut ema = sma;

    for &price in &prices[period..] {
        ema = price * k + ema * (1.0_f64 - k);
    }
    ema
}

/// MACD using standard 12 / 26 / 9 parameters.
/// Returns `(macd_line, signal_line, histogram)`.
pub fn compute_macd_signal(prices: &[f64]) -> (f64, f64, f64) {
    let ema12 = compute_ema(prices, 12);
    let ema26 = compute_ema(prices, 26);
    let macd_line = ema12 - ema26;

    // Build a MACD-line series so we can compute its 9-period EMA (= signal)
    if prices.len() < 26 {
        return (macd_line, 0.0_f64, macd_line);
    }

    let k12 = 2.0_f64 / 13.0_f64;
    let k26 = 2.0_f64 / 27.0_f64;

    let mut ema12_running = prices[..12].iter().sum::<f64>() / 12.0_f64;
    let mut ema26_running = prices[..26].iter().sum::<f64>() / 26.0_f64;

    // Advance EMA-12 through bars 12..26 first
    for &p in &prices[12..26] {
        ema12_running = p * k12 + ema12_running * (1.0_f64 - k12);
    }

    let mut macd_series: Vec<f64> = Vec::with_capacity(prices.len() - 26 + 1);
    macd_series.push(ema12_running - ema26_running);

    for &p in &prices[26..] {
        ema12_running = p * k12 + ema12_running * (1.0_f64 - k12);
        ema26_running = p * k26 + ema26_running * (1.0_f64 - k26);
        macd_series.push(ema12_running - ema26_running);
    }

    let signal = compute_ema(&macd_series, 9);
    let last_macd = *macd_series.last().unwrap_or(&0.0_f64);
    let histogram = last_macd - signal;

    (last_macd, signal, histogram)
}

/// Combine RSI and MACD histogram into a 0-100 momentum score.
///   - RSI contributes 60 %  (already 0-100)
///   - MACD histogram contributes 40 %  (clamped to [-2, 2] then scaled)
pub fn momentum_from_indicators(rsi: f64, macd_histogram: f64) -> f64 {
    let rsi_component = rsi; // already 0-100

    // Clamp histogram to [-2, 2], then map to 0-100
    let clamped = macd_histogram.max(-2.0_f64).min(2.0_f64);
    let macd_component = (clamped + 2.0_f64) / 4.0_f64 * 100.0_f64;

    let score = rsi_component * 0.6_f64 + macd_component * 0.4_f64;
    score.max(0.0_f64).min(100.0_f64)
}

// ---------------------------------------------------------------------------
// Existing scan_symbols — unchanged (backward-compatible)
// ---------------------------------------------------------------------------

#[pyfunction]
pub fn scan_symbols(
    _py: Python,
    symbols: Vec<String>,
    _prices: Vec<f64>,
    volumes: Vec<f64>,
    avg_volumes: Vec<f64>,
) -> PyResult<Vec<ScanResult>> {
    let result = panic::catch_unwind(|| {
        symbols
            .par_iter()
            .enumerate()
            .map(|(i, symbol)| {
                let vol_ratio = if avg_volumes[i] > 0.0_f64 {
                    volumes[i] / avg_volumes[i]
                } else {
                    0.0_f64
                };
                let volume_score = (vol_ratio - 1.0_f64).max(0.0_f64).min(1.0_f64);
                let momentum_score = 0.5_f64; // Placeholder — needs price history

                ScanResult {
                    symbol: symbol.clone(),
                    composite_score: (volume_score * 0.4_f64 + momentum_score * 0.6_f64) * 100.0_f64,
                    momentum_score: momentum_score * 100.0_f64,
                    volume_score: volume_score * 100.0_f64,
                    rsi: 50.0_f64,
                    macd_histogram: 0.0_f64,
                    trend_score: 50.0_f64,
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

// ---------------------------------------------------------------------------
// New scan_symbols_with_history — real composite scoring
// ---------------------------------------------------------------------------

#[pyfunction]
pub fn scan_symbols_with_history(
    _py: Python,
    symbols: Vec<String>,
    price_history: Vec<Vec<f64>>,
    volumes: Vec<f64>,
    avg_volumes: Vec<f64>,
) -> PyResult<Vec<ScanResult>> {
    let result = panic::catch_unwind(|| {
        symbols
            .par_iter()
            .enumerate()
            .map(|(i, symbol)| {
                let prices = &price_history[i];

                // --- Volume score (0-1) ---
                let vol_ratio = if avg_volumes[i] > 0.0_f64 {
                    volumes[i] / avg_volumes[i]
                } else {
                    0.0_f64
                };
                let volume_score = (vol_ratio - 1.0_f64).max(0.0_f64).min(1.0_f64);

                // --- Technical indicators ---
                let rsi = compute_rsi(prices, 14);
                let (_macd_line, _signal_line, macd_histogram) = compute_macd_signal(prices);
                let momentum_score = momentum_from_indicators(rsi, macd_histogram);

                // --- Trend score (0-1): price vs 20-EMA ---
                let ema20 = compute_ema(prices, 20);
                let current_price = *prices.last().unwrap_or(&0.0_f64);
                let trend_score = if ema20 > 0.0_f64 {
                    let ratio = (current_price - ema20) / ema20;
                    // Map ratio from [-0.05, 0.05] → [0, 1]
                    ((ratio + 0.05_f64) / 0.10_f64).max(0.0_f64).min(1.0_f64)
                } else {
                    0.5_f64
                };

                // --- Composite (all components normalised to 0-1) ---
                let vol_norm = volume_score;                  // already 0-1
                let mom_norm = momentum_score / 100.0_f64;    // 0-100 → 0-1
                let trend_norm = trend_score;                 // already 0-1

                let composite =
                    vol_norm * 0.3_f64 + mom_norm * 0.4_f64 + trend_norm * 0.3_f64;

                ScanResult {
                    symbol: symbol.clone(),
                    composite_score: composite * 100.0_f64,
                    momentum_score,
                    volume_score: volume_score * 100.0_f64,
                    rsi,
                    macd_histogram,
                    trend_score: trend_score * 100.0_f64,
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

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_scan_basic() {
        let symbols = vec!["AAPL".to_string(), "MSFT".to_string()];
        let _prices = vec![150.0_f64, 400.0_f64];
        let volumes = vec![2_000_000.0_f64, 500_000.0_f64];
        let avg_volumes = vec![1_000_000.0_f64, 1_000_000.0_f64];

        let results: Vec<ScanResult> = symbols
            .iter()
            .enumerate()
            .map(|(i, symbol)| {
                let vol_ratio = if avg_volumes[i] > 0.0_f64 {
                    volumes[i] / avg_volumes[i]
                } else {
                    0.0_f64
                };
                let volume_score = (vol_ratio - 1.0_f64).max(0.0_f64).min(1.0_f64);
                let momentum_score = 0.5_f64;

                ScanResult {
                    symbol: symbol.clone(),
                    composite_score: (volume_score * 0.4_f64 + momentum_score * 0.6_f64)
                        * 100.0_f64,
                    momentum_score: momentum_score * 100.0_f64,
                    volume_score: volume_score * 100.0_f64,
                    rsi: 50.0_f64,
                    macd_histogram: 0.0_f64,
                    trend_score: 50.0_f64,
                }
            })
            .collect();

        assert_eq!(results.len(), 2);
        assert!(results[0].volume_score > results[1].volume_score);
    }

    #[test]
    fn test_compute_rsi_basic() {
        // Alternating up/down: gains and losses should be roughly equal → RSI ~50
        let prices: Vec<f64> = (0..30)
            .map(|i| if i % 2 == 0 { 100.0_f64 } else { 101.0_f64 })
            .collect();
        let rsi = compute_rsi(&prices, 14);
        assert!(
            rsi > 40.0_f64 && rsi < 60.0_f64,
            "RSI of alternating prices should be near 50, got {rsi}"
        );
    }

    #[test]
    fn test_compute_rsi_overbought() {
        // Monotonically increasing prices → RSI near 100
        let prices: Vec<f64> = (0..30).map(|i| 100.0_f64 + i as f64).collect();
        let rsi = compute_rsi(&prices, 14);
        assert!(
            rsi > 95.0_f64,
            "RSI of all-up moves should be near 100, got {rsi}"
        );
    }

    #[test]
    fn test_compute_rsi_oversold() {
        // Monotonically decreasing prices → RSI near 0
        let prices: Vec<f64> = (0..30).map(|i| 200.0_f64 - i as f64).collect();
        let rsi = compute_rsi(&prices, 14);
        assert!(
            rsi < 5.0_f64,
            "RSI of all-down moves should be near 0, got {rsi}"
        );
    }

    #[test]
    fn test_compute_ema() {
        // Simple linearly increasing series: EMA should lag behind the latest price
        let prices: Vec<f64> = (1..=30).map(|i| i as f64).collect();
        let ema = compute_ema(&prices, 10);
        // EMA of an up-trend lags: should be below 30 but above 20
        assert!(
            ema > 20.0_f64 && ema < 30.0_f64,
            "EMA-10 of 1..30 should be between 20 and 30, got {ema}"
        );
    }

    #[test]
    fn test_compute_macd_signal() {
        // Generate a trending series long enough for MACD (need > 26 bars)
        let prices: Vec<f64> = (0..60).map(|i| 100.0_f64 + i as f64 * 0.5_f64).collect();
        let (macd_line, signal_line, histogram) = compute_macd_signal(&prices);

        // In an uptrend the short EMA > long EMA → positive MACD line
        assert!(
            macd_line > 0.0_f64,
            "MACD line should be positive in uptrend, got {macd_line}"
        );
        // Signal is a smoothed MACD, so it should also be positive
        assert!(
            signal_line > 0.0_f64,
            "Signal line should be positive in uptrend, got {signal_line}"
        );
        // Histogram = MACD - signal; sign depends on acceleration
        let _ = histogram; // valid float is enough for this basic test
    }

    #[test]
    fn test_scan_with_history() {
        // Build two symbols: one in an uptrend with high volume, one flat with low volume
        let symbols = vec!["BULL".to_string(), "FLAT".to_string()];

        let bull_prices: Vec<f64> = (0..60).map(|i| 100.0_f64 + i as f64).collect();
        // Oscillating around 100 so RSI settles near 50 (flat has both gains and losses)
        let flat_prices: Vec<f64> = (0..60)
            .map(|i| if i % 2 == 0 { 100.0_f64 } else { 101.0_f64 })
            .collect();
        let price_history = vec![bull_prices, flat_prices];

        let volumes = vec![5_000_000.0_f64, 500_000.0_f64];
        let avg_volumes = vec![1_000_000.0_f64, 1_000_000.0_f64];

        // Run the scoring logic directly (no Python GIL needed)
        let results: Vec<ScanResult> = symbols
            .iter()
            .enumerate()
            .map(|(i, symbol)| {
                let prices = &price_history[i];

                let vol_ratio = if avg_volumes[i] > 0.0_f64 {
                    volumes[i] / avg_volumes[i]
                } else {
                    0.0_f64
                };
                let volume_score = (vol_ratio - 1.0_f64).max(0.0_f64).min(1.0_f64);

                let rsi = compute_rsi(prices, 14);
                let (_macd_line, _signal_line, macd_histogram) = compute_macd_signal(prices);
                let momentum_score = momentum_from_indicators(rsi, macd_histogram);

                let ema20 = compute_ema(prices, 20);
                let current_price = *prices.last().unwrap_or(&0.0_f64);
                let trend_score = if ema20 > 0.0_f64 {
                    let ratio = (current_price - ema20) / ema20;
                    ((ratio + 0.05_f64) / 0.10_f64).max(0.0_f64).min(1.0_f64)
                } else {
                    0.5_f64
                };

                let vol_norm = volume_score;
                let mom_norm = momentum_score / 100.0_f64;
                let trend_norm = trend_score;

                let composite =
                    vol_norm * 0.3_f64 + mom_norm * 0.4_f64 + trend_norm * 0.3_f64;

                ScanResult {
                    symbol: symbol.clone(),
                    composite_score: composite * 100.0_f64,
                    momentum_score,
                    volume_score: volume_score * 100.0_f64,
                    rsi,
                    macd_histogram,
                    trend_score: trend_score * 100.0_f64,
                }
            })
            .collect();

        assert_eq!(results.len(), 2);

        // BULL should dominate FLAT on every metric
        assert!(
            results[0].composite_score > results[1].composite_score,
            "Bull composite {} should beat flat composite {}",
            results[0].composite_score,
            results[1].composite_score
        );
        assert!(
            results[0].rsi > results[1].rsi,
            "Bull RSI {} should exceed flat RSI {}",
            results[0].rsi,
            results[1].rsi
        );
        assert!(
            results[0].trend_score > results[1].trend_score,
            "Bull trend {} should exceed flat trend {}",
            results[0].trend_score,
            results[1].trend_score
        );
    }
}
