//! Hardened egress chokepoint — the ONLY way engine code makes outbound
//! HTTP requests (market-data websockets excepted; they have their own
//! pinned hosts). Enforces: https-only, exact-host allowlist, no redirects,
//! response byte cap, timeout, and secret-free error strings.

use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};
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
    "data.sec.gov",
    "www.sec.gov",
    // EDGAR full-text search (intel/FILINGS dedicated browser). Same hardened
    // egress: https-only, no redirects, byte cap, timeout; keyless, no secrets.
    "efts.sec.gov",
    // FINRA consolidated bi-monthly short interest (Rule 4560) — keyless public
    // CSV, the authoritative source for short % of float. Same hardened egress:
    // https-only, no redirects, byte cap, timeout; no credentials ever sent.
    "cdn.finra.org",
    "api.gdeltproject.org",
    // Read-only news/RSS + Atom feeds (intel/NEWS side only). Same hardened
    // egress: https-only, no redirects, byte cap, timeout. No credentials
    // ever travel to these; they publish public headlines.
    "news.google.com",
    "www.cnbc.com",
    "finance.yahoo.com",
    "feeds.finance.yahoo.com",
    "feeds.content.dowjones.io",
    "www.nasdaq.com",
    "www.aljazeera.com",
    "www.prnewswire.com",
    "www.globenewswire.com",
    "localhost",
    "127.0.0.1",
];

pub const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
pub const TIMEOUT_SECS: u64 = 15;

/// First local cooldown after a host says "slow down".
const THROTTLE_BASE_MS: i64 = 15_000;
/// Ceiling on the local cooldown. Long enough to actually let a rate limit
/// window expire, short enough that a recovered host is retried within minutes.
const THROTTLE_MAX_MS: i64 = 5 * 60_000;

/// Per-HOST cooldowns after a 429 / 503, shared PROCESS-WIDE.
///
/// Deliberately global rather than per-[`Egress`]: several subsystems construct
/// their own `Egress` (some per request), so a per-instance map would not
/// restrain anything. A rate limit belongs to the host and the process, not to
/// whichever struct happened to make the call.
///
/// Why this exists: nothing anywhere honoured a 429. Two intel pollers share one
/// keyless GDELT host on independent timers, and once that host started
/// throttling they simply kept asking at full cadence — observed in a live
/// engine log as 1,834 `http 429` responses across 64 consecutive hours, which
/// is a self-sustaining ban rather than a transient failure. Backing off locally
/// both stops the hammering and makes the failure cheap (no socket at all while
/// inside the cooldown).
static HOST_COOLDOWN: OnceLock<Mutex<HashMap<String, Cooldown>>> = OnceLock::new();

#[derive(Debug, Clone, Copy)]
struct Cooldown {
    /// Wall-clock ms before which requests to this host fail fast.
    until_ms: i64,
    /// Consecutive throttle responses, driving the exponential growth.
    strikes: u32,
}

fn cooldowns() -> &'static Mutex<HashMap<String, Cooldown>> {
    HOST_COOLDOWN.get_or_init(|| Mutex::new(HashMap::new()))
}

/// Remaining cooldown for `host` in ms, or 0 when it is free to call.
fn cooldown_remaining_ms(host: &str) -> i64 {
    let map = cooldowns().lock().unwrap_or_else(|p| p.into_inner());
    map.get(host)
        .map(|c| (c.until_ms - crate::time::now_ms()).max(0))
        .unwrap_or(0)
}

/// Record a throttle response and return the cooldown now in force (ms).
/// `retry_after_secs` is the host's own `Retry-After` when it sent one — always
/// preferred over our guess, since the host knows its window.
fn note_throttled(host: &str, retry_after_secs: Option<i64>) -> i64 {
    let mut map = cooldowns().lock().unwrap_or_else(|p| p.into_inner());
    let entry = map.entry(host.to_string()).or_insert(Cooldown {
        until_ms: 0,
        strikes: 0,
    });
    entry.strikes = entry.strikes.saturating_add(1);
    let backoff_ms = match retry_after_secs {
        Some(secs) if secs > 0 => (secs * 1_000).min(THROTTLE_MAX_MS),
        _ => {
            let shift = entry.strikes.saturating_sub(1).min(8);
            THROTTLE_BASE_MS
                .saturating_mul(1_i64 << shift)
                .min(THROTTLE_MAX_MS)
        }
    };
    entry.until_ms = crate::time::now_ms() + backoff_ms;
    backoff_ms
}

/// A successful response clears the host's penalty, so one bad window does not
/// keep a healthy host in a long cooldown.
fn note_success(host: &str) {
    let mut map = cooldowns().lock().unwrap_or_else(|p| p.into_inner());
    map.remove(host);
}

/// True for the statuses that mean "you are asking too often".
fn is_throttle_status(status: reqwest::StatusCode) -> bool {
    status == reqwest::StatusCode::TOO_MANY_REQUESTS
        || status == reqwest::StatusCode::SERVICE_UNAVAILABLE
}

