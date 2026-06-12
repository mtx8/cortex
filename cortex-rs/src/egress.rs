//! The single outbound-network chokepoint for all OSINT / geo / alt-data fetches.
//!
//! Ported faithfully from omniscient-macos `src-tauri/src/http.rs` (read-only
//! source) and made framework-agnostic (no Tauri). Every request is validated
//! against a compile-time, exact-match host allowlist before a byte leaves the
//! machine, is https-only, follows redirects only within the allowlist, caps the
//! body at 5 MiB (streamed + aborted), strips renderer-controlled hop-by-hop
//! headers, and binds credential headers to the host they belong to. A fully
//! compromised Python agent (or a prompt-injected LLM tool call) can therefore
//! still only reach these hosts — this is what makes the egress SSRF-proof.
//!
//! Exposed to Python via PyO3 as `geo_fetch`, `validate_host`, and
//! `allowed_hosts`. Network keys never touch the SwiftUI WebView and never
//! appear in logs (we log host only, never the full URL/query).

use crate::error::GeoError;
use futures_util::StreamExt;
use pyo3::prelude::*;
use std::collections::HashMap;
use std::sync::LazyLock;
use std::time::Duration;

/// Default cap on any single response body. Streamed + aborted past this.
pub const MAX_BYTES: usize = 5 * 1024 * 1024;

/// Absolute ceiling a caller may raise the per-request cap to. Even a buggy or
/// compromised backend caller cannot request an unbounded body (anti-OOM/DoS).
/// Large trusted feeds (e.g. a full regional AIS snapshot) opt into a higher cap
/// up to this ceiling; the WebView never calls egress directly.
pub const MAX_BYTES_CEILING: usize = 32 * 1024 * 1024;

/// Exact, lowercase host allowlist. `https` only. Each entry is documented with
/// what it returns and why it is trusted (security requirement). Derived from
/// omniscient's v7 OSINT sources plus the trading/maritime/econ feeds CORTEX
/// needs. Adding a host requires: a stated data contract, rate-limit awareness,
/// and credential isolation (keys live in Keychain, bound per-host below).
pub const ALLOWED_HOSTS: &[&str] = &[
    // ---- OSINT / geo (from omniscient) -------------------------------------
    "opensky-network.org",       // live aircraft state vectors (OAuth2)
    "celestrak.org",             // satellite TLEs
    "celestrak.com",             // satellite TLEs (legacy host)
    "meri.digitraffic.fi",       // Finnish/Baltic AIS — free, no key
    "earthquake.usgs.gov",       // earthquakes (GeoJSON) — asset-proximity risk
    "ll.thespacedevs.com",       // rocket launches
    "fdo.rocketlaunch.live",     // launch fallback
    "api.open-meteo.com",        // weather (energy / agriculture)
    "api.ioda.inetintel.cc.gatech.edu", // internet blackout zones
    "api.gdeltproject.org",      // global news graph
    "tile.googleapis.com",       // map tiles (key injected server-side)
    // ---- maritime / commodity flow ----------------------------------------
    "stream.aisstream.io",       // global AIS websocket spine (free key)
    "api.vesselfinder.com",      // paid satellite AIS, dark zones (keyed-only)
    // ---- macro / fixed income / energy fundamentals -----------------------
    "api.eia.gov",               // EIA petroleum status + chokepoint volumes
    "api.stlouisfed.org",        // FRED yield curve + economic series
    "api.fiscaldata.treasury.gov", // US Treasury daily yield curve
    // ---- social (keyed-only; falls back to GDELT without a token) ----------
    "api.x.com",
    "api.twitter.com",
];

/// Hosts allowed to receive credential headers (Authorization/Cookie). A key for
/// one feed can never be forwarded to another allowlisted feed (no cross-feed
/// token leak). VesselFinder/EIA/FRED use query-param keys, not headers.
const CREDENTIAL_HOSTS: &[&str] = &["api.x.com", "api.twitter.com"];

/// Exact, case-insensitive host validation. Exact match only — a lookalike that
/// merely *contains* an allowed host (`earthquake.usgs.gov.evil.com`) is a
/// classic SSRF/allowlist bypass and must be rejected.
pub fn validate_host_str(host: &str) -> Result<(), GeoError> {
    let h = host.to_ascii_lowercase();
    if ALLOWED_HOSTS.iter().any(|a| *a == h) {
        Ok(())
    } else {
        Err(GeoError::HostNotAllowed(h))
    }
}

/// Coarse, secret-free classification of a reqwest error. We NEVER surface the
/// raw Display — for connect/redirect failures it can embed the full URL (and
/// the tile/key path). Callers send this stable class to the log / caller.
fn classify(e: &reqwest::Error) -> &'static str {
    if e.is_timeout() {
        "timeout"
    } else if e.is_connect() {
        "connect"
    } else if e.is_redirect() {
        "redirect-blocked"
    } else if e.is_decode() || e.is_body() {
        "body"
    } else {
        "request"
    }
}

