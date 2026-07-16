//! cx-agents — the AI agent mesh.
//!
//! Five agents plus a copilot, sharing one [`ledger::ContextLedger`]:
//! - "market_analyst" (analysis): per-symbol technicals, speaks only on
//!   notable change.
//! - "macro_sentinel" (macro): real Treasury yield curve + ECB reference FX
//!   every 6h; refuses partial feeds outright.
//! - "risk_officer" (risk): drawdown / feed-degradation / high-vol watch,
//!   tighten-only caution requests.
//! - "execution_auditor" (execution): per-fill slippage audit.
//! - "strategist" (strategy-ai): LLM-read of the ledger on a slow cadence,
//!   only when an LLM is configured; advisory output only.
//! - asset-class DESKS ("desk-crypto" / "desk-equity" / "desk-options",
//!   one bus task in [`desks`]): 24/7 crypto dynamics, session gaps +
//!   scanner ranks + breadth divergence, and option-chain IV/skew —
//!   throttled thoughts, tighten-only cautions, advisory signals only.
//!
//! Invariants enforced at this layer:
//! - Bus-only inter-squadron IO: the mesh publishes [`EngineEvent`]s and
//!   reads the bus + [`BarStore`]; it never calls another squadron.
//! - No LLM ever sits in the execution hot path; every LLM touchpoint is a
//!   slow strategic cycle or an operator question.
//! - The ONLY text an LLM ever sees is `ledger.render()` output (plus the
//!   operator's question and, for memory questions, verbatim PALACE hits —
//!   stored engine output) — no secrets, no config, no raw keys.
//! - Agents degrade to Thought(info) on network trouble; the mesh never
//!   panics on external input.
//!
//! Two persistent-intelligence modules ride alongside the agents:
//! - [`palace`] (private): local-first VERBATIM memory (MemPalace-pattern
//!   rooms/drawers + closet index) fed by a bus subscriber; the ledger
//!   renders its closet, the copilot searches its drawers.
//! - [`autoresearch`] (public): the pure half of the recipe-optimization
//!   loop (grid + adoption rule + brief). cortexd hosts the runner, because
//!   cx-agents is bus-only and must not import cx-sim.

pub mod autoresearch;

mod analyst;
mod auditor;
mod copilot;
mod desks;
mod ledger;
mod llm;
mod macro_agent;
mod palace;
mod risk_officer;
mod strategist;

use std::sync::Arc;

use cx_core::events::{AgentThought, EngineEvent};
use cx_core::store::BarStore;
use cx_core::time::now_ms;
use cx_core::types::Severity;
use cx_core::{Bus, Config};

use ledger::ContextLedger;
use llm::LlmClient;

/// Handle to the running mesh. Cheap to clone the innards around; `ask` is
/// the copilot entry point used by cortexd's command loop.
pub struct MeshHandle {
    inner: Arc<MeshInner>,
}

struct MeshInner {
    bus: Arc<Bus>,
    ledger: Arc<ContextLedger>,
    llm: Arc<LlmClient>,
    palace: Option<Arc<palace::Palace>>,
    symbols: Vec<String>,
}

impl MeshHandle {
    /// Fire-and-forget copilot question: spawns its own task and returns
    /// immediately; the answer arrives on the bus as
    /// [`EngineEvent::AiAnswer`]. A slow (or absent) LLM can therefore never
    /// block the mesh or the caller.
    pub fn ask(&self, request_id: String, question: String) {
        let inner = Arc::clone(&self.inner);
        tokio::spawn(async move {
            copilot::answer(
                Arc::clone(&inner.bus),
                Arc::clone(&inner.ledger),
                Arc::clone(&inner.llm),
                inner.palace.clone(),
                inner.symbols.clone(),
                request_id,
                question,
            )
            .await;
        });
    }
}

