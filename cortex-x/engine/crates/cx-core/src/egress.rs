//! Hardened egress chokepoint — the ONLY way engine code makes outbound
//! HTTP requests (market-data websockets excepted; they have their own
//! pinned hosts). Enforces: https-only, exact-host allowlist, no redirects,
//! response byte cap, timeout, and secret-free error strings.

use std::time::Duration;

use crate::error::CxError;

/// Hosts the engine is permitted to reach over REST.
pub const ALLOWED_HOSTS: &[&str] = &[
    "api.exchange.coinbase.com",
    "api.coinbase.com",
    "api.frankfurter.dev",
    "home.treasury.gov",
    "api.anthropic.com",
    "cdn.cboe.com",
    "query1.finance.yahoo.com",
    "localhost",
    "127.0.0.1",
];

pub const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
pub const TIMEOUT_SECS: u64 = 15;

#[derive(Debug, Clone)]
pub struct Egress {
    client: reqwest::Client,
}

impl Default for Egress {
    fn default() -> Self {
        Self::new()
    }
}

impl Egress {
    pub fn new() -> Self {
        let client = reqwest::Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .timeout(Duration::from_secs(TIMEOUT_SECS))
            .user_agent("cortex-x/0.1 (MTX Labs)")
            .build()
            .expect("reqwest client");
        Self { client }
    }

    fn check_url(url: &str) -> Result<reqwest::Url, CxError> {
        let parsed = reqwest::Url::parse(url)
            .map_err(|_| CxError::EgressBlocked("unparseable url".into()))?;
        let host = parsed
            .host_str()
            .ok_or_else(|| CxError::EgressBlocked("no host".into()))?;
        let local = host == "localhost" || host == "127.0.0.1";
        if parsed.scheme() != "https" && !local {
            return Err(CxError::EgressBlocked(format!("non-https to {host}")));
        }
        if !ALLOWED_HOSTS.contains(&host) {
            return Err(CxError::EgressBlocked(format!("host not allowlisted: {host}")));
        }
        Ok(parsed)
    }

    /// GET returning capped text. Error strings carry the host, never the
    /// full URL (query strings can hold keys).
    pub async fn get_text(&self, url: &str) -> Result<String, CxError> {
        self.get_text_with_cap(url, MAX_RESPONSE_BYTES).await
    }

    /// Same as [`get_text`] with an explicit byte cap for known-large payloads
    /// (e.g. full option chains). The allowlist still applies unchanged.
    pub async fn get_text_with_cap(&self, url: &str, cap: usize) -> Result<String, CxError> {
        let parsed = Self::check_url(url)?;
        let host = parsed.host_str().unwrap_or("?").to_string();
        let resp = self
            .client
            .get(parsed)
            .send()
            .await
            .map_err(|e| CxError::EgressFailed(format!("{host}: {}", scrub(&e))))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(CxError::EgressFailed(format!("{host}: http {status}")));
        }
        let bytes = resp
            .bytes()
            .await
            .map_err(|e| CxError::EgressFailed(format!("{host}: {}", scrub(&e))))?;
        if bytes.len() > cap {
            return Err(CxError::EgressFailed(format!("{host}: response too large")));
        }
        String::from_utf8(bytes.to_vec())
            .map_err(|_| CxError::EgressFailed(format!("{host}: non-utf8 body")))
    }

    /// POST json -> json, with an optional bearer-style header. Used by the
    /// AI providers; the key travels in a header and never in errors.
    pub async fn post_json(
        &self,
        url: &str,
        headers: &[(&str, &str)],
        body: &serde_json::Value,
    ) -> Result<serde_json::Value, CxError> {
        let parsed = Self::check_url(url)?;
        let host = parsed.host_str().unwrap_or("?").to_string();
        let mut req = self.client.post(parsed).json(body);
        for (k, v) in headers {
            req = req.header(*k, *v);
        }
        let resp = req
            .send()
            .await
            .map_err(|e| CxError::EgressFailed(format!("{host}: {}", scrub(&e))))?;
        let status = resp.status();
        let bytes = resp
            .bytes()
            .await
            .map_err(|e| CxError::EgressFailed(format!("{host}: {}", scrub(&e))))?;
        if bytes.len() > MAX_RESPONSE_BYTES {
            return Err(CxError::EgressFailed(format!("{host}: response too large")));
        }
        if !status.is_success() {
            // Surface a short prefix of the error body — enough to debug,
            // too short to leak anything meaningful.
            let prefix: String = String::from_utf8_lossy(&bytes).chars().take(200).collect();
            return Err(CxError::EgressFailed(format!("{host}: http {status}: {prefix}")));
        }
        serde_json::from_slice(&bytes)
            .map_err(|_| CxError::EgressFailed(format!("{host}: invalid json body")))
    }
}

/// Reqwest errors can embed full URLs; keep only the error kind text.
fn scrub(e: &reqwest::Error) -> String {
    if e.is_timeout() {
        "timeout".into()
    } else if e.is_connect() {
        "connect failed".into()
    } else {
        "request failed".into()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocks_unlisted_and_plain_http() {
        assert!(Egress::check_url("https://evil.example.com/x").is_err());
        assert!(Egress::check_url("http://home.treasury.gov/x").is_err());
        assert!(Egress::check_url("https://home.treasury.gov/x").is_ok());
        assert!(Egress::check_url("http://127.0.0.1:11434/v1/chat").is_ok());
    }
}