fn build_client() -> reqwest::Client {
    // Redirects must NOT escape the allowlist. A 30x to a non-allowlisted (or
    // non-https) host is stopped, so a redirect can't be used to exfil or reach
    // an arbitrary host.
    let redirect = reqwest::redirect::Policy::custom(|attempt| {
        if attempt.previous().len() >= 8 {
            return attempt.error("too many redirects");
        }
        let url = attempt.url();
        let host_ok = url
            .host_str()
            .map(|h| {
                let h = h.to_ascii_lowercase();
                ALLOWED_HOSTS.iter().any(|a| *a == h)
            })
            .unwrap_or(false);
        // https + allowlisted host + default port only (no redirect to a non-443
        // port on an allowlisted host).
        if url.scheme() == "https" && host_ok && url.port().is_none() {
            attempt.follow()
        } else {
            attempt.stop()
        }
    });

    reqwest::Client::builder()
        .user_agent("CORTEX/1.0 (native macOS; autonomous trading geo-intelligence)")
        .gzip(true)
        .redirect(redirect)
        .connect_timeout(Duration::from_secs(10))
        .build()
        .expect("failed to build reqwest client")
}

/// Process-wide client (connection pooling, gzip, rustls — no OpenSSL).
static CLIENT: LazyLock<reqwest::Client> = LazyLock::new(build_client);

/// Process-wide multi-thread tokio runtime that drives the async egress. We keep
/// the PyO3 surface *blocking* (Python calls it from a thread-pool executor via
/// `loop.run_in_executor`) and release the GIL while the request is in flight.
static RUNTIME: LazyLock<tokio::runtime::Runtime> = LazyLock::new(|| {
    tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
        .expect("failed to build tokio runtime")
});

pub struct FetchOutcome {
    pub status: u16,
    pub content_type: String,
    pub body: String,
    pub truncated: bool,
}

/// Validate + GET with a per-request timeout and a streamed byte cap.
pub async fn guarded_get(
    client: &reqwest::Client,
    url: &str,
    headers: Option<HashMap<String, String>>,
    timeout_ms: u64,
    max_bytes: usize,
) -> Result<FetchOutcome, GeoError> {
    let cap = max_bytes.clamp(64 * 1024, MAX_BYTES_CEILING);
    let parsed = reqwest::Url::parse(url).map_err(|_| GeoError::InvalidUrl)?;
    if parsed.scheme() != "https" {
        return Err(GeoError::BadScheme);
    }
    let host = parsed.host_str().ok_or(GeoError::InvalidUrl)?.to_string();
    validate_host_str(&host)?;
    // Port must be the default https port. `url` normalizes :443 to None, so any
    // Some(port) is an explicit non-default port — reject it. Otherwise an
    // allowlisted host on a co-hosted non-443 service could be reached AND a bound
    // credential header forwarded there (the allowlist would be host-only).
    if let Some(p) = parsed.port() {
        return Err(GeoError::HostNotAllowed(format!("{host}:{p}")));
    }

    let mut req = client
        .get(parsed)
        .timeout(Duration::from_millis(timeout_ms.clamp(1000, 30_000)));

    if let Some(h) = headers {
        for (k, v) in h {
            // The caller must not control hop-by-hop / fetch-metadata headers.
            let kl = k.to_ascii_lowercase();
            if kl == "host" || kl == "content-length" || kl == "connection" || kl.starts_with("sec-") {
                continue;
            }
            // Credential headers are bound to their owning host — they can never
            // be forwarded to another allowlisted feed.
            if (kl == "authorization" || kl == "cookie" || kl == "proxy-authorization")
                && !CREDENTIAL_HOSTS.contains(&host.as_str())
            {
                continue;
            }
            req = req.header(k, v);
        }
    }

    let resp = req.send().await.map_err(|e| {
        // host only — never the full URL (keeps query params / tokens out of logs)
        eprintln!("[cortex-geo] {host}: {}", classify(&e));
        GeoError::Request(classify(&e).into())
    })?;
    let status = resp.status().as_u16();
    let content_type = resp
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("")
        .to_string();

    let mut stream = resp.bytes_stream();
    let mut buf: Vec<u8> = Vec::with_capacity(64 * 1024);
    let mut truncated = false;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk.map_err(|e| GeoError::Request(classify(&e).into()))?;
        if buf.len() + chunk.len() > cap {
            let take = cap.saturating_sub(buf.len());
            buf.extend_from_slice(&chunk[..take]);
            truncated = true;
            break;
        }
        buf.extend_from_slice(&chunk);
    }

    // Lossy decode: a byte-cap truncation can split a multi-byte codepoint (common
    // in AIS/CelesTrak/USGS names). The `truncated` flag already signals partial
    // data; do not discard a valid prefix over one split codepoint.
    let body = String::from_utf8_lossy(&buf).into_owned();
    Ok(FetchOutcome { status, content_type, body, truncated })
}

