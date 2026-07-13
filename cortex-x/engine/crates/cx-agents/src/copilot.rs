//! The copilot — answers operator questions (`Command::AskAi` routed through
//! [`crate::MeshHandle::ask`]). Invariants:
//! - Each question runs in its own task; an answer can never block the mesh.
//!   Palace drawer scans (file IO) run on the blocking pool.
//! - The LLM sees only `ledger.render()` plus the question (and, for memory
//!   questions, PALACE recall hits — stored engine output, never secrets —
//!   each snipped to [`RECALL_HIT_CHARS`] chars before embedding).
//! - With no LLM (or a failed one) the copilot still answers usefully from
//!   the ledger — a desk summary, not an error message — with model
//!   "heuristic". Memory questions answer with the (snipped) hits directly.
//! - Every ask produces exactly one `EngineEvent::AiAnswer` on the bus.

use std::sync::Arc;

use cx_core::events::{AiAnswer, EngineEvent};
use cx_core::time::now_ms;
use cx_core::types::Severity;
use cx_core::Bus;

use crate::ledger::{fin, fmt_px, fmt_qty, sev_label, snip, ContextLedger};
use crate::llm::LlmClient;
use crate::palace::Palace;

/// Every recall-style answer starts with this marker. The palace ingest
/// skips AiAnswers carrying it: a recall answer embeds stored drawer hits,
/// and re-remembering it would compound the palace into itself until the
/// total-size guard froze all writes.
pub(crate) const RECALL_ANSWER_PREFIX: &str = "Palace recall";

/// Each recall hit is snipped to this many chars before it is embedded in a
/// prompt or answer — the drawers stay verbatim; what rides into LLM
/// context (and back onto the bus) is bounded.
const RECALL_HIT_CHARS: usize = 600;

/// Answer one operator question and publish the AiAnswer. Infallible by
/// design: every path ends in a published answer.
pub(crate) async fn answer(
    bus: Arc<Bus>,
    ledger: Arc<ContextLedger>,
    llm: Arc<LlmClient>,
    palace: Option<Arc<Palace>>,
    symbols: Vec<String>,
    request_id: String,
    question: String,
) {
    // PALACE recall: a "recall ..." / "what did we learn ..." question
    // searches the verbatim drawers. Hits (snipped) ride into the LLM
    // context; on the heuristic path they ARE the answer. The drawer scan
    // is file IO — run it on the blocking pool, never on the async runtime.
    let recall_hits: Option<Vec<String>> = match (palace.as_ref(), recall_query(&question)) {
        (Some(p), Some(q)) => {
            let p = Arc::clone(p);
            match tokio::task::spawn_blocking(move || p.recall(&q)).await {
                Ok(hits) => Some(hits),
                Err(e) => {
                    tracing::warn!(error = %e, "palace recall task failed");
                    None
                }
            }
        }
        _ => None,
    };
    let palace_block = match &recall_hits {
        Some(hits) if !hits.is_empty() => format!(
            "\n\n=== PALACE RECALL (verbatim stored memory, newest first) ===\n{}",
            hits.iter()
                .map(|h| snip(h, RECALL_HIT_CHARS))
                .collect::<Vec<_>>()
                .join("\n")
        ),
        Some(_) => "\n\n=== PALACE RECALL ===\nno stored memory matched the question".into(),
        None => String::new(),
    };

    let context = ledger.render(&symbols);
    let prompt = format!(
        "You are the CORTEX X trading-desk copilot: a senior quantitative analyst and \
         derivatives-literate desk assistant. Using ONLY the engine context below, answer \
         the operator's question concisely and concretely, the way a head of desk would. \
         You understand and should USE the QUANT section: Hurst exponent (>0.5 trending, \
         <0.5 mean-reverting), OU half-life (mean-reversion speed in M1 bars), \
         Cornish-Fisher VaR95 / expected shortfall (1-day tail loss), EWMA annualized vol, \
         regimes, and the yield curve (2s10s/3m10s, inversion risk). Translate the math \
         into decisions: what it implies for sizing, entries, exits and risk right now. \
         When a PALACE RECALL section is present, ground your answer in those verbatim \
         memory hits and quote them faithfully. \
         If the context does not contain the answer, say what IS known instead of guessing. \
         Never invent numbers.\n\n{context}{palace_block}\n\nOPERATOR QUESTION: {question}"
    );
    let (answer, model) = match llm.complete(&prompt).await {
        Ok((text, model)) => (text, model),
        Err(e) => {
            tracing::debug!(error = %e, "copilot llm unavailable; answering heuristically");
            let text = match &recall_hits {
                Some(hits) => format_recall_answer(&question, hits),
                None => heuristic_answer(&ledger, &symbols, &question),
            };
            (text, "heuristic".to_string())
        }
    };
    bus.publish(EngineEvent::AiAnswer(AiAnswer {
        request_id,
        question,
        answer,
        model,
        ts_ms: now_ms(),
    }));
}

