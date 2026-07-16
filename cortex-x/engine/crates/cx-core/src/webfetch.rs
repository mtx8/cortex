//! WEB RESEARCH egress — the copilot's SEPARATE outbound channel for live
//! web access. This is NOT the trading egress: [`crate::egress::Egress`]
//! (market data, macro feeds, AI providers) keeps its exact-host allowlist
//! and stays byte-for-byte untouched, and nothing on a market-data or order
//! path ever calls into this module. This client can never carry a secret:
//! GET only, no auth headers, no cookies (reqwest's cookie store is never
//! enabled — it is not even compiled in), one fixed User-Agent.
//!
//! Policy, enforced per request AND per redirect hop:
//! - https only ([`reqwest::ClientBuilder::https_only`] plus the URL guard);
//!   default port (443) only; no userinfo in URLs.
//! - Redirects: at most [`RESEARCH_MAX_REDIRECTS`] hops, same scheme only
//!   (every hop must be https), every hop re-checked against the host guard.
//! - Response: [`RESEARCH_MAX_BYTES`] cap (the body is streamed; excess is
//!   discarded, never buffered), [`RESEARCH_TIMEOUT_SECS`] total timeout,
//!   `text/html` / `text/plain` content types only.
//! - Per-cycle request budget ([`ResearchBudget`]): one research cycle can
//!   spend at most N requests (search + page fetches), default
//!   [`DEFAULT_RESEARCH_BUDGET`], configured as `[ai] web_budget_per_query`.
//!
//! SSRF guard — honest about its limits. The guard REJECTS: IP-literal
//! hosts (ANY literal IP, v4 or v6, including non-canonical inet_aton
//! shorthand like `127.1` / `0177.0.0.1` / `0x7f.0.0.1` via the numeric-TLD
//! check — private ranges are classified by [`ip_is_private`] for the DNS
//! check), `localhost` and `*.localhost`,
//! single-label intranet names, and known private-use suffixes (`.local`,
//! `.internal`, `.lan`, `.home.arpa`, ...). Where feasible — the initial
//! fetch — the host is additionally pre-resolved and rejected when ANY
//! resolved address is private/loopback/link-local. Known limits:
//! 1. The pre-resolve check races the client's own resolution (TOCTOU): a
//!    DNS-rebinding server alternating public and private answers can slip
//!    through between check and connect.
//! 2. Redirect hops get hostname-level checks only — reqwest's redirect
//!    policy is synchronous, so no DNS pre-resolution there.
//! 3. The private-suffix list is a blocklist, not a proof: a public DNS
//!    name pointing at an internal address is caught only by check (1).
//! This is a research channel for public web pages, not a security boundary
//! against a hostile operator. Error strings carry the host, never the full
//! URL (query strings carry the operator's question).

use std::net::{IpAddr, Ipv4Addr};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use crate::error::CxError;

/// Response byte cap: bytes past this are discarded, never buffered.
pub const RESEARCH_MAX_BYTES: usize = 2 * 1024 * 1024;
/// Total per-request timeout (connect + headers + body).
pub const RESEARCH_TIMEOUT_SECS: u64 = 12;
/// Maximum redirect hops followed (same-scheme, guard-checked each hop).
pub const RESEARCH_MAX_REDIRECTS: usize = 3;
/// Fixed User-Agent — the ONLY header this client ever adds.
pub const RESEARCH_UA: &str = "cortex-x-research/0.1 (MTX Labs)";
/// HTML -> text extraction cap (chars), applied by [`html_to_text`].
pub const EXTRACT_MAX_CHARS: usize = 8_000;
/// Default per-cycle request budget (config: `[ai] web_budget_per_query`).
pub const DEFAULT_RESEARCH_BUDGET: usize = 6;

/// The research web client. Construct once, mint a fresh [`ResearchBudget`]
/// per research cycle via [`WebResearch::budget`].
pub struct WebResearch {
    client: reqwest::Client,
    budget_per_cycle: usize,
}