/// Start the agent mesh: the ledger ingest task, the four always-on agents,
/// and the strategist when an LLM is configured. Must be called from within
/// a tokio runtime. All bus subscriptions happen synchronously here, so no
/// event published after `start` returns can be missed.
pub fn start(bus: Arc<Bus>, store: Arc<BarStore>, cfg: Config) -> MeshHandle {
    // PALACE: local-first verbatim memory at ~/.cortex/palace. Unavailable
    // (no home dir, io error) degrades to a mesh without persistent memory
    // — never a startup failure. Its ingest task watches the bus for the
    // events that constitute institutional memory.
    let palace = palace::Palace::open_default();
    if let Some(p) = &palace {
        palace::spawn_ingest(p, &bus);
    }

    let ledger = ContextLedger::with_palace(Arc::clone(&store), palace.clone());
    ledger.spawn_ingest(&bus);

    let llm = Arc::new(LlmClient::new(cfg.ai.clone()));

    analyst::spawn(Arc::clone(&bus), Arc::clone(&store), cfg.symbols.clone());
    macro_agent::spawn(Arc::clone(&bus));
    risk_officer::spawn(
        Arc::clone(&bus),
        Arc::clone(&store),
        cfg.risk.max_daily_drawdown,
    );
    auditor::spawn(Arc::clone(&bus), Arc::clone(&ledger));
    desks::spawn(Arc::clone(&bus), Arc::clone(&store), cfg.symbols.clone());

    // Always spawn: the client auto-detects local servers (Ollama/LM Studio)
    // at runtime, so a user who starts one later is picked up on the next
    // cycle. Cycles without any reachable LLM skip silently.
    strategist::spawn(
        Arc::clone(&bus),
        Arc::clone(&ledger),
        Arc::clone(&llm),
        cfg.symbols.clone(),
        cfg.ai.strategist_cadence_secs,
    );
    let strategist_on = llm.is_configured();

    publish_thought(
        &bus,
        "mesh",
        "mesh",
        Severity::Info,
        None,
        1.0,
        format!(
            "agent mesh online: market_analyst, macro_sentinel, risk_officer, execution_auditor, asset desks (crypto/equity/options){}{}",
            if strategist_on {
                ", strategist (llm)"
            } else {
                ", strategist (auto-detecting local llm)"
            },
            if palace.is_some() {
                "; palace memory attached"
            } else {
                "; palace memory unavailable"
            }
        ),
    );

    MeshHandle {
        inner: Arc::new(MeshInner {
            bus,
            ledger,
            llm,
            palace,
            symbols: cfg.symbols,
        }),
    }
}

/// Shared thought publisher: confidence is clamped to [0,1] (NaN reads 0.5)
/// so no agent can push a malformed confidence onto the bus.
pub(crate) fn publish_thought(
    bus: &Bus,
    agent: &str,
    squadron: &str,
    severity: Severity,
    symbol: Option<String>,
    confidence: f64,
    text: impl Into<String>,
) {
    bus.publish(EngineEvent::Thought(AgentThought {
        agent: agent.into(),
        squadron: squadron.into(),
        severity,
        text: text.into(),
        tags: vec![agent.into()],
        confidence: if confidence.is_finite() {
            confidence.clamp(0.0, 1.0)
        } else {
            0.5
        },
        symbol,
        ts_ms: now_ms(),
    }));
}

#[cfg(test)]
mod tests {
    use std::collections::BTreeMap;
    use std::time::Duration;

    use cx_core::config::AiConfig;
    use cx_core::events::{
        AccountSnapshot, Bar, EngineEvent, FeedHealth, FeedStatus, Fill, MacroSnapshot, Position,
        RiskStatus, StrategySignal, Tick,
    };
    use cx_core::types::{AutonomyLevel, Interval, Liquidity, Side, Venue};

    use super::*;

    fn bar(i: i64, close: f64) -> Bar {
        Bar {
            symbol: "BTC-USD".into(),
            interval: Interval::M1,
            ts_open_ms: i * 60_000,
            open: close,
            high: close * 1.001,
            low: close * 0.999,
            close,
            volume: 2.0,
            trade_count: 3,
            vwap: close,
            complete: true,
        }
    }

    fn tick(px: f64, ts: i64) -> EngineEvent {
        EngineEvent::Tick(Tick {
            symbol: "BTC-USD".into(),
            ts_ms: ts,
            price: px,
            size: 0.1,
            aggressor: None,
            venue: Venue::Coinbase,
        })
    }