/// Detect a memory question and extract its search query. `"recall <q>"`
/// (case-insensitive prefix) or any question containing "what did we learn"
/// searches the palace; an empty extracted query recalls the newest
/// entries. None = not a memory question.
pub(crate) fn recall_query(question: &str) -> Option<String> {
    let lower = question.trim().to_lowercase();
    if let Some(rest) = lower.strip_prefix("recall") {
        // "recall", "recall <q>", "recall: <q>" — but not "recalling ...".
        if rest.is_empty() || rest.starts_with([' ', ':', ',']) {
            return Some(rest.trim_start_matches([':', ',']).trim().to_string());
        }
        return None;
    }
    if let Some(pos) = lower.find("what did we learn") {
        let mut rest = lower[pos + "what did we learn".len()..].trim();
        for lead in ["about ", "from ", "on ", "re "] {
            if let Some(r) = rest.strip_prefix(lead) {
                rest = r.trim();
                break;
            }
        }
        return Some(rest.trim_end_matches(['?', '.', '!']).trim().to_string());
    }
    None
}

/// The heuristic answer to a memory question: the stored hits themselves,
/// each snipped to [`RECALL_HIT_CHARS`]. Always starts with
/// [`RECALL_ANSWER_PREFIX`] so the palace ingest can recognize (and skip)
/// its own output.
pub(crate) fn format_recall_answer(question: &str, hits: &[String]) -> String {
    if hits.is_empty() {
        return format!(
            "{RECALL_ANSWER_PREFIX}: no stored memory matched \"{}\". The drawers hold \
             strategist decisions, research briefs, cautions, exits and copilot Q&A as \
             they happen.",
            snip(question, 120)
        );
    }
    let mut out =
        format!("{RECALL_ANSWER_PREFIX} — verbatim from the drawers (newest first):\n");
    for h in hits {
        out.push_str(&format!("- {}\n", snip(h, RECALL_HIT_CHARS)));
    }
    out
}