impl WebResearch {
    pub fn new(budget_per_cycle: usize) -> Self {
        // Custom redirect policy: every hop is re-checked (hop count, https,
        // host guard). A blocked hop fails the whole request.
        let policy = reqwest::redirect::Policy::custom(|attempt| {
            match redirect_allowed(attempt.url(), attempt.previous().len()) {
                Ok(()) => attempt.follow(),
                Err(reason) => {
                    let msg = format!("research redirect blocked: {reason}");
                    attempt.error(msg)
                }
            }
        });
        let client = reqwest::Client::builder()
            .redirect(policy)
            .https_only(true)
            .timeout(Duration::from_secs(RESEARCH_TIMEOUT_SECS))
            .user_agent(RESEARCH_UA)
            .build()
            .expect("reqwest client");
        Self {
            client,
            budget_per_cycle,
        }
    }

    /// A fresh budget for one research cycle.
    pub fn budget(&self) -> ResearchBudget {
        ResearchBudget::new(self.budget_per_cycle)
    }

    /// GET one https URL through the full guard stack, returning the raw
    /// text body (byte-capped, text/html or text/plain only). Check order
    /// matters: URL guard (free) -> budget (so blocked URLs never spend it
    /// -- and an exhausted budget fails before any network IO) -> DNS
    /// pre-resolve -> request.
    pub async fn fetch_text(
        &self,
        url: &str,
        budget: &ResearchBudget,
    ) -> Result<String, CxError> {
        let parsed = check_research_url(url)?;
        let host = parsed.host_str().unwrap_or("?").to_string();
        budget.spend()?;
        preresolve(&host).await?;
        let mut resp = self
            .client
            .get(parsed)
            .send()
            .await
            .map_err(|e| CxError::EgressFailed(format!("research: {host}: {}", scrub(&e))))?;
        let status = resp.status();
        if !status.is_success() {
            return Err(CxError::EgressFailed(format!("research: {host}: http {status}")));
        }
        let ctype = resp
            .headers()
            .get(reqwest::header::CONTENT_TYPE)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("")
            .to_ascii_lowercase();
        if !(ctype.starts_with("text/html") || ctype.starts_with("text/plain")) {
            let short: String = ctype.chars().take(40).collect();
            return Err(CxError::EgressBlocked(format!(
                "research: {host}: content-type not text ({short})"
            )));
        }
        // Stream the body up to the cap; excess bytes are discarded without
        // ever being buffered (a huge page can't balloon memory).
        let mut buf: Vec<u8> = Vec::with_capacity(64 * 1024);
        while let Some(chunk) = resp
            .chunk()
            .await
            .map_err(|e| CxError::EgressFailed(format!("research: {host}: {}", scrub(&e))))?
        {
            let room = RESEARCH_MAX_BYTES - buf.len();
            if chunk.len() >= room {
                buf.extend_from_slice(&chunk[..room]);
                break;
            }
            buf.extend_from_slice(&chunk);
        }
        Ok(String::from_utf8_lossy(&buf).into_owned())
    }

    /// [`Self::fetch_text`] followed by [`html_to_text`]: the guarded fetch
    /// plus tag/script/style stripping, whitespace collapse and the
    /// [`EXTRACT_MAX_CHARS`] cap.
    pub async fn fetch_page_text(
        &self,
        url: &str,
        budget: &ResearchBudget,
    ) -> Result<String, CxError> {
        Ok(html_to_text(&self.fetch_text(url, budget).await?))
    }
}

/// Per-cycle request budget: `spend` fails once the cycle's allowance is
/// gone, so one research cycle can never fan out unboundedly.
pub struct ResearchBudget {
    remaining: AtomicUsize,
}

impl ResearchBudget {
    pub fn new(n: usize) -> Self {
        Self {
            remaining: AtomicUsize::new(n),
        }
    }

    pub fn spend(&self) -> Result<(), CxError> {
        self.remaining
            .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |v| v.checked_sub(1))
            .map(|_| ())
            .map_err(|_| CxError::EgressBlocked("research budget exhausted".into()))
    }

    pub fn remaining(&self) -> usize {
        self.remaining.load(Ordering::SeqCst)
    }
}

// ---- policy functions (pure, zero-network, unit-tested) --------------------

/// Full URL guard for the research channel. Errors carry the host only.
pub fn check_research_url(url: &str) -> Result<reqwest::Url, CxError> {
    let parsed = reqwest::Url::parse(url)
        .map_err(|_| CxError::EgressBlocked("research: unparseable url".into()))?;
    if let Err(reason) = check_parsed_research_url(&parsed) {
        let host = parsed.host_str().unwrap_or("?");
        return Err(CxError::EgressBlocked(format!("research: {host}: {reason}")));
    }
    Ok(parsed)
}

