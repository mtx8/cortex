//! FILINGS — a dedicated, richer SEC EDGAR filings browser.
//!
//! Distinct from the COMPANY card's `filings` field (round 11): that is a
//! short cadence summary (newest ~12, doc link only). This browser answers a
//! query on demand with up to ~200 rows carrying period-of-report, accession,
//! primary-doc + index links, description, 8-K item codes, size and the XBRL
//! flag — everything the EDGAR submissions `recent` block exposes.
//!
//! Endpoints (keyless, UA identifies the client, all through the hardened
//! `Egress` chokepoint):
//!   https://data.sec.gov/submissions/CIK{cik10}.json   the recent-filings list
//!   https://efts.sec.gov/LATEST/search-index?q=...      full-text search
//!
//! Resolution (step 1): a query is a raw CIK (all digits), a ticker, or a
//! company name. Tickers/names resolve through [`company::cik_for`] — the SAME
//! 24h-cached SEC ticker map the COMPANY/NEWS engines share. An unresolved
//! query is NOT an error: it yields an empty report with an honest `note`.
//!
//! Honesty posture (mirrors COMPANY/NEWS): infallible by construction. Every
//! path publishes exactly one `EngineEvent::Filings`; a fetch failure, an
//! unresolved query, or an unparseable body degrades to an empty list plus a
//! disclosed `note`. Full-text search degrades to the submissions list on any
//! failure. Egress-only, bus-only, no secrets, never panics.

use std::sync::Arc;

use serde_json::Value;

use cx_core::egress::Egress;
use cx_core::events::{EngineEvent, FilingEntry, FilingsReport};
use cx_core::time::now_ms;
use cx_core::Bus;

use crate::company;

/// EDGAR submissions payloads run ~1-2 MB for the largest filers (mirrors
/// company.rs / news.rs).
const SUBMISSIONS_CAP: usize = 16 * 1024 * 1024;
/// Rows kept, newest first. The `recent` block holds up to ~1000; 200 is
/// enough for a deep browse without bloating the on-demand payload.
const MAX_FILINGS: usize = 200;

/// Disclosed source labels (exact wire contract strings).
const SRC_SUBMISSIONS: &str = "SEC EDGAR submissions (data.sec.gov)";
const SRC_FULLTEXT: &str = "SEC EDGAR full-text (efts.sec.gov)";

/// Honest `note` strings.
const NOTE_EMPTY: &str = "empty query";
const NOTE_NOT_IN_MAP: &str = "ticker not found in SEC map";
const NOTE_MAP_FETCH_FAILED: &str = "SEC ticker map fetch failed";
const NOTE_SUBMISSIONS_FAILED: &str = "submissions fetch failed";
const NOTE_NO_FILINGS: &str = "no filings in EDGAR submissions";
const NOTE_FTS_DEGRADED: &str = "full-text search unavailable; showing recent filings";
const NOTE_FTS_NO_MATCH: &str = "no full-text matches for keywords";

/// Handle `Command::GetFilings`: resolve the query, fetch (submissions or
/// full-text), and publish exactly one `EngineEvent::Filings`. Never errors
/// outward — any unfetchable/unresolvable path is disclosed in `note`.
pub fn serve_filings(bus: Arc<Bus>, query: String, form_filter: String, text: String) {
    tokio::spawn(async move {
        let egress = Egress::new();
        let report = build_report(&egress, &query, &form_filter, &text).await;
        bus.publish(EngineEvent::Filings(report));
    });
}

/// Build the report end to end. Resolve -> (full-text | submissions), each
/// degrading honestly. Split out from [`serve_filings`] so the spawn stays a
/// one-liner and the logic is straight-line.
async fn build_report(
    egress: &Egress,
    query: &str,
    form_filter: &str,
    text: &str,
) -> FilingsReport {
    let (cik, resolved_ticker) = match resolve(egress, query).await {
        Resolution::Resolved { cik, ticker } => (cik, ticker),
        Resolution::Unresolved { note } => return unresolved_report(query, note),
    };

    let text = text.trim();
    if !text.is_empty() {
        let cik10 = format!("{cik:010}");
        let url = efts_url(&cik10, text);
        match egress.get_text(&url).await {
            Ok(raw) => match parse_efts_hits(cik, &raw) {
                Some((name, ticker0, entries)) => {
                    let note = if entries.is_empty() { NOTE_FTS_NO_MATCH } else { "" };
                    return FilingsReport {
                        query: query.to_string(),
                        cik: cik10,
                        name,
                        ticker: pick_ticker(ticker0, resolved_ticker),
                        filings: entries,
                        source: SRC_FULLTEXT.into(),
                        note: note.into(),
                        ts_ms: now_ms(),
                    };
                }
                None => tracing::warn!(
                    query = %query,
                    "filings: efts response unparseable; degrading to submissions"
                ),
            },
            Err(e) => tracing::warn!(
                query = %query,
                error = %e,
                "filings: efts fetch failed; degrading to submissions"
            ),
        }
        // Degraded: fall through to the submissions list, flagged in `note`.
        return submissions_report(egress, query, cik, resolved_ticker, form_filter, true).await;
    }

    submissions_report(egress, query, cik, resolved_ticker, form_filter, false).await
}

