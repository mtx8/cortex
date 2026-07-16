//! NEWS — company + market headlines and a filing-cadence earnings calendar.
//! Headlines come from the GDELT DOC 2.0 API (keyless), one query per
//! CONFIGURED equity that has a curated company name (symbols without a
//! curated entry are skipped — a ticker string makes a terrible news query)
//! plus one general markets query. Earnings dates come from SEC EDGAR
//! submissions. Publishes `EngineEvent::News`.
//!
//! Honesty notes:
//! - `next_estimate` is ARITHMETIC — last periodic (10-Q/10-K) filing date
//!   + 91 days — and every row's `basis` says "estimated from filing
//!   cadence (not confirmed)". No fake earnings calendar.
//! - Company queries quote the curated legal name verbatim; that
//!   under-matches (missing colloquial mentions) rather than over-matches.
//! - Absent tone parses as 0.0 (neutral), same rule as MERIDIAN.
//! - A symbol the SEC ticker map doesn't know simply has no earnings row —
//!   absence over invention.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cx_core::config::Config;
use cx_core::egress::Egress;
use cx_core::events::{EarningsRow, EngineEvent, NewsBoard, NewsItem};
use cx_core::time::now_ms;
use cx_core::Bus;

use crate::{company, meridian, splc_data};

/// Headline ring capacity (deduped by normalized title).
const RING_CAP: usize = 150;
/// GDELT records requested per query (per symbol and for the markets query).
const MAX_RECORDS: u32 = 8;
/// Spacing between successive outbound queries (GDELT and EDGAR alike).
const QUERY_GAP: Duration = Duration::from_millis(1_000);
/// Earnings refresh cadence: filings move quarterly, 6h is generous.
const EARNINGS_REFRESH_MS: i64 = 6 * 3_600_000;
/// SEC ticker map TTL (mirrors company.rs's cache policy).
const CIK_TTL: Duration = Duration::from_secs(24 * 3600);
/// SEC ticker map is ~2 MB today; generous headroom.
const TICKER_MAP_CAP: usize = 8 * 1024 * 1024;
/// EDGAR submissions payloads run ~1-2 MB for the largest filers.
const SUBMISSIONS_CAP: usize = 16 * 1024 * 1024;
/// The one general markets query published with `symbol: None`.
const MARKETS_QUERY: &str =
    r#"("stock market" OR "wall street" OR "equity markets" OR "federal reserve") sourcelang:english"#;
/// Same ticker map company.rs uses (its URL const is module-private).
const SEC_TICKERS_URL: &str = "https://www.sec.gov/files/company_tickers.json";
/// Filing-cadence gap: one quarter, rounded to whole days.
pub(crate) const NEXT_REPORT_GAP_DAYS: u64 = 91;
pub(crate) const EARNINGS_BASIS: &str = "estimated from filing cadence (not confirmed)";

/// Spawn the periodic NEWS poller (cadence `intel.news_poll_secs`, floor
/// 300s). Query targets are fixed at spawn from the configured symbols.
pub fn spawn_poller(bus: Arc<Bus>, cfg: Config) {
    tokio::spawn(async move {
        let cadence = Duration::from_secs(cfg.intel.news_poll_secs.max(300));
        let egress = Egress::new();
        let queries = query_targets(&cfg.symbols);
        let equities = equity_symbols(&cfg.symbols);
        let mut state = NewsState::default();
        loop {
            match poll(&egress, &mut state, &queries, &equities).await {
                Some(board) => bus.publish(EngineEvent::News(board)),
                None => tracing::debug!("news: no board this cycle"),
            }
            tokio::time::sleep(cadence).await;
        }
    });
}

/// One company-news query target: a configured equity plus its curated name.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct NewsQuery {
    pub symbol: String,
    pub name: String,
}

/// Configured equities that have a curated company name to query by.
/// Crypto (dashed) symbols and symbols outside the curated graph are
/// skipped — the fallback is silence, never a junk query.
pub(crate) fn query_targets(symbols: &[String]) -> Vec<NewsQuery> {
    let mut out: Vec<NewsQuery> = Vec::new();
    for s in equity_symbols(symbols) {
        if out.iter().any(|q| q.symbol == s) {
            continue;
        }
        if let Some(profile) = splc_data::curated(&s) {
            if !profile.name.trim().is_empty() {
                out.push(NewsQuery { symbol: s, name: profile.name });
            }
        }
    }
    out
}

