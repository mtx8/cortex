//! The copilot — answers operator questions (`Command::AskAi` routed through
//! [`crate::MeshHandle::ask`]). Invariants:
//! - Each question runs in its own task; an answer can never block the mesh.
//! - The LLM sees only `ledger.render()` plus the question.
//! - With no LLM (or a failed one) the copilot still answers usefully from
//!   the ledger — a desk summary, not an error message — with model
//!   "heuristic".
//! - Every ask produces exactly one `EngineEvent::AiAnswer` on the bus.

use std::sync::Arc;

use cx_core::events::{AiAnswer, EngineEvent};
use cx_core::time::now_ms;
use cx_core::types::Severity;
use cx_core::Bus;

use crate::ledger::{fin, fmt_px, fmt_qty, sev_label, snip, ContextLedger};
use crate::llm::LlmClient;

/// Answer one operator question and publish the AiAnswer. Infallible by
/// design: every path ends in a published answer.
pub(crate) async fn answer(
    bus: Arc<Bus>,
    ledger: Arc<ContextLedger>,
    llm: Arc<LlmClient>,
    symbols: Vec<String>,
    request_id: String,
    question: String,
) {
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
         If the context does not contain the answer, say what IS known instead of guessing. \
         Never invent numbers.\n\n{context}\n\nOPERATOR QUESTION: {question}"
    );
    let (answer, model) = match llm.complete(&prompt).await {
        Ok((text, model)) => (text, model),
        Err(e) => {
            tracing::debug!(error = %e, "copilot llm unavailable; answering heuristically");
            (
                heuristic_answer(&ledger, &symbols, &question),
                "heuristic".to_string(),
            )
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
