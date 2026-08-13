//! Synthetic feed — per-symbol geometric brownian motion with
//! regime-switching drift/vol so downstream strategies see calm, trending
//! and volatile tape without a live venue.
//!
//! Invariants: prices are always finite and positive (any numeric escape
//! resets to the symbol's anchor price); ~4 ticks/sec/symbol; BookTop quotes
//! straddle the last price with a few bps of spread.
//!
//! CONTINUITY: when this runs as a *fallback* (REST backfill already put real
//! candles in the store, then the websocket died) the walk starts from the
//! store's last real print, not from a hard-coded book base. Seeding from the
//! base made BTC-USD snap to exactly 100,000.00 mid-session and spliced a
//! fabricated gap onto real history — that fake number is the mark cx-oms
//! fills paper orders at, so the discontinuity is not merely cosmetic.
//!
//! HONESTY: continuity does not make synthetic prices real, so the fake is
//! disclosed on the wire by (a) the sticky `FeedStatus { health:
//! SyntheticFallback }` published below — cortexd's snapshot replays it to
//! every late-joining client, and cx-agents' risk officer raises a caution on
//! the transition — and (b) `Venue::Synthetic` stamped on every Tick. The
//! status detail also states how many symbols are continuations and how many
//! were invented from a base, so "synthetic" never silently means "plausible".

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
    // Snapshot the anchors ONCE, at the moment of the switch, so the status
    // line below and the walks that follow agree about which symbols are
    // continuations of real prints and which are invented from a book base.
    let seeds = seeds(&store, &symbols);
    let continued = seeds.iter().filter(|s| s.is_some()).count();
    let invented = seeds.len() - continued;
    bus.publish(EngineEvent::FeedStatus(FeedStatus {
        feed: "synthetic".into(),
        health: FeedHealth::SyntheticFallback,
        detail: format!(
            "synthetic GBM feed for {} symbols ({continued} continued from last real print, \
             {invented} seeded from book base)",
            seeds.len()
        ),
        ts_ms: now_ms(),
    }));

    let mut tasks = Vec::with_capacity(symbols.len());
    for (symbol, seed) in symbols.into_iter().zip(seeds) {
        let bus = bus.clone();
        let store = store.clone();
        let tick_tx = tick_tx.clone();
        tasks.push(tokio::spawn(async move {
            run_symbol(symbol, seed, bus, store, tick_tx).await;
        }));
    }
    drop(tick_tx);
    for t in tasks {
        let _ = t.await;
    }
}

