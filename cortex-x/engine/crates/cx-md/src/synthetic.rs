//! Synthetic feed — per-symbol geometric brownian motion with
//! regime-switching drift/vol so downstream strategies see calm, trending
//! and volatile tape without a live venue.
//!
//! Invariants: prices are always finite and positive (any numeric escape
//! resets to the symbol's base price); ~4 ticks/sec/symbol; BookTop quotes
//! straddle the last price with a few bps of spread.

use std::sync::Arc;
use std::time::Duration;

use cx_core::events::{BookTop, EngineEvent, FeedHealth, FeedStatus, Tick};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::{Side, Venue};
use cx_core::Bus;
use rand::rngs::StdRng;
use rand::{Rng, SeedableRng};
use tokio::sync::mpsc;

const TICK_INTERVAL_MS: u64 = 250;
const SECS_PER_YEAR: f64 = 365.25 * 24.0 * 3600.0;

/// Run the synthetic generator for every symbol. Never returns while the
/// aggregator's tick channel is open.
pub(crate) async fn run(
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    symbols: Vec<String>,
    tick_tx: mpsc::Sender<Tick>,
) {
    bus.publish(EngineEvent::FeedStatus(FeedStatus {
        feed: "synthetic".into(),
        health: FeedHealth::SyntheticFallback,
        detail: format!("synthetic GBM feed for {} symbols", symbols.len()),
        ts_ms: now_ms(),
    }));

    let mut tasks = Vec::with_capacity(symbols.len());
    for symbol in symbols {
        let bus = bus.clone();
        let store = store.clone();
        let tick_tx = tick_tx.clone();
        tasks.push(tokio::spawn(async move {
            run_symbol(symbol, bus, store, tick_tx).await;
        }));
    }
    drop(tick_tx);
    for t in tasks {
        let _ = t.await;
    }
}

