//! NEWS — company + market headlines and a filing-cadence earnings calendar.
//! Headlines come from several honestly-attributed sources, each degrading
//! independently:
//!
//! - GDELT DOC 2.0 API (keyless): one query per CONFIGURED equity that has a
//!   curated company name (symbols without a curated entry are skipped — a
//!   ticker string makes a terrible news query) plus one general markets query.
//! - Reputable RSS/Atom feeds with a usable public feed: CNBC, Yahoo Finance
//!   (general + per-symbol headline feed), MarketWatch, Nasdaq, Al Jazeera
//!   (general, filtered to business/markets by keyword), PR Newswire and
//!   GlobeNewswire.
//! - Google-News-relayed RSS for outlets WITHOUT a usable public feed
//!   (Reuters killed public RSS; Bloomberg never had a free one). These are
//!   scoped per outlet (`site:reuters.com`, `site:bloomberg.com`) and the
//!   TRUE outlet is read from each item's `<source>` element — never "google".
//!
//! Earnings dates come from SEC EDGAR submissions. Publishes `EngineEvent::News`.
//!
//! Honesty notes:
//! - `next_estimate` is ARITHMETIC — last periodic (10-Q/10-K) filing date
//!   + 91 days — and every row's `basis` says "estimated from filing
//!   cadence (not confirmed)". No fake earnings calendar.
//! - Company queries quote the curated legal name verbatim; that
//!   under-matches (missing colloquial mentions) rather than over-matches.
//! - Absent tone parses as 0.0 (neutral), same rule as MERIDIAN. RSS/Atom
//!   feeds carry no tone at all, so their items record a neutral 0.0.
//! - A symbol the SEC ticker map doesn't know simply has no earnings row —
//!   absence over invention.
//! - Every item carries `source_name` (display outlet) + `source_domain` (the
//!   real domain). For Google-News relays both come from the item's `<source>`
//!   element (the actual outlet + its site), so attribution is never faked to
//!   "google". Items relayed by Google News are labeled as such in the board's
//!   `source` string.
//! - We only wire a feed we could VERIFY against its real XML shape (trimmed
//!   fixtures live in this file's tests). The generic parser also handles Atom
//!   (verified against SEC EDGAR's real Atom feed shape); no currently-wired
//!   live source emits Atom, because the one Atom feed we found (SEC EDGAR
//!   `getcurrent`) rejects our egress User-Agent — so it is parser-verified but
//!   deliberately NOT polled.

use std::collections::{BTreeMap, HashMap, HashSet, VecDeque};
use std::sync::Arc;
use std::time::{Duration, Instant};

use cx_core::config::Config;
use cx_core::egress::Egress;
use cx_core::events::{EarningsRow, EngineEvent, NewsBoard, NewsItem};
use cx_core::time::now_ms;
use cx_core::Bus;

use crate::{company, meridian, splc_data};

/// Headline ring capacity (deduped by normalized title). Raised for the
/// multi-source feed set so quiet outlets are not evicted by a busy one.
const RING_CAP: usize = 300;
/// GDELT records requested per query (per symbol and for the markets query).
const MAX_RECORDS: u32 = 8;
/// Max items ingested from any single RSS/Atom feed per poll — a runaway feed
/// cannot flood the ring or starve other sources.
const RSS_MAX_ITEMS: usize = 15;
/// Spacing between successive outbound queries (GDELT, RSS and EDGAR alike).
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

/// Display name used for the per-symbol Yahoo Finance headline feed.
const YAHOO_SYMBOL_DISPLAY: &str = "Yahoo Finance";

/// One market-wide RSS/Atom news feed.
///
/// `relay` feeds (Google News) carry the TRUE outlet per item in a `<source>`
/// element — for those `display` is only a log/fallback label and the real
/// outlet + domain come from the item. Direct feeds ARE the outlet named by
/// `display`. `business_only` keeps only business/markets items (Al Jazeera's
/// general `all.xml` covers sport/culture too).
#[derive(Debug, Clone, Copy)]
pub(crate) struct NewsSource {
    pub display: &'static str,
    pub url: &'static str,
    pub relay: bool,
    pub business_only: bool,
}

/// The wired market-wide feeds. Each URL's real XML shape is fixtured and
/// tested below; a feed we could not verify is left out on purpose.
///
/// Reuters and Bloomberg have no usable free feed (Reuters retired public RSS;
/// Bloomberg never offered one), so they are Google-News-relayed and scoped by
/// `site:` with true per-item attribution.
pub(crate) const NEWS_SOURCES: &[NewsSource] = &[
    NewsSource {
        display: "CNBC",
        url: "https://www.cnbc.com/id/100003114/device/rss/rss.html",
        relay: false,
        business_only: false,
    },
    NewsSource {
        display: "Yahoo Finance",
        url: "https://finance.yahoo.com/news/rssindex",
        relay: false,
        business_only: false,
    },
    NewsSource {
        display: "MarketWatch",
        url: "https://feeds.content.dowjones.io/public/rss/mw_topstories",
        relay: false,
        business_only: false,
    },
    NewsSource {
        display: "Nasdaq",
        url: "https://www.nasdaq.com/feed/rssoutbound?category=Markets",
        relay: false,
        business_only: false,
    },
    NewsSource {
        display: "Al Jazeera",
        url: "https://www.aljazeera.com/xml/rss/all.xml",
        relay: false,
        business_only: true,
    },
    NewsSource {
        display: "PR Newswire",
        url: "https://www.prnewswire.com/rss/news-releases-list.rss",
        relay: false,
        business_only: false,
    },
    NewsSource {
        display: "GlobeNewswire",
        url: "https://www.globenewswire.com/RssFeed/orgclass/1/feedTitle/GlobeNewswire%20-%20News%20about%20Public%20Companies",
        relay: false,
        business_only: false,
    },
    // Google-News relays — true outlet parsed from each item's <source>.
    NewsSource {
        display: "Reuters",
        url: "https://news.google.com/rss/search?q=when%3A1d%20site%3Areuters.com%20markets&hl=en-US&gl=US&ceid=US%3Aen",
        relay: true,
        business_only: false,
    },
    NewsSource {
        display: "Bloomberg",
        url: "https://news.google.com/rss/search?q=when%3A1d%20site%3Abloomberg.com%20markets&hl=en-US&gl=US&ceid=US%3Aen",
        relay: true,
        business_only: false,
    },
];