async fn run_symbol(
    symbol: String,
    seed: Option<f64>,
    bus: Arc<Bus>,
    store: Arc<BarStore>,
    tick_tx: mpsc::Sender<Tick>,
) {
    let mut rng = StdRng::from_entropy();
    let mut state = SynthState::new(&symbol, seed);
    let mut clock = tokio::time::interval(Duration::from_millis(TICK_INTERVAL_MS));
    clock.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        clock.tick().await;
        let ts = now_ms();
        let (tick, top) = state.step(&mut rng, ts, TICK_INTERVAL_MS as f64 / 1_000.0);
        // Declared as SYNTHETIC so the order path can refuse to route real
        // money off a fabricated price (see BarStore::mark_is_synthetic).
        store.set_last_price_from(&tick.symbol, tick.price, Venue::Synthetic);
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
    /// Where the walk started and where it is reset to on a numeric escape:
    /// the last real print when there was one, else `base_price`.
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
    /// `seed_px` is the store's last REAL print for `symbol`, if any. The walk
    /// continues from it so a websocket failure does not invent a price gap;
    /// only a symbol we have never seen a print for starts at `base_price`.
    /// A non-finite or non-positive seed is refused (it could only come from a
    /// corrupt print, and a GBM anchored on 0/NaN emits garbage forever).
    pub(crate) fn new(symbol: &str, seed_px: Option<f64>) -> Self {
        let base = seed_px
            .filter(|p| p.is_finite() && *p > 0.0)
            .unwrap_or_else(|| base_price(symbol));
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

/// Anchor for each symbol at the instant we switch to synthetic: `Some(px)`
/// when the store already holds a real print (REST backfill and/or a live
/// session that ran before the drop), `None` when we have never had one.
/// `BarStore::set_last_price` already rejects non-finite/non-positive prices,
/// so anything present here is usable — `SynthState::new` re-checks anyway
/// because a bad anchor is unrecoverable.
fn seeds(store: &BarStore, symbols: &[String]) -> Vec<Option<f64>> {
    symbols.iter().map(|s| store.last_price(s)).collect()
}

/// Last-resort anchor for a symbol with no real print of its own. Only ever
/// reached in synthetic-PRIMARY mode or for a symbol that never traded.
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
            let mut state = SynthState::new(symbol, None);
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
    fn seeds_continue_from_the_last_real_print() {
        // The exact scenario from the field: REST backfill filled the store,
        // then the websocket died 3x and we fell back to GBM. The walk must
        // pick up where the real tape left off, NOT at base_price(), or the
        // header (and every paper fill priced off last_price) jumps to
        // 100,000.00 mid-session.
        let store = BarStore::new();
        store.set_last_price_untracked("BTC-USD", 63_412.55);
        store.set_last_price_untracked("ETH-USD", 2_204.10);
        let symbols = vec!["BTC-USD".to_string(), "ETH-USD".to_string(), "SOL-USD".into()];

        let seeds = seeds(&store, &symbols);
        assert_eq!(seeds, vec![Some(63_412.55), Some(2_204.10), None]);

        let mut rng = StdRng::seed_from_u64(11);
        let mut state = SynthState::new(&symbols[0], seeds[0]);
        let (first, top) = state.step(&mut rng, 1_700_000_000_000, 0.25);
        // One 250ms GBM step is ~1bp even in the volatile regime, so anything
        // beyond 1% away means the anchor was ignored.
        let drift = (first.price - 63_412.55).abs() / 63_412.55;
        assert!(drift < 0.01, "first synthetic tick jumped {drift:.4} from the last real print");
        assert!(top.bid_px < first.price && first.price < top.ask_px);
        // And it is still labelled synthetic — continuity is not a disguise.
        assert_eq!(first.venue, Venue::Synthetic);
    }

    #[test]
    fn unseeded_symbol_falls_back_to_base_price() {
        // Synthetic-PRIMARY mode: the store is empty, there is no real print
        // to continue, so the book base is the honest starting point.
        let store = BarStore::new();
        assert_eq!(seeds(&store, &["BTC-USD".to_string()]), vec![None]);
        assert_eq!(SynthState::new("BTC-USD", None).price, 100_000.0);
    }

    #[test]
    fn corrupt_seeds_are_refused() {
        // A GBM anchored on 0/NaN/negative never recovers: every later tick is
        // garbage. Fall back to the base rather than poison the walk.
        for bad in [f64::NAN, f64::INFINITY, 0.0, -12.5] {
            let state = SynthState::new("ETH-USD", Some(bad));
            assert_eq!(state.price, 3_500.0, "bad seed {bad} was accepted");
            assert_eq!(state.base, 3_500.0);
            assert!(state.base_size.is_finite() && state.base_size > 0.0);
        }
    }

    #[test]
    fn numeric_escape_resets_to_the_seed_not_the_base() {
        // The escape hatch must not reintroduce the jump it is guarding
        // against: resetting a 63k BTC walk to 100k would be the same lie.
        let mut rng = StdRng::seed_from_u64(3);
        let mut state = SynthState::new("BTC-USD", Some(63_412.55));
        state.price = f64::NAN;
        let (tick, _) = state.step(&mut rng, 1_700_000_000_000, 0.25);
        assert_eq!(tick.price, 63_412.55);
    }

    #[test]
    fn spread_is_a_few_bps() {
        let mut rng = StdRng::seed_from_u64(7);
        let mut state = SynthState::new("BTC-USD", None);
        for i in 0..1_000 {
            let (_, top) = state.step(&mut rng, 1_700_000_000_000 + i * 250, 0.25);
            let bps = top.spread_bps();
            assert!(bps > 0.5 && bps < 12.0, "spread {bps} bps out of range");
        }
    }
}
