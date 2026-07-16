//! WEB RESEARCH — keyless web search + page extraction for the copilot.
//!
//! Every request rides [`cx_core::webfetch::WebResearch`] (the SEPARATE
//! research channel: https-only, SSRF-guarded, redirect/byte/time-capped,
//! per-cycle budget). The hardened trading [`cx_core::egress::Egress`] is
//! never involved. Allowlist policy: the SEARCH host is PINNED in code
//! ([`SEARCH_HOST`], never config-expandable); RESULT links may point at any
//! https host, but only through the research-channel guards — a result that
//! names an IP literal, a private hostname, http://, or a non-default port
//! never even enters the result list.
//!
//! Honest fragility note: [`parse_ddg_results`] scrapes DuckDuckGo's html
//! endpoint (`html.duckduckgo.com/html/?q=`) with a tolerant string scanner
//! keyed on the `result__a` / `result__snippet` CSS classes and the
//! `uddg=` redirect parameter. Markup drift, bot-detection interstitials,
//! or an empty SERP all degrade to an EMPTY result list — never an error,
//! never a panic. The copilot then says so instead of guessing.

use cx_core::webfetch::{check_research_url, WebResearch};

use crate::ledger::snip;

/// The pinned search host. Search queries go here and nowhere else.
pub(crate) const SEARCH_HOST: &str = "html.duckduckgo.com";
/// Parsed results are capped here whatever the SERP holds.
pub(crate) const MAX_RESULTS: usize = 5;
/// How many top result pages are fetched for full-text extracts.
pub(crate) const PAGES_TO_FETCH: usize = 2;
/// Render caps for titles/snippets riding into prompts and answers.
const TITLE_CHARS: usize = 160;
const SNIPPET_CHARS: usize = 280;
/// The citation suffix lists at most this many domains.
const MAX_SOURCE_DOMAINS: usize = 6;

/// One parsed search result.
#[derive(Debug, Clone)]
pub(crate) struct SearchResult {
    pub title: String,
    pub url: String,
    pub domain: String,
    pub snippet: String,
}

/// One fetched page, reduced to a text extract.
#[derive(Debug, Clone)]
pub(crate) struct PageExtract {
    pub domain: String,
    pub extract: String,
}

/// Everything one research cycle produced.
#[derive(Debug, Clone, Default)]
pub(crate) struct SearchBundle {
    pub query: String,
    pub results: Vec<SearchResult>,
    pub pages: Vec<PageExtract>,
}

/// Run one research cycle: search, parse (degrading to empty on any
/// malformation), fetch the top [`PAGES_TO_FETCH`] pages. Infallible by
/// design — every failure shrinks the bundle instead of erroring, and the
/// per-cycle budget bounds total network fan-out.
pub(crate) async fn research(web: &WebResearch, query: &str) -> SearchBundle {
    let mut bundle = SearchBundle {
        query: query.to_string(),
        ..Default::default()
    };
    let budget = web.budget();
    let url = format!("https://{SEARCH_HOST}/html/?q={}", urlencode(query));
    let raw = match web.fetch_text(&url, &budget).await {
        Ok(raw) => raw,
        Err(e) => {
            tracing::warn!(error = %e, "web search fetch failed");
            return bundle;
        }
    };
    bundle.results = parse_ddg_results(&raw);
    if bundle.results.is_empty() {
        tracing::debug!("ddg parse produced no results (markup drift or empty serp)");
    }
    for r in bundle.results.iter().take(PAGES_TO_FETCH) {
        match web.fetch_page_text(&r.url, &budget).await {
            Ok(extract) if !extract.trim().is_empty() => bundle.pages.push(PageExtract {
                domain: r.domain.clone(),
                extract,
            }),
            Ok(_) => {}
            Err(e) => tracing::debug!(error = %e, domain = %r.domain, "page fetch failed"),
        }
    }
    bundle
}

