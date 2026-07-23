//! cortexd — the CORTEX X engine daemon.
//! Wires feeds, strategies, agents, risk, OMS and the websocket gateway
//! around the single bus, then runs until killed.

mod active_broker;
mod options_enrich;
mod pipeline;
mod snapshot;

use std::sync::Arc;

use cx_broker::Broker;
use cx_core::autonomy::AutonomyDial;
use cx_core::store::BarStore;
use cx_core::types::AutonomyLevel;
use cx_core::{Bus, Command, Config, KillSwitch};

use crate::active_broker::ActiveBroker;
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
    // The handle also carries the LEVEL 2 depth control channel: the command
    // loop points it at the single actively-viewed symbol to bound bandwidth.
    let md = cx_md::MarketData::start(Arc::clone(&bus), Arc::clone(&store), cfg.clone());

    // OMS: paper execution, positions, account. The paper OMS runs in EVERY
    // mode — it is the paper broker's engine and the snapshot/risk view's
    // book. In live mode the IBKR adapter is the order SINK on top of it.
    let oms = cx_oms::Oms::new(Arc::clone(&bus), Arc::clone(&store), cfg.paper.clone());
    oms.spawn_marker();

    // Active broker: PAPER by default. mode="ibkr" attempts a Gateway
    // connection and, on ANY failure, falls back to paper with a loud critical
    // thought — never crashes, never silently live (see cx-broker + docs/IBKR.md).
    //
    // The built broker is wrapped in an ActiveBroker so Settings can hot-swap it
    // at runtime (Command::SetBrokerConfig) WITHOUT rebuilding the pipeline. The
    // pipeline and the snapshot both hold this SAME wrapper (as Arc<dyn Broker>),
    // so one swap updates the routed sink and the connect-time badge together,
    // and the kill/risk/flatten path always reaches the current delegate.
    let active = ActiveBroker::new(
        cx_broker::build_active_broker(&cfg.broker, Arc::clone(&bus), Arc::clone(&oms)).await,
    );
    let broker: Arc<dyn Broker> = Arc::clone(&active) as Arc<dyn Broker>;
    tracing::info!(broker = broker.name(), "active broker selected");
    // Announce the TRUE broker posture so the app badge reflects real money
    // from the first frame. build_active_broker already fell back to paper on
    // any failure, so this reports paper / ibkr_paper / ibkr_live per what is
    // actually wired. Re-published in every connect-time snapshot too, so a
    // client that reconnects always re-learns the posture.
    bus.publish(cx_core::EngineEvent::BrokerStatus(broker.status()));

    // ECHO: the risk engine every order faces.
    let risk = Arc::new(cx_risk::RiskEngine::new(cfg.risk.clone(), Arc::clone(&kill)));

    // The single order path. Risk-approved orders are handed to the active
    // broker; the broker is only ever a SINK downstream of risk.
    let pipeline = TradePipeline::new(
        Arc::clone(&bus),
        Arc::clone(&store),
        Arc::clone(&oms),
        Arc::clone(&broker),
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
    // The FINRA short-interest cache is shared by the scanner (row enrichment)
    // and the on-demand company profile, so it lives here and threads into both.
    let short_interest = Arc::new(cx_intel::short_interest::ShortInterestStore::new());
    cx_intel::start(
        Arc::clone(&bus),
        Arc::clone(&store),
        cfg.clone(),
        Arc::clone(&short_interest),
    );

    // AUTORESEARCH (scanner weights): the composite-weight self-optimization
    // loop — same contract as the strategy loop above (frozen data, bounded
    // grid, cooldown, one adoption per cycle, ParamUpdate audit + research
    // Thought) but graded by `cx_intel::scanner::evaluate_weight_variant`
    // (forward decile spread) instead of cx-sim. Adoptions ride the bus
    // ONLY: the scan task subscribes to ParamUpdate strategy=="scanner" and
    // applies them over its clamped route (hard bounds compiled in cx-intel).
    if cfg.ai.autoresearch_secs > 0 && cfg.intel.enable_scanner {
        spawn_scanner_autoresearch(
            Arc::clone(&bus),
            Arc::clone(&store),
            cx_intel::regimes::universe(&cfg),
            cfg.strategy_params.clone(),
            cfg.ai.autoresearch_secs,
        );
    }

    // Snapshot assembly + websocket gateway.
    let snap = SnapshotSrc::new(
        cfg.symbols.clone(),
        cx_intel::regimes::universe(&cfg),
        Arc::clone(&store),
        Arc::clone(&oms),
        Arc::clone(&risk),
        Arc::clone(&dial),
        Arc::clone(&broker),
    );
    snap.spawn_collector(Arc::clone(&bus));

    // Options-chain refresh: fresh chains on the bus for the options desk
    // (cx-agents) without the desk ever fetching — bus-only stays intact.
    let option_underlyings = equity_symbols(&cfg.symbols);
    if !option_underlyings.is_empty() {
        spawn_options_chain_refresh(Arc::clone(&bus), Arc::clone(&snap), option_underlyings);
    }

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
    // The single actively-viewed LEVEL 2 depth symbol (None = no depth
    // streaming). One at a time bounds bandwidth; see `next_active_depth`.
    let mut active_depth: Option<String> = None;
    while let Some(cmd) = cmd_rx.recv().await {
        match cmd {
            Command::SetStrategyEnabled { strategy, enabled } => {
                strategies.set_enabled(&strategy, enabled);
            }
            // LEVEL 2 depth subscribe/unsubscribe. The engine streams depth for
            // at most ONE symbol at a time: subscribing a new symbol implicitly
            // unsubscribes the previous, and a stale unsubscribe (for an already-
            // replaced symbol) is ignored. The class-appropriate connector
            // (Coinbase live L2 / CBOE delayed L1) responds to the watch update.
            Command::SubscribeDepth { .. } | Command::UnsubscribeDepth { .. } => {
                active_depth = next_active_depth(active_depth.take(), &cmd);
                md.set_active_depth(active_depth.clone());
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
                cx_intel::serve_company(
                    Arc::clone(&bus),
                    symbol,
                    cfg.intel.enable_company,
                    Arc::clone(&short_interest),
                );
            }
            Command::GetFilings {
                query,
                form_filter,
                text,
            } => {
                cx_intel::serve_filings(Arc::clone(&bus), query, form_filter, text);
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
            // Runtime broker (re)configuration from Settings. Validated through
            // the SAME gates as disk config, then the sink is rebuilt and
            // hot-swapped behind the shared ActiveBroker (see reconfigure_broker).
            // The `{ .. }` pattern binds nothing, so `cmd` is borrowed, not moved.
            Command::SetBrokerConfig { .. } => {
                reconfigure_broker(&cmd, &active, &bus, &oms).await;
            }
            other => pipeline.handle_command(other).await,
        }
    }
    Ok(())
}

/// Apply a runtime `Command::SetBrokerConfig` from the app's Settings:
/// reconfigure / reconnect the active order sink with the SAME live-safety
/// gates a `[broker]` config load uses, then publish the true posture. Fail-safe
/// by construction — it never bypasses a gate, never goes silently live, and
/// never crashes:
///
/// - The command is converted to the engine's `BrokerConfig`
///   (`Command::to_broker_config`) and `validate()`d: identical live-port
///   refusal, ibkr-account requirement, live-account identity gate, and
///   finite>0 live-limit checks as disk config. A REJECTED config keeps the
///   PREVIOUS safe broker untouched (no swap) and emits a CRITICAL thought.
/// - A VALID config is handed to `build_active_broker`, which is PAPER-FIRST:
///   `mode="paper"` swaps instantly; `mode="ibkr"` attempts the Gateway and, on
///   ANY failure, itself falls back to paper with a loud critical thought. The
///   result is swapped into the shared `ActiveBroker` the pipeline and snapshot
///   both route through — so the kill / risk / flatten path keeps working across
///   the swap — and the OUTGOING broker is disconnected AFTER the new one is
///   already live (routing is never interrupted).
/// - The updated `BrokerStatus` (masked account) is published so the app badge
///   reflects real money immediately.
///
/// No secret transits this path: IBKR API authentication happens in the
/// operator's own IB Gateway / TWS login — CORTEX only opens a localhost socket.
/// The account id is wrapped in `Secret` on conversion and appears only masked.
async fn reconfigure_broker(
    cmd: &Command,
    active: &Arc<ActiveBroker>,
    bus: &Arc<Bus>,
    oms: &Arc<cx_oms::Oms>,
) {
    use cx_core::events::{AgentThought, BrokerMode, EngineEvent};
    use cx_core::time::now_ms;
    use cx_core::types::Severity;

    let Some(new_cfg) = cmd.to_broker_config() else {
        return; // defensive: only SetBrokerConfig routes here
    };

    // Gate: the EXACT config validation a disk `[broker]` load runs. A
    // misconfigured request NEVER swaps the sink — the previous safe broker
    // keeps routing. `CxError`'s Display never contains the account id.
    if let Err(e) = new_cfg.validate() {
        let text = format!(
            "broker reconfigure REFUSED (invalid config): {e} — staying on the current broker"
        );
        tracing::error!("{text}");
        bus.publish(EngineEvent::Thought(AgentThought {
            agent: "broker".into(),
            squadron: "execution".into(),
            severity: Severity::Critical,
            text,
            tags: vec!["broker".into(), "config".into(), "refused".into()],
            confidence: 1.0,
            symbol: None,
            ts_ms: now_ms(),
        }));
        return;
    }

    // Valid: build the replacement. PAPER-FIRST and fail-safe — an ibkr connect
    // failure returns a paper broker WITH its own critical thought, so this can
    // never silently go live and never panics.
    let next = cx_broker::build_active_broker(&new_cfg, Arc::clone(bus), Arc::clone(oms)).await;
    let status = next.status();
    // Swap first so routing is never interrupted, then tear down the OUTGOING
    // session (paper disconnect is a no-op; an old IBKR socket is closed).
    let previous = active.swap(next);
    previous.disconnect().await;

    // Announce the TRUE posture (masked account) so the operator badge updates.
    bus.publish(EngineEvent::BrokerStatus(status.clone()));
    let mode_label = match status.mode {
        BrokerMode::Paper => "paper exchange",
        BrokerMode::IbkrPaper => "IBKR (paper account)",
        BrokerMode::IbkrLive => "IBKR (LIVE — real money)",
    };
    tracing::info!(mode = ?status.mode, connected = status.connected, "broker reconfigured");
    bus.publish(EngineEvent::Thought(AgentThought {
        agent: "broker".into(),
        squadron: "execution".into(),
        severity: Severity::Insight,
        text: format!(
            "broker reconfigured to {mode_label} ({})",
            if status.connected { "connected" } else { "not connected" }
        ),
        tags: vec!["broker".into(), "config".into()],
        confidence: 1.0,
        symbol: None,
        ts_ms: now_ms(),
    }));
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

/// The SCANNER-weight AUTORESEARCH runner, mirroring [`spawn_autoresearch`].
/// Each cycle (same validated cadence):
/// 1. FREEZES the exact D1 window every evaluation reads
///    ([`freeze_scan_store`]) so incumbent and variants grade against
///    identical bars while the live store keeps mutating;
/// 2. builds the bounded grid (<= 10 one-weight variants) around the
///    current recipe via `ar::scanner_weight_grid`, skipping weights still
///    in their post-adoption cooldown ([`bars_since_adoption`] must reach
///    `EVAL_SPAN_BARS` frozen D1 bars — counted in BARS, not calendar
///    time, since equity D1 bars only print on trading days — so a weight
///    is not re-graded until the D1 data no longer overlaps the window
///    that adopted it; the cooldown is per KEY, so consecutive cycles can
///    still adopt OTHER keys off overlapping windows — a known, accepted
///    residual);
/// 3. measures the incumbent once and every variant via
///    `cx_intel::scanner::evaluate_weight_variant` (spawn_blocking — never
///    on the async hot path; <= 11 evaluations per cycle);
/// 4. adopts at most ONE winner per cycle when it clears the bar (positive
///    forward top-vs-bottom-decile spread, > 20% relative edge): publishes
///    `ParamUpdate { strategy: "scanner" }` — the scan task applies it over
///    its clamped bus route (hard bounds compiled in cx-intel) — and always
///    publishes the written brief as a Thought (squadron "research").
fn spawn_scanner_autoresearch(
    bus: Arc<cx_core::Bus>,
    store: Arc<BarStore>,
    universe: Vec<String>,
    cfg_params: std::collections::BTreeMap<String, std::collections::BTreeMap<String, f64>>,
    cadence_secs: u64,
) {
    use cx_agents::autoresearch as ar;
    use cx_intel::scanner;

    tokio::spawn(async move {
        let mut current = ar::seeded_scanner_weights(&cfg_params);
        // Anti-ratchet bookkeeping: weight key -> newest frozen D1 bar ts
        // at that weight's last adoption.
        let mut last_adopt: std::collections::BTreeMap<String, i64> =
            std::collections::BTreeMap::new();
        let cadence = std::time::Duration::from_secs(cadence_secs);
        loop {
            // Sleep first: evaluations need stored D1 history worth grading.
            tokio::time::sleep(cadence).await;

            let frozen = Arc::new(freeze_scan_store(&store, &universe));
            let newest = newest_scan_bar(&frozen, &universe);

            let variants: Vec<ar::WeightVariant> = ar::scanner_weight_grid(&current)
                .into_iter()
                .filter(|v| match last_adopt.get(&v.key) {
                    Some(&adopted_ts) => {
                        let bars = bars_since_adoption(&frozen, &universe, adopted_ts);
                        let over = bars >= scanner::EVAL_SPAN_BARS;
                        if !over {
                            tracing::debug!(
                                key = %v.key,
                                bars_since = bars,
                                need = scanner::EVAL_SPAN_BARS,
                                "scanner autoresearch cooldown: evaluation window still \
                                 overlaps the last adoption; skipping variant"
                            );
                        }
                        over
                    }
                    None => true,
                })
                .collect();

            // The incumbent grades exactly once, on the same frozen data
            // every variant sees. Without an incumbent spread nothing can
            // be compared — the (empty-outcomes) brief still publishes.
            let incumbent: Option<f64> = {
                let (frozen2, universe2) = (Arc::clone(&frozen), universe.clone());
                let weights = scanner::BASE_WEIGHTS.with_params(&current);
                match tokio::task::spawn_blocking(move || {
                    scanner::evaluate_weight_variant(&frozen2, &universe2, &weights)
                })
                .await
                {
                    Ok(spread) => spread,
                    Err(e) => {
                        tracing::warn!(error = %e, "scanner incumbent evaluation failed");
                        None
                    }
                }
            };

            let mut outcomes: Vec<ar::WeightOutcome> = Vec::new();
            if let Some(incumbent_spread) = incumbent {
                for variant in variants {
                    let (frozen2, universe2) = (Arc::clone(&frozen), universe.clone());
                    let weights = scanner::BASE_WEIGHTS.with_params(&variant.weights);
                    let spread = match tokio::task::spawn_blocking(move || {
                        scanner::evaluate_weight_variant(&frozen2, &universe2, &weights)
                    })
                    .await
                    {
                        Ok(Some(spread)) => spread,
                        Ok(None) => continue, // thin data: no fabricated spread
                        Err(e) => {
                            tracing::warn!(error = %e, "scanner variant evaluation failed");
                            continue;
                        }
                    };
                    outcomes.push(ar::WeightOutcome {
                        variant,
                        spread,
                        incumbent_spread,
                    });
                }
            }

            let adopted = ar::select_weight_adoption(&outcomes).cloned();
            let brief = ar::format_weight_brief(&outcomes, adopted.as_ref());
            bus.publish(cx_core::EngineEvent::Thought(cx_core::events::AgentThought {
                agent: "autoresearch".into(),
                squadron: "research".into(),
                severity: if outcomes.is_empty() {
                    cx_core::types::Severity::Info
                } else {
                    cx_core::types::Severity::Insight
                },
                text: brief,
                tags: vec!["autoresearch".into(), "research".into(), "scanner".into()],
                confidence: if adopted.is_some() { 0.7 } else { 0.5 },
                symbol: None,
                ts_ms: cx_core::time::now_ms(),
            }));

            if let Some(winner) = adopted {
                current = winner.variant.weights.clone();
                if let Some(ts) = newest {
                    last_adopt.insert(winner.variant.key.clone(), ts);
                }
                // The audit/palace/UI record AND the application path: the
                // scan task consumes this over its clamped bus route.
                bus.publish(cx_core::EngineEvent::ParamUpdate(
                    cx_core::events::ParamUpdate {
                        strategy: ar::SCANNER_STRATEGY.into(),
                        params: current.clone(),
                        source: "autoresearch".into(),
                        rationale: format!(
                            "{} -> {:.2}: forward top-vs-bottom-decile composite return \
                             spread {:+.1}bps vs incumbent {:+.1}bps on the frozen D1 window \
                             (>20% relative edge; clamped + renormalized on application)",
                            winner.variant.key,
                            winner.variant.value,
                            winner.spread * 10_000.0,
                            winner.incumbent_spread * 10_000.0,
                        ),
                        ts_ms: cx_core::time::now_ms(),
                    },
                ));
            }
        }
    });
}

/// Snapshot the exact D1 bars every scanner-weight evaluation this cycle
/// reads into a private store — `evaluate_weight_variant` fetches
/// `recent(sym, D1, HISTORY + EVAL_SPAN_BARS)`, so freezing precisely that
/// window makes incumbent/variant grades deterministic and mutually
/// comparable while the live store keeps mutating.
fn freeze_scan_store(store: &BarStore, symbols: &[String]) -> BarStore {
    let frozen = BarStore::new();
    let depth = cx_intel::scanner::HISTORY + cx_intel::scanner::EVAL_SPAN_BARS;
    for sym in symbols {
        for bar in store.recent(sym, cx_core::types::Interval::D1, depth) {
            frozen.push(bar);
        }
    }
    frozen
}

/// Newest D1 bar ts across the scan universe — the clock the scanner-weight
/// cooldown runs on. None when nothing is stored yet.
fn newest_scan_bar(store: &BarStore, symbols: &[String]) -> Option<i64> {
    symbols
        .iter()
        .filter_map(|s| {
            store
                .recent(s, cx_core::types::Interval::D1, 1)
                .last()
                .map(|b| b.ts_open_ms)
        })
        .max()
}

/// Frozen D1 bars STRICTLY newer than a scanner weight's adoption stamp,
/// maxed across the scan universe — the scanner-weight cooldown clock.
/// Counted in BARS, not wall time: equity D1 bars only print on trading
/// days (~5/week), so `EVAL_SPAN_BARS` of calendar days would unlock ~50
/// days early while a third of the evaluation bars still overlapped the
/// window that adopted the weight — exactly the re-fit the cooldown
/// exists to prevent. The max mirrors [`newest_scan_bar`], which stamps
/// adoptions with the newest D1 bar anywhere in the universe.
fn bars_since_adoption(store: &BarStore, symbols: &[String], adopted_ts: i64) -> usize {
    let depth = cx_intel::scanner::HISTORY + cx_intel::scanner::EVAL_SPAN_BARS;
    symbols
        .iter()
        .map(|s| {
            store
                .recent(s, cx_core::types::Interval::D1, depth)
                .iter()
                .filter(|b| b.ts_open_ms > adopted_ts)
                .count()
        })
        .max()
        .unwrap_or(0)
}

/// Compute the next actively-viewed LEVEL 2 depth symbol from a depth command
/// and the current one, enforcing the ONE-active-symbol bandwidth bound:
///
/// - `SubscribeDepth { symbol }` makes `symbol` the sole active one, implicitly
///   unsubscribing any previous symbol. An empty/whitespace symbol is a no-op.
/// - `UnsubscribeDepth { symbol }` clears the active symbol ONLY when it matches
///   the current one; a stale unsubscribe for an already-replaced symbol is
///   ignored so it can never tear down a newer subscription.
/// - Any other command leaves the active symbol unchanged.
///
/// Returns the new active symbol (None = stream no depth).
fn next_active_depth(current: Option<String>, cmd: &Command) -> Option<String> {
    match cmd {
        Command::SubscribeDepth { symbol } => {
            let s = symbol.trim();
            if s.is_empty() {
                current
            } else {
                Some(s.to_string())
            }
        }
        Command::UnsubscribeDepth { symbol } => {
            if current.as_deref() == Some(symbol.trim()) {
                None
            } else {
                current
            }
        }
        _ => current,
    }
}

/// The configured EQUITY (bare-ticker) symbols — the only underlyings the
/// options-chain refresh loop targets; dashed crypto products have no
/// listed CBOE chain.
fn equity_symbols(symbols: &[String]) -> Vec<String> {
    symbols
        .iter()
        .filter(|s| cx_core::types::asset_class_of(s) == cx_core::types::AssetClass::Equity)
        .cloned()
        .collect()
}

/// The options-chain refresh loop: every 15 minutes (market hours are
/// irrelevant in v1 — a closed market simply republishes the prior
/// session's chain, with staleness visible via `as_of`), fetch the
/// front-expiry chain for each configured EQUITY symbol through the SAME
/// `cx_md::options::fetch_chain` + greek-enrichment path as
/// `Command::GetOptionsChain`, and publish `EngineEvent::OptionsChain` —
/// the options desk (cx-agents) reads fresh chains off the bus. Failures
/// degrade per-symbol with a warn; the loop never dies.
fn spawn_options_chain_refresh(
    bus: Arc<cx_core::Bus>,
    snap: Arc<SnapshotSrc>,
    underlyings: Vec<String>,
) {
    const REFRESH: std::time::Duration = std::time::Duration::from_secs(900);
    tokio::spawn(async move {
        let egress = cx_core::egress::Egress::new();
        loop {
            for sym in &underlyings {
                match cx_md::options::fetch_chain(&egress, sym, None).await {
                    Ok(mut chain) => {
                        options_enrich::enrich(&mut chain, snap.risk_free_rate());
                        bus.publish(cx_core::EngineEvent::OptionsChain(chain));
                    }
                    Err(e) => {
                        tracing::warn!(
                            symbol = %sym,
                            error = %e,
                            "options chain refresh failed; symbol degrades this cycle"
                        );
                    }
                }
            }
            tokio::time::sleep(REFRESH).await;
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
    fn subscribe_unsubscribe_swaps_the_single_active_depth_symbol() {
        use cx_core::Command;

        // Subscribe from nothing -> that symbol becomes active.
        let a = next_active_depth(None, &Command::SubscribeDepth { symbol: "BTC-USD".into() });
        assert_eq!(a, Some("BTC-USD".to_string()));

        // Subscribing a NEW symbol swaps (implicitly unsubscribes the previous):
        // only one active symbol at a time.
        let b = next_active_depth(a, &Command::SubscribeDepth { symbol: "ETH-USD".into() });
        assert_eq!(b, Some("ETH-USD".to_string()));

        // A STALE unsubscribe (for the already-replaced symbol) is ignored — it
        // never tears down the newer subscription.
        let c = next_active_depth(
            b,
            &Command::UnsubscribeDepth { symbol: "BTC-USD".into() },
        );
        assert_eq!(c, Some("ETH-USD".to_string()));

        // Unsubscribing the CURRENT symbol clears it.
        let d = next_active_depth(
            c,
            &Command::UnsubscribeDepth { symbol: "ETH-USD".into() },
        );
        assert_eq!(d, None);

        // Whitespace-tolerant match; empty subscribe is a no-op.
        let e = next_active_depth(
            Some("AAPL".into()),
            &Command::SubscribeDepth { symbol: "  ".into() },
        );
        assert_eq!(e, Some("AAPL".to_string()));
        let f = next_active_depth(
            Some("AAPL".into()),
            &Command::UnsubscribeDepth { symbol: " AAPL ".into() },
        );
        assert_eq!(f, None);

        // An unrelated command never changes the active symbol.
        let g = next_active_depth(
            Some("AAPL".into()),
            &Command::FlattenAll { reason: "x".into() },
        );
        assert_eq!(g, Some("AAPL".to_string()));
    }

    #[test]
    fn options_refresh_targets_equities_only() {
        let symbols = vec![
            "BTC-USD".to_string(),
            "SPY".to_string(),
            "ETH-USD".to_string(),
            "NVDA".to_string(),
        ];
        assert_eq!(equity_symbols(&symbols), vec!["SPY", "NVDA"]);
        assert!(equity_symbols(&["BTC-USD".to_string()]).is_empty());
        assert!(equity_symbols(&[]).is_empty());
    }

    #[test]
    fn frozen_scan_store_is_immune_to_live_mutation_and_grades_deterministically() {
        let live = BarStore::new();
        let symbols: Vec<String> = (0..5).map(|i| format!("S{i}")).collect();
        for (i, sym) in symbols.iter().enumerate() {
            let g = 1.0 + (i as f64 - 2.0) / 100.0; // -2% .. +2% per bar
            for d in 0..300i64 {
                live.push(bar(sym, Interval::D1, d * 86_400_000, 100.0 * g.powi(d as i32)));
            }
        }
        let frozen = freeze_scan_store(&live, &symbols);
        assert_eq!(frozen.recent("S0", Interval::D1, 2_000).len(), 300);

        // Live keeps mutating; the frozen snapshot must not move.
        for d in 300..340i64 {
            live.push(bar("S0", Interval::D1, d * 86_400_000, 999.0));
        }
        assert_eq!(frozen.recent("S0", Interval::D1, 2_000).len(), 300);

        // Grading the frozen store twice yields the identical spread — the
        // determinism incumbent/variant comparisons rely on.
        let w = cx_intel::scanner::BASE_WEIGHTS;
        let s1 = cx_intel::scanner::evaluate_weight_variant(&frozen, &symbols, &w);
        let s2 = cx_intel::scanner::evaluate_weight_variant(&frozen, &symbols, &w);
        assert!(s1.is_some(), "fixture has depth for evaluation");
        assert_eq!(s1, s2);
    }

    #[test]
    fn newest_scan_bar_tracks_the_freshest_d1_across_the_universe() {
        let store = BarStore::new();
        let symbols = vec!["AAPL".to_string(), "NVDA".to_string()];
        assert_eq!(newest_scan_bar(&store, &symbols), None);
        store.push(bar("AAPL", Interval::D1, 86_400_000, 200.0));
        assert_eq!(newest_scan_bar(&store, &symbols), Some(86_400_000));
        store.push(bar("NVDA", Interval::D1, 2 * 86_400_000, 100.0));
        assert_eq!(newest_scan_bar(&store, &symbols), Some(2 * 86_400_000));
        // Symbols outside the universe are ignored; M1 bars are not D1.
        store.push(bar("BTC-USD", Interval::D1, 9 * 86_400_000, 1.0));
        assert_eq!(newest_scan_bar(&store, &symbols), Some(2 * 86_400_000));
    }

    #[test]
    fn scanner_cooldown_counts_bars_not_calendar_days() {
        const DAY: i64 = 86_400_000;
        let store = BarStore::new();
        let symbols = vec!["AAPL".to_string(), "NVDA".to_string()];
        // Nothing stored: zero bars have printed since any adoption.
        assert_eq!(bars_since_adoption(&store, &symbols, 0), 0);

        // AAPL prints ONLY on trading days (weekends skipped): 10 bars
        // spread over 12 calendar days.
        let mut aapl_ts = Vec::new();
        for week in 0..2i64 {
            for day in 0..5i64 {
                let t = (week * 7 + day) * DAY;
                store.push(bar("AAPL", Interval::D1, t, 100.0));
                aapl_ts.push(t);
            }
        }
        // Adopted at the newest bar: nothing strictly newer counts.
        assert_eq!(bars_since_adoption(&store, &symbols, *aapl_ts.last().unwrap()), 0);
        // Adopted before everything: all 10 bars count.
        assert_eq!(bars_since_adoption(&store, &symbols, -1), 10);
        // Adopted mid-window (day-2 bar): only the 7 BARS after the stamp
        // count — a calendar-day clock over the same stretch would read 9
        // days and unlock early across the weekend gap.
        assert_eq!(bars_since_adoption(&store, &symbols, 2 * DAY), 7);

        // Max across the universe: a symbol that prints every calendar
        // day (crypto-style) has MORE bars since the stamp — max governs,
        // mirroring the newest_scan_bar adoption stamp.
        for d in 0..14i64 {
            store.push(bar("NVDA", Interval::D1, d * DAY, 50.0));
        }
        assert_eq!(bars_since_adoption(&store, &symbols, 2 * DAY), 11);
        // Symbols outside the universe never count.
        store.push(bar("BTC-USD", Interval::D1, 30 * DAY, 1.0));
        assert_eq!(bars_since_adoption(&store, &symbols, 2 * DAY), 11);
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