/// The scheme/port/userinfo/host checks on an already-parsed URL. Shared by
/// the initial-fetch guard and the redirect policy.
pub fn check_parsed_research_url(url: &reqwest::Url) -> Result<(), &'static str> {
    if url.scheme() != "https" {
        return Err("https only");
    }
    if !url.username().is_empty() || url.password().is_some() {
        return Err("userinfo not allowed");
    }
    if url.port().is_some() {
        // url normalizes an explicit :443 away, so Some(_) is always
        // non-default — internal service ports are not reachable here.
        return Err("non-default port");
    }
    let Some(host) = url.host_str() else {
        return Err("no host");
    };
    // ANY literal IP is rejected (public ones included): research targets
    // are named web hosts, and this closes v4/v6/mapped-encoding games.
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    if bare.parse::<IpAddr>().is_ok() {
        return Err("ip-literal host");
    }
    // Non-canonical numeric hosts (127.1, 0177.0.0.1, 0x7f.0.0.1) fail the
    // IpAddr parse above yet still resolve numerically (inet_aton shorthand)
    // at connect time. Rejected HERE — not in the DNS pre-resolve — so
    // redirect hops, which get no pre-resolution (module limit 2), are
    // covered too.
    if host_ends_in_number(bare) {
        return Err("numeric host");
    }
    match hostname_block_reason(host) {
        Some(reason) => Err(reason),
        None => Ok(()),
    }
}

/// WHATWG-style "ends in a number" host test: true when the host's rightmost
/// non-empty label is entirely ASCII digits or a `0x`/`0X` hex literal. Real
/// DNS names never have such a TLD, but inet_aton-style resolution accepts
/// these as numeric addresses (`127.1`, `0177.0.0.1`, `0x7f.0.0.1`) even
/// though `IpAddr::from_str` rejects them — so any such host is treated as
/// an IP literal.
fn host_ends_in_number(bare: &str) -> bool {
    let Some(last) = bare.trim_end_matches('.').rsplit('.').next() else {
        return false;
    };
    if last.is_empty() {
        return false;
    }
    if last.bytes().all(|b| b.is_ascii_digit()) {
        return true;
    }
    let hex = last.strip_prefix("0x").or_else(|| last.strip_prefix("0X"));
    matches!(hex, Some(h) if h.bytes().all(|b| b.is_ascii_hexdigit()))
}

/// Hostname-level private-name blocklist (see the module docs for limits).
pub fn hostname_block_reason(host: &str) -> Option<&'static str> {
    let h = host.trim_end_matches('.').to_ascii_lowercase();
    if h == "localhost" || h.ends_with(".localhost") {
        return Some("localhost");
    }
    if !h.contains('.') {
        return Some("single-label host");
    }
    const PRIVATE_SUFFIXES: &[&str] = &[
        ".local",
        ".localdomain",
        ".internal",
        ".intranet",
        ".lan",
        ".home",
        ".corp",
        ".home.arpa",
    ];
    if PRIVATE_SUFFIXES.iter().any(|s| h.ends_with(s)) {
        return Some("private-use hostname");
    }
    None
}

/// Redirect-hop policy: bounded hop count plus the full URL guard on the
/// target. `prior_hops` is the number of URLs already visited beyond zero
/// (reqwest's `previous().len()`), so 4 means the 4th redirect — blocked.
pub fn redirect_allowed(url: &reqwest::Url, prior_hops: usize) -> Result<(), &'static str> {
    if prior_hops > RESEARCH_MAX_REDIRECTS {
        return Err("too many redirects");
    }
    check_parsed_research_url(url)
}