/// Fetch + parse the submissions `recent` list into a report. `degraded` marks
/// a fall-through from a failed full-text search (the note discloses it).
async fn submissions_report(
    egress: &Egress,
    query: &str,
    cik: u64,
    resolved_ticker: String,
    form_filter: &str,
    degraded: bool,
) -> FilingsReport {
    let cik10 = format!("{cik:010}");
    match egress
        .get_text_with_cap(&crate::news::submissions_url(cik), SUBMISSIONS_CAP)
        .await
    {
        Ok(raw) => {
            let (name, ticker0) = parse_submissions_meta(&raw);
            let entries = parse_submissions_filings(cik, &raw, form_filter);
            let note = if degraded {
                NOTE_FTS_DEGRADED
            } else if entries.is_empty() {
                NOTE_NO_FILINGS
            } else {
                ""
            };
            FilingsReport {
                query: query.to_string(),
                cik: cik10,
                name,
                ticker: pick_ticker(ticker0, resolved_ticker),
                filings: entries,
                source: SRC_SUBMISSIONS.into(),
                note: note.into(),
                ts_ms: now_ms(),
            }
        }
        Err(e) => {
            tracing::warn!(query = %query, error = %e, "filings: submissions fetch failed");
            FilingsReport {
                query: query.to_string(),
                cik: cik10,
                name: String::new(),
                ticker: resolved_ticker,
                filings: Vec::new(),
                source: SRC_SUBMISSIONS.into(),
                note: NOTE_SUBMISSIONS_FAILED.into(),
                ts_ms: now_ms(),
            }
        }
    }
}

/// The honest empty report for a query that never resolved to a CIK.
fn unresolved_report(query: &str, note: String) -> FilingsReport {
    FilingsReport {
        query: query.to_string(),
        cik: String::new(),
        name: String::new(),
        ticker: String::new(),
        filings: Vec::new(),
        source: SRC_SUBMISSIONS.into(),
        note,
        ts_ms: now_ms(),
    }
}

/// Prefer the source-derived ticker; fall back to the resolution ticker.
fn pick_ticker(from_source: String, resolved: String) -> String {
    if from_source.is_empty() {
        resolved
    } else {
        from_source
    }
}

// ---------------------------------------------------------------------------
// Query resolution.
// ---------------------------------------------------------------------------

/// A query classified into an EDGAR identifier.
#[derive(Debug, PartialEq, Eq)]
enum QueryKind {
    /// All-digits: a raw CIK.
    Cik(u64),
    /// Everything else: a ticker candidate (uppercased, punctuation-normalized).
    Ticker(String),
}

/// The outcome of resolving a query to a CIK.
#[derive(Debug, PartialEq, Eq)]
enum Resolution {
    Resolved { cik: u64, ticker: String },
    Unresolved { note: String },
}

/// Classify a query. `None` = nothing usable (empty, or a digit run that
/// overflows a u64 — vanishingly unlikely for a <=10-digit CIK).
fn classify_query(query: &str) -> Option<QueryKind> {
    let q = query.trim();
    if q.is_empty() {
        return None;
    }
    if q.bytes().all(|b| b.is_ascii_digit()) {
        return q.parse::<u64>().ok().map(QueryKind::Cik);
    }
    let cand = ticker_candidate(q);
    if cand.is_empty() {
        None
    } else {
        Some(QueryKind::Ticker(cand))
    }
}

/// Normalize a ticker candidate: uppercase, keep A-Z/0-9 and inner `.`/`-`
/// (real tickers use them: "BRK.B"), drop everything else. A company name's
/// spaces collapse away — a deliberately best-effort match against the
/// ticker-keyed SEC map (names are not indexed there).
fn ticker_candidate(q: &str) -> String {
    let raw: String = q
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || *c == '.' || *c == '-')
        .flat_map(char::to_uppercase)
        .collect();
    raw.trim_matches(|c| c == '.' || c == '-').to_string()
}

/// Resolve a query to a CIK using the shared cached SEC ticker map (tickers /
/// names) or a direct parse (raw CIK). An unknown ticker or a map-fetch
/// failure is disclosed, never surfaced as an error.
async fn resolve(egress: &Egress, query: &str) -> Resolution {
    match classify_query(query) {
        None => Resolution::Unresolved { note: NOTE_EMPTY.into() },
        Some(QueryKind::Cik(cik)) => Resolution::Resolved { cik, ticker: String::new() },
        Some(QueryKind::Ticker(cand)) => {
            // SEC's company_tickers.json keys class-share tickers with a HYPHEN
            // ("BRK-B", "BF-B"), while the ticker candidate preserves the
            // dotted form a user is likely to type ("BRK.B"). Try the candidate
            // first, then its hyphenated variant (only when it differs — no
            // extra lookup for dot-less tickers; the map is 24h-cached either
            // way) before declaring not-found.
            let dashed = cand.replace('.', "-");
            let lookup = match company::cik_for(egress, &cand).await {
                Ok(None) if dashed != cand => company::cik_for(egress, &dashed).await,
                other => other,
            };
            match lookup {
                Ok(Some(cik)) => Resolution::Resolved { cik, ticker: cand },
                Ok(None) => Resolution::Unresolved { note: NOTE_NOT_IN_MAP.into() },
                Err(e) => {
                    tracing::warn!(query = %query, error = %e, "filings: cik map fetch failed");
                    Resolution::Unresolved { note: NOTE_MAP_FETCH_FAILED.into() }
                }
            }
        }
    }
}