/// The configured EQUITY (bare-ticker) symbols, trimmed/uppercased/deduped.
pub(crate) fn equity_symbols(symbols: &[String]) -> Vec<String> {
    let mut out: Vec<String> = Vec::new();
    for s in symbols {
        let s = s.trim().to_uppercase();
        if !s.is_empty() && !s.contains('-') && !out.contains(&s) {
            out.push(s);
        }
    }
    out
}

/// Rolling NEWS state: the deduped headline ring plus the earnings cache
/// (CIK map 24h TTL, rows refreshed every 6h, retained across failures).
#[derive(Default)]
pub struct NewsState {
    /// Deduped headline ring, oldest -> newest.
    ring: VecDeque<NewsItem>,
    /// Normalized titles currently in the ring.
    seen: HashSet<String>,
    /// Ticker -> CIK map; kept (stale) when a refresh fetch fails.
    cik: Option<(Instant, Arc<HashMap<String, u64>>)>,
    /// Symbol -> earnings row; a failed refresh keeps the prior row.
    earnings: BTreeMap<String, EarningsRow>,
    last_earnings_ms: i64,
}

impl NewsState {
    /// Dedupe items into the ring by normalized title; returns how many were
    /// fresh. The ring is display state: eviction frees a title for re-entry
    /// (no counting baselines here, unlike MERIDIAN).
    fn ingest(&mut self, items: Vec<NewsItem>) -> usize {
        let mut fresh = 0;
        for item in items {
            let key = normalize_title(&item.title);
            if key.is_empty() || !self.seen.insert(key) {
                continue;
            }
            fresh += 1;
            self.ring.push_back(item);
            if self.ring.len() > RING_CAP {
                if let Some(old) = self.ring.pop_front() {
                    self.seen.remove(&normalize_title(&old.title));
                }
            }
        }
        fresh
    }
}

/// One poll cycle: per-company GDELT queries + the markets query, then (when
/// due) the EDGAR earnings refresh. None when every fetch failed this cycle
/// (degradation is silent but logged), mirroring MERIDIAN's contract.
pub async fn poll(
    egress: &Egress,
    state: &mut NewsState,
    queries: &[NewsQuery],
    equities: &[String],
) -> Option<NewsBoard> {
    let mut any_ok = false;

    for q in queries {
        let url = gdelt_news_url(&company_query(&q.name));
        match egress.get_text(&url).await {
            Ok(raw) => {
                any_ok = true;
                let now = now_ms();
                let fresh = state.ingest(parse_news(Some(&q.symbol), &raw, now));
                tracing::debug!(symbol = %q.symbol, fresh, "news: company query polled");
            }
            Err(e) => {
                tracing::warn!(symbol = %q.symbol, error = %e, "news: company fetch failed; continuing");
            }
        }
        tokio::time::sleep(QUERY_GAP).await;
    }

    match egress.get_text(&gdelt_news_url(MARKETS_QUERY)).await {
        Ok(raw) => {
            any_ok = true;
            let now = now_ms();
            let fresh = state.ingest(parse_news(None, &raw, now));
            tracing::debug!(fresh, "news: markets query polled");
        }
        Err(e) => {
            tracing::warn!(error = %e, "news: markets fetch failed; continuing");
        }
    }

    let now = now_ms();
    if now - state.last_earnings_ms >= EARNINGS_REFRESH_MS {
        if refresh_earnings(egress, state, equities).await {
            any_ok = true;
            state.last_earnings_ms = now;
        }
        // A fully failed refresh leaves the clock alone: retried next cycle.
    }

    if !any_ok {
        tracing::warn!("news: every fetch failed this cycle");
        return None;
    }
    Some(NewsBoard {
        items: state.ring.iter().rev().cloned().collect(),
        earnings: state.earnings.values().cloned().collect(),
        source: "gdelt 2.0 (doc api) + sec edgar submissions (filing-cadence estimate)".into(),
        ts_ms: now_ms(),
    })
}

/// Refresh the earnings rows from EDGAR submissions. True when the refresh
/// made progress (there was nothing to do, or at least one symbol updated);
/// false means everything failed and the caller should retry next cycle.
async fn refresh_earnings(egress: &Egress, state: &mut NewsState, equities: &[String]) -> bool {
    if equities.is_empty() {
        return true;
    }
    let Some(map) = cik_map(egress, state).await else {
        return false;
    };
    let mut any_ok = false;
    for symbol in equities {
        let Some(cik) = map.get(symbol).copied() else {
            // Not an SEC filer (ETFs like SPY/QQQ): honestly no row.
            continue;
        };
        match egress.get_text_with_cap(&submissions_url(cik), SUBMISSIONS_CAP).await {
            Ok(raw) => {
                any_ok = true;
                match parse_submissions_last_periodic(&raw).and_then(|d| earnings_row(symbol, &d)) {
                    Some(row) => {
                        state.earnings.insert(symbol.clone(), row);
                    }
                    None => tracing::debug!(symbol = %symbol, "news: no periodic filings in submissions"),
                }
            }
            Err(e) => {
                tracing::warn!(symbol = %symbol, error = %e, "news: submissions fetch failed; prior row retained");
            }
        }
        tokio::time::sleep(QUERY_GAP).await;
    }
    any_ok
}

