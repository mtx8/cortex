//! "strategist" (squadron "strategy-ai") — the ONLY agent that talks to an
//! LLM on a cadence, and it runs at all only when an LLM is configured.
//! Invariants (non-negotiable):
//! - The LLM sees exactly `ledger.render()` plus a fixed instruction —
//!   never secrets, never config.
//! - Output is parsed defensively: every field optional, values clamped,
//!   unknown symbols dropped, at most 2 caution entries and 3 signals.
//! - The strategist NEVER does anything beyond thoughts, tighten-only
//!   caution requests, and advisory signals. No orders, no kill switch.
//! - Unparseable replies degrade to a Thought(info); the loop never dies.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use cx_core::events::{CautionUpdate, EngineEvent, StrategySignal};
use cx_core::time::now_ms;
use cx_core::types::Severity;
use cx_core::Bus;

use crate::ledger::{snip, ContextLedger};
use crate::llm::LlmClient;
use crate::publish_thought;

const AGENT: &str = "strategist";
const SQUADRON: &str = "strategy-ai";
const STRATEGY: &str = "llm-strategist";
const MAX_CAUTIONS: usize = 2;
const MAX_SIGNALS: usize = 3;
const MIN_CADENCE_SECS: u64 = 30;
const MAX_CADENCE_SECS: u64 = 86_400;

const INSTRUCTION: &str = r#"You are the strategist agent of the CORTEX X trading engine: a senior quantitative portfolio strategist. Read the engine context below — pay particular attention to the QUANT section (Hurst exponent: >0.5 trending / <0.5 mean-reverting; OU half-life: mean-reversion speed in M1 bars; Cornish-Fisher VaR95 and expected shortfall: 1-day tail loss; EWMA annualized vol), the regime and trend features in MARKET, the yield curve in MACRO (2s10s/3m10s inversion is a risk-off tell), and current PORTFOLIO exposure. Reason like a quant: favor trend signals where Hurst is high and regime is trending; favor fades where Hurst is low with a short OU half-life; tighten caution when tail risk (VaR/ES) is elevated relative to vol, when the curve inverts deeper, or when exposure looks crowded. Then reply with STRICT JSON only — no markdown fences, no prose outside the JSON — exactly this shape:
{"market_read": string, "caution": [{"scope": string|null, "value": number, "reason": string}], "signals": [{"symbol": string, "direction": number, "conviction": number, "rationale": string}], "notes": string}
Rules: caution is tighten-only advice with value in [0,1]; direction in [-1,1] (negative short, positive long); conviction in [0,1]; ground every rationale in numbers from the context; use only symbols shown in MARKET; at most 2 caution entries and 3 signals; empty arrays are fine."#;

/// The strategist's parsed, sanitized opinion for one cycle.
#[derive(Debug, Default, PartialEq)]
pub(crate) struct StrategistPlan {
    pub market_read: Option<String>,
    pub notes: Option<String>,
    /// (scope, value in [0,1], reason)
    pub cautions: Vec<(Option<String>, f64, String)>,
    /// (symbol, direction in [-1,1], conviction in [0,1], rationale)
    pub signals: Vec<(String, f64, f64, String)>,
}

pub(crate) fn spawn(
    bus: Arc<Bus>,
    ledger: Arc<ContextLedger>,
    llm: Arc<LlmClient>,
    symbols: Vec<String>,
    cadence_secs: u64,
) {
    tokio::spawn(async move {
        let cadence = Duration::from_secs(cadence_secs.clamp(MIN_CADENCE_SECS, MAX_CADENCE_SECS));
        loop {
            // Sleep first: the ledger needs a cadence of engine life before
            // the first read is worth tokens.
            tokio::time::sleep(cadence).await;
            run_once(&bus, &ledger, &llm, &symbols).await;
        }
    });
}