    fn account() -> EngineEvent {
        EngineEvent::Account(AccountSnapshot {
            equity: 100_500.0,
            cash: 60_000.0,
            gross_exposure: 40_000.0,
            net_exposure: 40_000.0,
            unrealized_pnl: 500.0,
            realized_pnl_day: 120.0,
            fees_paid: 3.0,
            open_orders: 1,
            daily_trades: 4,
            drawdown_day: 0.004,
            drawdown_total: 0.01,
            ts_ms: 1_000_000,
        })
    }

    fn risk_status() -> EngineEvent {
        EngineEvent::Risk(RiskStatus {
            kill_switch: false,
            kill_reason: None,
            autonomy: AutonomyLevel::FullAuto,
            caution: 0.15,
            caution_reasons: vec!["yield curve inverted".into()],
            throttle: 1.0,
            breaches: vec![],
            ts_ms: 1_000_000,
        })
    }

    fn position() -> EngineEvent {
        EngineEvent::Position(Position {
            symbol: "BTC-USD".into(),
            qty: 0.5,
            avg_px: 100.0,
            mark_px: 104.0,
            unrealized_pnl: 2.0,
            realized_pnl: 0.0,
            ts_ms: 1_000_000,
        })
    }

    fn thought_note() -> EngineEvent {
        EngineEvent::Thought(AgentThought {
            agent: "market_analyst".into(),
            squadron: "analysis".into(),
            severity: Severity::Insight,
            text: "test note alpha".into(),
            tags: vec![],
            confidence: 0.7,
            symbol: Some("BTC-USD".into()),
            ts_ms: 1_000_000,
        })
    }

    fn signal() -> EngineEvent {
        EngineEvent::Signal(StrategySignal {
            strategy: "fusion".into(),
            symbol: "BTC-USD".into(),
            direction: 0.5,
            conviction: 0.6,
            rationale: "momentum and breakout agree".into(),
            features: BTreeMap::new(),
            ts_ms: 1_000_000,
        })
    }

    fn macro_snap() -> EngineEvent {
        let mut yields = BTreeMap::new();
        yields.insert("2y".to_string(), 4.71);
        yields.insert("10y".to_string(), 4.36);
        let mut fx = BTreeMap::new();
        fx.insert("EURUSD".to_string(), 1.086);
        EngineEvent::Macro(MacroSnapshot {
            yields,
            spread_2s10s_bps: Some(-35.0),
            spread_3m10s_bps: Some(-84.0),
            curve_regime: "inverted".into(),
            fx,
            source: "test".into(),
            ts_ms: 1_000_000,
        })
    }

    fn feed_status() -> EngineEvent {
        EngineEvent::FeedStatus(FeedStatus {
            feed: "coinbase".into(),
            health: FeedHealth::Live,
            detail: "ws ok".into(),
            ts_ms: 1_000_000,
        })
    }

    fn fill() -> EngineEvent {
        EngineEvent::Fill(Fill {
            order_id: 1,
            symbol: "BTC-USD".into(),
            side: Side::Buy,
            qty: 0.5,
            px: 104.0,
            fee: 0.1,
            liquidity: Liquidity::Taker,
            venue: Venue::Paper,
            ts_ms: 1_000_000,
        })
    }