fn retry_after_secs(resp: &reqwest::Response) -> Option<i64> {
    resp.headers()
        .get(reqwest::header::RETRY_AFTER)?
        .to_str()
        .ok()?
        .trim()
        .parse::<i64>()
        .ok()
}

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
            // SEC's edge (Akamai) 403s a generic UA — their access policy
            // requires a contact-identifying User-Agent. A role alias, never
            // a personal address. Harmless for every other allowlisted host.
            .user_agent("MTX Labs Cortex-X admin@mtxlabs.io")
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
        // Inside a cooldown, do not open a socket at all: continuing to ask is
        // what turns a rate limit into a standing ban.
        let waiting = cooldown_remaining_ms(&host);
        if waiting > 0 {
            return Err(CxError::EgressFailed(format!(
                "{host}: backing off after rate limit, {}s remaining",
                (waiting + 999) / 1_000
            )));
        }
        let resp = self
            .client
            .get(parsed)
            .send()
            .await
            .map_err(|e| CxError::EgressFailed(format!("{host}: {}", scrub(&e))))?;
        let status = resp.status();
        if is_throttle_status(status) {
            let backoff = note_throttled(&host, retry_after_secs(&resp));
            tracing::warn!(
                target: "cx_core::egress",
                host = %host, %status, backoff_ms = backoff,
                "host is rate limiting; backing off"
            );
            return Err(CxError::EgressFailed(format!(
                "{host}: http {status}, backing off {}s",
                backoff / 1_000
            )));
        }
        if !status.is_success() {
            return Err(CxError::EgressFailed(format!("{host}: http {status}")));
        }
        note_success(&host);
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

    /// The cooldown map is process-global, so these use distinct fake hosts and
    /// never collide with each other.
    #[test]
    fn a_throttled_host_backs_off_exponentially_and_is_cleared_by_success() {
        let host = "test-backoff.invalid";
        assert_eq!(cooldown_remaining_ms(host), 0, "starts free");

        let first = note_throttled(host, None);
        assert_eq!(first, THROTTLE_BASE_MS, "first strike is the base delay");
        assert!(cooldown_remaining_ms(host) > 0, "requests now fail fast");

        let second = note_throttled(host, None);
        assert_eq!(second, THROTTLE_BASE_MS * 2, "strikes compound");

        // A healthy response must not leave a recovered host in a long cooldown.
        note_success(host);
        assert_eq!(cooldown_remaining_ms(host), 0);
        assert_eq!(
            note_throttled(host, None),
            THROTTLE_BASE_MS,
            "strike count resets with the entry"
        );
        note_success(host);
    }

    #[test]
    fn retry_after_wins_over_our_guess_and_the_ceiling_holds() {
        let host = "test-retry-after.invalid";
        assert_eq!(note_throttled(host, Some(42)), 42_000, "host knows its window");
        // Absurd Retry-After values are clamped, so one hostile header cannot
        // silence a feed for hours.
        assert_eq!(note_throttled(host, Some(86_400)), THROTTLE_MAX_MS);
        note_success(host);

        // Exponential growth is also capped.
        let runaway = "test-runaway.invalid";
        let mut last = 0;
        for _ in 0..20 {
            last = note_throttled(runaway, None);
        }
        assert_eq!(last, THROTTLE_MAX_MS);
        note_success(runaway);
    }

    #[test]
    fn only_rate_limit_statuses_trigger_a_backoff() {
        use reqwest::StatusCode;
        assert!(is_throttle_status(StatusCode::TOO_MANY_REQUESTS));
        assert!(is_throttle_status(StatusCode::SERVICE_UNAVAILABLE));
        // A 403 or 404 is not "too often" — backing off would delay recovery
        // from an unrelated fault (the CBOE feed 403s on its own schedule).
        assert!(!is_throttle_status(StatusCode::FORBIDDEN));
        assert!(!is_throttle_status(StatusCode::NOT_FOUND));
        assert!(!is_throttle_status(StatusCode::INTERNAL_SERVER_ERROR));
    }

    #[test]
    fn blocks_unlisted_and_plain_http() {
        assert!(Egress::check_url("https://evil.example.com/x").is_err());
        assert!(Egress::check_url("http://home.treasury.gov/x").is_err());
        assert!(Egress::check_url("https://home.treasury.gov/x").is_ok());
        assert!(Egress::check_url("http://127.0.0.1:11434/v1/chat").is_ok());
    }

    #[test]
    fn sec_edgar_hosts_are_allowlisted_https_only() {
        // The FILINGS browser reaches submissions (data.sec.gov), archives
        // (www.sec.gov) and full-text search (efts.sec.gov) — all https-only.
        for host in ["data.sec.gov", "www.sec.gov", "efts.sec.gov"] {
            assert!(
                Egress::check_url(&format!("https://{host}/LATEST/search-index?q=x")).is_ok(),
                "{host} should be allowlisted"
            );
            assert!(
                Egress::check_url(&format!("http://{host}/x")).is_err(),
                "{host} must be https-only"
            );
        }
    }

    #[test]
    fn news_and_google_news_hosts_are_allowlisted_https_only() {
        // The added read-only news feeds resolve, over https only.
        for host in [
            "news.google.com",
            "www.cnbc.com",
            "finance.yahoo.com",
            "feeds.finance.yahoo.com",
            "feeds.content.dowjones.io",
            "www.nasdaq.com",
            "www.aljazeera.com",
            "www.prnewswire.com",
            "www.globenewswire.com",
        ] {
            assert!(
                Egress::check_url(&format!("https://{host}/feed")).is_ok(),
                "{host} should be allowlisted"
            );
            assert!(
                Egress::check_url(&format!("http://{host}/feed")).is_err(),
                "{host} must be https-only"
            );
        }
    }
}
