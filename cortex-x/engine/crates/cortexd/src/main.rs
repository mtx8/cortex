//! cortexd — the CORTEX X engine daemon.
//! Wires feeds, strategies, agents, risk, OMS and the websocket gateway
//! around the single bus, then runs until killed.

mod options_enrich;
mod pipeline;
mod snapshot;

use std::sync::Arc;

use cx_core::autonomy::AutonomyDial;
use cx_core::store::BarStore;
use cx_core::types::AutonomyLevel;
use cx_core::{Bus, Command, Config, KillSwitch};

use crate::pipeline::TradePipeline;
use crate::snapshot::SnapshotSrc;

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "info,tungstenite=warn,tokio_tungstenite=warn".into()),
        )
        .init();

    let cfg = Config::load()?;
    tracing::info!(symbols = ?cfg.symbols, feed = %cfg.feed.primary, port = cfg.server.port, "cortex x starting");

    let bus = Bus::new(8_192);
    let store = Arc::new(BarStore::new());
    let kill = Arc::new(KillSwitch::new());
    let dial = Arc::new(AutonomyDial::new(AutonomyLevel::FullAuto));

    // Market data squadron: live feed (+ synthetic fallback), bars, backfill.
    cx_md::MarketData::start(Arc::clone(&bus), Arc::clone(&store), cfg.clone());

    // OMS: paper execution, positions, account.
    let oms = cx_oms::Oms::new(Arc::clone(&bus), Arc::clone(&store), cfg.paper.clone());
    oms.spawn_marker();

    // ECHO: the risk engine every order faces.
    let risk = Arc::new(cx_risk::RiskEngine::new(cfg.risk.clone(), Arc::clone(&kill)));

    // The single order path.
    let pipeline = TradePipeline::new(
        Arc::clone(&bus),
        Arc::clone(&store),
        Arc::clone(&oms),
        Arc::clone(&risk),
        Arc::clone(&dial),
        Arc::clone(&kill),
        cfg.clone(),
    );
    pipeline.spawn();

    // Strategy runtime: momentum, mean-reversion, breakout -> fusion.
    let strategies = cx_strategy::start(Arc::clone(&bus), Arc::clone(&store), cfg.clone());

    // AI agent mesh: analyst, macro sentinel, risk officer, auditor, strategist.
    let mesh = cx_agents::start(Arc::clone(&bus), Arc::clone(&store), cfg.clone());

    // AUTORESEARCH: the recipe self-optimization loop. cx-agents owns the
    // pure half (grid, adoption rule, brief — bus-only, unit-tested there);
    // cortexd hosts the experiment RUNNER because only cortexd may import
    // cx-sim. Paper-only replay of stored history, bounded grid, off the
    // hot path; adoptions ride the bus as ParamUpdate (clamped again by the
    // strategy runtime) + a research Thought the palace records verbatim.
    if cfg.ai.autoresearch_secs > 0 {
        spawn_autoresearch(
            Arc::clone(&bus),
            Arc::clone(&store),
            cfg.symbols.clone(),
            cfg.strategy_params.clone(),
            cfg.ai.autoresearch_secs,
            strategies.clone(),
        );
    }

    // Intel squadron: REGIMES scanner + MERIDIAN poller (COMPANY is on-demand).
    cx_intel::start(Arc::clone(&bus), Arc::clone(&store), cfg.clone());

    // Snapshot assembly + websocket gateway.
    let snap = SnapshotSrc::new(
        cfg.symbols.clone(),
        cx_intel::regimes::universe(&cfg),
        Arc::clone(&store),
        Arc::clone(&oms),
        Arc::clone(&risk),
        Arc::clone(&dial),
    );
    snap.spawn_collector(Arc::clone(&bus));

    let (cmd_tx, mut cmd_rx) = tokio::sync::mpsc::channel::<Command>(256);
    {
        let bus = Arc::clone(&bus);
        let host = cfg.server.host.clone();
        let port = cfg.server.port;
        let snap: Arc<dyn cx_server::SnapshotSource> = Arc::clone(&snap) as _;
        tokio::spawn(async move {
            if let Err(e) = cx_server::serve(bus, host, port, cmd_tx, snap).await {
                tracing::error!(error = %e, "server exited");
            }
        });
    }

    // Command dispatch: operator commands from connected clients.
    tracing::info!("cortex x live");
    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            Command::SetStrategyEnabled { strategy, enabled } => {
                strategies.set_enabled(&strategy, enabled);
            }
            Command::AskAi {
                request_id,
                question,
            } => {
                mesh.ask(request_id, question);
            }
            Command::Sync { .. } => { /* handled by the server per-client */ }
            Command::RunSimulation {} => {
                let bus = Arc::clone(&bus);
                let store = Arc::clone(&store);
                let symbols = cfg.symbols.clone();
                tokio::spawn(async move {
                    let report =
                        tokio::task::spawn_blocking(move || cx_sim::run(&store, &symbols))
                            .await
                            .unwrap_or_else(|_| cx_sim::empty_report("simulation task failed"));
                    bus.publish(cx_core::EngineEvent::Sim(report));
                });
            }
            Command::GetOptionsChain { underlying, expiry } => {
                let bus = Arc::clone(&bus);
                let rate = snap.risk_free_rate();
                tokio::spawn(async move {
                    let egress = cx_core::egress::Egress::new();
                    match cx_md::options::fetch_chain(&egress, &underlying, expiry.as_deref())
                        .await
                    {
                        Ok(mut chain) => {
                            options_enrich::enrich(&mut chain, rate);
                            bus.publish(cx_core::EngineEvent::OptionsChain(chain));
                        }
                        Err(e) => {
                            bus.publish(cx_core::EngineEvent::Thought(
                                cx_core::events::AgentThought {
                                    agent: "options".into(),
                                    squadron: "market-data".into(),
                                    severity: cx_core::types::Severity::Warning,
                                    text: format!("option chain fetch failed for {underlying}: {e}"),
                                    tags: vec!["options".into()],
                                    confidence: 1.0,
                                    symbol: Some(underlying),
                                    ts_ms: cx_core::time::now_ms(),
                                },
                            ));
                        }
                    }
                });
            }
            Command::GetCompany { symbol } => {
                cx_intel::serve_company(Arc::clone(&bus), symbol, cfg.intel.enable_company);
            }
            Command::GetHistory { symbol } => {
                let bus = Arc::clone(&bus);
                let store = Arc::clone(&store);
                tokio::spawn(async move {
                    let egress = cx_core::egress::Egress::new();
                    let bars =
                        cx_intel::regimes::backfill_symbol_d1(&egress, &store, &symbol).await;
                    // Always answer — an empty slice tells the client the
                    // lookup found nothing rather than leaving it waiting.
                    bus.publish(cx_core::EngineEvent::History(cx_core::events::HistorySlice {
                        symbol: symbol.trim().to_uppercase(),
                        interval: cx_core::types::Interval::D1,
                        bars,
                        source: "yahoo D1 (delayed, on demand)".into(),
                        ts_ms: cx_core::time::now_ms(),
                    }));
                });
            }
            other => pipeline.handle_command(other).await,
        }
    }
    Ok(())
}