    #[tokio::test]
    async fn ledger_renders_all_sections_from_bus_events() {
        let bus = Bus::new(1_024);
        let store = Arc::new(BarStore::new());
        for i in 0..40 {
            store.push(bar(i, 100.0 + (i % 5) as f64));
        }
        let ledger = ContextLedger::new(Arc::clone(&store));
        ledger.spawn_ingest(&bus);

        bus.publish(tick(104.0, 1_000_000));
        bus.publish(account());
        bus.publish(risk_status());
        bus.publish(position());
        bus.publish(thought_note());
        bus.publish(signal());
        bus.publish(macro_snap());
        bus.publish(feed_status());
        bus.publish(fill());

        let symbols = vec!["BTC-USD".to_string()];
        let sections = [
            "=== MARKET ===",
            "=== PORTFOLIO ===",
            "=== RISK ===",
            "=== MACRO ===",
            "=== RECENT AGENT NOTES ===",
            "=== RECENT SIGNALS ===",
        ];
        let mut rendered = String::new();
        for _ in 0..200 {
            rendered = ledger.render(&symbols);
            let complete = sections.iter().all(|s| rendered.contains(s))
                && rendered.contains("last 104.00")
                && rendered.contains("regime ")
                && rendered.contains("equity 100500.00")
                && rendered.contains("fills_today 1")
                && rendered.contains("- BTC-USD qty +0.500000")
                && rendered.contains("caution 0.15 (yield curve inverted)")
                && rendered.contains("2s10s -35.0bps")
                && rendered.contains("EURUSD 1.0860")
                && rendered.contains("test note alpha")
                && rendered.contains("- fusion BTC-USD dir +0.50")
                && rendered.contains("feed coinbase: Live");
            if complete {
                return;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        panic!("ledger never rendered the full picture; last render:\n{rendered}");
    }

    #[tokio::test]
    async fn heuristic_copilot_answers_from_ledger_and_publishes() {
        let bus = Bus::new(256);
        let store = Arc::new(BarStore::new());
        let ledger = ContextLedger::new(store);
        // Apply state synchronously — no ingest task needed for this test.
        ledger.apply(&tick(104.0, 1_000_000));
        ledger.apply(&account());
        ledger.apply(&risk_status());
        ledger.apply(&position());
        ledger.apply(&thought_note());
        ledger.apply(&macro_snap());

        let llm = Arc::new(LlmClient::with_probe(AiConfig::default(), false)); // no provider, no probe
        let mut rx = bus.subscribe();
        copilot::answer(
            Arc::clone(&bus),
            ledger,
            llm,
            None, // no palace: the heuristic desk read must not need one
            vec!["BTC-USD".to_string()],
            "req-7".into(),
            "how are we positioned?".into(),
        )
        .await;

        let ev = rx.recv().await.expect("bus closed");
        match &*ev {
            EngineEvent::AiAnswer(a) => {
                assert_eq!(a.request_id, "req-7");
                assert_eq!(a.question, "how are we positioned?");
                assert_eq!(a.model, "heuristic");
                assert!(a.answer.contains("Positions: long 0.5 BTC-USD"), "{}", a.answer);
                assert!(a.answer.contains("Risk: kill switch off"), "{}", a.answer);
                assert!(a.answer.contains("caution 0.15"), "{}", a.answer);
                assert!(a.answer.contains("Macro: curve inverted"), "{}", a.answer);
                assert!(a.answer.contains("test note alpha"), "{}", a.answer);
            }
            other => panic!("expected AiAnswer, got {other:?}"),
        }
    }

    /// Exercises the exact public API cortexd compiles against:
    /// `start(bus, store, cfg) -> MeshHandle` and `MeshHandle::ask`.
    #[tokio::test]
    async fn start_and_ask_answer_arrives_on_the_bus() {
        // Redirect the palace into a scratch dir so the test never touches
        // the operator's real ~/.cortex/palace.
        std::env::set_var("CORTEX_PALACE_DIR", palace::test_dir("start-ask"));
        let bus = Bus::new(1_024);
        let store = Arc::new(BarStore::new());
        // Point the "local llm" at the discard port so the test can never
        // pick up a developer's real Ollama via auto-detection: the fast
        // connection failure forces the heuristic copilot deterministically.
        let mut cfg = Config::default();
        cfg.ai.local_llm_url = "http://127.0.0.1:9".into();
        let mesh = start(Arc::clone(&bus), store, cfg);

        let mut rx = bus.subscribe();
        mesh.ask("req-1".into(), "status?".into());

        let deadline = tokio::time::Instant::now() + Duration::from_secs(10);
        loop {
            let ev = tokio::time::timeout_at(deadline, rx.recv())
                .await
                .expect("timed out waiting for AiAnswer")
                .expect("bus closed");
            if let EngineEvent::AiAnswer(a) = &*ev {
                assert_eq!(a.request_id, "req-1");
                assert_eq!(a.model, "heuristic");
                assert!(a.answer.contains("Positions:"));
                assert!(a.answer.contains("Risk:"));
                break;
            }
        }
    }
}