// ---------------------------------------------------------------------------
// PyO3 surface
// ---------------------------------------------------------------------------

/// Result of a guarded fetch, exposed to Python.
#[pyclass]
#[derive(Clone)]
pub struct FetchResult {
    #[pyo3(get)]
    pub status: u16,
    #[pyo3(get)]
    pub ok: bool,
    #[pyo3(get)]
    pub content_type: String,
    #[pyo3(get)]
    pub body: String,
    #[pyo3(get)]
    pub truncated: bool,
}

#[pymethods]
impl FetchResult {
    fn __repr__(&self) -> String {
        format!(
            "FetchResult(status={}, ok={}, bytes={}, truncated={})",
            self.status,
            self.ok,
            self.body.len(),
            self.truncated
        )
    }
}

/// Guarded HTTPS GET against the host allowlist. Blocking on the Python side —
/// call it inside `await loop.run_in_executor(None, geo_fetch, url, ...)` so the
/// asyncio event loop is never blocked. The GIL is released while in flight.
#[pyfunction]
#[pyo3(signature = (url, headers=None, timeout_ms=8000, max_bytes=MAX_BYTES))]
pub fn geo_fetch(
    py: Python<'_>,
    url: String,
    headers: Option<HashMap<String, String>>,
    timeout_ms: u64,
    max_bytes: usize,
) -> PyResult<FetchResult> {
    // pyo3 0.29: detach from the interpreter (formerly allow_threads) so the
    // asyncio thread-pool executor isn't blocked while the request is in flight.
    let outcome = py.detach(|| {
        RUNTIME.block_on(async { guarded_get(&CLIENT, &url, headers, timeout_ms, max_bytes).await })
    })?;
    Ok(FetchResult {
        status: outcome.status,
        ok: (200..300).contains(&outcome.status),
        content_type: outcome.content_type,
        body: outcome.body,
        truncated: outcome.truncated,
    })
}

/// True if `host` is on the egress allowlist (exact, case-insensitive).
#[pyfunction]
pub fn validate_host(host: &str) -> bool {
    validate_host_str(host).is_ok()
}

/// The full egress allowlist, for diagnostics / the security preflight.
#[pyfunction]
pub fn allowed_hosts() -> Vec<String> {
    ALLOWED_HOSTS.iter().map(|s| s.to_string()).collect()
}

/// Register egress symbols on the module.
pub fn register(m: &Bound<'_, PyModule>) -> PyResult<()> {
    m.add_function(wrap_pyfunction!(geo_fetch, m)?)?;
    m.add_function(wrap_pyfunction!(validate_host, m)?)?;
    m.add_function(wrap_pyfunction!(allowed_hosts, m)?)?;
    m.add_class::<FetchResult>()?;
    m.add("MAX_FETCH_BYTES", MAX_BYTES)?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn allowlist_exact_and_case_insensitive() {
        assert!(validate_host_str("earthquake.usgs.gov").is_ok());
        assert!(validate_host_str("EARTHQUAKE.USGS.GOV").is_ok());
        assert!(validate_host_str("meri.digitraffic.fi").is_ok());
        assert!(validate_host_str("api.eia.gov").is_ok());
        assert!(validate_host_str("stream.aisstream.io").is_ok());
    }

    #[test]
    fn allowlist_rejects_unknown_and_subdomain_spoof() {
        assert!(matches!(validate_host_str("evil.com"), Err(GeoError::HostNotAllowed(_))));
        // Exact match only — a lookalike that merely contains an allowed host
        // (classic SSRF bypass) must be rejected.
        assert!(validate_host_str("earthquake.usgs.gov.evil.com").is_err());
        assert!(validate_host_str("api.eia.gov.attacker.net").is_err());
        assert!(validate_host_str("not-celestrak.org").is_err());
    }

    #[tokio::test]
    async fn rejects_http_scheme_before_request() {
        let c = reqwest::Client::new();
        let r = guarded_get(&c, "http://earthquake.usgs.gov/x", None, 3000, MAX_BYTES).await;
        assert!(matches!(r, Err(GeoError::BadScheme)));
    }

    #[tokio::test]
    async fn rejects_disallowed_host_before_request() {
        let c = reqwest::Client::new();
        let r = guarded_get(&c, "https://attacker.example/secret", None, 3000, MAX_BYTES).await;
        assert!(matches!(r, Err(GeoError::HostNotAllowed(_))));
    }

    #[tokio::test]
    async fn rejects_non_default_port_on_allowlisted_host() {
        // Allowlisted host but an explicit non-443 port — must be rejected before
        // any byte leaves (host-only allowlist would otherwise forward credentials).
        let c = reqwest::Client::new();
        let r = guarded_get(&c, "https://api.x.com:1337/x", None, 3000, MAX_BYTES).await;
        assert!(matches!(r, Err(GeoError::HostNotAllowed(_))));
    }
}
