//! End-to-end strategy runtime tests: a real Bus, injected Bar events,
//! assertions on a bus subscriber. Synthetic series are pre-validated with
//! cx-ta so a regime/feature drift fails loudly at the setup assert, not as
//! a mystery timeout.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use cx_core::bus::BusEvent;
use cx_core::events::{Bar, EngineEvent, StrategySignal};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::Interval;
use cx_core::{Bus, Config};
use tokio::sync::broadcast::error::TryRecvError;
use tokio::sync::broadcast::Receiver;
use tokio::time::timeout;

const SYM: &str = "TST-USD";

fn cfg() -> Config {
    Config {
        symbols: vec![SYM.to_string()],
        ..Config::default()
    }
}

fn m1_hl(i: i64, open: f64, high: f64, low: f64, close: f64) -> Bar {
    Bar {
        symbol: SYM.to_string(),
        interval: Interval::M1,
        ts_open_ms: i * 60_000,
        open,
        high,
        low,
        close,
        volume: 1.0,
        trade_count: 1,
        vwap: close,
        complete: true,
    }
}

fn m1(i: i64, close: f64) -> Bar {
    m1_hl(i, close, close * 1.001, close * 0.999, close)
}

fn bars_from_closes(closes: &[f64]) -> Vec<Bar> {
    closes
        .iter()
        .enumerate()
        .map(|(i, &c)| m1(i as i64, c))
        .collect()
}

fn trending_closes(n: usize) -> Vec<f64> {
    (0..n).map(|i| 100.0 * 1.01f64.powi(i as i32)).collect()
}

fn signal(strategy: &str, direction: f64, conviction: f64, ts_ms: i64) -> EngineEvent {
    EngineEvent::Signal(StrategySignal {
        strategy: strategy.to_string(),
        symbol: SYM.to_string(),
        direction,
        conviction,
        rationale: "injected".to_string(),
        features: BTreeMap::new(),
        ts_ms,
    })
}

/// Await the next Signal from `strategy`, skipping everything else.
async fn next_signal(
    rx: &mut Receiver<BusEvent>,
    strategy: &str,
    wait_ms: u64,
) -> Option<StrategySignal> {
    let deadline = tokio::time::Instant::now() + Duration::from_millis(wait_ms);
    loop {
        let remaining = deadline.saturating_duration_since(tokio::time::Instant::now());
        if remaining.is_zero() {
            return None;
        }
        match timeout(remaining, rx.recv()).await {
            Ok(Ok(ev)) => {
                if let EngineEvent::Signal(s) = ev.as_ref() {
                    if s.strategy == strategy {
                        return Some(s.clone());
                    }
                }
            }
            Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => continue,
            Ok(Err(_)) | Err(_) => return None,
        }
    }
}

/// Drain the receiver, collecting Signals from `strategy`, until the bus has
/// been quiet for `quiet_ms`.
async fn drain_signals(
    rx: &mut Receiver<BusEvent>,
    strategy: &str,
    quiet_ms: u64,
) -> Vec<StrategySignal> {
    let mut out = Vec::new();
    loop {
        match timeout(Duration::from_millis(quiet_ms), rx.recv()).await {
            Ok(Ok(ev)) => {
                if let EngineEvent::Signal(s) = ev.as_ref() {
                    if s.strategy == strategy {
                        out.push(s.clone());
                    }
                }
            }
            Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => continue,
            Ok(Err(_)) | Err(_) => return out,
        }
    }
}

/// Drain everything currently pending plus anything arriving within
/// `quiet_ms` — used to reach a known-quiet bus before a phase change.
async fn drain_until_quiet(rx: &mut Receiver<BusEvent>, quiet_ms: u64) {
    loop {
        match timeout(Duration::from_millis(quiet_ms), rx.recv()).await {
            Ok(Ok(_)) => continue,
            Ok(Err(tokio::sync::broadcast::error::RecvError::Lagged(_))) => continue,
            Ok(Err(_)) | Err(_) => return,
        }
    }
}

#[tokio::test]
async fn momentum_goes_long_on_trending_series() {
    let closes = trending_closes(90);
    // Setup guard: the series must actually read TrendingUp to cx-ta.
    let (regime, _) = cx_ta::detect_regime(&bars_from_closes(&closes));
    assert_eq!(regime, cx_ta::Regime::TrendingUp, "setup drifted");

    let bus = Bus::new(8_192);
    let store = Arc::new(BarStore::new());
    let _handle = cx_strategy::start(Arc::clone(&bus), store, cfg());
    let mut rx = bus.subscribe();

    for bar in bars_from_closes(&closes) {
        bus.publish(EngineEvent::Bar(bar));
    }
    let sig = next_signal(&mut rx, "momentum_x", 5_000)
        .await
        .expect("momentum_x must signal on a steady uptrend");
    assert!(sig.direction > 0.0, "expected long, got {sig:?}");
    assert!((0.3..=0.95).contains(&sig.conviction));
    assert_eq!(sig.symbol, SYM);
    assert!(sig.features.contains_key("trend_score"));
}