/// The ticker -> CIK map, refreshed at most every 24h; a failed refresh
/// keeps serving the stale map rather than dropping earnings entirely.
async fn cik_map(egress: &Egress, state: &mut NewsState) -> Option<Arc<HashMap<String, u64>>> {
    let expired = state.cik.as_ref().is_none_or(|(at, _)| at.elapsed() >= CIK_TTL);
    if expired {
        match egress.get_text_with_cap(SEC_TICKERS_URL, TICKER_MAP_CAP).await {
            Ok(raw) => match company::parse_cik_map(&raw) {
                Ok(map) => state.cik = Some((Instant::now(), Arc::new(map))),
                Err(e) => tracing::warn!(error = %e, "news: cik map parse failed; keeping stale map"),
            },
            Err(e) => tracing::warn!(error = %e, "news: cik map fetch failed; keeping stale map"),
        }
    }
    state.cik.as_ref().map(|(_, map)| Arc::clone(map))
}

/// A company query: the curated name as a quoted phrase, English sources.
fn company_query(name: &str) -> String {
    format!(r#""{name}" sourcelang:english"#)
}

fn gdelt_news_url(query: &str) -> String {
    format!(
        "https://api.gdeltproject.org/api/v2/doc/doc?query={}&mode=ArtList&format=json&maxrecords={MAX_RECORDS}&timespan=24h",
        url_encode(query)
    )
}

/// EDGAR submissions require the 10-digit zero-padded CIK in the path.
pub(crate) fn submissions_url(cik: u64) -> String {
    format!("https://data.sec.gov/submissions/CIK{cik:010}.json")
}

/// Parse a GDELT ArtList body into news items via MERIDIAN's parser (same
/// tone/seendate/empty-title rules), attributing every row to `symbol`
/// (None = the general markets query).
pub(crate) fn parse_news(symbol: Option<&str>, raw: &str, fallback_ts: i64) -> Vec<NewsItem> {
    meridian::parse_artlist(symbol.unwrap_or("markets"), raw, fallback_ts)
        .into_iter()
        .map(|ev| NewsItem {
            symbol: symbol.map(str::to_string),
            title: ev.title,
            source_domain: ev.source_domain,
            url: ev.url,
            tone: ev.tone,
            ts_ms: ev.ts_ms,
        })
        .collect()
}

/// Latest periodic (10-Q*/10-K*) filing date, "YYYY-MM-DD", from an EDGAR
/// submissions payload. Malformed bodies or rows degrade to None/fewer rows,
/// never a panic. ISO dates compare correctly as strings.
pub(crate) fn parse_submissions_last_periodic(raw: &str) -> Option<String> {
    let v: serde_json::Value = serde_json::from_str(raw).ok()?;
    let recent = v.get("filings")?.get("recent")?;
    let forms = recent.get("form")?.as_array()?;
    let dates = recent.get("filingDate")?.as_array()?;
    let mut last: Option<String> = None;
    for (form, date) in forms.iter().zip(dates.iter()) {
        let periodic = form
            .as_str()
            .is_some_and(|f| f.starts_with("10-Q") || f.starts_with("10-K"));
        if !periodic {
            continue;
        }
        let Some(date) = date.as_str() else { continue };
        if chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d").is_err() {
            continue;
        }
        if last.as_deref().is_none_or(|l| date > l) {
            last = Some(date.to_string());
        }
    }
    last
}

/// Build one earnings row: `last_report` + 91 days, honestly labeled.
/// None when the date is unparseable (never an invented estimate).
pub(crate) fn earnings_row(symbol: &str, last_report: &str) -> Option<EarningsRow> {
    let last = chrono::NaiveDate::parse_from_str(last_report, "%Y-%m-%d").ok()?;
    let next = last.checked_add_days(chrono::Days::new(NEXT_REPORT_GAP_DAYS))?;
    Some(EarningsRow {
        symbol: symbol.to_string(),
        last_report: last_report.to_string(),
        next_estimate: next.format("%Y-%m-%d").to_string(),
        basis: EARNINGS_BASIS.into(),
    })
}

