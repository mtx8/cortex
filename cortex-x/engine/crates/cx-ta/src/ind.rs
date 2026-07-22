//! Streaming indicators. Pure, synchronous, allocation-light.
//!
//! Invariants shared by every indicator here:
//! - `update` returns `None` until a full warm-up window of VALID (finite)
//!   samples has been seen; the window counts valid samples only.
//! - Non-finite inputs are skipped: state does not advance and the call
//!   returns the indicator's current output. NaN never propagates.

use std::collections::VecDeque;

/// Simple moving average over the trailing `period` valid samples.
#[derive(Debug, Clone)]
pub struct Sma {
    period: usize,
    window: VecDeque<f64>,
    sum: f64,
}

impl Sma {
    pub fn new(period: usize) -> Self {
        let period = period.max(1);
        Self {
            period,
            window: VecDeque::with_capacity(period + 1),
            sum: 0.0,
        }
    }

    pub fn update(&mut self, x: f64) -> Option<f64> {
        if x.is_finite() {
            self.window.push_back(x);
            self.sum += x;
            if self.window.len() > self.period {
                if let Some(old) = self.window.pop_front() {
                    self.sum -= old;
                }
            }
        }
        (self.window.len() == self.period).then(|| self.sum / self.period as f64)
    }
}

/// Exponential moving average, alpha = 2 / (period + 1), seeded with the
/// SMA of the first `period` valid samples (so warm-up equals the period).
#[derive(Debug, Clone)]
pub struct Ema {
    period: usize,
    alpha: f64,
    seed_sum: f64,
    seed_n: usize,
    value: Option<f64>,
}

impl Ema {
    pub fn new(period: usize) -> Self {
        let period = period.max(1);
        Self {
            period,
            alpha: 2.0 / (period as f64 + 1.0),
            seed_sum: 0.0,
            seed_n: 0,
            value: None,
        }
    }

    pub fn update(&mut self, x: f64) -> Option<f64> {
        if x.is_finite() {
            match self.value {
                Some(v) => self.value = Some(v + self.alpha * (x - v)),
                None => {
                    self.seed_sum += x;
                    self.seed_n += 1;
                    if self.seed_n == self.period {
                        self.value = Some(self.seed_sum / self.period as f64);
                    }
                }
            }
        }
        self.value
    }
}

/// Relative Strength Index with Wilder smoothing. Warm after `period`
/// price changes (i.e. `period + 1` valid closes). Degenerate flat input
/// (no gains, no losses) reads 50.
#[derive(Debug, Clone)]
pub struct Rsi {
    period: usize,
    prev_close: Option<f64>,
    avg_gain: f64,
    avg_loss: f64,
    seen: usize,
}

impl Rsi {
    pub fn new(period: usize) -> Self {
        Self {
            period: period.max(1),
            prev_close: None,
            avg_gain: 0.0,
            avg_loss: 0.0,
            seen: 0,
        }
    }

    pub fn update(&mut self, close: f64) -> Option<f64> {
        if close.is_finite() {
            if let Some(prev) = self.prev_close {
                let change = close - prev;
                let (gain, loss) = if change >= 0.0 {
                    (change, 0.0)
                } else {
                    (0.0, -change)
                };
                let p = self.period as f64;
                if self.seen < self.period {
                    self.avg_gain += gain;
                    self.avg_loss += loss;
                    self.seen += 1;
                    if self.seen == self.period {
                        self.avg_gain /= p;
                        self.avg_loss /= p;
                    }
                } else {
                    self.avg_gain = (self.avg_gain * (p - 1.0) + gain) / p;
                    self.avg_loss = (self.avg_loss * (p - 1.0) + loss) / p;
                }
            }
            self.prev_close = Some(close);
        }
        (self.seen >= self.period).then(|| {
            if self.avg_loss <= 0.0 && self.avg_gain <= 0.0 {
                50.0
            } else if self.avg_loss <= 0.0 {
                100.0
            } else {
                100.0 - 100.0 / (1.0 + self.avg_gain / self.avg_loss)
            }
        })
    }
}

/// Average True Range with Wilder smoothing, seeded with the SMA of the
/// first `period` true ranges. A sample is valid only when high/low/close
/// are finite and `high >= low`.
#[derive(Debug, Clone)]
pub struct Atr {
    period: usize,
    prev_close: Option<f64>,
    seed_sum: f64,
    seed_n: usize,
    value: Option<f64>,
}