async fn run_once(bus: &Bus, ledger: &ContextLedger, llm: &LlmClient, symbols: &[String]) {
    let context = ledger.render(symbols);
    let prompt = format!("{INSTRUCTION}\n\n{context}");
    let reply = match llm.complete(&prompt).await {
        Ok((text, _model)) => text,
        Err(e) => {
            // No reachable LLM at all is the quiet steady state under
            // auto-detection — only real provider failures are worth a note.
            if !e.to_string().contains("no llm available") {
                publish_thought(
                    bus,
                    AGENT,
                    SQUADRON,
                    Severity::Info,
                    None,
                    0.3,
                    format!("strategist llm call failed ({e}); skipping cycle"),
                );
            }
            return;
        }
    };
    let Some(plan) = parse_reply(&reply, symbols) else {
        publish_thought(
            bus,
            AGENT,
            SQUADRON,
            Severity::Info,
            None,
            0.3,
            "strategist reply unparseable; skipped",
        );
        return;
    };

    if let Some(read) = &plan.market_read {
        let text = match &plan.notes {
            Some(n) => format!("{read} | notes: {n}"),
            None => read.clone(),
        };
        publish_thought(bus, AGENT, SQUADRON, Severity::Insight, None, 0.6, text);
    }
    for (scope, value, reason) in plan.cautions {
        bus.publish(EngineEvent::Caution(CautionUpdate {
            scope,
            value,
            reason,
            agent: AGENT.into(),
            ts_ms: now_ms(),
        }));
    }
    for (symbol, direction, conviction, rationale) in plan.signals {
        bus.publish(EngineEvent::Signal(StrategySignal {
            strategy: STRATEGY.into(),
            symbol,
            direction,
            conviction,
            rationale,
            features: BTreeMap::new(),
            ts_ms: now_ms(),
        }));
    }
}