#[tokio::test]
async fn meanrev_fades_a_zscore_extreme_in_a_range() {
    // 60 bars alternating 100/101, then a sharp dip to 99. The dip pushes
    // zscore_20 through -2 while the vol-EWMA median guard keeps the slice
    // out of HighVol and the EMAs barely move (still Ranging).
    let mut closes: Vec<f64> = (0..60)
        .map(|i| if i % 2 == 0 { 100.0 } else { 101.0 })
        .collect();
    closes.push(99.0);

    // Setup guards: pin the regime and the z extreme this test relies on.
    let window = bars_from_closes(&closes);
    let (regime, _) = cx_ta::detect_regime(&window);
    assert_eq!(regime, cx_ta::Regime::Ranging, "setup drifted: not ranging");
    let feats = cx_ta::compute_features(&window);
    let z = feats["zscore_20"];
    assert!(z <= -2.0, "setup drifted: z must reach -2, got {z}");

    let bus = Bus::new(8_192);
    let store = Arc::new(BarStore::new());
    let _handle = cx_strategy::start(Arc::clone(&bus), store, cfg());
    let mut rx = bus.subscribe();

    for bar in window {
        bus.publish(EngineEvent::Bar(bar));
    }
    let sig = next_signal(&mut rx, "meanrev_z", 5_000)
        .await
        .expect("meanrev_z must fade the dip");
    assert!(sig.direction > 0.0, "fading a low extreme means buy: {sig:?}");
    assert!((0.35..=0.8).contains(&sig.conviction));
    assert!(sig.features.contains_key("zscore_20"));
}

#[tokio::test]
async fn breakout_fires_on_confirmed_channel_break() {
    // 40 bars alternating in the 100..101 band, then a wide-range bar
    // closing well above the prior donchian high.
    let mut bars: Vec<Bar> = (0..40)
        .map(|i| m1(i as i64, if i % 2 == 0 { 100.0 } else { 101.0 }))
        .collect();
    bars.push(m1_hl(40, 101.0, 102.6, 100.8, 102.5));

    let bus = Bus::new(8_192);
    let store = Arc::new(BarStore::new());
    let _handle = cx_strategy::start(Arc::clone(&bus), store, cfg());
    let mut rx = bus.subscribe();

    for bar in bars {
        bus.publish(EngineEvent::Bar(bar));
    }
    let sig = next_signal(&mut rx, "breakout_d", 5_000)
        .await
        .expect("breakout_d must fire on a confirmed break");
    assert!(sig.direction > 0.0, "expected upside break: {sig:?}");
    assert!((0.35..=0.9).contains(&sig.conviction));
}

#[tokio::test]
async fn fusion_agreement_raises_and_disagreement_lowers_conviction() {
    async fn fused_for(sigs: &[(&str, f64, f64)]) -> StrategySignal {
        let bus = Bus::new(4_096);
        let store = Arc::new(BarStore::new());
        let _handle = cx_strategy::start(Arc::clone(&bus), store, cfg());
        let mut rx = bus.subscribe();
        for (name, dir, conv) in sigs {
            bus.publish(signal(name, *dir, *conv, now_ms()));
        }
        // A complete M1 bar triggers the fuse; the signals above are already
        // ahead of it in bus order.
        bus.publish(EngineEvent::Bar(m1(0, 100.0)));
        next_signal(&mut rx, "fusion", 5_000)
            .await
            .expect("fusion must publish")
    }

    let agree = fused_for(&[("alpha", 1.0, 0.8), ("beta", 1.0, 0.8)]).await;
    let disagree = fused_for(&[("alpha", 1.0, 0.8), ("beta", -1.0, 0.8)]).await;

    assert!(agree.direction > 0.9, "{agree:?}");
    assert!(agree.conviction > 0.7, "{agree:?}");
    assert!(disagree.direction.abs() < 0.1, "{disagree:?}");
    assert!(disagree.conviction < 0.4, "{disagree:?}");
    assert!(agree.conviction > disagree.conviction);
    assert!(agree.rationale.contains("alpha") && agree.rationale.contains("beta"));

    // Weighting: the LLM strategist (0.6) outweighs an unknown source (0.4).
    let llm = fused_for(&[("llm-strategist", 1.0, 0.8), ("mystery", -1.0, 0.8)]).await;
    assert!(
        (llm.direction - 0.2).abs() < 0.05,
        "llm weight must tilt the blend: {llm:?}"
    );
}

#[tokio::test]
async fn fusion_drops_expired_contributors() {
    let bus = Bus::new(4_096);
    let store = Arc::new(BarStore::new());
    let _handle = cx_strategy::start(Arc::clone(&bus), store, cfg());
    let mut rx = bus.subscribe();

    bus.publish(signal("stale_src", -1.0, 0.9, now_ms() - 31 * 60_000));
    bus.publish(signal("fresh_src", 1.0, 0.5, now_ms()));
    bus.publish(EngineEvent::Bar(m1(0, 100.0)));

    let sig = next_signal(&mut rx, "fusion", 5_000)
        .await
        .expect("fusion must publish");
    assert!(sig.direction > 0.9, "stale short must not drag: {sig:?}");
    assert!(sig.rationale.contains("fresh_src"));
    assert!(!sig.rationale.contains("stale_src"));
}