// ---------------------------------------------------------------------------
// EDGAR submissions parsing.
// ---------------------------------------------------------------------------

/// Read the filer's legal `name` and first `tickers[0]` from a submissions
/// payload. Both default to "" on any malformed/absent field (never a panic).
fn parse_submissions_meta(raw: &str) -> (String, String) {
    let Ok(v) = serde_json::from_str::<Value>(raw) else {
        return (String::new(), String::new());
    };
    let name = v
        .get("name")
        .and_then(|x| x.as_str())
        .unwrap_or_default()
        .to_string();
    let ticker = v
        .get("tickers")
        .and_then(|t| t.as_array())
        .and_then(|a| a.first())
        .and_then(|x| x.as_str())
        .unwrap_or_default()
        .to_string();
    (name, ticker)
}

/// Build the FILINGS list from a submissions payload. The `filings.recent`
/// object holds PARALLEL arrays (form/filingDate/reportDate/accessionNumber/
/// primaryDocument/primaryDocDescription/items/size/isXBRL); we zip them by
/// index, guarding every access so a short or absent optional array degrades
/// per-field (never a panic, never an out-of-range). `form/filingDate/
/// accessionNumber` are required per row (a row missing any, or carrying a
/// malformed date, is skipped); `primaryDocument` MAY be empty (unlike the
/// COMPANY card, the browser keeps doc-less rows and links the index instead).
/// Newest-first order is preserved; capped at [`MAX_FILINGS`]. When
/// `form_filter` is non-empty, only forms exactly equal to it or its amendment
/// (case-insensitive — "10-K" matches "10-K" and "10-K/A" but not "10-K405")
/// are kept; see [`form_matches`].
fn parse_submissions_filings(cik: u64, raw: &str, form_filter: &str) -> Vec<FilingEntry> {
    let Ok(v) = serde_json::from_str::<Value>(raw) else {
        return Vec::new();
    };
    let Some(recent) = v.get("filings").and_then(|f| f.get("recent")) else {
        return Vec::new();
    };
    let arr = |k: &str| recent.get(k).and_then(|x| x.as_array());
    let (Some(forms), Some(dates), Some(accns)) =
        (arr("form"), arr("filingDate"), arr("accessionNumber"))
    else {
        return Vec::new();
    };
    // Optional parallel arrays: absent -> that field defaults for every row.
    let report_dates = arr("reportDate");
    let docs = arr("primaryDocument");
    let descs = arr("primaryDocDescription");
    let items_a = arr("items");
    let sizes = arr("size");
    let xbrls = arr("isXBRL");

    let filter = form_filter.trim();
    let mut out = Vec::with_capacity(MAX_FILINGS.min(forms.len()));
    for i in 0..forms.len() {
        if out.len() >= MAX_FILINGS {
            break;
        }
        let (Some(form), Some(date), Some(accn)) = (
            forms.get(i).and_then(|x| x.as_str()),
            dates.get(i).and_then(|x| x.as_str()),
            accns.get(i).and_then(|x| x.as_str()),
        ) else {
            continue; // malformed row: skip, never panic
        };
        if form.is_empty() || accn.is_empty() {
            continue;
        }
        // Honest date: skip rows whose filingDate isn't a real YYYY-MM-DD.
        if chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d").is_err() {
            continue;
        }
        if !form_matches(form, filter) {
            continue;
        }
        let report_date = str_at(report_dates, i);
        let primary_doc = str_at(docs, i);
        let desc_raw = str_at(descs, i);
        let items = str_at(items_a, i);
        let size = u64_at(sizes, i);
        let is_xbrl = flag_at(xbrls, i);

        let description = if desc_raw.is_empty() {
            form_human_name(form)
        } else {
            desc_raw.to_string()
        };
        out.push(entry(cik, form, date, report_date, accn, primary_doc, &description, items, size, is_xbrl));
    }
    out
}

/// Case-insensitive exact-or-amendment form match; an empty filter keeps
/// everything. Mirrors the client chip filter (`FilingsSupport.baseMatch`):
/// the exact form, or the same form as an amendment ("10-K/A"). Deliberately
/// NOT a raw prefix — a prefix would sweep "10-K405"/"10-KSB"/"10-KT" into
/// "10-K" and "40-F" into "4", the exact fold the client avoids.
fn form_matches(form: &str, filter: &str) -> bool {
    if filter.is_empty() {
        return true;
    }
    let form_u = form.to_ascii_uppercase();
    let filter_u = filter.to_ascii_uppercase();
    form_u == filter_u || form_u.starts_with(&format!("{filter_u}/"))
}

// ---------------------------------------------------------------------------
// EDGAR full-text search parsing.
// ---------------------------------------------------------------------------

/// Build the EDGAR full-text search URL, scoped to one filer. The keyword
/// phrase is wrapped in quotes then percent-encoded whole (no raw quotes or
/// spaces reach the URL).
fn efts_url(cik10: &str, keywords: &str) -> String {
    format!(
        "https://efts.sec.gov/LATEST/search-index?q={}&ciks={cik10}",
        url_encode(&format!("\"{keywords}\""))
    )
}