/// Per-symbol Yahoo Finance headline feed (RSS 2.0). `symbol` is already the
/// uppercased bare ticker; the value is safe in a query string.
pub(crate) fn yahoo_symbol_url(symbol: &str) -> String {
    format!(
        "https://feeds.finance.yahoo.com/rss/2.0/headline?s={}&region=US&lang=en-US",
        url_encode(symbol)
    )
}

/// Spawn the periodic NEWS poller (cadence `intel.news_poll_secs`, floor
/// 300s). Query targets are fixed at spawn from the configured symbols.
pub fn spawn_poller(bus: Arc<Bus>, cfg: Config) {
    tokio::spawn(async move {
        let cadence = Duration::from_secs(cfg.intel.news_poll_secs.max(300));
        let egress = Egress::new();
        let queries = query_targets(&cfg.symbols);
        let equities = equity_symbols(&cfg.symbols);
        let rss = cfg.intel.enable_news_rss;
        let mut state = NewsState::default();
        loop {
            match poll(&egress, &mut state, &queries, &equities, rss).await {
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
/// `rss` is on) the RSS/Atom + Google-News feeds and per-symbol Yahoo feeds,
/// then (when due) the EDGAR earnings refresh. Every fetch is spaced by
/// `QUERY_GAP` and each source failing degrades independently. None when every
/// fetch failed this cycle (silent but logged), mirroring MERIDIAN's contract.
///
/// Dedupe across ALL sources is the ring's job (normalized title, first-seen
/// wins): the per-symbol GDELT/Yahoo passes run first, so a headline keeps its
/// symbol attribution over a later market-wide copy of the same title.
pub async fn poll(
    egress: &Egress,
    state: &mut NewsState,
    queries: &[NewsQuery],
    equities: &[String],
    rss: bool,
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

    // Per-symbol Yahoo Finance headline feeds (equities only) — run before the
    // market-wide feeds so the symbol attribution wins the dedupe.
    if rss {
        for symbol in equities {
            match egress.get_text(&yahoo_symbol_url(symbol)).await {
                Ok(raw) => {
                    any_ok = true;
                    let now = now_ms();
                    let items = feed_to_news(&YAHOO_SYMBOL_SOURCE, Some(symbol), &raw, now);
                    let fresh = state.ingest(items);
                    tracing::debug!(symbol = %symbol, fresh, "news: yahoo symbol feed polled");
                }
                Err(e) => {
                    tracing::warn!(symbol = %symbol, error = %e, "news: yahoo symbol fetch failed; continuing");
                }
            }
            tokio::time::sleep(QUERY_GAP).await;
        }
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

    // Market-wide RSS/Atom + Google-News-relay feeds.
    if rss {
        for src in NEWS_SOURCES {
            match egress.get_text(src.url).await {
                Ok(raw) => {
                    any_ok = true;
                    let now = now_ms();
                    let items = feed_to_news(src, None, &raw, now);
                    let fresh = state.ingest(items);
                    tracing::debug!(source = src.display, relay = src.relay, fresh, "news: rss source polled");
                }
                Err(e) => {
                    tracing::warn!(source = src.display, error = %e, "news: rss fetch failed; continuing");
                }
            }
            tokio::time::sleep(QUERY_GAP).await;
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
        source: board_source_label(rss),
        ts_ms: now_ms(),
    })
}

/// The disclosed provenance string for the board — names every wired family
/// so the UI never implies a single origin.
fn board_source_label(rss: bool) -> String {
    let mut s = String::from("gdelt 2.0 (doc api)");
    if rss {
        s.push_str(
            " + rss/atom (cnbc, yahoo finance, marketwatch, nasdaq, al jazeera, pr newswire, globenewswire)",
        );
        s.push_str(" + google news relay (reuters, bloomberg)");
    }
    s.push_str(" + sec edgar submissions (filing-cadence estimate)");
    s
}

/// The per-symbol Yahoo Finance headline feed as a direct source (no relay:
/// the outlet is Yahoo Finance and the domain is the article's real host).
const YAHOO_SYMBOL_SOURCE: NewsSource = NewsSource {
    display: YAHOO_SYMBOL_DISPLAY,
    url: "",
    relay: false,
    business_only: false,
};

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
            // GDELT names no outlet — the domain is the only honest
            // attribution, so display falls back to it (source_name None).
            source_name: None,
            url: ev.url,
            tone: ev.tone,
            ts_ms: ev.ts_ms,
        })
        .collect()
}

// ---------------------------------------------------------------------------
// Generic RSS / Atom feed parsing + honest attribution.
//
// Hand-written (no XML crate — same posture as the GDELT/percent-encode
// helpers): a small, defensive tag scanner that degrades to fewer items on
// any malformed input and never panics. It handles RSS 2.0 `<item>` and Atom
// `<entry>` shapes; Google-News relays are RSS whose true outlet rides in each
// item's `<source>` element.
// ---------------------------------------------------------------------------

/// One parsed feed row before source attribution is resolved.
#[derive(Debug, Clone)]
pub(crate) struct FeedItem {
    pub title: String,
    pub link: String,
    pub ts_ms: i64,
    /// The `<source>` element's outlet name / site, when present (Google News
    /// and Yahoo's general feed carry it; most direct feeds do not).
    pub item_source_name: Option<String>,
    pub item_source_url: Option<String>,
}

/// Words that mark a headline as business/markets-relevant. Used to filter a
/// general feed (Al Jazeera's `all.xml`) down to the section NEWS cares about.
/// Errs toward inclusion — dropping a real market story is worse than keeping
/// a borderline one.
const BUSINESS_KEYWORDS: &[&str] = &[
    "market", "stock", "share", "econom", "trade", "tariff", "inflation",
    "interest rate", "fed", "central bank", "oil", "crude", "gas", "energy",
    "earnings", "revenue", "profit", "bank", "dollar", "currency", "bond",
    "yield", "gdp", "recession", "opec", "ipo", "merger", "acquisition",
    "nasdaq", "dow", "s&p", "commodity", "gold", "crypto", "bitcoin",
    "investor", "debt", "budget", "imf", "sanction", "wall street", "business",
];

/// Parse an RSS 2.0 / Atom feed body into items, auto-detecting the shape
/// (`<entry>` present without `<item>` = Atom). Malformed bodies or rows
/// degrade to fewer items, never a panic; missing/garbage dates fall back to
/// `fallback_ts`. Bounded to a sane number of rows.
pub(crate) fn parse_feed(raw: &str, fallback_ts: i64) -> Vec<FeedItem> {
    let atom = find_tag(raw, "entry", 0).is_some() && find_tag(raw, "item", 0).is_none();
    let item_tag = if atom { "entry" } else { "item" };
    let close = format!("</{item_tag}>");
    let mut out = Vec::new();
    let mut from = 0;
    while let Some((start, _content, _open)) = find_tag(raw, item_tag, from) {
        let Some(end_rel) = raw[start..].find(&close) else { break };
        let end = start + end_rel + close.len();
        let block = &raw[start..end];
        from = end;
        let Some(title) = tag_text(block, "title").filter(|t| !t.is_empty()) else {
            continue;
        };
        let link = if atom { atom_link(block) } else { rss_link(block) };
        let date = if atom {
            tag_text(block, "updated").or_else(|| tag_text(block, "published"))
        } else {
            tag_text(block, "pubDate").or_else(|| tag_text(block, "date"))
        };
        let ts_ms = parse_feed_ts(date.as_deref().unwrap_or(""), fallback_ts);
        let (item_source_name, item_source_url) = source_element(block);
        out.push(FeedItem { title, link, ts_ms, item_source_name, item_source_url });
        if out.len() >= 400 {
            break;
        }
    }
    out
}

/// Map parsed feed rows to attributed `NewsItem`s for one source: apply the
/// business filter, resolve the TRUE outlet + domain, strip a Google-News
/// title suffix, and cap at [`RSS_MAX_ITEMS`]. `symbol` tags per-symbol feeds.
pub(crate) fn feed_to_news(
    src: &NewsSource,
    symbol: Option<&str>,
    raw: &str,
    fallback_ts: i64,
) -> Vec<NewsItem> {
    let mut out = Vec::new();
    for it in parse_feed(raw, fallback_ts) {
        if src.business_only && !business_relevant(&it.title) {
            continue;
        }
        let (name, domain) = attribution(src, &it);
        let title = if src.relay {
            strip_outlet_suffix(&it.title, &name)
        } else {
            it.title.clone()
        };
        if title.trim().is_empty() {
            continue;
        }
        out.push(NewsItem {
            symbol: symbol.map(str::to_string),
            title,
            source_domain: domain,
            source_name: Some(name),
            url: it.link,
            // RSS/Atom feeds carry no GDELT tone; neutral 0.0, same honesty
            // rule as an absent tone.
            tone: 0.0,
            ts_ms: it.ts_ms,
        });
        if out.len() >= RSS_MAX_ITEMS {
            break;
        }
    }
    out
}

/// Resolve one item's display outlet + real domain, honestly.
fn attribution(src: &NewsSource, it: &FeedItem) -> (String, String) {
    if src.relay {
        // Google News: the real outlet is the item's <source>; fall back to
        // the "… - Outlet" title suffix, and only then to an honest label —
        // never "google".
        let name = it
            .item_source_name
            .clone()
            .filter(|n| !n.is_empty())
            .or_else(|| suffix_outlet(&it.title))
            .unwrap_or_else(|| "via Google News".to_string());
        let domain = it
            .item_source_url
            .as_deref()
            .and_then(host_of)
            // Never surface Google's aggregator host: a relay <link> is a
            // news.google.com redirect, so pairing it with a real outlet name
            // would fake attribution. Keep a genuine outlet host if the redirect
            // resolves to one, else leave the domain empty (UI shows name alone).
            .or_else(|| host_of(&it.link).filter(|h| h != "news.google.com"))
            .unwrap_or_default();
        (name, domain)
    } else {
        // Direct feed: prefer a per-item <source> outlet when present (Yahoo's
        // general feed relays third-party publishers), else the feed's name.
        let name = it
            .item_source_name
            .clone()
            .filter(|n| !n.is_empty())
            .unwrap_or_else(|| src.display.to_string());
        let domain = it
            .item_source_url
            .as_deref()
            .and_then(host_of)
            .or_else(|| host_of(&it.link))
            .unwrap_or_default();
        (name, domain)
    }
}

/// True when a headline reads as business/markets news.
fn business_relevant(title: &str) -> bool {
    let t = title.to_lowercase();
    BUSINESS_KEYWORDS.iter().any(|k| t.contains(k))
}

/// Drop a trailing " - Outlet" (Google News appends the outlet to titles).
fn strip_outlet_suffix(title: &str, outlet: &str) -> String {
    for sep in [" - ", " \u{2013} ", " \u{2014} "] {
        let suffix = format!("{sep}{outlet}");
        if let Some(head) = title.strip_suffix(&suffix) {
            if !head.trim().is_empty() {
                return head.trim_end().to_string();
            }
        }
    }
    title.to_string()
}

/// The outlet named by a "Headline - Outlet" suffix, when a `<source>` element
/// was absent. Bounded length so a hyphenated headline is not mistaken for one.
fn suffix_outlet(title: &str) -> Option<String> {
    for sep in [" - ", " \u{2013} ", " \u{2014} "] {
        if let Some(idx) = title.rfind(sep) {
            let name = title[idx + sep.len()..].trim();
            if !name.is_empty() && name.chars().count() <= 40 {
                return Some(name.to_string());
            }
        }
    }
    None
}

/// The bare host of a URL, lowercased (keeps `www.`), or None. No allocation
/// of a full URL parser — a small, defensive split.
fn host_of(url: &str) -> Option<String> {
    let after = url.split("://").nth(1).unwrap_or(url);
    let host = after.split(['/', '?', '#']).next().unwrap_or("");
    let host = host.rsplit('@').next().unwrap_or(host); // strip any userinfo
    let host = host.split(':').next().unwrap_or(host).trim(); // strip any port
    if host.is_empty() {
        None
    } else {
        Some(host.to_ascii_lowercase())
    }
}

/// The RSS `<link>` text; falls back to a `<guid>` that is itself a URL.
fn rss_link(block: &str) -> String {
    if let Some(t) = tag_text(block, "link") {
        if !t.is_empty() {
            return t;
        }
    }
    if let Some(g) = tag_text(block, "guid") {
        if g.starts_with("http") {
            return g;
        }
    }
    String::new()
}

/// The best Atom `<link href>`: prefer `rel="alternate"` (or no rel); never
/// return the feed's `self`/`edit` link.
fn atom_link(block: &str) -> String {
    let mut from = 0;
    let mut fallback = String::new();
    while let Some((_, after, tag)) = find_tag(block, "link", from) {
        from = after;
        let Some(href) = attr(tag, "href").filter(|h| !h.is_empty()) else {
            continue;
        };
        let rel = attr(tag, "rel").unwrap_or_default();
        if rel.is_empty() || rel == "alternate" {
            return href;
        }
        if fallback.is_empty() && rel != "self" && rel != "edit" {
            fallback = href;
        }
    }
    fallback
}

/// The `<source url="…">Name</source>` element (Google News + Yahoo general):
/// (outlet name, outlet url), each None when absent/empty.
fn source_element(block: &str) -> (Option<String>, Option<String>) {
    let Some((_, content_start, open)) = find_tag(block, "source", 0) else {
        return (None, None);
    };
    let url = attr(open, "url").filter(|u| !u.is_empty());
    let name = block[content_start..]
        .find("</source>")
        .map(|end| clean_text(&block[content_start..content_start + end]))
        .filter(|n| !n.is_empty());
    (name, url)
}

/// Inner text of the FIRST `<name …>…</name>` in `block`, CDATA-unwrapped and
/// entity-decoded. None for absent or self-closing elements.
fn tag_text(block: &str, name: &str) -> Option<String> {
    let (_, content_start, _) = find_tag(block, name, 0)?;
    let close = format!("</{name}>");
    let end_rel = block[content_start..].find(&close)?;
    Some(clean_text(&block[content_start..content_start + end_rel]))
}

/// Locate `<name …>` at or after `from`, respecting the name boundary (so
/// `<source>` never matches `<sourcecountry>`). Returns (tag start, index just
/// past the opening `>`, the opening-tag slice with its attributes).
fn find_tag<'a>(block: &'a str, name: &str, from: usize) -> Option<(usize, usize, &'a str)> {
    let needle = format!("<{name}");
    let mut search = from;
    while let Some(rel) = block.get(search..)?.find(&needle) {
        let start = search + rel;
        let after_name = start + needle.len();
        match block[after_name..].chars().next() {
            Some(c) if c == '>' || c == '/' || c.is_whitespace() => {
                let gt = after_name + block[after_name..].find('>')?;
                return Some((start, gt + 1, &block[start..=gt]));
            }
            Some(_) => search = after_name, // e.g. <sourcecountry>: keep looking
            None => return None,
        }
    }
    None
}

/// Read a quoted attribute value from an opening tag, boundary-aware so `url`
/// does not match inside another attribute name.
fn attr(tag: &str, name: &str) -> Option<String> {
    let mut from = 0;
    while let Some(rel) = tag.get(from..)?.find(name) {
        let at = from + rel;
        let boundary_before = at == 0
            || tag[..at]
                .chars()
                .next_back()
                .is_some_and(|c| c.is_whitespace());
        let rest = &tag[at + name.len()..];
        if boundary_before && rest.starts_with('=') {
            let val = &rest[1..];
            if let Some(q) = val.chars().next() {
                if q == '"' || q == '\'' {
                    let inner = &val[1..];
                    if let Some(end) = inner.find(q) {
                        return Some(clean_text(&inner[..end]));
                    }
                }
            }
        }
        from = at + name.len();
    }
    None
}

/// Trim, unwrap a single CDATA section (literal — no entity decoding), else
/// decode XML entities.
fn clean_text(s: &str) -> String {
    let s = s.trim();
    if let Some(inner) = s.strip_prefix("<![CDATA[") {
        return inner.strip_suffix("]]>").unwrap_or(inner).trim().to_string();
    }
    xml_decode(s)
}

/// Decode the XML entities feeds actually use (`&amp; &lt; &gt; &quot; &apos;`
/// and numeric `&#NN;` / `&#xHH;`). A lone `&` or an over-long "entity" is left
/// literal so ordinary text is never mangled.
fn xml_decode(s: &str) -> String {
    if !s.contains('&') {
        return s.to_string();
    }
    let mut out = String::with_capacity(s.len());
    let mut rest = s;
    while let Some(amp) = rest.find('&') {
        out.push_str(&rest[..amp]);
        let tail = &rest[amp..];
        match tail.find(';') {
            Some(semi) if semi <= 12 => {
                let decoded = match &tail[1..semi] {
                    "amp" => Some('&'),
                    "lt" => Some('<'),
                    "gt" => Some('>'),
                    "quot" => Some('"'),
                    "apos" => Some('\''),
                    ent => ent
                        .strip_prefix("#x")
                        .or_else(|| ent.strip_prefix("#X"))
                        .and_then(|h| u32::from_str_radix(h, 16).ok())
                        .or_else(|| ent.strip_prefix('#').and_then(|d| d.parse::<u32>().ok()))
                        .and_then(char::from_u32),
                };
                match decoded {
                    Some(c) => {
                        out.push(c);
                        rest = &tail[semi + 1..];
                    }
                    None => {
                        out.push('&');
                        rest = &tail[1..];
                    }
                }
            }
            _ => {
                out.push('&');
                rest = &tail[1..];
            }
        }
    }
    out.push_str(rest);
    out
}

/// A feed timestamp -> epoch millis. Handles RFC-822/2822 (RSS `pubDate`,
/// numeric offset or named `GMT`) and RFC-3339/ISO-8601 (Atom / Yahoo). Any
/// unparseable value degrades to `fallback`.
fn parse_feed_ts(s: &str, fallback: i64) -> i64 {
    let s = s.trim();
    if s.is_empty() {
        return fallback;
    }
    if let Ok(dt) = chrono::DateTime::parse_from_rfc2822(s) {
        return dt.timestamp_millis();
    }
    if let Ok(dt) = chrono::DateTime::parse_from_rfc3339(s) {
        return dt.timestamp_millis();
    }
    for fmt in ["%a, %d %b %Y %H:%M:%S %z", "%a, %d %b %Y %H:%M %z"] {
        if let Ok(dt) = chrono::DateTime::parse_from_str(s, fmt) {
            return dt.timestamp_millis();
        }
    }
    // A named-zone "… GMT" that chrono's rfc2822 declined: treat GMT as UTC.
    if let Some(stripped) = s.strip_suffix(" GMT") {
        for fmt in ["%a, %d %b %Y %H:%M:%S", "%a, %d %b %Y %H:%M"] {
            if let Ok(dt) = chrono::NaiveDateTime::parse_from_str(stripped.trim(), fmt) {
                return dt.and_utc().timestamp_millis();
            }
        }
    }
    fallback
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
            source_name: None,
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
    fn ring_caps_at_300_and_eviction_frees_titles() {
        assert_eq!(RING_CAP, 300);
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

    // -----------------------------------------------------------------------
    // Multi-source RSS / Atom / Google-News feed parsing.
    //
    // Every fixture below is a TRIMMED but structurally faithful capture of the
    // named feed's real XML shape (fetched live while building this module). A
    // feed we could not fixture is not wired (see the module docs re: SEC EDGAR
    // Atom). Timestamps use whatever epoch the fixture parses to; the guard
    // `> 1_700_000_000_000` just proves the date parsed (not the fallback).
    // -----------------------------------------------------------------------

    fn direct(display: &'static str) -> NewsSource {
        NewsSource { display, url: "", relay: false, business_only: false }
    }
    fn relay(display: &'static str) -> NewsSource {
        NewsSource { display, url: "", relay: true, business_only: false }
    }

    /// Real CNBC top-news RSS shape (channel title precedes items; item title
    /// sits after several `metadata:` namespaced tags).
    const CNBC_FIXTURE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:metadata="http://search.cnbc.com/rss/2.0/modules/siteContentMetadata" version="2.0">
  <channel>
    <title>US Top News and Analysis</title>
    <link>https://www.cnbc.com/us-top-news-and-analysis/</link>
    <item>
      <link>https://www.cnbc.com/2026/07/16/us-grocery-spending-slows.html</link>
      <guid isPermaLink="false">108332648</guid>
      <metadata:type>cnbcnewsstory</metadata:type>
      <metadata:id>108332648</metadata:id>
      <title>U.S. grocery slowdown deepens as shoppers buy fewer items</title>
      <description><![CDATA[New data show the U.S. grocery slowdown is deepening.]]></description>
      <pubDate>Thu, 16 Jul 2026 11:00:01 GMT</pubDate>
    </item>
  </channel>
</rss>"#;

    /// Real MarketWatch top-stories RSS shape (guid before title; dc:creator).
    const MARKETWATCH_FIXTURE: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<rss xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0"><channel>
<title>MarketWatch.com - Top Stories</title>
<item>
<guid isPermaLink="false">WP-MKTW-0005113900</guid>
<title>The No. 1 decision for aging retirees: stay home or move?</title>
<description>Why staying in your longtime home requires planning.</description>
<link>https://www.marketwatch.com/story/the-no-1-decision-4ea23d02?mod=mw_rss_topstories</link>
<pubDate>Thu, 16 Jul 2026 15:33:00 GMT</pubDate>
<dc:creator>Morey Stettner</dc:creator>
</item>
</channel></rss>"#;

    /// Real Nasdaq markets RSS shape (guid is a permalink URL; +0000 offset).
    const NASDAQ_FIXTURE: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0"><channel>
<title>Markets Feed</title>
 <item>
  <title>Thursday 7/16 Insider Buying Report: FULC, ECAT</title>
  <link>https://www.nasdaq.com/articles/thursday-7-16-insider-buying-report-fulc-ecat</link>
  <description>Two noteworthy recent insider buys.</description>
  <pubDate>Thu, 16 Jul 2026 15:23:22 +0000</pubDate>
  <guid isPermaLink="true">https://www.nasdaq.com/articles/thursday-7-16-insider-buying-report-fulc-ecat?time=1784215402</guid>
 </item>
</channel></rss>"#;

    /// Real PR Newswire RSS shape (single-line item; CDATA description).
    const PRNEWSWIRE_FIXTURE: &str = r#"<?xml version="1.0" encoding="UTF-8"?><rss xmlns:dc="http://purl.org/dc/elements/1.1/" version="2.0"><channel><title>All News Releases</title><item><title>Acme Corp Reports Record Quarterly Revenue and Raises Guidance</title><link>https://www.prnewswire.com/news-releases/acme-corp-reports-record-302826952.html</link><guid>https://www.prnewswire.com/news-releases/acme-corp-reports-record-302826952.html</guid><pubDate>Thu, 16 Jul 2026 15:46:00 +0000</pubDate><description><![CDATA[<p>SAN DIEGO, July 16, 2026 /PRNewswire/ -- Acme Corp today announced results.</p>]]></description></item></channel></rss>"#;

    /// Real GlobeNewswire RSS shape: opening tags whose attributes wrap onto the
    /// next line (`<guid\n isPermaLink=...>`, `<category\n domain=...>`).
    const GLOBENEWSWIRE_FIXTURE: &str = r#"<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0"><channel>
<title>GlobeNewswire - News about Public Companies</title>
    <item>
      <guid
        isPermaLink="true">https://www.globenewswire.com/news-release/2026/07/16/3328676/0/en/Ipsos-buyback.html</guid>
      <link>https://www.globenewswire.com/news-release/2026/07/16/3328676/0/en/Ipsos-buyback.html</link>
      <category
        domain="https://www.globenewswire.com/rss/stock">Paris:IPS</category>
      <title>Ipsos: Disclosure of trading in own shares under a buyback programme</title>
      <description><![CDATA[<p align="right">15 July 2026</p>]]></description>
      <pubDate>Thu, 16 Jul 2026 15:45:00 GMT</pubDate>
    </item>
</channel></rss>"#;

    /// Real Yahoo Finance GENERAL feed shape: RSS with an ISO-8601 `pubDate` and
    /// a per-item `<source url="…">Outlet</source>` (Yahoo relays 3rd parties).
    const YAHOO_GENERAL_FIXTURE: &str = r#"<?xml version="1.0" encoding="UTF-8"?><rss xmlns:media="http://search.yahoo.com/mrss/" version="2.0"><channel><title>Yahoo Finance</title><item><title>From Streaming Giant to Media Conglomerate: Netflix's 2026 Transformation</title><link>https://finance.yahoo.com/media-advertising/articles/streaming-giant-153519408.html</link><pubDate>2026-07-16T15:35:19Z</pubDate><source url="https://247wallst.com/">24/7 Wall St.</source><guid isPermaLink="false">streaming-giant-153519408.html</guid><media:content height="86" url="https://media.zenfs.com/en/x.jpg" width="130"/></item></channel></rss>"#;

    /// Real Yahoo Finance PER-SYMBOL headline feed shape: RSS, RFC-822 +0000
    /// date, NO `<source>` (the outlet is the article link's own host).
    const YAHOO_SYMBOL_FIXTURE: &str = r#"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>
<rss version="2.0">
    <channel>
        <description>Latest Financial News for AAPL</description>
        <item>
            <description>Greg Abel has reshaped the portfolio.</description>
            <guid isPermaLink="false">c9ec7a19-397d-3c34-bad0-106c7ab3f448</guid>
            <link>https://www.fool.com/investing/2026/07/16/warren-buffetts-successor-greg-abel/?.tsrc=rss</link>
            <pubDate>Thu, 16 Jul 2026 15:05:00 +0000</pubDate>
            <title>Warren Buffett's Successor Holds Nearly 30% of the Portfolio in 2 AI Stocks</title>
        </item>
    </channel>
</rss>"#;

    /// Real Google News search-RSS shape: title carries a " - Outlet" suffix,
    /// `&amp;` entities, and — crucially — a `<source url="…">Outlet</source>`
    /// giving the TRUE outlet (Reuters), never "google".
    const GOOGLE_NEWS_FIXTURE: &str = r##"<?xml version="1.0" encoding="UTF-8" standalone="yes"?><rss version="2.0" xmlns:media="http://search.yahoo.com/mrss/"><channel><generator>NFE/5.0</generator><title>"site:reuters.com markets" - Google News</title><item><title>S&amp;P 500, Nasdaq fall as chip stocks weaken; earnings in focus - Reuters</title><link>https://news.google.com/rss/articles/CBMitwFBVV95cUxPWA?oc=5</link><guid isPermaLink="false">CBMitwFBVV95cUxPWA</guid><pubDate>Thu, 16 Jul 2026 14:15:07 GMT</pubDate><description>&lt;a href="https://news.google.com/rss/articles/CBMitwFBVV95cUxPWA?oc=5"&gt;S&amp;P 500 falls&lt;/a&gt;&amp;nbsp;&lt;font color="#6f6f6f"&gt;Reuters&lt;/font&gt;</description><source url="https://www.reuters.com">Reuters</source></item></channel></rss>"##;

    /// Real SEC EDGAR `getcurrent` ATOM shape: `<feed>`/`<entry>`, a
    /// `rel="alternate"` link amid a feed-level `rel="self"` link, and an
    /// RFC-3339 `<updated>` with a zone offset. Parser-verified only — this
    /// endpoint rejects our egress User-Agent, so it is NOT a wired source.
    const EDGAR_ATOM_FIXTURE: &str = r#"<?xml version="1.0" encoding="ISO-8859-1" ?>
<feed xmlns="http://www.w3.org/2005/Atom">
<title>Latest Filings - Thu, 16 Jul 2026 11:51:25 EDT</title>
<link rel="alternate" href="/cgi-bin/browse-edgar?action=getcurrent"/>
<link rel="self" href="/cgi-bin/browse-edgar?action=getcurrent"/>
<entry>
<title>8-K - STAR GROUP, L.P. (0001002590) (Filer)</title>
<link rel="alternate" type="text/html" href="https://www.sec.gov/Archives/edgar/data/1002590/000117184326004725/0001171843-26-004725-index.htm"/>
<summary type="html"> &lt;b&gt;Filed:&lt;/b&gt; 2026-07-16 </summary>
<updated>2026-07-16T11:39:40-04:00</updated>
<category scheme="https://www.sec.gov/" label="form type" term="8-K"/>
<id>urn:tag:sec.gov,2008:accession-number=0001171843-26-004725</id>
</entry>
</feed>"#;

    /// Real Al Jazeera `all.xml` item shape (a sport item that the business
    /// filter must drop) plus an economy item in the SAME shape (kept).
    const ALJAZEERA_FIXTURE: &str = r#"<rss version="2.0" xmlns:content="http://purl.org/rss/1.0/modules/content/"><channel>
<title>Al Jazeera</title>
<image><title>Al Jazeera</title><link>https://www.aljazeera.com</link></image>
    <item>
        <link>https://www.aljazeera.com/sports/2026/7/16/uk-urges-fifa-to-investigate-argentina?traffic_source=rss</link>
        <title>UK urges FIFA to investigate Argentina over World Cup banner</title>
        <description><![CDATA[The UK and Argentina fought a brief war in 1982.]]></description>
        <pubDate>Thu, 16 Jul 2026 15:10:52 +0000</pubDate>
        <category>Sport</category>
        <guid isPermaLink="false">https://www.aljazeera.com/?t=1784213670</guid>
    </item>
    <item>
        <link>https://www.aljazeera.com/economy/2026/7/16/oil-prices-climb-as-opec-signals-cut?traffic_source=rss</link>
        <title>Oil prices climb as OPEC signals a deeper output cut</title>
        <description><![CDATA[Crude rose on supply concerns.]]></description>
        <pubDate>Thu, 16 Jul 2026 14:00:00 +0000</pubDate>
        <category>Economy</category>
        <guid isPermaLink="false">https://www.aljazeera.com/?t=1784210000</guid>
    </item>
</channel></rss>"#;

    #[test]
    fn direct_rss_feeds_parse_and_attribute_to_the_feed_outlet() {
        for (src, fixture, host) in [
            (direct("CNBC"), CNBC_FIXTURE, "www.cnbc.com"),
            (direct("MarketWatch"), MARKETWATCH_FIXTURE, "www.marketwatch.com"),
            (direct("Nasdaq"), NASDAQ_FIXTURE, "www.nasdaq.com"),
            (direct("PR Newswire"), PRNEWSWIRE_FIXTURE, "www.prnewswire.com"),
            (direct("GlobeNewswire"), GLOBENEWSWIRE_FIXTURE, "www.globenewswire.com"),
        ] {
            let items = feed_to_news(&src, None, fixture, 42);
            assert_eq!(items.len(), 1, "{} should yield one item", src.display);
            let it = &items[0];
            assert_eq!(it.source_name.as_deref(), Some(src.display));
            assert_eq!(it.source_domain, host, "{} domain", src.display);
            assert!(!it.title.is_empty() && it.title != "Markets Feed");
            assert!(it.url.starts_with("https://"), "{} url", src.display);
            assert!(it.symbol.is_none());
            assert_eq!(it.tone, 0.0, "rss carries no tone");
            assert!(it.ts_ms > 1_700_000_000_000, "{} date parsed", src.display);
        }
    }

    #[test]
    fn cnbc_item_title_is_not_the_channel_title() {
        let items = feed_to_news(&direct("CNBC"), None, CNBC_FIXTURE, 42);
        assert_eq!(items[0].title, "U.S. grocery slowdown deepens as shoppers buy fewer items");
        assert_eq!(items[0].url, "https://www.cnbc.com/2026/07/16/us-grocery-spending-slows.html");
    }

    #[test]
    fn yahoo_general_prefers_per_item_source_element() {
        // The general feed relays third parties: attribution follows the item's
        // <source>, not the "Yahoo Finance" feed name.
        let items = feed_to_news(&direct("Yahoo Finance"), None, YAHOO_GENERAL_FIXTURE, 42);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].source_name.as_deref(), Some("24/7 Wall St."));
        assert_eq!(items[0].source_domain, "247wallst.com");
        assert!(items[0].ts_ms > 1_700_000_000_000, "iso date parsed");
    }

    #[test]
    fn yahoo_per_symbol_feed_tags_symbol_and_uses_link_host() {
        let items = feed_to_news(&YAHOO_SYMBOL_SOURCE, Some("AAPL"), YAHOO_SYMBOL_FIXTURE, 42);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].symbol.as_deref(), Some("AAPL"));
        assert_eq!(items[0].source_name.as_deref(), Some("Yahoo Finance"));
        // No <source> element: the real domain is the article link's host.
        assert_eq!(items[0].source_domain, "www.fool.com");
        assert!(items[0].ts_ms > 1_700_000_000_000, "+0000 date parsed");
        // The per-symbol URL is well-formed and escaped.
        let url = yahoo_symbol_url("BRK-B");
        assert!(url.starts_with("https://feeds.finance.yahoo.com/rss/2.0/headline?s=BRK-B"));
        assert!(!url.contains(' '));
    }

    #[test]
    fn google_news_relay_uses_true_outlet_and_strips_title_suffix() {
        let items = feed_to_news(&relay("Reuters"), None, GOOGLE_NEWS_FIXTURE, 42);
        assert_eq!(items.len(), 1);
        let it = &items[0];
        // True outlet + its real site come from <source>, never "google".
        assert_eq!(it.source_name.as_deref(), Some("Reuters"));
        assert_eq!(it.source_domain, "www.reuters.com");
        assert_ne!(it.source_domain, "news.google.com");
        // " - Reuters" suffix stripped; &amp; decoded to &.
        assert_eq!(it.title, "S&P 500, Nasdaq fall as chip stocks weaken; earnings in focus");
        assert!(it.ts_ms > 1_700_000_000_000, "rfc822 GMT date parsed");
    }

    #[test]
    fn google_news_falls_back_to_title_suffix_when_source_absent() {
        // A relay item with no <source> still resolves the outlet from the
        // "… - Outlet" suffix (honest), never "google".
        let no_source = r#"<rss version="2.0"><channel><item>
            <title>Fed holds rates steady, signals caution - Bloomberg</title>
            <link>https://news.google.com/rss/articles/ABC?oc=5</link>
            <pubDate>Thu, 16 Jul 2026 14:15:07 GMT</pubDate>
        </item></channel></rss>"#;
        let items = feed_to_news(&relay("Bloomberg"), None, no_source, 42);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].source_name.as_deref(), Some("Bloomberg"));
        assert_eq!(items[0].title, "Fed holds rates steady, signals caution");
        // The link is a news.google.com redirect: never pair the real outlet
        // name with Google's aggregator host. Domain is left empty instead.
        assert_ne!(items[0].source_domain, "news.google.com");
        assert_eq!(items[0].source_domain, "");
    }

    #[test]
    fn google_news_relay_keeps_real_outlet_host_from_redirect_link() {
        // A relay item whose <link> already resolves to a genuine outlet host
        // (not the news.google.com redirect) keeps that host as the domain.
        let outlet_link = r#"<rss version="2.0"><channel><item>
            <title>Oil steadies after supply data - Reuters</title>
            <link>https://www.reuters.com/markets/oil-steadies</link>
            <pubDate>Thu, 16 Jul 2026 14:15:07 GMT</pubDate>
        </item></channel></rss>"#;
        let items = feed_to_news(&relay("Reuters"), None, outlet_link, 42);
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].source_name.as_deref(), Some("Reuters"));
        assert_eq!(items[0].source_domain, "www.reuters.com");
    }

    #[test]
    fn atom_feed_parses_with_alternate_link_and_rfc3339_date() {
        let items = feed_to_news(&direct("SEC EDGAR"), None, EDGAR_ATOM_FIXTURE, 42);
        assert_eq!(items.len(), 1);
        let it = &items[0];
        assert_eq!(it.title, "8-K - STAR GROUP, L.P. (0001002590) (Filer)");
        // The entry's rel="alternate" href wins over the feed-level rel="self".
        assert_eq!(
            it.url,
            "https://www.sec.gov/Archives/edgar/data/1002590/000117184326004725/0001171843-26-004725-index.htm"
        );
        assert_eq!(it.source_domain, "www.sec.gov");
        assert!(it.ts_ms > 1_700_000_000_000, "rfc3339 offset date parsed");
    }

    #[test]
    fn al_jazeera_business_filter_keeps_markets_drops_sport() {
        let src = NewsSource {
            display: "Al Jazeera",
            url: "",
            relay: false,
            business_only: true,
        };
        let items = feed_to_news(&src, None, ALJAZEERA_FIXTURE, 42);
        assert_eq!(items.len(), 1, "only the economy item survives the filter");
        assert!(items[0].title.starts_with("Oil prices climb"));
        assert_eq!(items[0].source_domain, "www.aljazeera.com");
        // Without the filter, BOTH items parse (proving the filter, not the
        // parser, dropped the sport story).
        let unfiltered = NewsSource { business_only: false, ..src };
        assert_eq!(feed_to_news(&unfiltered, None, ALJAZEERA_FIXTURE, 42).len(), 2);
    }

    #[test]
    fn dedupe_across_sources_keeps_first_seen_attribution() {
        // The same story from a direct feed and a Google-News relay: the ring
        // keeps ONE, with the first-ingested source's attribution.
        let cnbc = r#"<rss version="2.0"><channel><item>
            <title>Markets steady as investors weigh earnings</title>
            <link>https://www.cnbc.com/2026/07/16/markets-steady.html</link>
            <pubDate>Thu, 16 Jul 2026 12:00:00 GMT</pubDate>
        </item></channel></rss>"#;
        let gnews = r#"<rss version="2.0"><channel><item>
            <title>Markets steady as investors weigh earnings - Reuters</title>
            <link>https://news.google.com/rss/articles/XYZ?oc=5</link>
            <pubDate>Thu, 16 Jul 2026 12:05:00 GMT</pubDate>
            <source url="https://www.reuters.com">Reuters</source>
        </item></channel></rss>"#;
        let mut st = NewsState::default();
        assert_eq!(st.ingest(feed_to_news(&direct("CNBC"), None, cnbc, 42)), 1);
        // The relayed copy normalizes to the same title -> nothing fresh.
        assert_eq!(st.ingest(feed_to_news(&relay("Reuters"), None, gnews, 42)), 0);
        assert_eq!(st.ring.len(), 1);
        assert_eq!(st.ring[0].source_name.as_deref(), Some("CNBC"));
    }

    #[test]
    fn malformed_feeds_degrade_to_empty_never_panic() {
        for bad in [
            "",
            "not xml at all",
            "<html><body>blocked by anti-bot</body></html>",
            "<rss><channel><item><title>",         // truncated item
            "<rss><channel><item></item></channel>", // item without a title
            "{\"json\":true}",
        ] {
            assert!(parse_feed(bad, 1).is_empty(), "fixture: {bad:?}");
            assert!(feed_to_news(&direct("X"), None, bad, 1).is_empty());
        }
    }

    #[test]
    fn parse_feed_ts_handles_rss_iso_and_named_gmt() {
        // RSS RFC-822 with a named zone.
        assert!(parse_feed_ts("Thu, 16 Jul 2026 11:00:01 GMT", 7) > 1_700_000_000_000);
        // RSS with a numeric offset.
        assert!(parse_feed_ts("Thu, 16 Jul 2026 15:05:00 +0000", 7) > 1_700_000_000_000);
        // ISO-8601 / RFC-3339, both zulu and offset.
        assert!(parse_feed_ts("2026-07-16T15:35:19Z", 7) > 1_700_000_000_000);
        assert!(parse_feed_ts("2026-07-16T11:39:40-04:00", 7) > 1_700_000_000_000);
        // GMT with no seconds still parses via the fallback.
        assert!(parse_feed_ts("Thu, 16 Jul 2026 15:43 GMT", 7) > 1_700_000_000_000);
        // The +0000 and -04:00 renderings of the same instant agree.
        assert_eq!(
            parse_feed_ts("Thu, 16 Jul 2026 15:39:40 +0000", 0),
            parse_feed_ts("2026-07-16T11:39:40-04:00", 0)
        );
        // Garbage degrades to the fallback, never a panic.
        assert_eq!(parse_feed_ts("not-a-date", 7), 7);
        assert_eq!(parse_feed_ts("", 7), 7);
    }

    #[test]
    fn xml_decode_and_host_of_are_defensive() {
        assert_eq!(xml_decode("S&amp;P 500 &lt;up&gt; &quot;x&quot; &#39;y&#39;"), "S&P 500 <up> \"x\" 'y'");
        assert_eq!(xml_decode("smart &#8217; quote"), "smart \u{2019} quote");
        assert_eq!(xml_decode("hex &#x26; amp"), "hex & amp");
        // A lone ampersand and an over-long "entity" are left literal.
        assert_eq!(xml_decode("Tom & Jerry"), "Tom & Jerry");
        assert_eq!(xml_decode("a &notanentityatall; b"), "a &notanentityatall; b");

        assert_eq!(host_of("https://www.reuters.com/markets/x?a=1"), Some("www.reuters.com".into()));
        assert_eq!(host_of("http://Finance.YAHOO.com:8080/p"), Some("finance.yahoo.com".into()));
        assert_eq!(host_of("247wallst.com/"), Some("247wallst.com".into()));
        assert_eq!(host_of(""), None);
    }

    #[test]
    fn cdata_titles_are_unwrapped_without_entity_decoding() {
        // A CDATA title keeps its literal ampersand (CDATA is not entity-coded).
        let f = r#"<rss version="2.0"><channel><item>
            <title><![CDATA[AT&T & Verizon in focus]]></title>
            <link>https://www.cnbc.com/2026/07/16/att.html</link>
            <pubDate>Thu, 16 Jul 2026 12:00:00 GMT</pubDate>
        </item></channel></rss>"#;
        let items = feed_to_news(&direct("CNBC"), None, f, 42);
        assert_eq!(items[0].title, "AT&T & Verizon in focus");
    }

    #[test]
    fn every_wired_source_is_https_and_egress_allowlisted() {
        use cx_core::egress::ALLOWED_HOSTS;
        for src in NEWS_SOURCES {
            let host = host_of(src.url).expect("source url has a host");
            assert!(src.url.starts_with("https://"), "{} must be https", src.display);
            assert!(ALLOWED_HOSTS.contains(&host.as_str()), "{host} not allowlisted");
            // Relays go through Google News; direct feeds do not.
            assert_eq!(src.relay, host == "news.google.com", "{} relay flag", src.display);
        }
        // The per-symbol Yahoo feed host is allowlisted too.
        let yh = host_of(&yahoo_symbol_url("AAPL")).unwrap();
        assert!(ALLOWED_HOSTS.contains(&yh.as_str()), "{yh} not allowlisted");
    }

    #[test]
    fn board_source_label_discloses_every_wired_family() {
        let full = board_source_label(true);
        assert!(full.contains("gdelt"));
        assert!(full.contains("rss/atom") && full.contains("cnbc") && full.contains("al jazeera"));
        assert!(full.contains("google news relay") && full.contains("reuters"));
        assert!(full.contains("sec edgar"));
        // With the RSS layer off, only GDELT + EDGAR are claimed.
        let gdelt_only = board_source_label(false);
        assert!(!gdelt_only.contains("rss") && !gdelt_only.contains("google news"));
        assert!(gdelt_only.contains("gdelt") && gdelt_only.contains("sec edgar"));
    }
}
