//! LLM client — local-first with AUTO-DETECTION, Anthropic fallback.
//! Invariants:
//! - Every request flows through [`Egress`] (allowlist, timeout, byte cap).
//! - The API key is exposed ONLY to place it in a request header; it never
//!   appears in errors, logs, or prompts.
//! - Each attempt sits behind a 60s guard timeout on top of Egress' own 15s,
//!   so a wedged provider can never stall a mesh task indefinitely.
//! - The LLM is strictly advisory and NEVER in the execution hot path.
//!
//! Local detection: when no local url is configured, the client probes the
//! standard local servers (Ollama :11434, LM Studio :1234) via the
//! OpenAI-compatible `/v1/models` endpoint, picks a sensible model, and
//! caches the result. A user who starts Ollama AFTER the engine is up gets
//! picked up automatically on the next cycle (probe backoff 60s).

use std::time::Duration;

use cx_core::config::AiConfig;
use cx_core::egress::Egress;
use cx_core::error::CxError;
use cx_core::time::now_ms;

const GUARD: Duration = Duration::from_secs(60);
const ANTHROPIC_URL: &str = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION: &str = "2023-06-01";
const LOCAL_CANDIDATES: &[&str] = &["http://127.0.0.1:11434", "http://127.0.0.1:1234"];
const PROBE_BACKOFF_MS: i64 = 60_000;
/// Preference order when the configured model is not on the server.
const MODEL_PREFS: &[&str] = &["llama", "qwen", "mistral", "gemma", "deepseek", "phi"];

#[derive(Default)]
struct DetectState {
    resolved: Option<(String, String)>,
    last_probe_ms: i64,
}

pub(crate) struct LlmClient {
    egress: Egress,
    ai: AiConfig,
    probe_enabled: bool,
    detect: tokio::sync::RwLock<DetectState>,
}

impl LlmClient {
    pub fn new(ai: AiConfig) -> Self {
        Self::with_probe(ai, true)
    }

    /// Tests disable probing so they never touch a developer's real local
    /// LLM server.
    pub fn with_probe(ai: AiConfig, probe_enabled: bool) -> Self {
        Self {
            egress: Egress::new(),
            ai,
            probe_enabled,
            detect: tokio::sync::RwLock::new(DetectState::default()),
        }
    }

    /// True when a provider is EXPLICITLY configured. Auto-detection can
    /// still find a local server at runtime even when this is false.
    pub fn is_configured(&self) -> bool {
        !self.ai.local_llm_url.trim().is_empty() || !self.ai.anthropic_api_key.is_empty()
    }

    /// The local endpoint to use right now: the configured one verbatim, or
    /// the cached/probed auto-detected one. None when nothing is reachable.
    async fn resolve_local(&self) -> Option<(String, String)> {
        let configured = self.ai.local_llm_url.trim();
        if !configured.is_empty() {
            return Some((
                configured.trim_end_matches('/').to_string(),
                self.ai.local_llm_model.clone(),
            ));
        }
        if !self.probe_enabled {
            return None;
        }
        {
            let st = self.detect.read().await;
            if st.resolved.is_some() {
                return st.resolved.clone();
            }
            if now_ms() - st.last_probe_ms < PROBE_BACKOFF_MS {
                return None;
            }
        }
        let mut st = self.detect.write().await;
        if st.resolved.is_some() {
            return st.resolved.clone();
        }
        if now_ms() - st.last_probe_ms < PROBE_BACKOFF_MS {
            return None;
        }
        st.last_probe_ms = now_ms();
        for base in LOCAL_CANDIDATES {
            let url = format!("{base}/v1/models");
            let Ok(Ok(raw)) =
                tokio::time::timeout(Duration::from_secs(3), self.egress.get_text(&url)).await
            else {
                continue;
            };
            let ids = parse_model_ids(&raw);
            if ids.is_empty() {
                continue;
            }
            let model = pick_model(&ids, &self.ai.local_llm_model);
            tracing::info!(server = %base, model = %model, "local llm auto-detected");
            st.resolved = Some((base.to_string(), model));
            return st.resolved.clone();
        }
        None
    }

    /// Forget a failed auto-detected endpoint so the next call re-probes.
    async fn invalidate_local(&self) {
        if self.ai.local_llm_url.trim().is_empty() {
            let mut st = self.detect.write().await;
            st.resolved = None;
        }
    }

    /// Complete `prompt`, returning (text, model_name). Local (configured or
    /// auto-detected) is tried first; Anthropic is the fallback.
    pub async fn complete(&self, prompt: &str) -> Result<(String, String), CxError> {
        let mut last_err: Option<CxError> = None;

        if let Some((base, model)) = self.resolve_local().await {
            match tokio::time::timeout(GUARD, self.try_local(&base, &model, prompt)).await {
                Ok(Ok(text)) => return Ok((text, model)),
                Ok(Err(e)) => {
                    self.invalidate_local().await;
                    last_err = Some(e);
                }
                Err(_) => {
                    self.invalidate_local().await;
                    last_err = Some(CxError::Ai("local llm timed out".into()));
                }
            }
        }

        if !self.ai.anthropic_api_key.is_empty() {
            match tokio::time::timeout(GUARD, self.try_anthropic(prompt)).await {
                Ok(Ok(text)) => return Ok((text, self.ai.model.clone())),
                Ok(Err(e)) => last_err = Some(e),
                Err(_) => last_err = Some(CxError::Ai("anthropic timed out".into())),
            }
        }

        Err(last_err.unwrap_or_else(|| CxError::Ai("no llm available".into())))
    }