async fn run_symbol(
    symbol: String,
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    tick_tx: mpsc::Sender<Tick>,
) {
    let mut rng = StdRng::from_entropy();
    let mut state = SynthState::new(&symbol);
    let mut clock = tokio::time::interval(Duration::from_millis(TICK_INTERVAL_MS));
    clock.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        clock.tick().await;
        let ts = now_ms();
        let (tick, top) = state.step(&mut rng, ts, TICK_INTERVAL_MS as f64 / 1_000.0);
        store.set_last_price(&tick.symbol, tick.price);
        bus.publish(EngineEvent::Tick(tick.clone()));
        bus.publish(EngineEvent::BookTop(top));
        if tick_tx.send(tick).await.is_err() {
            // Aggregator gone: the squadron is shutting down.
            return;
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Regime {
    Calm,
    Trending,
    Volatile,
}

pub(crate) struct SynthState {
    symbol: String,
    base: f64,
    price: f64,
    /// Annualized drift / volatility of the current regime.
    drift: f64,
    vol: f64,
    regime: Regime,
    regime_until_ms: i64,
    /// Typical trade size (~$2k notional at base price).
    base_size: f64,
}

impl SynthState {
    pub(crate) fn new(symbol: &str) -> Self {
        let base = base_price(symbol);
        Self {
            symbol: symbol.to_string(),
            base,
            price: base,
            drift: 0.0,
            vol: 0.15,
            regime: Regime::Calm,
            regime_until_ms: 0,
            base_size: 2_000.0 / base,
        }
    }

    /// Advance one tick of `dt_secs` and emit a (Tick, BookTop) pair.
    pub(crate) fn step(&mut self, rng: &mut StdRng, ts_ms: i64, dt_secs: f64) -> (Tick, BookTop) {
        if ts_ms >= self.regime_until_ms {
            self.switch_regime(rng, ts_ms);
        }
        let dt_years = dt_secs / SECS_PER_YEAR;
        let z = normal(rng);
        let ret = (self.drift - 0.5 * self.vol * self.vol) * dt_years
            + self.vol * dt_years.sqrt() * z;
        self.price *= ret.exp();
        if !self.price.is_finite() || self.price <= 0.0 {
            self.price = self.base;
        }

        let size = (self.base_size * (0.9 * normal(rng)).exp())
            .clamp(self.base_size * 0.05, self.base_size * 20.0);
        let aggressor = if z >= 0.0 { Side::Buy } else { Side::Sell };
        let tick = Tick {
            symbol: self.symbol.clone(),
            ts_ms,
            price: self.price,
            size,
            aggressor: Some(aggressor),
            venue: Venue::Synthetic,
        };

        let spread_bps = 1.5 + rng.gen::<f64>() * 6.0;
        let half = self.price * spread_bps / 20_000.0;
        let top = BookTop {
            symbol: self.symbol.clone(),
            ts_ms,
            bid_px: self.price - half,
            bid_sz: self.base_size * (0.5 + rng.gen::<f64>() * 4.0),
            ask_px: self.price + half,
            ask_sz: self.base_size * (0.5 + rng.gen::<f64>() * 4.0),
        };
        (tick, top)
    }

    fn switch_regime(&mut self, rng: &mut StdRng, ts_ms: i64) {
        self.regime = match rng.gen_range(0..3u8) {
            0 => Regime::Calm,
            1 => Regime::Trending,
            _ => Regime::Volatile,
        };
        let (drift, vol) = match self.regime {
            Regime::Calm => (0.0, 0.15),
            Regime::Trending => {
                let sign = if rng.gen::<bool>() { 1.0 } else { -1.0 };
                (sign * 2.0, 0.35)
            }
            Regime::Volatile => (0.0, 1.10),
        };
        self.drift = drift;
        self.vol = vol;
        // A few minutes per regime.
        self.regime_until_ms = ts_ms + rng.gen_range(120_000..=420_000);
    }
}

fn base_price(symbol: &str) -> f64 {
    let asset = symbol.split('-').next().unwrap_or(symbol);
    match asset {
        "BTC" => 100_000.0,
        "ETH" => 3_500.0,
        "SOL" => 200.0,
        _ => 100.0,
    }
}

/// Standard normal via Box-Muller; u1 in (0,1] keeps ln() finite.
fn normal(rng: &mut StdRng) -> f64 {
    let u1: f64 = 1.0 - rng.gen::<f64>();
    let u2: f64 = rng.gen();
    (-2.0 * u1.ln()).sqrt() * (std::f64::consts::TAU * u2).cos()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn prices_stay_finite_and_positive_over_long_paths() {
        for (symbol, base) in [("BTC-USD", 100_000.0), ("ETH-USD", 3_500.0), ("XYZ-USD", 100.0)] {
            let mut rng = StdRng::seed_from_u64(42);
            let mut state = SynthState::new(symbol);
            let mut ts = 1_700_000_000_000i64;
            for _ in 0..20_000 {
                ts += 250;
                let (tick, top) = state.step(&mut rng, ts, 0.25);
                assert!(tick.price.is_finite() && tick.price > 0.0);
                assert!(tick.size.is_finite() && tick.size > 0.0);
                assert!(top.bid_px.is_finite() && top.ask_px.is_finite());
                assert!(top.bid_px > 0.0 && top.bid_px < top.ask_px);
                assert!(top.bid_sz > 0.0 && top.ask_sz > 0.0);
            }
            // The walk should stay in the same universe as its base price.
            assert!(state.price > base * 0.01 && state.price < base * 100.0);
        }
    }

    #[test]
    fn base_prices_are_realistic() {
        assert_eq!(base_price("BTC-USD"), 100_000.0);
        assert_eq!(base_price("ETH-USD"), 3_500.0);
        assert_eq!(base_price("SOL-USD"), 200.0);
        assert_eq!(base_price("DOGE-USD"), 100.0);
    }

    #[test]
    fn spread_is_a_few_bps() {
        let mut rng = StdRng::seed_from_u64(7);
        let mut state = SynthState::new("BTC-USD");
        for i in 0..1_000 {
            let (_, top) = state.step(&mut rng, 1_700_000_000_000 + i * 250, 0.25);
            let bps = top.spread_bps();
            assert!(bps > 0.5 && bps < 12.0, "spread {bps} bps out of range");
        }
    }
}