/// Unique source domains, pages (actually read) first, then result-only
/// domains — bounded to [`MAX_SOURCE_DOMAINS`].
pub(crate) fn unique_domains(b: &SearchBundle) -> Vec<String> {
    let mut seen: Vec<String> = Vec::new();
    for d in b
        .pages
        .iter()
        .map(|p| p.domain.as_str())
        .chain(b.results.iter().map(|r| r.domain.as_str()))
    {
        if !d.is_empty() && !seen.iter().any(|s| s == d) {
            seen.push(d.to_string());
        }
    }
    seen.truncate(MAX_SOURCE_DOMAINS);
    seen
}

/// The `"sources: d1, d2"` citation suffix; empty when nothing was fetched.
pub(crate) fn sources_suffix(b: &SearchBundle) -> String {
    let d = unique_domains(b);
    if d.is_empty() {
        String::new()
    } else {
        format!("sources: {}", d.join(", "))
    }
}

/// Scrape DDG's html endpoint. Tolerant single-pass anchor scan:
/// `result__a` anchors open a result (href via `uddg=` redirect or direct
/// https), the next `result__snippet` anchor attaches its snippet. Results
/// failing the research URL guard (http, IP literal, private name, the
/// search host itself) are dropped where they stand — a rejected result's
/// snippet is skipped too, never misattributed to the previous result.
/// Anything unrecognizable degrades to an empty vec.
pub(crate) fn parse_ddg_results(html: &str) -> Vec<SearchResult> {
    let lower = html.to_ascii_lowercase();
    let mut out: Vec<SearchResult> = Vec::new();
    let mut skip_next_snippet = false;
    let mut pos = 0usize;
    loop {
        let Some(rel) = lower[pos..].find("<a ") else { break };
        let a_start = pos + rel;
        let Some(tag_end_rel) = lower[a_start..].find('>') else { break };
        let tag_end = a_start + tag_end_rel;
        let Some(close_rel) = lower[tag_end..].find("</a>") else { break };
        let attrs = &html[a_start..tag_end];
        let attrs_lower = &lower[a_start..tag_end];
        let inner = &html[tag_end + 1..tag_end + close_rel];
        pos = tag_end + close_rel + "</a>".len();

        if attrs_lower.contains("result__a") {
            if out.len() >= MAX_RESULTS {
                break;
            }
            skip_next_snippet = true; // until this result proves admissible
            let Some(href) = extract_attr(attrs, "href") else { continue };
            let Some(url) = resolve_ddg_href(&href) else { continue };
            // Guard-check the RESULT link itself: only fetchable targets
            // (and never the search host) enter the list at all.
            let Ok(parsed) = check_research_url(&url) else { continue };
            let domain = parsed.host_str().unwrap_or("").to_ascii_lowercase();
            if domain.is_empty() || domain.ends_with("duckduckgo.com") {
                continue;
            }
            let title = snip(&clean_fragment(inner), TITLE_CHARS);
            if title.is_empty() {
                continue;
            }
            skip_next_snippet = false;
            out.push(SearchResult {
                title,
                url,
                domain,
                snippet: String::new(),
            });
        } else if attrs_lower.contains("result__snippet") {
            if skip_next_snippet {
                skip_next_snippet = false;
                continue;
            }
            if let Some(last) = out.last_mut() {
                if last.snippet.is_empty() {
                    last.snippet = snip(&clean_fragment(inner), SNIPPET_CHARS);
                }
            }
        }
    }
    out
}

/// Inner-anchor HTML fragment -> clean one-line text.
fn clean_fragment(fragment: &str) -> String {
    cx_core::webfetch::html_to_text(fragment)
}

/// Pull `name="..."` (or single-quoted) out of a tag's attribute string.
fn extract_attr(tag: &str, name: &str) -> Option<String> {
    let lower = tag.to_ascii_lowercase();
    for quote in ['"', '\''] {
        let pat = format!("{name}={quote}");
        if let Some(i) = lower.find(&pat) {
            let rest = &tag[i + pat.len()..];
            if let Some(end) = rest.find(quote) {
                return Some(rest[..end].to_string());
            }
        }
    }
    None
}