/// Defensive parse of the LLM reply. `None` means no JSON object could be
/// recovered at all ("unparseable"); everything inside the object is
/// optional and sanitized:
/// - `value`/`conviction` clamped to [0,1], `direction` to [-1,1]
/// - entries with symbols not in `symbols` are dropped (caution scope too)
/// - at most 2 caution entries and 3 signals survive
pub(crate) fn parse_reply(raw: &str, symbols: &[String]) -> Option<StrategistPlan> {
    let start = raw.find('{')?;
    let end = raw.rfind('}')?;
    if end < start {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(&raw[start..=end]).ok()?;
    let obj = v.as_object()?;

    let canon = |s: &str| -> Option<String> {
        let up = s.trim().to_uppercase();
        symbols.iter().find(|sym| sym.to_uppercase() == up).cloned()
    };
    let text_of = |key: &str, max: usize| -> Option<String> {
        obj.get(key)
            .and_then(|x| x.as_str())
            .map(|s| snip(s.trim(), max))
            .filter(|s| !s.is_empty())
    };

    let market_read = text_of("market_read", 1_500);
    let notes = text_of("notes", 500);

    let mut cautions = Vec::new();
    if let Some(arr) = obj.get("caution").and_then(|x| x.as_array()) {
        for item in arr {
            if cautions.len() >= MAX_CAUTIONS {
                break;
            }
            let Some(o) = item.as_object() else { continue };
            let Some(value) = o.get("value").and_then(|x| x.as_f64()).filter(|v| v.is_finite())
            else {
                continue;
            };
            let scope = match o.get("scope") {
                None | Some(serde_json::Value::Null) => None,
                Some(serde_json::Value::String(s)) if s.trim().is_empty() => None,
                Some(serde_json::Value::String(s)) => match canon(s) {
                    Some(sym) => Some(sym),
                    None => continue, // unknown symbol scope: drop the entry
                },
                Some(_) => continue,
            };
            let reason = o
                .get("reason")
                .and_then(|x| x.as_str())
                .map(|s| snip(s.trim(), 200))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "strategist caution".into());
            cautions.push((scope, value.clamp(0.0, 1.0), reason));
        }
    }

    let mut signals = Vec::new();
    if let Some(arr) = obj.get("signals").and_then(|x| x.as_array()) {
        for item in arr {
            if signals.len() >= MAX_SIGNALS {
                break;
            }
            let Some(o) = item.as_object() else { continue };
            let Some(symbol) = o.get("symbol").and_then(|x| x.as_str()).and_then(&canon)
            else {
                continue; // unknown or missing symbol: drop
            };
            let Some(direction) = o
                .get("direction")
                .and_then(|x| x.as_f64())
                .filter(|v| v.is_finite())
            else {
                continue;
            };
            let conviction = o
                .get("conviction")
                .and_then(|x| x.as_f64())
                .filter(|v| v.is_finite())
                .map(|v| v.clamp(0.0, 1.0))
                .unwrap_or(0.25);
            let rationale = o
                .get("rationale")
                .and_then(|x| x.as_str())
                .map(|s| snip(s.trim(), 300))
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "llm strategist signal".into());
            signals.push((symbol, direction.clamp(-1.0, 1.0), conviction, rationale));
        }
    }

    Some(StrategistPlan {
        market_read,
        notes,
        cautions,
        signals,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn syms() -> Vec<String> {
        vec!["BTC-USD".into(), "ETH-USD".into()]
    }

    #[test]
    fn parses_a_valid_reply() {
        let raw = r#"{"market_read":"btc grinding higher on thin vol","caution":[{"scope":null,"value":0.2,"reason":"low liquidity"}],"signals":[{"symbol":"BTC-USD","direction":0.6,"conviction":0.7,"rationale":"trend intact"}],"notes":"watch the 10y"}"#;
        let plan = parse_reply(raw, &syms()).unwrap();
        assert_eq!(plan.market_read.as_deref(), Some("btc grinding higher on thin vol"));
        assert_eq!(plan.notes.as_deref(), Some("watch the 10y"));
        assert_eq!(plan.cautions, vec![(None, 0.2, "low liquidity".to_string())]);
        assert_eq!(
            plan.signals,
            vec![("BTC-USD".to_string(), 0.6, 0.7, "trend intact".to_string())]
        );
    }

    #[test]
    fn parses_reply_wrapped_in_markdown_and_prose() {
        let raw = "Sure! Here's my read:\n```json\n{\"market_read\":\"chop\",\"signals\":[]}\n```\nHope that helps!";
        let plan = parse_reply(raw, &syms()).unwrap();
        assert_eq!(plan.market_read.as_deref(), Some("chop"));
        assert!(plan.signals.is_empty());
    }

    #[test]
    fn hostile_junk_is_unparseable() {
        assert!(parse_reply("lol no", &syms()).is_none());
        assert!(parse_reply("", &syms()).is_none());
        assert!(parse_reply("{not json at all", &syms()).is_none());
        assert!(parse_reply("[1,2,3]", &syms()).is_none());
        // A bare JSON array of objects has no top-level object -> refused.
        assert!(parse_reply("} backwards {", &syms()).is_none());
    }

    #[test]
    fn out_of_range_values_are_clamped() {
        let raw = r#"{"caution":[{"scope":"BTC-USD","value":7.5,"reason":"x"}],"signals":[{"symbol":"ETH-USD","direction":-9.0,"conviction":42.0,"rationale":"y"}]}"#;
        let plan = parse_reply(raw, &syms()).unwrap();
        assert_eq!(plan.cautions[0].1, 1.0);
        assert_eq!(plan.signals[0].1, -1.0);
        assert_eq!(plan.signals[0].2, 1.0);
    }

    #[test]
    fn unknown_symbols_are_dropped_and_counts_capped() {
        let raw = r#"{
            "caution":[
                {"scope":"DOGE-USD","value":0.5,"reason":"unknown scope drops"},
                {"scope":null,"value":0.1,"reason":"a"},
                {"scope":"BTC-USD","value":0.2,"reason":"b"},
                {"scope":null,"value":0.3,"reason":"never reached (cap 2)"}
            ],
            "signals":[
                {"symbol":"DOGE-USD","direction":1.0,"conviction":1.0,"rationale":"dropped"},
                {"symbol":"btc-usd","direction":0.1,"conviction":0.1,"rationale":"case-folded ok"},
                {"symbol":"ETH-USD","direction":0.2,"conviction":0.2,"rationale":"ok"},
                {"symbol":"BTC-USD","direction":0.3,"conviction":0.3,"rationale":"ok"},
                {"symbol":"ETH-USD","direction":0.4,"conviction":0.4,"rationale":"over cap"}
            ]
        }"#;
        let plan = parse_reply(raw, &syms()).unwrap();
        assert_eq!(plan.cautions.len(), 2);
        assert_eq!(plan.cautions[0].2, "a");
        assert_eq!(plan.cautions[1].0.as_deref(), Some("BTC-USD"));
        assert_eq!(plan.signals.len(), 3);
        // Case-folded symbol resolves to the canonical config symbol.
        assert_eq!(plan.signals[0].0, "BTC-USD");
    }

    #[test]
    fn missing_fields_are_tolerated() {
        let plan = parse_reply("{}", &syms()).unwrap();
        assert_eq!(plan, StrategistPlan::default());
        // Entries missing their load-bearing field are skipped, not fatal.
        let raw = r#"{"caution":[{"scope":null,"reason":"no value"}],"signals":[{"symbol":"BTC-USD","conviction":0.5}]}"#;
        let plan = parse_reply(raw, &syms()).unwrap();
        assert!(plan.cautions.is_empty());
        assert!(plan.signals.is_empty());
    }
}