/// Parse an EDGAR full-text search (`efts.sec.gov`) response.
///
/// Response shape (verified against the live API's structure): the top-level
/// `hits` object carries `hits.hits[]`, each an object with `_id` =
/// "{accession}:{primaryDoc}" and a `_source` object:
///   { ciks:[".."], root_form|file_type|form, file_date, period_ending,
///     display_names:["Name (TICK) (CIK ..)"], file_description, adsh, items }.
/// We read defensively (multiple form-field fallbacks; adsh from `_source`
/// else the `_id` prefix; primary doc from the `_id` suffix) so a
/// field-naming drift degrades a row rather than the whole response.
///
/// Returns `Some((name, ticker, entries))` — a SUCCESSFUL parse, even with
/// zero hits (an honest "no matches"). Returns `None` only when the body is
/// unparseable or lacks the `hits` structure entirely; the caller then
/// degrades to the submissions list.
fn parse_efts_hits(cik: u64, raw: &str) -> Option<(String, String, Vec<FilingEntry>)> {
    let v: Value = serde_json::from_str(raw).ok()?;
    let hits_root = v.get("hits")?;
    // Real shape is hits.hits[]; tolerate a bare hits[] array too.
    let arr = hits_root
        .get("hits")
        .and_then(|x| x.as_array())
        .or_else(|| hits_root.as_array())?;

    let mut name = String::new();
    let mut ticker = String::new();
    let mut out = Vec::with_capacity(arr.len().min(MAX_FILINGS));
    for hit in arr {
        if out.len() >= MAX_FILINGS {
            break;
        }
        let src = hit.get("_source");
        let id = hit.get("_id").and_then(|x| x.as_str()).unwrap_or("");
        let (id_accn, id_doc) = match id.split_once(':') {
            Some((a, d)) => (a, d),
            None => (id, ""),
        };
        let accn = src
            .and_then(|s| s.get("adsh"))
            .and_then(|x| x.as_str())
            .filter(|s| !s.is_empty())
            .unwrap_or(id_accn);
        if accn.is_empty() {
            continue; // no accession: cannot link a filing honestly
        }
        let form = efts_form(src);
        let filed = src
            .and_then(|s| s.get("file_date"))
            .and_then(|x| x.as_str())
            .unwrap_or("");
        let report_date = src
            .and_then(|s| s.get("period_ending"))
            .and_then(|x| x.as_str())
            .unwrap_or("");
        let desc_raw = src
            .and_then(|s| s.get("file_description"))
            .and_then(|x| x.as_str())
            .unwrap_or("");
        let description = if desc_raw.is_empty() {
            form_human_name(&form)
        } else {
            desc_raw.to_string()
        };
        let items = efts_items(src);

        // Company name/ticker from the first hit that carries display_names.
        if name.is_empty() {
            if let Some((n, t)) = src
                .and_then(|s| s.get("display_names"))
                .and_then(|x| x.as_array())
                .and_then(|a| a.first())
                .and_then(|x| x.as_str())
                .map(parse_display_name)
            {
                name = n;
                if ticker.is_empty() {
                    ticker = t;
                }
            }
        }

        out.push(entry(cik, &form, filed, report_date, accn, id_doc, &description, &items, 0, false));
    }
    Some((name, ticker, out))
}

/// The form type from an efts `_source`, trying the fields EDGAR has used.
fn efts_form(src: Option<&Value>) -> String {
    for key in ["root_form", "file_type", "form"] {
        if let Some(f) = src
            .and_then(|s| s.get(key))
            .and_then(|x| x.as_str())
            .filter(|s| !s.is_empty())
        {
            return f.to_string();
        }
    }
    // Some payloads carry a `root_forms` array instead of a scalar.
    src.and_then(|s| s.get("root_forms"))
        .and_then(|x| x.as_array())
        .and_then(|a| a.first())
        .and_then(|x| x.as_str())
        .unwrap_or_default()
        .to_string()
}

/// The `items` field from an efts `_source`: an array (joined CSV) or a
/// scalar string, else "".
fn efts_items(src: Option<&Value>) -> String {
    match src.and_then(|s| s.get("items")) {
        Some(Value::Array(a)) => a
            .iter()
            .filter_map(|x| x.as_str())
            .filter(|s| !s.is_empty())
            .collect::<Vec<_>>()
            .join(","),
        Some(Value::String(s)) => s.clone(),
        _ => String::new(),
    }
}

/// Split an EDGAR `display_names` entry — "Apple Inc. (AAPL) (CIK 0000320193)"
/// — into (name, ticker). The ticker is the first parenthesized token that
/// looks like one (not the "CIK ..." group); "" when absent.
fn parse_display_name(s: &str) -> (String, String) {
    let name = s.split(" (").next().unwrap_or(s).trim().to_string();
    let ticker = s
        .find('(')
        .and_then(|i| {
            let rest = &s[i + 1..];
            rest.find(')').map(|j| rest[..j].trim().to_string())
        })
        .filter(|t| {
            !t.is_empty()
                && !t.starts_with("CIK")
                && t.len() <= 8
                && t.chars().all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
        })
        .unwrap_or_default();
    (name, ticker)
}

// ---------------------------------------------------------------------------
// Shared entry construction + helpers.
// ---------------------------------------------------------------------------