impl Atr {
    pub fn new(period: usize) -> Self {
        Self {
            period: period.max(1),
            prev_close: None,
            seed_sum: 0.0,
            seed_n: 0,
            value: None,
        }
    }

    pub fn update(&mut self, high: f64, low: f64, close: f64) -> Option<f64> {
        if high.is_finite() && low.is_finite() && close.is_finite() && high >= low {
            let tr = match self.prev_close {
                Some(pc) => (high - low).max((high - pc).abs()).max((low - pc).abs()),
                None => high - low,
            };
            match self.value {
                Some(v) => {
                    let p = self.period as f64;
                    self.value = Some((v * (p - 1.0) + tr) / p);
                }
                None => {
                    self.seed_sum += tr;
                    self.seed_n += 1;
                    if self.seed_n == self.period {
                        self.value = Some(self.seed_sum / self.period as f64);
                    }
                }
            }
            self.prev_close = Some(close);
        }
        self.value
    }

    /// The current ATR without advancing it — `None` until it has warmed over a
    /// full `period`. Lets the risk gate read the live stop distance at
    /// order-evaluation time without needing a bar to update.
    pub fn value(&self) -> Option<f64> {
        self.value
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MacdOut {
    pub macd: f64,
    pub signal: f64,
    pub hist: f64,
}

/// MACD = EMA(fast) - EMA(slow); signal = EMA(signal) of the MACD line.
/// Warm once the signal line is warm (slow + signal - 1 valid closes).
#[derive(Debug, Clone)]
pub struct Macd {
    fast: Ema,
    slow: Ema,
    signal: Ema,
    last: Option<MacdOut>,
}

impl Macd {
    pub fn new(fast: usize, slow: usize, signal: usize) -> Self {
        Self {
            fast: Ema::new(fast),
            slow: Ema::new(slow),
            signal: Ema::new(signal),
            last: None,
        }
    }

    pub fn update(&mut self, close: f64) -> Option<MacdOut> {
        if close.is_finite() {
            let f = self.fast.update(close);
            let s = self.slow.update(close);
            if let (Some(f), Some(s)) = (f, s) {
                let macd = f - s;
                if let Some(sig) = self.signal.update(macd) {
                    self.last = Some(MacdOut {
                        macd,
                        signal: sig,
                        hist: macd - sig,
                    });
                }
            }
        }
        self.last
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct BollOut {
    pub upper: f64,
    pub mid: f64,
    pub lower: f64,
    /// (upper - lower) / |mid| — relative band width; 0 when mid is ~0.
    pub width: f64,
}

/// Bollinger bands: mid = SMA(period), bands at ±k population std devs.
#[derive(Debug, Clone)]
pub struct Bollinger {
    period: usize,
    k: f64,
    window: VecDeque<f64>,
}

impl Bollinger {
    pub fn new(period: usize, k: f64) -> Self {
        let period = period.max(1);
        Self {
            period,
            k: if k.is_finite() { k } else { 0.0 },
            window: VecDeque::with_capacity(period + 1),
        }
    }

    pub fn update(&mut self, close: f64) -> Option<BollOut> {
        if close.is_finite() {
            self.window.push_back(close);
            if self.window.len() > self.period {
                self.window.pop_front();
            }
        }
        if self.window.len() < self.period {
            return None;
        }
        let n = self.period as f64;
        let mean = self.window.iter().sum::<f64>() / n;
        let var = self.window.iter().map(|x| (x - mean) * (x - mean)).sum::<f64>() / n;
        let std = var.max(0.0).sqrt();
        let upper = mean + self.k * std;
        let lower = mean - self.k * std;
        let width = if mean.abs() > f64::EPSILON {
            (upper - lower) / mean.abs()
        } else {
            0.0
        };
        Some(BollOut {
            upper,
            mid: mean,
            lower,
            width,
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct DonchianOut {
    pub upper: f64,
    pub lower: f64,
    pub mid: f64,
}

/// Donchian channel over the trailing `period` valid (high, low) pairs.
/// A sample is valid only when both are finite and `high >= low`.
#[derive(Debug, Clone)]
pub struct Donchian {
    period: usize,
    highs: VecDeque<f64>,
    lows: VecDeque<f64>,
}

impl Donchian {
    pub fn new(period: usize) -> Self {
        let period = period.max(1);
        Self {
            period,
            highs: VecDeque::with_capacity(period + 1),
            lows: VecDeque::with_capacity(period + 1),
        }
    }

    pub fn update(&mut self, high: f64, low: f64) -> Option<DonchianOut> {
        if high.is_finite() && low.is_finite() && high >= low {
            self.highs.push_back(high);
            self.lows.push_back(low);
            if self.highs.len() > self.period {
                self.highs.pop_front();
                self.lows.pop_front();
            }
        }
        if self.highs.len() < self.period {
            return None;
        }
        let upper = self.highs.iter().copied().fold(f64::MIN, f64::max);
        let lower = self.lows.iter().copied().fold(f64::MAX, f64::min);
        Some(DonchianOut {
            upper,
            lower,
            mid: 0.5 * (upper + lower),
        })
    }
}

/// On-balance volume. Starts at 0 on the first valid sample and returns
/// `Some` from then on; volume adds on up-closes, subtracts on down-closes.
#[derive(Debug, Clone, Default)]
pub struct Obv {
    prev_close: Option<f64>,
    value: f64,
}

impl Obv {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn update(&mut self, close: f64, volume: f64) -> Option<f64> {
        if close.is_finite() && volume.is_finite() && volume >= 0.0 {
            if let Some(prev) = self.prev_close {
                if close > prev {
                    self.value += volume;
                } else if close < prev {
                    self.value -= volume;
                }
            }
            self.prev_close = Some(close);
        }
        self.prev_close.map(|_| self.value)
    }
}

/// Z-score of the latest sample against the trailing `period` window
/// (window includes the latest sample). Zero-variance windows read 0.
#[derive(Debug, Clone)]
pub struct RollingZscore {
    period: usize,
    window: VecDeque<f64>,
}

impl RollingZscore {
    pub fn new(period: usize) -> Self {
        let period = period.max(1);
        Self {
            period,
            window: VecDeque::with_capacity(period + 1),
        }
    }

    pub fn update(&mut self, x: f64) -> Option<f64> {
        if x.is_finite() {
            self.window.push_back(x);
            if self.window.len() > self.period {
                self.window.pop_front();
            }
        }
        if self.window.len() < self.period {
            return None;
        }
        let n = self.period as f64;
        let mean = self.window.iter().sum::<f64>() / n;
        let var = self.window.iter().map(|v| (v - mean) * (v - mean)).sum::<f64>() / n;
        let std = var.max(0.0).sqrt();
        let last = self.window.back().copied().unwrap_or(mean);
        Some(if std > 0.0 { (last - mean) / std } else { 0.0 })
    }
}

/// Session volume-weighted average price. `None` until the first valid
/// sample with positive volume; `reset()` starts a new session.
#[derive(Debug, Clone, Default)]
pub struct VwapSession {
    cum_pv: f64,
    cum_v: f64,
}

impl VwapSession {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn update(&mut self, price: f64, volume: f64) -> Option<f64> {
        if price.is_finite() && volume.is_finite() && volume > 0.0 {
            self.cum_pv += price * volume;
            self.cum_v += volume;
        }
        (self.cum_v > 0.0).then(|| self.cum_pv / self.cum_v)
    }

    pub fn reset(&mut self) {
        *self = Self::default();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sma_warmup_and_values() {
        let mut sma = Sma::new(3);
        assert_eq!(sma.update(1.0), None);
        assert_eq!(sma.update(2.0), None);
        assert_eq!(sma.update(3.0), Some(2.0));
        assert_eq!(sma.update(4.0), Some(3.0));
    }

    #[test]
    fn sma_skips_non_finite() {
        let mut sma = Sma::new(2);
        assert_eq!(sma.update(1.0), None);
        assert_eq!(sma.update(f64::NAN), None);
        assert_eq!(sma.update(3.0), Some(2.0));
        // Skipped input with a full window returns the current value.
        assert_eq!(sma.update(f64::INFINITY), Some(2.0));
    }

    #[test]
    fn ema_seeds_with_sma_then_smooths() {
        // period 3 -> alpha 0.5, seed = sma(1,2,3) = 2.
        let mut ema = Ema::new(3);
        assert_eq!(ema.update(1.0), None);
        assert_eq!(ema.update(2.0), None);
        assert_eq!(ema.update(3.0), Some(2.0));
        assert_eq!(ema.update(4.0), Some(3.0));
        assert_eq!(ema.update(5.0), Some(4.0));
    }

    #[test]
    fn rsi_wilder_hand_computed() {
        // period 2, closes [1,2,3,2]: two gains -> RSI 100, then
        // avg_gain=(1*1+0)/2=0.5, avg_loss=(0*1+1)/2=0.5 -> RSI 50.
        let mut rsi = Rsi::new(2);
        assert_eq!(rsi.update(1.0), None);
        assert_eq!(rsi.update(2.0), None);
        assert_eq!(rsi.update(3.0), Some(100.0));
        let v = rsi.update(2.0).unwrap();
        assert!((v - 50.0).abs() < 1e-12);
    }

    #[test]
    fn rsi_flat_series_reads_50_and_stays_bounded() {
        let mut rsi = Rsi::new(3);
        let mut last = None;
        for _ in 0..10 {
            last = rsi.update(5.0);
        }
        assert_eq!(last, Some(50.0));

        let mut rsi = Rsi::new(14);
        for i in 0..200 {
            if let Some(v) = rsi.update(100.0 + ((i * 37) % 11) as f64) {
                assert!((0.0..=100.0).contains(&v));
            }
        }
    }

    #[test]
    fn atr_wilder_hand_computed() {
        let mut atr = Atr::new(2);
        assert_eq!(atr.update(12.0, 10.0, 11.0), None); // TR = 2
        assert_eq!(atr.update(13.0, 11.0, 12.0), Some(2.0)); // TR = 2, seed avg = 2
        assert_eq!(atr.update(16.0, 12.0, 15.0), Some(3.0)); // TR = 4 -> (2+4)/2
    }

    #[test]
    fn macd_warm_index_and_hist_identity() {
        let mut macd = Macd::new(3, 5, 3);
        let mut first_some = None;
        for i in 0..10 {
            let out = macd.update(1.0 + i as f64);
            if let Some(o) = out {
                first_some.get_or_insert(i);
                assert!((o.hist - (o.macd - o.signal)).abs() < 1e-12);
            }
        }
        // slow warm at index 4, signal needs 3 macd values -> index 6.
        assert_eq!(first_some, Some(6));
    }

    #[test]
    fn bollinger_hand_computed() {
        let mut boll = Bollinger::new(3, 2.0);
        assert!(boll.update(1.0).is_none());
        assert!(boll.update(2.0).is_none());
        let out = boll.update(3.0).unwrap();
        let std = (2.0f64 / 3.0).sqrt();
        assert!((out.mid - 2.0).abs() < 1e-12);
        assert!((out.upper - (2.0 + 2.0 * std)).abs() < 1e-12);
        assert!((out.lower - (2.0 - 2.0 * std)).abs() < 1e-12);
        assert!((out.width - (4.0 * std / 2.0)).abs() < 1e-12);
    }

    #[test]
    fn donchian_hand_computed() {
        let mut d = Donchian::new(2);
        assert!(d.update(10.0, 9.0).is_none());
        let out = d.update(12.0, 11.0).unwrap();
        assert_eq!(out.upper, 12.0);
        assert_eq!(out.lower, 9.0);
        assert!((out.mid - 10.5).abs() < 1e-12);
    }

    #[test]
    fn obv_signs_and_first_sample() {
        let mut obv = Obv::new();
        assert_eq!(obv.update(10.0, 5.0), Some(0.0));
        assert_eq!(obv.update(11.0, 3.0), Some(3.0));
        assert_eq!(obv.update(9.0, 4.0), Some(-1.0));
        assert_eq!(obv.update(9.0, 2.0), Some(-1.0)); // unchanged close
        assert_eq!(obv.update(f64::NAN, 2.0), Some(-1.0)); // skipped
    }

    #[test]
    fn zscore_hand_computed() {
        let mut z = RollingZscore::new(3);
        assert!(z.update(1.0).is_none());
        assert!(z.update(2.0).is_none());
        let v = z.update(3.0).unwrap();
        assert!((v - 1.0 / (2.0f64 / 3.0).sqrt()).abs() < 1e-12);
        // Zero variance -> 0.
        let mut z = RollingZscore::new(2);
        z.update(4.0);
        assert_eq!(z.update(4.0), Some(0.0));
    }

    #[test]
    fn vwap_session_accumulates_and_resets() {
        let mut v = VwapSession::new();
        assert_eq!(v.update(10.0, 0.0), None); // no volume yet
        assert_eq!(v.update(10.0, 1.0), Some(10.0));
        assert_eq!(v.update(20.0, 1.0), Some(15.0));
        v.reset();
        assert_eq!(v.update(30.0, 2.0), Some(30.0));
    }

    #[test]
    fn ema_skip_returns_current_value() {
        let mut ema = Ema::new(2);
        ema.update(1.0);
        let warm = ema.update(3.0);
        assert_eq!(warm, Some(2.0));
        assert_eq!(ema.update(f64::NEG_INFINITY), Some(2.0));
    }
}