/// The AUTORESEARCH runner. Each cycle (cadence validated >= 1h):
/// 1. FREEZES the replay data once: the exact `recent(sym, interval, 1200)`
///    window every replay reads is snapshotted into a private [`BarStore`],
///    so incumbent and variants all grade against identical bars and an
///    identical walk-forward split while the live store keeps mutating;
/// 2. builds the bounded grid (<= 6 one-param variants) around the current
///    recipe via `cx_agents::autoresearch::param_grid`, skipping tunables
///    still in their post-adoption cooldown (`ar::cooldown_over` — a
///    tunable is not re-graded until its OOS window no longer overlaps the
///    one that adopted it, killing the overlapping-window ratchet);
/// 3. measures each touched strategy's incumbent once and every variant via
///    `cx_sim::evaluate_strategy_params` (spawn_blocking — the sim never
///    runs on the async hot path; <= 9 sim runs per cycle);
/// 4. adopts at most ONE winner per cycle when it clears the bar (>= 10 OOS
///    trades both sides, positive OOS expectancy, > 20% relative edge):
///    applies the recipe DIRECTLY through the [`cx_strategy::StrategyHandle`]
///    (same clamping path as the bus route — bus lag can never lose an
///    adoption), publishes `ParamUpdate` purely as the audit/palace/UI
///    record, and always publishes the written brief as a Thought
///    (squadron "research").
fn spawn_autoresearch(
    bus: Arc<cx_core::Bus>,
    store: Arc<BarStore>,
    symbols: Vec<String>,
    cfg_params: std::collections::BTreeMap<String, std::collections::BTreeMap<String, f64>>,
    cadence_secs: u64,
    strategies: cx_strategy::StrategyHandle,
) {
    use cx_agents::autoresearch as ar;

    tokio::spawn(async move {
        // The incumbent recipe: defaults overlaid with the (clamped) config
        // seed — the same values the strategy runtime seeded itself with.
        let mut current = ar::seeded_params(&cfg_params);
        // Anti-ratchet bookkeeping: (strategy, key) -> newest replay-bar ts
        // at that tunable's last adoption.
        let mut last_adopt: std::collections::BTreeMap<(String, String), i64> =
            std::collections::BTreeMap::new();
        let cadence = std::time::Duration::from_secs(cadence_secs);
        loop {
            // Sleep first: experiments need stored history worth replaying.
            tokio::time::sleep(cadence).await;

            // Freeze the data once per cycle (fix for walk-forward skew).
            let frozen = Arc::new(freeze_replay_store(&store, &symbols));
            let newest = newest_replay_bar(&frozen, &symbols);

            let variants: Vec<ar::Variant> = ar::param_grid(&current)
                .into_iter()
                .filter(|v| {
                    let key = (v.strategy.clone(), v.key.clone());
                    match (newest, last_adopt.get(&key)) {
                        (Some((ts, interval_ms)), Some(&adopted_ts)) => {
                            let over = ar::cooldown_over(adopted_ts, ts, interval_ms);
                            if !over {
                                tracing::debug!(
                                    strategy = %v.strategy,
                                    key = %v.key,
                                    "autoresearch cooldown: OOS window still overlaps \
                                     the last adoption; skipping variant"
                                );
                            }
                            over
                        }
                        _ => true,
                    }
                })
                .collect();
            let mut incumbents: std::collections::BTreeMap<String, cx_sim::OosSummary> =
                std::collections::BTreeMap::new();
            let mut outcomes: Vec<ar::Outcome> = Vec::new();
            for variant in variants {
                // Measure each touched strategy's incumbent exactly once,
                // on the same FROZEN data the variant will see.
                if !incumbents.contains_key(&variant.strategy) {
                    let (store2, symbols2, strategy2, params2) = (
                        Arc::clone(&frozen),
                        symbols.clone(),
                        variant.strategy.clone(),
                        current.clone(),
                    );
                    match tokio::task::spawn_blocking(move || {
                        cx_sim::evaluate_strategy_params(&store2, &symbols2, &strategy2, &params2)
                    })
                    .await
                    {
                        Ok(summary) => {
                            incumbents.insert(variant.strategy.clone(), summary);
                        }
                        Err(e) => {
                            tracing::warn!(error = %e, "autoresearch incumbent replay failed");
                            continue;
                        }
                    }
                }
                let incumbent = incumbents[&variant.strategy];
                let (store2, symbols2, strategy2, params2) = (
                    Arc::clone(&frozen),
                    symbols.clone(),
                    variant.strategy.clone(),
                    variant.params.clone(),
                );
                let summary = match tokio::task::spawn_blocking(move || {
                    cx_sim::evaluate_strategy_params(&store2, &symbols2, &strategy2, &params2)
                })
                .await
                {
                    Ok(summary) => summary,
                    Err(e) => {
                        tracing::warn!(error = %e, "autoresearch variant replay failed");
                        continue;
                    }
                };
                outcomes.push(ar::Outcome {
                    variant,
                    oos_trades: summary.trades,
                    oos_expectancy: summary.expectancy,
                    incumbent_trades: incumbent.trades,
                    incumbent_expectancy: incumbent.expectancy,
                });
            }

            let adopted = ar::select_adoption(&outcomes).cloned();
            let measured = outcomes
                .iter()
                .any(|o| o.oos_trades > 0 || o.incumbent_trades > 0);
            let brief = ar::format_brief(&outcomes, adopted.as_ref());
            bus.publish(cx_core::EngineEvent::Thought(cx_core::events::AgentThought {
                agent: "autoresearch".into(),
                squadron: "research".into(),
                severity: if measured {
                    cx_core::types::Severity::Insight
                } else {
                    cx_core::types::Severity::Info
                },
                text: brief,
                tags: vec!["autoresearch".into(), "research".into()],
                confidence: if adopted.is_some() { 0.7 } else { 0.5 },
                symbol: None,
                ts_ms: cx_core::time::now_ms(),
            }));

            if let Some(winner) = adopted {
                current = winner.variant.params.clone();
                let params = current
                    .get(&winner.variant.strategy)
                    .cloned()
                    .unwrap_or_default();
                // Apply DIRECTLY through the strategy handle (the same
                // clamping path the bus route takes): a lagged broadcast
                // bus can never lose the adoption the audit trail records.
                strategies.apply_params(&winner.variant.strategy, &params);
                if let Some((ts, _)) = newest {
                    last_adopt.insert(
                        (winner.variant.strategy.clone(), winner.variant.key.clone()),
                        ts,
                    );
                }
                // The ParamUpdate below is the audit/palace/UI record; the
                // strategy runtime re-applies it idempotently.
                bus.publish(cx_core::EngineEvent::ParamUpdate(
                    cx_core::events::ParamUpdate {
                        strategy: winner.variant.strategy.clone(),
                        params,
                        source: "autoresearch".into(),
                        rationale: format!(
                            "{}.{} -> {:.2}: OOS expectancy {:+.1}bps vs incumbent {:+.1}bps \
                             over {} OOS trades (>20% relative edge, walk-forward 70/30)",
                            winner.variant.strategy,
                            winner.variant.key,
                            winner.variant.value,
                            winner.oos_expectancy * 10_000.0,
                            winner.incumbent_expectancy * 10_000.0,
                            winner.oos_trades,
                        ),
                        ts_ms: cx_core::time::now_ms(),
                    },
                ));
            }
        }
    });
}