    /// OpenAI-style chat completion against a local endpoint. Egress permits
    /// localhost/127.0.0.1 over plain http.
    async fn try_local(&self, base: &str, model: &str, prompt: &str) -> Result<String, CxError> {
        let url = format!("{base}/v1/chat/completions");
        let body = serde_json::json!({
            "model": model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": self.ai.max_output_tokens,
        });
        let resp = self.egress.post_json(&url, &[], &body).await?;
        resp.get("choices")
            .and_then(|c| c.get(0))
            .and_then(|c| c.get("message"))
            .and_then(|m| m.get("content"))
            .and_then(|c| c.as_str())
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .ok_or_else(|| CxError::Ai("local llm returned no content".into()))
    }

    /// Anthropic Messages API. The key travels in the `x-api-key` header
    /// only; response text blocks are concatenated.
    async fn try_anthropic(&self, prompt: &str) -> Result<String, CxError> {
        let key = self.ai.anthropic_api_key.expose();
        let headers: [(&str, &str); 3] = [
            ("x-api-key", key),
            ("anthropic-version", ANTHROPIC_VERSION),
            ("content-type", "application/json"),
        ];
        let body = serde_json::json!({
            "model": self.ai.model,
            "max_tokens": self.ai.max_output_tokens,
            "messages": [{"role": "user", "content": prompt}],
        });
        let resp = self.egress.post_json(ANTHROPIC_URL, &headers, &body).await?;
        let mut text = String::new();
        if let Some(items) = resp.get("content").and_then(|c| c.as_array()) {
            for it in items {
                if it.get("type").and_then(|t| t.as_str()) == Some("text") {
                    if let Some(s) = it.get("text").and_then(|t| t.as_str()) {
                        text.push_str(s);
                    }
                }
            }
        }
        let text = text.trim().to_string();
        if text.is_empty() {
            Err(CxError::Ai("anthropic returned no text content".into()))
        } else {
            Ok(text)
        }
    }
}

/// `/v1/models` -> ["llama3.1:latest", ...]. Both Ollama and LM Studio use
/// the OpenAI list shape.
fn parse_model_ids(raw: &str) -> Vec<String> {
    serde_json::from_str::<serde_json::Value>(raw)
        .ok()
        .and_then(|v| {
            v.get("data")?.as_array().map(|arr| {
                arr.iter()
                    .filter_map(|m| m.get("id").and_then(|i| i.as_str()).map(String::from))
                    .collect()
            })
        })
        .unwrap_or_default()
}

fn pick_model(ids: &[String], preferred: &str) -> String {
    if !preferred.trim().is_empty() {
        if let Some(hit) = ids.iter().find(|i| i.starts_with(preferred.trim())) {
            return hit.clone();
        }
    }
    for pref in MODEL_PREFS {
        if let Some(hit) = ids.iter().find(|i| i.to_lowercase().contains(pref)) {
            return hit.clone();
        }
    }
    ids.first().cloned().unwrap_or_else(|| "default".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::config::Secret;

    #[tokio::test]
    async fn unconfigured_client_errs_without_network() {
        // Probe disabled: never touches a developer's real local server.
        let llm = LlmClient::with_probe(AiConfig::default(), false);
        assert!(!llm.is_configured());
        let err = llm.complete("hello").await.unwrap_err();
        assert!(err.to_string().contains("no llm available"));
    }

    #[test]
    fn configured_detection() {
        let ai = AiConfig {
            local_llm_url: "http://127.0.0.1:11434".into(),
            ..Default::default()
        };
        assert!(LlmClient::new(ai).is_configured());

        let ai = AiConfig {
            anthropic_api_key: Secret("sk-test".into()),
            ..Default::default()
        };
        assert!(LlmClient::new(ai).is_configured());
    }

    #[test]
    fn model_listing_and_preference() {
        let raw = r#"{"object":"list","data":[{"id":"nomic-embed-text"},{"id":"qwen2.5:14b"},{"id":"llama3.1:8b"}]}"#;
        let ids = parse_model_ids(raw);
        assert_eq!(ids.len(), 3);
        // Configured model wins by prefix.
        assert_eq!(pick_model(&ids, "qwen2.5"), "qwen2.5:14b");
        // Otherwise preference order: llama beats qwen.
        assert_eq!(pick_model(&ids, ""), "llama3.1:8b");
        // Unknown preferred falls through to prefs.
        assert_eq!(pick_model(&ids, "gpt-oss"), "llama3.1:8b");
        assert!(parse_model_ids("junk").is_empty());
    }
}