/// True when an address must never be fetched: loopback, RFC1918, link-local,
/// CGNAT, unspecified/broadcast, benchmarking, multicast/reserved, and their
/// v6 equivalents (unique-local, link-local, multicast, v4-mapped forms).
/// Not exhaustive across every IANA special registry — see module docs.
pub fn ip_is_private(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => {
            let o = v4.octets();
            v4.is_private()
                || v4.is_loopback()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_broadcast()
                || o[0] == 0
                || (o[0] == 100 && (64..=127).contains(&o[1])) // CGNAT 100.64/10
                || (o[0] == 192 && o[1] == 0 && o[2] == 0) // 192.0.0/24
                || (o[0] == 198 && (o[1] == 18 || o[1] == 19)) // benchmarking
                || o[0] >= 224 // multicast + reserved
        }
        IpAddr::V6(v6) => {
            let s = v6.segments();
            // ::ffff:a.b.c.d — classify by the mapped v4 address.
            if s[..5] == [0, 0, 0, 0, 0] && s[5] == 0xffff {
                let v4 =
                    Ipv4Addr::new((s[6] >> 8) as u8, s[6] as u8, (s[7] >> 8) as u8, s[7] as u8);
                return ip_is_private(IpAddr::V4(v4));
            }
            v6.is_loopback()
                || v6.is_unspecified()
                || (s[0] & 0xfe00) == 0xfc00 // unique-local fc00::/7
                || (s[0] & 0xffc0) == 0xfe80 // link-local fe80::/10
                || (s[0] & 0xff00) == 0xff00 // multicast ff00::/8
        }
    }
}

/// Pre-resolve `host` and reject when ANY answer is private (the "where
/// feasible" half of the SSRF guard — see module docs for the TOCTOU limit).
async fn preresolve(host: &str) -> Result<(), CxError> {
    match tokio::net::lookup_host((host, 443)).await {
        Ok(addrs) => {
            for addr in addrs {
                if ip_is_private(addr.ip()) {
                    return Err(CxError::EgressBlocked(format!(
                        "research: {host}: resolves to a private address"
                    )));
                }
            }
            Ok(())
        }
        Err(_) => Err(CxError::EgressFailed(format!(
            "research: {host}: dns lookup failed"
        ))),
    }
}

/// Reqwest errors can embed full URLs; keep only the error kind text.
fn scrub(e: &reqwest::Error) -> String {
    if e.is_timeout() {
        "timeout".into()
    } else if e.is_connect() {
        "connect failed".into()
    } else if e.is_redirect() {
        "redirect blocked".into()
    } else {
        "request failed".into()
    }
}

// ---- HTML -> text extraction (pure) -----------------------------------------

/// Strip an HTML document down to readable text: script/style/noscript
/// blocks and comments dropped, all tags removed, a handful of common
/// entities decoded, whitespace collapsed, capped at [`EXTRACT_MAX_CHARS`]
/// chars. Deliberately simple — a text scraper, not an HTML parser.
pub fn html_to_text(html: &str) -> String {
    let s = strip_block(html, "<script", "</script", true);
    let s = strip_block(&s, "<style", "</style", true);
    let s = strip_block(&s, "<noscript", "</noscript", true);
    let s = strip_block(&s, "<!--", "-->", false);
    let s = strip_tags(&s);
    let s = decode_entities(&s);
    let collapsed = s.split_whitespace().collect::<Vec<_>>().join(" ");
    if collapsed.chars().count() <= EXTRACT_MAX_CHARS {
        collapsed
    } else {
        let mut out: String = collapsed.chars().take(EXTRACT_MAX_CHARS).collect();
        out.push('…');
        out
    }
}

/// Remove every `open`..`close` block (case-insensitive; ASCII lowering
/// keeps byte offsets valid). When `scan_gt` is set the close pattern is a
/// tag prefix (`"</script"`) and removal extends through its `>`.
/// An unterminated block drops the rest of the input — safe for scraping.
fn strip_block(html: &str, open: &str, close: &str, scan_gt: bool) -> String {
    let lower = html.to_ascii_lowercase();
    let mut out = String::with_capacity(html.len());
    let mut pos = 0usize;
    while let Some(rel) = lower[pos..].find(open) {
        let start = pos + rel;
        out.push_str(&html[pos..start]);
        let Some(crel) = lower[start..].find(close) else {
            return out; // unterminated: drop the remainder
        };
        let mut end = start + crel + close.len();
        if scan_gt {
            end = lower[end..].find('>').map(|i| end + i + 1).unwrap_or(html.len());
        }
        pos = end;
    }
    out.push_str(&html[pos..]);
    out
}

