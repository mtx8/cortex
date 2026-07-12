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

    // Intel squadron: REGIMES scanner + MERIDIAN poller (COMPANY is on-demand).
    cx_intel::start(Arc::clone(&bus), Arc::clone(&store), cfg.clone());

    // Snapshot assembly + websocket gateway.
    let snap = SnapshotSrc::new(
        cfg.symbols.clone(),
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
            other => pipeline.handle_command(other).await,
        }
    }
    Ok(())
}