/// Compose a desk-assistant answer straight from the ledger: prices and
/// session moves, positions and PnL, risk posture, the latest macro read,
/// and the most recent notable agent notes.
pub(crate) fn heuristic_answer(
    ledger: &ContextLedger,
    symbols: &[String],
    question: &str,
) -> String {
    let st = ledger.snapshot();
    let mut out = String::with_capacity(1024);
    out.push_str("Desk read, straight from the live ledger:\n\n");

    // Market: last prices + session moves.
    let mut market = Vec::new();
    for sym in symbols {
        if let Some(p) = st.prices.get(sym) {
            let mut line = format!("{sym} {}", fmt_px(p.last));
            if p.last.is_finite() && p.session_open.is_finite() && p.session_open > 0.0 {
                let chg = (p.last / p.session_open - 1.0) * 100.0;
                if chg.is_finite() {
                    line.push_str(&format!(" ({chg:+.2}% session)"));
                }
            }
            market.push(line);
        }
    }
    if market.is_empty() {
        out.push_str("Market: no live prices yet.\n");
    } else {
        out.push_str(&format!("Market: {}.\n", market.join("; ")));
    }

    // Positions + PnL.
    let open: Vec<_> = st
        .positions
        .values()
        .filter(|p| p.qty.abs() > 1e-12)
        .collect();
    if open.is_empty() {
        out.push_str("Positions: flat — no open positions.\n");
    } else {
        let lines: Vec<String> = open
            .iter()
            .map(|p| {
                format!(
                    "{} {} {} @ {} (uPnL {:+.2})",
                    if p.qty > 0.0 { "long" } else { "short" },
                    fmt_qty(p.qty.abs()),
                    p.symbol,
                    fmt_px(p.avg_px),
                    fin(p.unrealized_pnl),
                )
            })
            .collect();
        out.push_str(&format!("Positions: {}.\n", lines.join("; ")));
    }
    if let Some(a) = &st.account {
        out.push_str(&format!(
            "Account: equity {}, day realized {:+.2}, day drawdown {:.2}%, fills today {}.\n",
            fmt_px(a.equity),
            fin(a.realized_pnl_day),
            fin(a.drawdown_day) * 100.0,
            st.fills_today,
        ));
    }

    // Risk posture.
    match &st.risk {
        Some(r) => {
            let why = if r.caution_reasons.is_empty() {
                String::new()
            } else {
                format!(" ({})", snip(&r.caution_reasons.join("; "), 160))
            };
            out.push_str(&format!(
                "Risk: kill switch {}, autonomy {:?}, caution {:.2}{}, throttle {:.2}.\n",
                if r.kill_switch { "ENGAGED" } else { "off" },
                r.autonomy,
                fin(r.caution),
                why,
                fin(r.throttle),
            ));
        }
        None => out.push_str("Risk: no risk status received yet.\n"),
    }

    // Latest macro read.
    if let Some(m) = &st.macro_snap {
        let mut line = format!("Macro: curve {}", m.curve_regime);
        if let Some(s) = m.spread_2s10s_bps {
            line.push_str(&format!(" (2s10s {:+.1}bps)", fin(s)));
        }
        if let Some(y10) = m.yields.get("10y") {
            line.push_str(&format!(", 10y {:.2}%", fin(*y10)));
        }
        if !m.fx.is_empty() {
            let fx: Vec<String> = m
                .fx
                .iter()
                .map(|(k, v)| format!("{k} {:.4}", fin(*v)))
                .collect();
            line.push_str(&format!("; fx {}", fx.join(" ")));
        }
        line.push_str(".\n");
        out.push_str(&line);
    }

    // Three most recent notable notes (insight and up), newest last.
    let notable: Vec<_> = st
        .thoughts
        .iter()
        .rev()
        .filter(|t| t.severity >= Severity::Insight)
        .take(3)
        .collect();
    if !notable.is_empty() {
        out.push_str("Recent notes:\n");
        for t in notable.iter().rev() {
            out.push_str(&format!(
                "- [{}] {}: {}\n",
                sev_label(t.severity),
                t.agent,
                snip(&t.text, 160),
            ));
        }
    }

    out.push_str(&format!(
        "\nRe \"{}\": the summary above is the freshest engine state I hold; no LLM is configured, so this answer is assembled directly from the live ledger.",
        snip(question, 120)
    ));
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::config::AiConfig;
    use cx_core::store::BarStore;

    #[test]
    fn recall_query_detects_memory_questions() {
        assert_eq!(recall_query("recall NVDA breakout"), Some("nvda breakout".into()));
        assert_eq!(recall_query("Recall: CPI"), Some("cpi".into()));
        assert_eq!(recall_query("recall"), Some(String::new()));
        assert_eq!(
            recall_query("so, what did we learn about NVDA?"),
            Some("nvda".into())
        );
        assert_eq!(recall_query("What did we learn?"), Some(String::new()));
        assert_eq!(recall_query("how are we positioned?"), None);
        assert_eq!(recall_query("show recall stats"), None, "prefix only");
    }

    #[tokio::test]
    async fn recall_path_returns_verbatim_hits_on_the_heuristic_path() {
        let dir = crate::palace::test_dir("copilot");
        let palace = Palace::open(dir.clone()).unwrap();
        palace.remember(
            "NVDA",
            "regime",
            "NVDA breakout above 900 held for 3 sessions before fading",
            vec![],
            1,
        );
        palace.remember("decisions", "strategist", "cut gross into FOMC", vec![], 2);

        let bus = Bus::new(64);
        let mut rx = bus.subscribe();
        let ledger = ContextLedger::new(Arc::new(BarStore::new()));
        let llm = Arc::new(LlmClient::with_probe(AiConfig::default(), false)); // no provider
        answer(
            Arc::clone(&bus),
            ledger,
            llm,
            Some(Arc::clone(&palace)),
            vec!["NVDA".to_string()],
            "req-9".into(),
            "recall NVDA breakout".into(),
        )
        .await;

        let ev = rx.recv().await.expect("bus closed");
        match &*ev {
            EngineEvent::AiAnswer(a) => {
                assert_eq!(a.model, "heuristic");
                assert!(
                    a.answer
                        .contains("NVDA breakout above 900 held for 3 sessions before fading"),
                    "verbatim hit missing: {}",
                    a.answer
                );
                assert!(a.answer.contains("Palace recall"), "{}", a.answer);
                assert!(
                    !a.answer.contains("cut gross into FOMC"),
                    "non-matching entry leaked: {}",
                    a.answer
                );
            }
            other => panic!("expected AiAnswer, got {other:?}"),
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn recall_hits_are_snipped_before_embedding_in_answers() {
        let dir = crate::palace::test_dir("copilot-snip");
        let palace = Palace::open(dir.clone()).unwrap();
        // Stored fully (under the palace's per-entry cap), but far past the
        // per-hit embedding budget.
        palace.remember("NVDA", "note", format!("snipmark {}", "z".repeat(1_500)), vec![], 1);

        let bus = Bus::new(64);
        let mut rx = bus.subscribe();
        let ledger = ContextLedger::new(Arc::new(BarStore::new()));
        let llm = Arc::new(LlmClient::with_probe(AiConfig::default(), false));
        answer(
            Arc::clone(&bus),
            ledger,
            llm,
            Some(Arc::clone(&palace)),
            vec![],
            "req-12".into(),
            "recall snipmark".into(),
        )
        .await;

        let ev = rx.recv().await.expect("bus closed");
        match &*ev {
            EngineEvent::AiAnswer(a) => {
                assert!(a.answer.starts_with(RECALL_ANSWER_PREFIX), "{}", a.answer);
                assert!(a.answer.contains("snipmark"), "{}", a.answer);
                assert!(
                    !a.answer.contains(&"z".repeat(700)),
                    "hit was embedded unsnipped ({} chars)",
                    a.answer.len()
                );
                assert!(a.answer.contains('…'), "snip marker missing: {}", a.answer);
            }
            other => panic!("expected AiAnswer, got {other:?}"),
        }
        let _ = std::fs::remove_dir_all(dir);
    }

    #[tokio::test]
    async fn recall_with_no_match_says_so_and_non_memory_questions_stay_desk_reads() {
        let dir = crate::palace::test_dir("copilot-nomatch");
        let palace = Palace::open(dir.clone()).unwrap();
        palace.remember("decisions", "strategist", "cut gross into FOMC", vec![], 1);

        let bus = Bus::new(64);
        let mut rx = bus.subscribe();
        let ledger = ContextLedger::new(Arc::new(BarStore::new()));
        let llm = Arc::new(LlmClient::with_probe(AiConfig::default(), false));
        answer(
            Arc::clone(&bus),
            Arc::clone(&ledger),
            Arc::clone(&llm),
            Some(Arc::clone(&palace)),
            vec![],
            "req-10".into(),
            "recall unicorn rally".into(),
        )
        .await;
        let ev = rx.recv().await.expect("bus closed");
        if let EngineEvent::AiAnswer(a) = &*ev {
            assert!(a.answer.contains("no stored memory matched"), "{}", a.answer);
        } else {
            panic!("expected AiAnswer");
        }

        // A normal question keeps the plain desk read even with a palace.
        answer(
            bus.clone(),
            ledger,
            llm,
            Some(palace),
            vec![],
            "req-11".into(),
            "how are we positioned?".into(),
        )
        .await;
        let ev = rx.recv().await.expect("bus closed");
        if let EngineEvent::AiAnswer(a) = &*ev {
            assert!(a.answer.contains("Desk read"), "{}", a.answer);
            assert!(!a.answer.contains("Palace recall"), "{}", a.answer);
        } else {
            panic!("expected AiAnswer");
        }
        let _ = std::fs::remove_dir_all(dir);
    }
}