/// Assemble one [`FilingEntry`], building the archive URLs per the contract.
#[allow(clippy::too_many_arguments)]
fn entry(
    fallback_cik: u64,
    form: &str,
    filed: &str,
    report_date: &str,
    accession: &str,
    primary_doc: &str,
    description: &str,
    items: &str,
    size: u64,
    is_xbrl: bool,
) -> FilingEntry {
    // EDGAR archive paths use the non-padded FILER CIK (the accession's first
    // dash-segment) and the dash-free accession number.
    let cik_int = archive_cik(accession, fallback_cik);
    let accn_no_dashes = accession.replace('-', "");
    let primary_doc_url = if primary_doc.is_empty() {
        String::new()
    } else {
        format!("https://www.sec.gov/Archives/edgar/data/{cik_int}/{accn_no_dashes}/{primary_doc}")
    };
    // The index page is always resolvable (named by the DASHED accession).
    let filing_index_url = format!(
        "https://www.sec.gov/Archives/edgar/data/{cik_int}/{accn_no_dashes}/{accession}-index.htm"
    );
    FilingEntry {
        form: form.to_string(),
        filed: filed.to_string(),
        report_date: report_date.to_string(),
        accession: accession.to_string(),
        primary_doc: primary_doc.to_string(),
        primary_doc_url,
        filing_index_url,
        description: description.to_string(),
        items: items.to_string(),
        size,
        is_xbrl,
    }
}

/// The filer CIK for an archive path: the accession's first dash-segment
/// (e.g. "0000320193-26-000005" -> 320193), falling back to the resolved CIK
/// when the accession is malformed. Robust across co-filings (e.g. insider
/// Form 4s) whose filer differs from the queried company.
fn archive_cik(accession: &str, fallback: u64) -> u64 {
    accession
        .split('-')
        .next()
        .and_then(|p| p.parse::<u64>().ok())
        .filter(|c| *c > 0)
        .unwrap_or(fallback)
}

/// The human name for a form type, used as the `description` fallback when the
/// filing carries no primaryDocDescription. "" for forms we don't name.
/// Amendments ("…/A") reuse the base name plus " (amended)".
fn form_human_name(form: &str) -> String {
    let (base, amended) = match form.strip_suffix("/A") {
        Some(b) => (b, true),
        None => (form, false),
    };
    let name = match base {
        "10-K" => "Annual report",
        "10-Q" => "Quarterly report",
        "8-K" => "Current report",
        "S-1" | "S-3" | "S-4" => "Registration statement",
        "20-F" | "40-F" => "Annual report (foreign issuer)",
        "6-K" => "Report of foreign issuer",
        "DEF 14A" | "DEFA14A" => "Proxy statement",
        "3" => "Initial statement of beneficial ownership",
        "4" => "Statement of changes in beneficial ownership",
        "5" => "Annual statement of beneficial ownership",
        "SC 13D" | "SC 13G" => "Beneficial ownership report",
        "13F-HR" => "Institutional holdings report",
        "11-K" => "Employee benefit plan report",
        "SD" => "Specialized disclosure report",
        b if b.starts_with("424") => "Prospectus",
        _ => "",
    };
    if name.is_empty() {
        String::new()
    } else if amended {
        format!("{name} (amended)")
    } else {
        name.to_string()
    }
}

/// A string cell from an optional parallel array at index `i`, or "".
fn str_at(a: Option<&Vec<Value>>, i: usize) -> &str {
    a.and_then(|a| a.get(i)).and_then(|x| x.as_str()).unwrap_or("")
}

/// A u64 cell from an optional parallel array at index `i`, or 0.
fn u64_at(a: Option<&Vec<Value>>, i: usize) -> u64 {
    a.and_then(|a| a.get(i)).and_then(|x| x.as_u64()).unwrap_or(0)
}

/// A boolean flag cell (EDGAR isXBRL is integer 1/0; tolerate a real bool).
fn flag_at(a: Option<&Vec<Value>>, i: usize) -> bool {
    match a.and_then(|a| a.get(i)) {
        Some(Value::Bool(b)) => *b,
        Some(v) => v.as_i64() == Some(1),
        None => false,
    }
}