/// Drop everything between `<` and `>`, emitting a space per tag so words
/// separated only by markup don't concatenate.
fn strip_tags(html: &str) -> String {
    let mut out = String::with_capacity(html.len());
    let mut in_tag = false;
    for c in html.chars() {
        match c {
            '<' if !in_tag => {
                in_tag = true;
                out.push(' ');
            }
            '>' if in_tag => in_tag = false,
            _ if !in_tag => out.push(c),
            _ => {}
        }
    }
    out
}

/// The common entities only; `&amp;` decodes LAST so `&amp;lt;` becomes the
/// literal text "&lt;" (single decode, never double).
fn decode_entities(s: &str) -> String {
    s.replace("&nbsp;", " ")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&#x27;", "'")
        .replace("&apos;", "'")
        .replace("&amp;", "&")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guard_rejects_ssrf_shapes() {
        // Any literal IP — public or private, v4 or v6.
        for url in [
            "https://8.8.8.8/x",
            "https://127.0.0.1/x",
            "https://10.0.0.8/x",
            "https://192.168.1.1/router",
            "https://169.254.169.254/latest/meta-data",
            "https://[::1]/x",
            "https://[fd00::1]/x",
        ] {
            let err = check_research_url(url).unwrap_err().to_string();
            assert!(err.contains("ip-literal"), "{url}: {err}");
        }
        // Private / local hostnames.
        for url in [
            "https://localhost/x",
            "https://foo.localhost/x",
            "https://printer.local/x",
            "https://intranet/x", // single-label
            "https://svc.internal/x",
            "https://router.lan/x",
            "https://nas.home.arpa/x",
        ] {
            assert!(check_research_url(url).is_err(), "{url} must be blocked");
        }
        // Scheme / port / userinfo.
        assert!(check_research_url("http://example.com/x").is_err(), "http");
        assert!(check_research_url("https://example.com:8443/x").is_err(), "port");
        assert!(
            check_research_url("https://user:pw@example.com/x").is_err(),
            "userinfo"
        );
        assert!(check_research_url("not a url").is_err());
        // Legit public https passes; explicit :443 normalizes to default.
        assert!(check_research_url("https://example.com/page?q=1").is_ok());
        assert!(check_research_url("https://example.com:443/").is_ok());
    }

    #[test]
    fn guard_rejects_non_canonical_numeric_hosts() {
        // inet_aton shorthand must be blocked whether the URL parser
        // canonicalizes it to a dotted quad (ip-literal) or leaves it
        // as-is (numeric host) — and on redirect hops too.
        for url in [
            "https://127.1/x",
            "https://0177.0.0.1/x",
            "https://0x7f.0.0.1/x",
            "https://0x7f.1/x",
            "https://010.010.010.010/x",
        ] {
            assert!(check_research_url(url).is_err(), "{url} must be blocked");
            if let Ok(parsed) = reqwest::Url::parse(url) {
                assert!(redirect_allowed(&parsed, 1).is_err(), "{url} redirect hop");
            }
        }
        // The label test itself, independent of URL-parser canonicalization.
        for h in ["127.1", "0177.0.0.1", "0x7f.0.0.1", "10.0.0.0x1", "a.b.0X1F", "1.2.3.4.5"] {
            assert!(host_ends_in_number(h), "{h} must read as numeric");
        }
        for h in ["example.com", "1.example.com", "web3.foo.bar", "a.0xzg", "e.com."] {
            assert!(!host_ends_in_number(h), "{h} is a DNS name");
        }
    }

    #[test]
    fn ip_privacy_classification() {
        let private = [
            "10.1.2.3",
            "172.16.0.1",
            "192.168.0.9",
            "169.254.169.254",
            "127.0.0.1",
            "100.64.0.1",
            "0.0.0.0",
            "255.255.255.255",
            "198.18.0.1",
            "224.0.0.1",
            "::1",
            "fc00::1",
            "fd12::1",
            "fe80::1",
            "ff02::1",
            "::ffff:10.0.0.1",
        ];
        for ip in private {
            assert!(ip_is_private(ip.parse().unwrap()), "{ip} must be private");
        }
        let public = ["8.8.8.8", "1.1.1.1", "93.184.216.34", "2606:4700::1", "::ffff:8.8.8.8"];
        for ip in public {
            assert!(!ip_is_private(ip.parse().unwrap()), "{ip} must be public");
        }
    }

    #[test]
    fn redirect_policy_limits_hops_scheme_and_targets() {
        let ok = reqwest::Url::parse("https://example.com/next").unwrap();
        // previous().len() is 1..=3 for the first three redirects: allowed.
        for hops in 1..=RESEARCH_MAX_REDIRECTS {
            assert!(redirect_allowed(&ok, hops).is_ok(), "hop {hops}");
        }
        // The 4th redirect is one too many.
        assert_eq!(
            redirect_allowed(&ok, RESEARCH_MAX_REDIRECTS + 1),
            Err("too many redirects")
        );
        // Same-scheme only: an https->http downgrade is blocked ...
        let http = reqwest::Url::parse("http://example.com/next").unwrap();
        assert_eq!(redirect_allowed(&http, 1), Err("https only"));
        // ... and every hop passes the full host guard.
        let private = reqwest::Url::parse("https://10.0.0.1/steal").unwrap();
        assert!(redirect_allowed(&private, 1).is_err());
        let local = reqwest::Url::parse("https://backend.internal/x").unwrap();
        assert!(redirect_allowed(&local, 1).is_err());
    }

    #[test]
    fn html_to_text_strips_scripts_styles_tags_and_entities() {
        let html = r#"<html><head>
            <style>body { color: red; }</style>
            <SCRIPT type="text/javascript">alert("evil &amp; hidden");</SCRIPT>
        </head><body>
            <!-- a comment with <b>markup</b> inside -->
            <h1>Fed holds &amp; markets rally</h1>
            <p>Rates stay at   <b>5.25%</b>&nbsp;&mdash; the &lt;pause&gt; continues.</p>
            <noscript>enable js</noscript>
        </body></html>"#;
        let text = html_to_text(html);
        assert!(text.contains("Fed holds & markets rally"), "{text}");
        assert!(text.contains("Rates stay at 5.25%"), "{text}");
        assert!(text.contains("<pause>"), "entities must decode: {text}");
        assert!(!text.contains("alert"), "script leaked: {text}");
        assert!(!text.contains("color: red"), "style leaked: {text}");
        assert!(!text.contains("a comment"), "comment leaked: {text}");
        assert!(!text.contains("enable js"), "noscript leaked: {text}");
        assert!(!text.contains('<') || text.contains("<pause>"), "{text}");
        // Whitespace collapsed: no double spaces anywhere.
        assert!(!text.contains("  "), "{text}");
    }

    #[test]
    fn html_to_text_caps_at_extract_limit() {
        let body = "word ".repeat(EXTRACT_MAX_CHARS); // way past the cap
        let text = html_to_text(&format!("<p>{body}</p>"));
        assert_eq!(text.chars().count(), EXTRACT_MAX_CHARS + 1, "cap + ellipsis");
        assert!(text.ends_with('…'));
    }

    #[test]
    fn html_to_text_survives_malformed_markup() {
        // Unterminated script: the remainder is dropped, never leaked.
        let text = html_to_text("<p>safe</p><script>evil never closes");
        assert!(text.contains("safe"), "{text}");
        assert!(!text.contains("evil"), "{text}");
        // Unclosed tag at EOF.
        assert_eq!(html_to_text("tail <b>bold</b> then <unclosed"), "tail bold then");
        assert_eq!(html_to_text(""), "");
    }

    #[test]
    fn budget_is_enforced() {
        let b = ResearchBudget::new(2);
        assert!(b.spend().is_ok());
        assert!(b.spend().is_ok());
        let err = b.spend().unwrap_err().to_string();
        assert!(err.contains("budget exhausted"), "{err}");
        assert_eq!(b.remaining(), 0);
    }

    /// Both rejection paths fire BEFORE any network IO: an exhausted budget
    /// (checked before DNS) and a guard-blocked URL (checked before budget —
    /// so a blocked URL never spends it either).
    #[tokio::test]
    async fn fetch_blocks_offline_on_guard_and_budget() {
        let web = WebResearch::new(0);
        let budget = web.budget();
        let err = web
            .fetch_text("https://example.com/", &budget)
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("budget exhausted"), "{err}");

        let web = WebResearch::new(6);
        let budget = web.budget();
        let err = web
            .fetch_text("https://127.0.0.1/admin", &budget)
            .await
            .unwrap_err()
            .to_string();
        assert!(err.contains("ip-literal"), "{err}");
        assert_eq!(budget.remaining(), 6, "blocked url must not spend budget");
    }
}