/// Title normalization for dedupe: lowercase alphanumerics, single-spaced.
/// Mirrors MERIDIAN's normalizer (private to that module).
fn normalize_title(title: &str) -> String {
    let mut out = String::with_capacity(title.len());
    let mut last_space = true;
    for ch in title.chars() {
        if ch.is_alphanumeric() {
            out.extend(ch.to_lowercase());
            last_space = false;
        } else if !last_space {
            out.push(' ');
            last_space = true;
        }
    }
    out.trim_end().to_string()
}

/// Minimal percent-encoder (RFC 3986 unreserved kept verbatim). Local on
/// purpose: no new crate deps, and MERIDIAN's copy is module-private.
fn url_encode(s: &str) -> String {
    let mut out = String::with_capacity(s.len() * 3);
    for byte in s.bytes() {
        match byte {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(byte as char)
            }
            _ => out.push_str(&format!("%{byte:02X}")),
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    const ARTLIST_FIXTURE: &str = r#"{
        "articles": [
            {"url": "https://example.com/a", "title": "NVIDIA Corporation lifts data-center outlook",
             "domain": "example.com", "seendate": "20260712T063000Z",
             "sourcecountry": "United States", "tone": -1.4},
            {"url": "https://example.org/b", "title": "Chip stocks rally on AI capex",
             "domain": "example.org", "seendate": "20260712T070000Z"},
            {"url": "https://example.net/c", "title": "  ",
             "domain": "example.net", "seendate": "20260712T070500Z"},
            {"url": "https://example.com/d", "title": "NVIDIA CORPORATION lifts data center outlook!",
             "domain": "example.com", "seendate": "20260712T080000Z", "tone": "-2.5"}
        ]
    }"#;

    fn item(title: &str) -> NewsItem {
        NewsItem {
            symbol: None,
            title: title.to_string(),
            source_domain: "x.com".into(),
            url: String::new(),
            tone: 0.0,
            ts_ms: 1,
        }
    }

    #[test]
    fn parse_news_attributes_symbol_and_keeps_meridian_tone_rules() {
        let items = parse_news(Some("NVDA"), ARTLIST_FIXTURE, 42);
        // Empty-title row dropped; near-duplicate survives parse (dedupe is
        // the state's job).
        assert_eq!(items.len(), 3);
        assert!(items.iter().all(|i| i.symbol.as_deref() == Some("NVDA")));
        assert_eq!(items[0].tone, -1.4);
        assert_eq!(items[1].tone, 0.0); // absent tone -> neutral
        assert_eq!(items[2].tone, -2.5); // string tone parsed
        assert!(items[0].ts_ms > 1_700_000_000_000);
        // The markets query carries no symbol.
        let markets = parse_news(None, ARTLIST_FIXTURE, 42);
        assert!(markets.iter().all(|i| i.symbol.is_none()));
        assert!(parse_news(None, "junk", 1).is_empty());
    }

    #[test]
    fn ingest_dedupes_by_normalized_title_across_polls_and_queries() {
        let mut st = NewsState::default();
        // Rows 0 and 3 normalize identically -> 2 fresh.
        assert_eq!(st.ingest(parse_news(Some("NVDA"), ARTLIST_FIXTURE, 42)), 2);
        assert_eq!(st.ring.len(), 2);
        // The same titles from ANOTHER query (markets): nothing fresh.
        assert_eq!(st.ingest(parse_news(None, ARTLIST_FIXTURE, 42)), 0);
        assert_eq!(st.ring.len(), 2);
        // First attribution wins.
        assert!(st.ring.iter().all(|i| i.symbol.as_deref() == Some("NVDA")));
    }

    #[test]
    fn ring_caps_at_150_and_eviction_frees_titles() {
        let mut st = NewsState::default();
        for i in 0..(RING_CAP + 50) {
            st.ingest(vec![item(&format!("headline number {i}"))]);
        }
        assert_eq!(st.ring.len(), RING_CAP);
        assert_eq!(st.seen.len(), RING_CAP);
        assert_eq!(st.ring.front().unwrap().title, "headline number 50");
        // The evicted oldest title may re-enter (display-only dedupe).
        assert_eq!(st.ingest(vec![item("headline number 0")]), 1);
        assert_eq!(st.ring.len(), RING_CAP);
    }

    #[test]
    fn query_targets_use_curated_names_and_skip_unknown_or_crypto() {
        let symbols = vec![
            "NVDA".to_string(),
            "nvda ".to_string(),   // dup after trim/uppercase
            "BTC-USD".to_string(), // crypto: skipped
            "ZZZZ".to_string(),    // no curated entry: skipped
            "AAPL".to_string(),
        ];
        let targets = query_targets(&symbols);
        assert_eq!(targets.len(), 2);
        assert_eq!(targets[0].symbol, "NVDA");
        assert_eq!(targets[0].name, "NVIDIA Corporation");
        assert_eq!(targets[1].symbol, "AAPL");
        assert_eq!(targets[1].name, "Apple Inc.");
        // Earnings targets keep ALL equities (curated or not).
        assert_eq!(equity_symbols(&symbols), vec!["NVDA", "ZZZZ", "AAPL"]);
    }

    #[test]
    fn news_url_is_encoded_and_on_allowlisted_host() {
        let url = gdelt_news_url(&company_query("Apple Inc."));
        assert!(url.starts_with("https://api.gdeltproject.org/api/v2/doc/doc?query="));
        assert!(!url.contains(' '), "unencoded space");
        assert!(!url.contains('"'), "unencoded quote");
        assert!(url.contains("maxrecords=8") && url.contains("timespan=24h"));
        let markets = gdelt_news_url(MARKETS_QUERY);
        assert!(!markets.contains(' ') && !markets.contains('"'));
        assert_eq!(url_encode("a b\"c"), "a%20b%22c");
    }

    const SUBMISSIONS_FIXTURE: &str = r#"{
      "cik": 1045810,
      "name": "NVIDIA CORP",
      "filings": { "recent": {
        "form":       ["4",          "8-K",        "10-Q",       "10-K/A",     "10-K",       "10-Q"],
        "filingDate": ["2026-06-30", "2026-06-01", "2026-05-28", "2026-03-10", "2026-02-26", "2025-11-19"]
      }}
    }"#;

    #[test]
    fn submissions_fixture_extracts_latest_periodic_filing_date() {
        // 4 and 8-K are not periodic; the latest of the 10-Q/10-K family wins.
        assert_eq!(
            parse_submissions_last_periodic(SUBMISSIONS_FIXTURE),
            Some("2026-05-28".to_string())
        );
        // Amendments still count as periodic filings.
        let amended_only = r#"{"filings":{"recent":{
            "form": ["10-K/A"], "filingDate": ["2026-03-10"]}}}"#;
        assert_eq!(
            parse_submissions_last_periodic(amended_only),
            Some("2026-03-10".to_string())
        );
        // Malformed / empty / non-periodic payloads: honestly None.
        assert_eq!(parse_submissions_last_periodic("junk"), None);
        assert_eq!(parse_submissions_last_periodic("{}"), None);
        let non_periodic = r#"{"filings":{"recent":{"form":["8-K"],"filingDate":["2026-06-01"]}}}"#;
        assert_eq!(parse_submissions_last_periodic(non_periodic), None);
        // A garbage date on the periodic row is skipped, not propagated.
        let bad_date = r#"{"filings":{"recent":{"form":["10-Q"],"filingDate":["not-a-date"]}}}"#;
        assert_eq!(parse_submissions_last_periodic(bad_date), None);
    }

    #[test]
    fn earnings_estimate_adds_91_days_with_honest_basis() {
        let row = earnings_row("NVDA", "2026-05-28").unwrap();
        assert_eq!(row.symbol, "NVDA");
        assert_eq!(row.last_report, "2026-05-28");
        assert_eq!(row.next_estimate, "2026-08-27");
        assert_eq!(row.basis, "estimated from filing cadence (not confirmed)");
        // Year and leap-year boundaries.
        assert_eq!(earnings_row("X", "2023-12-01").unwrap().next_estimate, "2024-03-01");
        assert_eq!(earnings_row("X", "2024-12-01").unwrap().next_estimate, "2025-03-02");
        // Unparseable dates produce no row, never an invented one.
        assert!(earnings_row("X", "05/28/2026").is_none());
        assert!(earnings_row("X", "").is_none());
    }

    #[test]
    fn submissions_url_zero_pads_to_ten_digits() {
        assert_eq!(
            submissions_url(1045810),
            "https://data.sec.gov/submissions/CIK0001045810.json"
        );
    }

    #[test]
    fn normalize_title_collapses_case_and_punctuation() {
        assert_eq!(
            normalize_title("NVIDIA Corporation lifts data-center outlook"),
            normalize_title("NVIDIA CORPORATION lifts data center outlook!")
        );
        assert_eq!(normalize_title("  !!  "), "");
    }
}