/// DDG result hrefs are usually redirect links carrying the real target in
/// the `uddg=` query parameter (`//duckduckgo.com/l/?uddg=<urlencoded>`);
/// occasionally they are direct. Anything else (ads' `y.js`, relative junk)
/// resolves to None.
fn resolve_ddg_href(href: &str) -> Option<String> {
    let href = href.replace("&amp;", "&");
    if let Some(rest) = href.split("uddg=").nth(1) {
        let enc = rest.split('&').next().unwrap_or("");
        let dec = urldecode(enc);
        return if dec.is_empty() { None } else { Some(dec) };
    }
    if href.starts_with("https://") {
        return Some(href);
    }
    None
}

/// Percent-encode a query for the search URL (RFC 3986 unreserved set).
pub(crate) fn urlencode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for b in s.as_bytes() {
        match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'.' | b'_' | b'~' => {
                out.push(*b as char)
            }
            _ => out.push_str(&format!("%{b:02X}")),
        }
    }
    out
}

/// Percent-decode (+ '+' as space). Malformed escapes pass through as
/// literals; invalid UTF-8 decodes lossily — never a panic.
pub(crate) fn urldecode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out: Vec<u8> = Vec::with_capacity(bytes.len());
    let mut i = 0usize;
    while i < bytes.len() {
        match bytes[i] {
            b'%' if i + 2 < bytes.len() => {
                if let (Some(h), Some(l)) = (hexval(bytes[i + 1]), hexval(bytes[i + 2])) {
                    out.push(h * 16 + l);
                    i += 3;
                    continue;
                }
                out.push(b'%');
                i += 1;
            }
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b => {
                out.push(b);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn hexval(b: u8) -> Option<u8> {
    match b {
        b'0'..=b'9' => Some(b - b'0'),
        b'a'..=b'f' => Some(b - b'a' + 10),
        b'A'..=b'F' => Some(b - b'A' + 10),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const FIXTURE: &str = r##"<html><body>
<div class="result results_links results_links_deep web-result">
  <h2 class="result__title">
    <a rel="nofollow" class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.reuters.com%2Fmarkets%2Fbtc%2Dflows&amp;rut=abc123">Bitcoin ETF flows hit <b>record</b></a>
  </h2>
  <a class="result__snippet" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.reuters.com%2Fmarkets%2Fbtc%2Dflows">Spot <b>bitcoin</b> ETFs drew record inflows this week.</a>
</div>
<div class="result">
  <a rel="nofollow" class="result__a" href="https://www.coindesk.com/markets/analysis">CoinDesk analysis</a>
  <a class="result__snippet">Analysts see continued demand.</a>
</div>
<div class="result">
  <a rel="nofollow" class="result__a" href="http://insecure.example.com/x">Insecure result</a>
  <a class="result__snippet">This snippet must NOT attach to CoinDesk.</a>
</div>
<div class="result">
  <a rel="nofollow" class="result__a" href="https://10.0.0.7/internal">Private target</a>
  <a class="result__snippet">Filtered by the SSRF guard.</a>
</div>
<div class="result">
  <a rel="nofollow" class="result__a" href="https://duckduckgo.com/y.js?ad_domain=ads.example.com">Sponsored</a>
  <a class="result__snippet">Ad result, dropped.</a>
</div>
</body></html>"##;

    #[test]
    fn ddg_parse_extracts_titles_urls_domains_snippets_and_filters() {
        let results = parse_ddg_results(FIXTURE);
        assert_eq!(results.len(), 2, "{results:?}");
        // uddg redirect decoded to the real target.
        assert_eq!(results[0].url, "https://www.reuters.com/markets/btc-flows");
        assert_eq!(results[0].domain, "www.reuters.com");
        assert_eq!(results[0].title, "Bitcoin ETF flows hit record");
        assert_eq!(
            results[0].snippet,
            "Spot bitcoin ETFs drew record inflows this week."
        );
        // Direct https link kept as-is.
        assert_eq!(results[1].url, "https://www.coindesk.com/markets/analysis");
        assert_eq!(results[1].domain, "www.coindesk.com");
        // The filtered http result's snippet never bled into CoinDesk's.
        assert_eq!(results[1].snippet, "Analysts see continued demand.");
        // http, ip-literal and ad results are all gone.
        assert!(!results.iter().any(|r| r.url.contains("insecure")), "{results:?}");
        assert!(!results.iter().any(|r| r.url.contains("10.0.0.7")), "{results:?}");
        assert!(!results.iter().any(|r| r.domain.contains("duckduckgo")), "{results:?}");
    }

    #[test]
    fn ddg_parse_caps_results_at_five() {
        let mut html = String::from("<html><body>");
        for i in 0..8 {
            html.push_str(&format!(
                r#"<a class="result__a" href="https://site{i}.example.com/p">Result {i}</a>
                   <a class="result__snippet">snippet {i}</a>"#
            ));
        }
        html.push_str("</body></html>");
        let results = parse_ddg_results(&html);
        assert_eq!(results.len(), MAX_RESULTS);
        assert_eq!(results[4].title, "Result 4");
        assert_eq!(results[4].snippet, "snippet 4");
    }

    #[test]
    fn ddg_parse_degrades_to_empty_on_malformed_html() {
        assert!(parse_ddg_results("").is_empty());
        assert!(parse_ddg_results("<html><p>no results for query</p></html>").is_empty());
        assert!(parse_ddg_results("<a class=\"result__a\" href=").is_empty());
        // Anomaly/bot interstitial: no result anchors at all.
        assert!(parse_ddg_results("<html>Unfortunately, bots are not allowed.</html>").is_empty());
        // An unclosed anchor mid-scan stops cleanly.
        assert!(parse_ddg_results("<a class=\"result__a\" href=\"https://a.example.com\">t").is_empty());
    }

    #[test]
    fn href_resolution_handles_uddg_direct_and_junk() {
        assert_eq!(
            resolve_ddg_href(
                "//duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%20b&amp;rut=x"
            ),
            Some("https://example.com/a b".into())
        );
        assert_eq!(
            resolve_ddg_href("https://example.com/direct"),
            Some("https://example.com/direct".into())
        );
        assert_eq!(resolve_ddg_href("/relative/path"), None);
        assert_eq!(resolve_ddg_href("//duckduckgo.com/l/?uddg=&rut=x"), None);
        assert_eq!(resolve_ddg_href("javascript:alert(1)"), None);
    }

    #[test]
    fn url_encoding_roundtrip() {
        assert_eq!(urlencode("btc etf flows?"), "btc%20etf%20flows%3F");
        assert_eq!(urlencode("a-b_c.d~e"), "a-b_c.d~e");
        assert_eq!(urldecode("a%20b+c"), "a b c");
        assert_eq!(urldecode("%zz"), "%zz", "malformed escape passes through");
        assert_eq!(urldecode("100%"), "100%", "trailing percent survives");
    }

    #[test]
    fn source_domains_dedupe_pages_first_and_suffix_formats() {
        let bundle = SearchBundle {
            query: "q".into(),
            results: vec![
                SearchResult {
                    title: "t1".into(),
                    url: "https://a.com/1".into(),
                    domain: "a.com".into(),
                    snippet: String::new(),
                },
                SearchResult {
                    title: "t2".into(),
                    url: "https://b.com/2".into(),
                    domain: "b.com".into(),
                    snippet: String::new(),
                },
                SearchResult {
                    title: "t3".into(),
                    url: "https://a.com/3".into(),
                    domain: "a.com".into(),
                    snippet: String::new(),
                },
            ],
            pages: vec![PageExtract {
                domain: "b.com".into(),
                extract: "x".into(),
            }],
        };
        // Pages (actually read) lead; duplicates collapse.
        assert_eq!(unique_domains(&bundle), vec!["b.com", "a.com"]);
        assert_eq!(sources_suffix(&bundle), "sources: b.com, a.com");
        assert_eq!(sources_suffix(&SearchBundle::default()), "");
    }
}