/// The bar interval a symbol replays at in cx-sim (crypto M1, everything
/// else D1) — a mirror of cx-sim's internal routing, which is not exported.
fn replay_interval(symbol: &str) -> cx_core::types::Interval {
    match cx_core::types::asset_class_of(symbol) {
        cx_core::types::AssetClass::Crypto => cx_core::types::Interval::M1,
        _ => cx_core::types::Interval::D1,
    }
}

/// Snapshot the exact bars every replay this cycle will see into a private
/// store. cx-sim reads `recent(sym, interval, REPLAY_BARS)`, so freezing
/// precisely that window makes every incumbent/variant replay of the cycle
/// deterministic and mutually comparable — the LIVE store keeps mutating
/// underneath, which would otherwise shift the walk-forward split between
/// sequential runs.
fn freeze_replay_store(store: &BarStore, symbols: &[String]) -> BarStore {
    let frozen = BarStore::new();
    for sym in symbols {
        for bar in store.recent(
            sym,
            replay_interval(sym),
            cx_agents::autoresearch::REPLAY_BARS,
        ) {
            frozen.push(bar);
        }
    }
    frozen
}

/// Newest bar across the frozen replay universe: `(ts_open_ms, interval_ms
/// of the series holding it)` — the clock the post-adoption cooldown runs
/// on. None when nothing is stored yet.
fn newest_replay_bar(store: &BarStore, symbols: &[String]) -> Option<(i64, i64)> {
    let mut newest: Option<(i64, i64)> = None;
    for sym in symbols {
        let interval = replay_interval(sym);
        if let Some(last) = store.recent(sym, interval, 1).last() {
            if newest.is_none_or(|(ts, _)| last.ts_open_ms > ts) {
                newest = Some((last.ts_open_ms, interval.ms()));
            }
        }
    }
    newest
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::Bar;
    use cx_core::types::Interval;

    fn bar(sym: &str, interval: Interval, ts_open_ms: i64, close: f64) -> Bar {
        Bar {
            symbol: sym.into(),
            interval,
            ts_open_ms,
            open: close,
            high: close * 1.001,
            low: close * 0.999,
            close,
            volume: 1.0,
            trade_count: 1,
            vwap: close,
            complete: true,
        }
    }

    #[test]
    fn frozen_store_is_immune_to_live_mutation() {
        let live = BarStore::new();
        for i in 0..50i64 {
            live.push(bar("BTC-USD", Interval::M1, i * 60_000, 100.0 + i as f64));
        }
        for i in 0..10i64 {
            live.push(bar("AAPL", Interval::D1, i * 86_400_000, 200.0));
        }
        let symbols = vec!["BTC-USD".to_string(), "AAPL".to_string()];
        let frozen = freeze_replay_store(&live, &symbols);
        assert_eq!(frozen.recent("BTC-USD", Interval::M1, 2_000).len(), 50);
        assert_eq!(frozen.recent("AAPL", Interval::D1, 2_000).len(), 10);

        // The live store keeps mutating; the frozen snapshot must not move
        // — every replay of the cycle sees the identical window and split.
        for i in 50..90i64 {
            live.push(bar("BTC-USD", Interval::M1, i * 60_000, 999.0));
        }
        let after = frozen.recent("BTC-USD", Interval::M1, 2_000);
        assert_eq!(after.len(), 50, "frozen store grew with the live one");
        assert!(after.iter().all(|b| b.close < 999.0), "live bars leaked into the snapshot");

        // Replaying the frozen store twice yields byte-identical summaries:
        // the determinism incumbent/variant comparisons rely on.
        let s1 =
            cx_sim::evaluate_strategy_params(&frozen, &symbols, "meanrev_z", &cx_sim::ParamMap::new());
        let s2 =
            cx_sim::evaluate_strategy_params(&frozen, &symbols, "meanrev_z", &cx_sim::ParamMap::new());
        assert_eq!(s1, s2);
    }

    #[test]
    fn newest_replay_bar_tracks_the_freshest_series_and_its_interval() {
        let store = BarStore::new();
        let symbols = vec!["BTC-USD".to_string(), "AAPL".to_string()];
        assert_eq!(newest_replay_bar(&store, &symbols), None);

        store.push(bar("AAPL", Interval::D1, 86_400_000, 200.0));
        assert_eq!(
            newest_replay_bar(&store, &symbols),
            Some((86_400_000, Interval::D1.ms()))
        );
        // A fresher crypto bar wins and carries M1's interval.
        store.push(bar("BTC-USD", Interval::M1, 90_000_000, 100.0));
        assert_eq!(
            newest_replay_bar(&store, &symbols),
            Some((90_000_000, Interval::M1.ms()))
        );
        // Symbols outside the replay universe are ignored.
        assert_eq!(
            newest_replay_bar(&store, &["ETH-USD".to_string()]),
            None
        );
    }
}