#[tokio::test]
async fn set_enabled_false_silences_and_removes_from_fusion() {
    let closes = trending_closes(120);
    let bus = Bus::new(16_384);
    let store = Arc::new(BarStore::new());
    let handle = cx_strategy::start(Arc::clone(&bus), store, cfg());
    let mut rx = bus.subscribe();

    let bars = bars_from_closes(&closes);
    for bar in &bars[..100] {
        bus.publish(EngineEvent::Bar(bar.clone()));
    }
    let mom = next_signal(&mut rx, "momentum_x", 5_000)
        .await
        .expect("momentum_x must go long first");
    assert!(mom.direction > 0.0);
    // Fusion fuses on the next bar AFTER the momentum signal is in its book.
    for bar in &bars[100..105] {
        bus.publish(EngineEvent::Bar(bar.clone()));
    }
    let fus = next_signal(&mut rx, "fusion", 5_000)
        .await
        .expect("fusion must follow momentum");
    assert!(fus.direction > 0.5, "{fus:?}");
    assert!(fus.rationale.contains("momentum_x"));

    // Let the runtime finish the backlog so no pre-disable signal is still
    // in flight, then silence momentum_x.
    drain_until_quiet(&mut rx, 300).await;
    assert!(handle.set_enabled("momentum_x", false));

    for bar in &bars[105..115] {
        bus.publish(EngineEvent::Bar(bar.clone()));
    }
    // Fusion loses its only contributor and decays to flat...
    let flat = next_signal(&mut rx, "fusion", 5_000)
        .await
        .expect("fusion must republish after the purge");
    assert!(flat.direction.abs() < 0.15, "{flat:?}");
    assert!(!flat.rationale.contains("momentum_x"));
    // ...and the disabled strategy stayed silent throughout.
    let mom = drain_signals(&mut rx, "momentum_x", 300).await;
    assert!(mom.is_empty(), "disabled strategy must emit nothing: {mom:?}");
}

#[tokio::test]
async fn no_spam_identical_opinions_do_not_republish() {
    let closes = trending_closes(140);
    let bus = Bus::new(16_384);
    let store = Arc::new(BarStore::new());
    let _handle = cx_strategy::start(Arc::clone(&bus), store, cfg());
    let mut rx = bus.subscribe();

    for bar in bars_from_closes(&closes) {
        bus.publish(EngineEvent::Bar(bar));
    }
    let signals = drain_signals(&mut rx, "momentum_x", 700).await;
    assert!(
        !signals.is_empty(),
        "momentum_x must publish at least its initial opinion"
    );
    assert!(
        signals.len() <= 3,
        "a steady trend is ONE opinion, not {} republishes",
        signals.len()
    );
    for pair in signals.windows(2) {
        let flipped = pair[0].direction.signum() != pair[1].direction.signum();
        let moved = (pair[0].conviction - pair[1].conviction).abs() > 0.15;
        assert!(
            flipped || moved,
            "consecutive publishes must differ materially: {pair:?}"
        );
    }
}

#[tokio::test]
async fn warms_from_store_at_startup() {
    let closes = trending_closes(90);
    let bars = bars_from_closes(&closes);
    let store = Arc::new(BarStore::new());
    for bar in &bars[..89] {
        store.push(bar.clone());
    }

    let bus = Bus::new(4_096);
    let _handle = cx_strategy::start(Arc::clone(&bus), Arc::clone(&store), cfg());
    let mut rx = bus.subscribe();

    // A single live bar on a warmed window must be enough to evaluate.
    bus.publish(EngineEvent::Bar(bars[89].clone()));
    let sig = next_signal(&mut rx, "momentum_x", 5_000)
        .await
        .expect("warmed strategy must signal on the first live bar");
    assert!(sig.direction > 0.0);
}

#[tokio::test]
async fn incomplete_and_foreign_bars_are_ignored() {
    let bus = Bus::new(4_096);
    let store = Arc::new(BarStore::new());
    let _handle = cx_strategy::start(Arc::clone(&bus), store, cfg());
    let mut rx = bus.subscribe();

    // Forming (incomplete) bars and bars for unconfigured symbols must not
    // move any strategy or fusion.
    for (i, close) in trending_closes(80).into_iter().enumerate() {
        let mut bar = m1(i as i64, close);
        bar.complete = false;
        bus.publish(EngineEvent::Bar(bar));
        let mut foreign = m1(i as i64, close);
        foreign.symbol = "OTHER-USD".to_string();
        bus.publish(EngineEvent::Bar(foreign));
    }
    tokio::time::sleep(Duration::from_millis(300)).await;
    loop {
        match rx.try_recv() {
            Ok(ev) => assert!(
                !matches!(ev.as_ref(), EngineEvent::Signal(_)),
                "no signal may come from incomplete/foreign bars: {ev:?}"
            ),
            Err(TryRecvError::Empty) | Err(TryRecvError::Closed) => break,
            Err(TryRecvError::Lagged(_)) => continue,
        }
    }
}