/// Minimal percent-encoder (RFC 3986 unreserved kept verbatim). Local by the
/// same convention as news.rs / meridian.rs — no new crate dep for one call.
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
    use std::collections::HashMap;

    /// Pure test mirror of [`resolve`] against a provided map — the async
    /// `resolve` differs only in fetching the map via `company::cik_for`; both
    /// classify identically through [`classify_query`].
    fn resolve_in_map(query: &str, map: &HashMap<String, u64>) -> Resolution {
        match classify_query(query) {
            None => Resolution::Unresolved { note: NOTE_EMPTY.into() },
            Some(QueryKind::Cik(cik)) => Resolution::Resolved { cik, ticker: String::new() },
            Some(QueryKind::Ticker(cand)) => {
                // Mirrors `resolve`: try the dotted candidate, then its
                // hyphenated (SEC class-share) variant.
                let dashed = cand.replace('.', "-");
                let hit = map.get(&cand).or_else(|| map.get(&dashed)).copied();
                match hit {
                    Some(cik) => Resolution::Resolved { cik, ticker: cand },
                    None => Resolution::Unresolved { note: NOTE_NOT_IN_MAP.into() },
                }
            }
        }
    }

    /// Shape-faithful submissions payload: parallel `recent` arrays, newest
    /// first, with an amendment, a doc-less row, and a bad-date row to skip.
    const SUBMISSIONS_FIXTURE: &str = r#"{
      "cik": 320193,
      "name": "Apple Inc.",
      "tickers": ["AAPL", "APC.F"],
      "filings": { "recent": {
        "form":                  ["10-K",                 "8-K",                  "10-K/A",               "4"],
        "filingDate":            ["2026-02-15",           "2026-01-20",           "2025-12-05",           "not-a-date"],
        "reportDate":            ["2025-12-28",           "",                     "2024-09-28",           ""],
        "accessionNumber":       ["0000320193-26-000005", "0000320193-26-000002", "0000320193-25-000120", "0000320193-25-000119"],
        "primaryDocument":       ["aapl-20251228.htm",    "aapl-8k.htm",          "",                     "form4.xml"],
        "primaryDocDescription": ["10-K",                 "",                     "AMENDED ANNUAL REPORT","OWNERSHIP"],
        "items":                 ["",                     "2.02,9.01",            "",                     ""],
        "size":                  [1200000,                45000,                  800000,                 3000],
        "isXBRL":                [1,                       0,                      1,                      0]
      }}
    }"#;

    #[test]
    fn submissions_parses_entries_and_builds_archive_urls() {
        let f = parse_submissions_filings(320193, SUBMISSIONS_FIXTURE, "");
        // 10-K, 8-K, 10-K/A survive; the form-4 row (bad date) is skipped.
        assert_eq!(f.len(), 3);

        let k = &f[0];
        assert_eq!(k.form, "10-K");
        assert_eq!(k.filed, "2026-02-15");
        assert_eq!(k.report_date, "2025-12-28");
        assert_eq!(k.accession, "0000320193-26-000005");
        assert_eq!(k.primary_doc, "aapl-20251228.htm");
        // Non-padded CIK, dash-free accession, primary document.
        assert_eq!(
            k.primary_doc_url,
            "https://www.sec.gov/Archives/edgar/data/320193/000032019326000005/aapl-20251228.htm"
        );
        // Index URL named by the DASHED accession.
        assert_eq!(
            k.filing_index_url,
            "https://www.sec.gov/Archives/edgar/data/320193/000032019326000005/0000320193-26-000005-index.htm"
        );
        assert_eq!(k.description, "10-K"); // from primaryDocDescription
        assert_eq!(k.items, "");
        assert_eq!(k.size, 1_200_000);
        assert!(k.is_xbrl);

        // 8-K: empty description falls back to the human form name; item codes
        // preserved; not XBRL.
        let eight = &f[1];
        assert_eq!(eight.form, "8-K");
        assert_eq!(eight.description, "Current report");
        assert_eq!(eight.items, "2.02,9.01");
        assert_eq!(eight.report_date, "");
        assert!(!eight.is_xbrl);

        // 10-K/A: doc-less row is KEPT (index still links); no fake doc URL.
        let amend = &f[2];
        assert_eq!(amend.form, "10-K/A");
        assert_eq!(amend.primary_doc, "");
        assert_eq!(amend.primary_doc_url, "");
        assert_eq!(
            amend.filing_index_url,
            "https://www.sec.gov/Archives/edgar/data/320193/000032019325000120/0000320193-25-000120-index.htm"
        );
        assert_eq!(amend.description, "AMENDED ANNUAL REPORT");
        assert!(amend.is_xbrl);
    }

    #[test]
    fn submissions_meta_reads_name_and_first_ticker() {
        assert_eq!(
            parse_submissions_meta(SUBMISSIONS_FIXTURE),
            ("Apple Inc.".to_string(), "AAPL".to_string())
        );
        // Malformed / absent -> empty, never a panic.
        assert_eq!(parse_submissions_meta("junk"), (String::new(), String::new()));
        assert_eq!(parse_submissions_meta("{}"), (String::new(), String::new()));
    }

    #[test]
    fn form_filter_matches_prefix_including_amendments() {
        // "10-K" keeps the 10-K and its amendment, drops the 8-K.
        let ks = parse_submissions_filings(320193, SUBMISSIONS_FIXTURE, "10-K");
        assert_eq!(ks.len(), 2);
        assert!(ks.iter().all(|e| e.form.starts_with("10-K")));
        // Case-insensitive.
        assert_eq!(parse_submissions_filings(320193, SUBMISSIONS_FIXTURE, "10-k").len(), 2);
        // "8-K" keeps only the current report.
        let eights = parse_submissions_filings(320193, SUBMISSIONS_FIXTURE, "8-K");
        assert_eq!(eights.len(), 1);
        assert_eq!(eights[0].form, "8-K");
        // A prefix matching nothing yields an empty list.
        assert!(parse_submissions_filings(320193, SUBMISSIONS_FIXTURE, "DEF 14A").is_empty());
    }

    #[test]
    fn form_matches_is_exact_or_amendment_not_raw_prefix() {
        // Empty filter keeps everything.
        assert!(form_matches("8-K", ""));
        // Exact form and its amendment match.
        assert!(form_matches("10-K", "10-K"));
        assert!(form_matches("10-K/A", "10-K"));
        // Case-insensitive on both sides.
        assert!(form_matches("10-k", "10-K"));
        assert!(form_matches("10-K", "10-k"));
        // A raw prefix must NOT fold sibling forms in — mirrors the client
        // chip filter (FilingsSupport.baseMatch), which these siblings escape.
        assert!(!form_matches("10-K405", "10-K"));
        assert!(!form_matches("10-KSB", "10-K"));
        assert!(!form_matches("10-KT", "10-K"));
        assert!(!form_matches("40-F", "4"));
        assert!(!form_matches("424B5", "4"));
    }

    #[test]
    fn submissions_caps_newest_first() {
        // 250 valid rows, newest first: only the newest MAX_FILINGS survive.
        let n = 250usize;
        let forms: Vec<String> = (0..n).map(|_| "10-Q".into()).collect();
        let dates: Vec<String> = (0..n).map(|i| format!("2026-{:02}-01", (i % 12) + 1)).collect();
        let accns: Vec<String> = (0..n).map(|i| format!("0000320193-26-{i:06}")).collect();
        let docs: Vec<String> = (0..n).map(|i| format!("doc{i}.htm")).collect();
        let body = serde_json::json!({
            "filings": { "recent": {
                "form": forms, "filingDate": dates,
                "accessionNumber": accns, "primaryDocument": docs
            }}
        })
        .to_string();
        let f = parse_submissions_filings(320193, &body, "");
        assert_eq!(f.len(), MAX_FILINGS);
        // The first array row (newest) is kept and correctly linked.
        assert_eq!(
            f[0].primary_doc_url,
            "https://www.sec.gov/Archives/edgar/data/320193/000032019326000000/doc0.htm"
        );
    }

    #[test]
    fn submissions_degrades_on_malformed_or_short_arrays() {
        // Malformed / empty / partial bodies -> empty list, never a panic.
        assert!(parse_submissions_filings(320193, "junk", "").is_empty());
        assert!(parse_submissions_filings(320193, "{}", "").is_empty());
        assert!(parse_submissions_filings(320193, r#"{"filings":{"recent":{}}}"#, "").is_empty());

        // Short OPTIONAL arrays: required arrays have 2 rows, `size` has 1,
        // `isXBRL`/`primaryDocument` absent. Row 1's missing optionals default
        // (size 0, not XBRL, no doc) with no out-of-range panic.
        let short = r#"{"filings":{"recent":{
            "form": ["10-K", "10-Q"],
            "filingDate": ["2026-02-15", "2026-05-10"],
            "accessionNumber": ["0000320193-26-000005", "0000320193-26-000006"],
            "size": [1200000]
        }}}"#;
        let f = parse_submissions_filings(320193, short, "");
        assert_eq!(f.len(), 2);
        assert_eq!(f[0].size, 1_200_000);
        assert_eq!(f[1].size, 0);
        assert_eq!(f[1].primary_doc, "");
        assert_eq!(f[1].primary_doc_url, "");
        assert!(!f[1].is_xbrl);
        // The index URL is still resolvable for the doc-less row.
        assert!(f[1].filing_index_url.ends_with("0000320193-26-000006-index.htm"));
    }

    /// Shape-faithful EDGAR full-text search response: `hits.hits[]` with
    /// `_id` = "{accession}:{primaryDoc}" and a `_source` object.
    const EFTS_FIXTURE: &str = r#"{
      "took": 5, "timed_out": false,
      "hits": {
        "total": {"value": 2, "relation": "eq"},
        "hits": [
          {
            "_id": "0000320193-24-000123:aapl-20240928.htm",
            "_source": {
              "ciks": ["0000320193"],
              "period_ending": "2024-09-28",
              "root_form": "10-K",
              "file_date": "2024-11-01",
              "file_description": "10-K",
              "display_names": ["Apple Inc. (AAPL) (CIK 0000320193)"],
              "adsh": "0000320193-24-000123",
              "items": ["2.02"]
            }
          },
          {
            "_id": "0000320193-24-000100:aapl-8k.htm",
            "_source": {
              "ciks": ["0000320193"],
              "root_form": "8-K",
              "file_date": "2024-08-01",
              "display_names": ["Apple Inc. (AAPL) (CIK 0000320193)"],
              "adsh": "0000320193-24-000100"
            }
          }
        ]
      }
    }"#;

    #[test]
    fn efts_parses_hits_with_names_urls_and_degrades() {
        let (name, ticker, entries) = parse_efts_hits(320193, EFTS_FIXTURE).unwrap();
        assert_eq!(name, "Apple Inc.");
        assert_eq!(ticker, "AAPL");
        assert_eq!(entries.len(), 2);

        let k = &entries[0];
        assert_eq!(k.form, "10-K");
        assert_eq!(k.filed, "2024-11-01");
        assert_eq!(k.report_date, "2024-09-28");
        assert_eq!(k.accession, "0000320193-24-000123");
        assert_eq!(k.primary_doc, "aapl-20240928.htm"); // from the _id suffix
        assert_eq!(
            k.primary_doc_url,
            "https://www.sec.gov/Archives/edgar/data/320193/000032019324000123/aapl-20240928.htm"
        );
        assert_eq!(
            k.filing_index_url,
            "https://www.sec.gov/Archives/edgar/data/320193/000032019324000123/0000320193-24-000123-index.htm"
        );
        assert_eq!(k.description, "10-K"); // file_description
        assert_eq!(k.items, "2.02"); // array joined
        assert_eq!(k.size, 0); // efts does not report size
        assert!(!k.is_xbrl);

        // Second hit: no file_description -> human form name.
        assert_eq!(entries[1].form, "8-K");
        assert_eq!(entries[1].description, "Current report");
        assert_eq!(entries[1].items, "");

        // A successful-but-empty result is Some(empty), NOT a degrade.
        let empty = parse_efts_hits(320193, r#"{"hits":{"hits":[]}}"#).unwrap();
        assert!(empty.2.is_empty());

        // Unparseable / structureless bodies -> None (caller degrades).
        assert!(parse_efts_hits(320193, "junk").is_none());
        assert!(parse_efts_hits(320193, "{}").is_none());
    }

    #[test]
    fn efts_url_is_encoded_and_scoped_to_the_cik() {
        let url = efts_url("0000320193", "carbon neutral");
        assert!(url.starts_with("https://efts.sec.gov/LATEST/search-index?q="));
        assert!(!url.contains(' '), "unencoded space");
        assert!(!url.contains('"'), "unencoded quote");
        assert!(url.contains("&ciks=0000320193"));
        // The phrase is quoted then percent-encoded whole.
        assert!(url.contains("%22carbon%20neutral%22"));
    }

    #[test]
    fn classify_query_separates_cik_ticker_and_name() {
        assert_eq!(classify_query("320193"), Some(QueryKind::Cik(320193)));
        assert_eq!(classify_query("aapl"), Some(QueryKind::Ticker("AAPL".into())));
        assert_eq!(classify_query("BRK.B"), Some(QueryKind::Ticker("BRK.B".into())));
        // A company name collapses to a best-effort candidate (spaces dropped).
        assert_eq!(
            classify_query("Apple Inc."),
            Some(QueryKind::Ticker("APPLEINC".into()))
        );
        assert_eq!(classify_query(""), None);
        assert_eq!(classify_query("   "), None);
    }

    #[test]
    fn resolve_in_map_covers_cik_ticker_name_and_unresolved() {
        let mut map = HashMap::new();
        map.insert("AAPL".to_string(), 320193u64);

        // Ticker hit (case-insensitive via classify).
        assert_eq!(
            resolve_in_map("aapl", &map),
            Resolution::Resolved { cik: 320193, ticker: "AAPL".into() }
        );
        // Raw CIK: resolved with no ticker (submissions supplies it later).
        assert_eq!(
            resolve_in_map("1045810", &map),
            Resolution::Resolved { cik: 1045810, ticker: String::new() }
        );
        // Unknown ticker -> honest note, never an error.
        assert_eq!(
            resolve_in_map("ZZZZ", &map),
            Resolution::Unresolved { note: NOTE_NOT_IN_MAP.into() }
        );
        // Company name collapses to a candidate absent from the ticker map.
        assert_eq!(
            resolve_in_map("Apple Inc", &map),
            Resolution::Unresolved { note: NOTE_NOT_IN_MAP.into() }
        );
        // Empty query.
        assert_eq!(
            resolve_in_map("   ", &map),
            Resolution::Unresolved { note: NOTE_EMPTY.into() }
        );
    }

    #[test]
    fn resolve_maps_class_share_dot_to_sec_hyphen_key() {
        let mut map = HashMap::new();
        // SEC's company_tickers.json keys class shares with a hyphen.
        map.insert("BRK-B".to_string(), 1067983u64);

        // A dotted query resolves via the hyphenated SEC key.
        assert_eq!(
            resolve_in_map("BRK.B", &map),
            Resolution::Resolved { cik: 1067983, ticker: "BRK.B".into() }
        );
        // Lowercase dotted input too (classify uppercases it).
        assert_eq!(
            resolve_in_map("brk.b", &map),
            Resolution::Resolved { cik: 1067983, ticker: "BRK.B".into() }
        );
        // A dotted ticker with no hyphenated key still degrades honestly.
        assert_eq!(
            resolve_in_map("ZZ.Q", &map),
            Resolution::Unresolved { note: NOTE_NOT_IN_MAP.into() }
        );
    }

    #[test]
    fn form_human_name_maps_common_forms_and_amendments() {
        assert_eq!(form_human_name("10-K"), "Annual report");
        assert_eq!(form_human_name("10-K/A"), "Annual report (amended)");
        assert_eq!(form_human_name("8-K"), "Current report");
        assert_eq!(form_human_name("4"), "Statement of changes in beneficial ownership");
        assert_eq!(form_human_name("424B5"), "Prospectus");
        assert_eq!(form_human_name("DEF 14A"), "Proxy statement");
        // Unknown forms honestly produce no name (never a fabricated one).
        assert_eq!(form_human_name("XYZ-9"), "");
    }

    #[test]
    fn parse_display_name_splits_name_and_ticker() {
        assert_eq!(
            parse_display_name("Apple Inc. (AAPL) (CIK 0000320193)"),
            ("Apple Inc.".to_string(), "AAPL".to_string())
        );
        // No ticker group (a fund): name only, ticker "".
        assert_eq!(
            parse_display_name("Big Trust Fund (CIK 0001234567)"),
            ("Big Trust Fund".to_string(), String::new())
        );
    }

    #[test]
    fn archive_cik_prefers_the_accession_filer() {
        // Insider Form 4 co-filing: the archive CIK is the filer in the
        // accession, not the queried company.
        assert_eq!(archive_cik("0001214156-26-000045", 320193), 1214156);
        // Malformed accession falls back to the resolved CIK.
        assert_eq!(archive_cik("garbage", 320193), 320193);
        assert_eq!(archive_cik("", 320193), 320193);
    }
}
