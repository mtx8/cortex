//! COMPANY: merge the curated supply-chain graph with live SEC EDGAR
//! fundamentals into one `CompanyProfile`.
//!
//! EDGAR endpoints (keyless, UA identifies the client):
//!   https://www.sec.gov/files/company_tickers.json         ticker -> CIK
//!   https://data.sec.gov/api/xbrl/companyfacts/CIK{10}.json  us-gaap facts
//!
//! Both sides degrade independently: no curated entry -> honest
//! "no curated graph"; EDGAR unreachable/unknown ticker -> fundamentals
//! stay None with `fundamentals_source: "unavailable"`; a filer whose
//! companyfacts hold no annual (10-K/20-F) values -> "no annual report
//! data in EDGAR" (data absence is not a fetch failure).

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cx_core::egress::Egress;
use cx_core::error::CxError;
use cx_core::events::{CompanyProfile, Filing, Fundamentals};
use cx_core::time::now_ms;

use crate::splc_data;

const SEC_TICKERS_URL: &str = "https://www.sec.gov/files/company_tickers.json";
/// The ticker map is ~2 MB today; leave generous headroom.
const TICKER_MAP_CAP: usize = 8 * 1024 * 1024;
/// companyfacts payloads for megacaps run well past the default 4 MB cap,
/// and money-center banks (JPM, BAC) carry the largest XBRL fact sets of
/// all — keep headroom well above their current payload sizes.
const COMPANYFACTS_CAP: usize = 48 * 1024 * 1024;
/// EDGAR submissions payloads run ~1-2 MB for the largest filers.
const SUBMISSIONS_CAP: usize = 16 * 1024 * 1024;
/// Keep the most recent dozen filings — enough to show cadence without
/// bloating the on-demand profile payload.
const MAX_FILINGS: usize = 12;
const CIK_TTL: Duration = Duration::from_secs(24 * 3600);

/// Ticker -> CIK map, parsed once and reused for 24h. The SEC file changes
/// rarely and is ~10k entries, so an in-process cache is plenty.
static CIK_CACHE: Mutex<Option<(Instant, Arc<HashMap<String, u64>>)>> = Mutex::new(None);

/// Build the full profile for `symbol`. Infallible by design: always returns
/// a profile, with source labels disclosing exactly what was available.
pub async fn fetch_company(egress: &Egress, symbol: &str) -> CompanyProfile {
    let symbol = symbol.trim().to_uppercase();
    let mut profile = splc_data::curated(&symbol).unwrap_or_else(|| minimal_profile(&symbol));

    if is_equity(&symbol) {
        match fetch_fundamentals(egress, &symbol).await {
            Ok(FundamentalsOutcome::Data(f)) => {
                profile.fundamentals = Some(f);
                profile.fundamentals_source = "sec-edgar (10-K/20-F)".into();
            }
            Ok(FundamentalsOutcome::NotAFiler) => {
                profile.fundamentals_source = "unavailable (not an SEC filer)".into();
            }
            Ok(FundamentalsOutcome::NoAnnualData) => {
                profile.fundamentals_source = "no annual report data in EDGAR".into();
            }
            Err(e) => {
                tracing::warn!(symbol = %symbol, error = %e, "edgar fetch failed");
                profile.fundamentals_source = "unavailable (fetch failed)".into();
            }
        }

        // One more egress call: the recent-filings list. Fully independent of
        // fundamentals — it degrades to empty on any failure, never panics.
        match fetch_filings(egress, &symbol).await {
            Ok(filings) if !filings.is_empty() => {
                profile.filings = filings;
                profile.filings_source = "sec-edgar submissions".into();
            }
            Ok(_) => profile.filings_source = "unavailable".into(),
            Err(e) => {
                tracing::warn!(symbol = %symbol, error = %e, "edgar submissions fetch failed");
                profile.filings_source = "unavailable (fetch failed)".into();
            }
        }
    }
    profile.ts_ms = now_ms();
    profile
}

fn is_equity(symbol: &str) -> bool {
    !symbol.contains('-')
}

/// Honest fallback card when a symbol has no curated graph entry.
fn minimal_profile(symbol: &str) -> CompanyProfile {
    let crypto = symbol.contains('-');
    CompanyProfile {
        symbol: symbol.to_string(),
        name: symbol.to_string(),
        sector: if crypto { "digital assets".into() } else { String::new() },
        industry: String::new(),
        country: String::new(),
        description: if crypto {
            "Crypto asset — supply-chain analysis does not apply.".into()
        } else {
            String::new()
        },
        segments: Vec::new(),
        suppliers: Vec::new(),
        customers: Vec::new(),
        competitors: Vec::new(),
        fundamentals: None,
        filings: Vec::new(),
        graph_source: "no curated graph".into(),
        fundamentals_source: "unavailable".into(),
        filings_source: "unavailable".into(),
        ts_ms: 0,
    }
}

/// Profile served when COMPANY intel is disabled in config: an honest,
/// instant answer instead of a request that never resolves client-side.
pub fn disabled_profile(symbol: &str) -> CompanyProfile {
    let mut p = minimal_profile(&symbol.trim().to_uppercase());
    p.description = "COMPANY intelligence is disabled (intel.enable_company = false).".into();
    p.graph_source = "disabled".into();
    p.fundamentals_source = "disabled".into();
    p.filings_source = "disabled".into();
    p.ts_ms = now_ms();
    p
}

/// Outcome of an EDGAR fundamentals lookup that completed without a fetch
/// error. Lets the caller label "no data exists" differently from "the
/// fetch failed".
#[derive(Debug)]
pub enum FundamentalsOutcome {
    /// Latest annual fundamentals extracted.
    Data(Fundamentals),
    /// Ticker is not in the SEC map (ETFs, non-filers).
    NotAFiler,
    /// companyfacts fetched fine but held no annual (10-K/20-F, FY)
    /// us-gaap values (e.g. IFRS-only filers).
    NoAnnualData,
}

/// Latest annual fundamentals from EDGAR company facts.
pub async fn fetch_fundamentals(
    egress: &Egress,
    symbol: &str,
) -> Result<FundamentalsOutcome, CxError> {
    let Some(cik) = cik_for(egress, symbol).await? else {
        return Ok(FundamentalsOutcome::NotAFiler);
    };
    let raw = egress
        .get_text_with_cap(&companyfacts_url(cik), COMPANYFACTS_CAP)
        .await?;
    Ok(match parse_companyfacts(&raw)? {
        Some(f) => FundamentalsOutcome::Data(f),
        None => FundamentalsOutcome::NoAnnualData,
    })
}

/// EDGAR requires the 10-digit zero-padded CIK in the path.
pub(crate) fn companyfacts_url(cik: u64) -> String {
    format!("https://data.sec.gov/api/xbrl/companyfacts/CIK{cik:010}.json")
}

/// Recent SEC filings (newest first, capped at [`MAX_FILINGS`]) from EDGAR
/// submissions. `Ok(Vec::new())` for non-filers or filers with no usable
/// rows; a fetch failure is an `Err` the caller labels honestly. One egress
/// call (the shared ticker map is cached from the fundamentals lookup).
pub async fn fetch_filings(egress: &Egress, symbol: &str) -> Result<Vec<Filing>, CxError> {
    let Some(cik) = cik_for(egress, symbol).await? else {
        return Ok(Vec::new());
    };
    let raw = egress
        .get_text_with_cap(&crate::news::submissions_url(cik), SUBMISSIONS_CAP)
        .await?;
    Ok(parse_submissions_filings(cik, &raw))
}

/// Build the recent-filings list from an EDGAR submissions payload. Parses the
/// parallel `recent` arrays (form / filingDate / accessionNumber /
/// primaryDocument) into archive-linked [`Filing`]s, preserving EDGAR's
/// newest-first order and capping at [`MAX_FILINGS`]. Rows missing any field,
/// carrying a malformed date, or lacking a primary document are skipped; a
/// malformed body yields an empty list. Never panics.
pub(crate) fn parse_submissions_filings(cik: u64, raw: &str) -> Vec<Filing> {
    let Ok(v) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Vec::new();
    };
    let Some(recent) = v.get("filings").and_then(|f| f.get("recent")) else {
        return Vec::new();
    };
    let (Some(forms), Some(dates), Some(accns), Some(docs)) = (
        recent.get("form").and_then(|x| x.as_array()),
        recent.get("filingDate").and_then(|x| x.as_array()),
        recent.get("accessionNumber").and_then(|x| x.as_array()),
        recent.get("primaryDocument").and_then(|x| x.as_array()),
    ) else {
        return Vec::new();
    };

    let mut out = Vec::with_capacity(MAX_FILINGS);
    for (((form, date), accn), doc) in forms.iter().zip(dates).zip(accns).zip(docs) {
        if out.len() >= MAX_FILINGS {
            break;
        }
        let (Some(form), Some(date), Some(accn), Some(doc)) =
            (form.as_str(), date.as_str(), accn.as_str(), doc.as_str())
        else {
            continue;
        };
        if form.is_empty() || accn.is_empty() || doc.is_empty() {
            continue;
        }
        // Honest date: skip rows whose filingDate isn't a real YYYY-MM-DD.
        if chrono::NaiveDate::parse_from_str(date, "%Y-%m-%d").is_err() {
            continue;
        }
        // EDGAR archive paths use the non-padded CIK and the dash-free
        // accession number, e.g. 0001045810-26-000012 -> 000104581026000012.
        let accn_no_dashes = accn.replace('-', "");
        out.push(Filing {
            form: form.to_string(),
            filed: date.to_string(),
            primary_doc_url: format!(
                "https://www.sec.gov/Archives/edgar/data/{cik}/{accn_no_dashes}/{doc}"
            ),
        });
    }
    out
}

/// Resolve a ticker to its CIK, refreshing the shared map at most once
/// per 24h. `Ok(None)` = ticker unknown to the SEC (honest, not an error).
/// `pub(crate)` so the dedicated FILINGS browser reuses the SAME cached
/// ticker map (`symbol` must already be trimmed/uppercased).
pub(crate) async fn cik_for(egress: &Egress, symbol: &str) -> Result<Option<u64>, CxError> {
    if let Some(map) = cached_cik_map() {
        return Ok(map.get(symbol).copied());
    }
    let raw = egress.get_text_with_cap(SEC_TICKERS_URL, TICKER_MAP_CAP).await?;
    let map = Arc::new(parse_cik_map(&raw)?);
    *CIK_CACHE.lock().unwrap_or_else(|p| p.into_inner()) =
        Some((Instant::now(), Arc::clone(&map)));
    Ok(map.get(symbol).copied())
}

fn cached_cik_map() -> Option<Arc<HashMap<String, u64>>> {
    let guard = CIK_CACHE.lock().unwrap_or_else(|p| p.into_inner());
    guard
        .as_ref()
        .and_then(|(at, map)| (at.elapsed() < CIK_TTL).then(|| Arc::clone(map)))
}

/// Parse the SEC ticker map: `{"0": {"cik_str": 320193, "ticker": "AAPL",
/// "title": "Apple Inc."}, ...}`. Malformed payloads are an Err, never a
/// panic; individual bad rows are skipped.
pub(crate) fn parse_cik_map(raw: &str) -> Result<HashMap<String, u64>, CxError> {
    let v: serde_json::Value = serde_json::from_str(raw)?;
    let obj = v
        .as_object()
        .ok_or_else(|| CxError::Serde("sec ticker map: not a json object".into()))?;
    let mut map = HashMap::with_capacity(obj.len());
    for entry in obj.values() {
        let (Some(ticker), Some(cik)) = (
            entry.get("ticker").and_then(|t| t.as_str()),
            entry.get("cik_str").and_then(|c| c.as_u64()),
        ) else {
            continue;
        };
        map.insert(ticker.to_uppercase(), cik);
    }
    if map.is_empty() {
        return Err(CxError::Serde("sec ticker map: no usable entries".into()));
    }
    Ok(map)
}

/// One us-gaap tag reduced to its latest annual (10-K/20-F, fp "FY") point,
/// plus the prior fiscal year's value for YoY math.
#[derive(Debug, Clone)]
struct TagLatest {
    val: f64,
    prior: Option<f64>,
    end: String,
    fy: i64,
}

/// Extract `Fundamentals` from a companyfacts payload. Malformed JSON ->
/// Err; a well-formed payload without extractable annual us-gaap values ->
/// `Ok(None)` (the caller discloses "no annual report data", not a fetch
/// failure). Every number passes the NaN firewall.
pub(crate) fn parse_companyfacts(raw: &str) -> Result<Option<Fundamentals>, CxError> {
    let v: serde_json::Value = serde_json::from_str(raw)?;
    let Some(gaap) = v
        .get("facts")
        .and_then(|f| f.get("us-gaap"))
        .and_then(|g| g.as_object())
    else {
        return Ok(None);
    };

    // Revenues predates ASC 606 and often goes stale after 2018, while the
    // contract-revenue tag is current — so among the fallbacks we keep the
    // one with the most recent period end, not merely the first present.
    let revenue = latest_with_fallback(
        gaap,
        &["Revenues", "RevenueFromContractWithCustomerExcludingAssessedTax"],
        "USD",
    );
    let gross = latest_with_fallback(gaap, &["GrossProfit"], "USD");
    let op = latest_with_fallback(gaap, &["OperatingIncomeLoss"], "USD");
    let net = latest_with_fallback(gaap, &["NetIncomeLoss"], "USD");
    let assets = latest_with_fallback(gaap, &["Assets"], "USD");
    let liabilities = latest_with_fallback(gaap, &["Liabilities"], "USD");
    let equity = latest_with_fallback(gaap, &["StockholdersEquity"], "USD");
    let eps = latest_with_fallback(
        gaap,
        &["EarningsPerShareDiluted", "EarningsPerShareBasic"],
        "USD/shares",
    );
    let cash = latest_with_fallback(gaap, &["CashAndCashEquivalentsAtCarryingValue"], "USD");
    let ocf = latest_with_fallback(gaap, &["NetCashProvidedByUsedInOperatingActivities"], "USD");

    let Some(frame) = revenue
        .as_ref()
        .or(net.as_ref())
        .or(assets.as_ref())
        .or(op.as_ref())
        .or(gross.as_ref())
        .or(equity.as_ref())
        .or(liabilities.as_ref())
        .or(eps.as_ref())
        .or(cash.as_ref())
        .or(ocf.as_ref())
    else {
        return Ok(None);
    };
    let fiscal_year = if frame.fy > 0 {
        frame.fy.to_string()
    } else {
        frame.end.get(..4).unwrap_or_default().to_string()
    };

    let rev_val = revenue.as_ref().and_then(|r| fin(r.val));
    let revenue_yoy = revenue
        .as_ref()
        .and_then(|r| r.prior.filter(|p| *p != 0.0).map(|p| (r.val - p) / p.abs()))
        .and_then(fin);
    let val = |t: &Option<TagLatest>| t.as_ref().and_then(|x| fin(x.val));

    // dei cover-page facts live under facts["dei"] alongside us-gaap: the
    // latest common shares outstanding (a share COUNT) and public float
    // (a USD DOLLAR amount, not shares). Both degrade to None independently.
    let dei = v.get("facts").and_then(|f| f.get("dei")).and_then(|d| d.as_object());
    let shares_outstanding =
        dei.and_then(|d| latest_dei(d, "EntityCommonStockSharesOutstanding", "shares"));
    let public_float_usd = dei.and_then(|d| latest_dei(d, "EntityPublicFloat", "USD"));

    Ok(Some(Fundamentals {
        revenue: rev_val,
        revenue_yoy,
        gross_margin: ratio(val(&gross), rev_val),
        op_margin: ratio(val(&op), rev_val),
        net_income: val(&net),
        net_margin: ratio(val(&net), rev_val),
        eps: val(&eps),
        assets: val(&assets),
        liabilities: val(&liabilities),
        equity: val(&equity),
        ocf: val(&ocf),
        cash: val(&cash),
        shares_outstanding,
        public_float_usd,
        // Short interest is a separate FINRA (Rule 4560) integration, not EDGAR —
        // left None here; a dedicated bi-monthly fetch populates it later.
        short_interest: None,
        short_interest_date: None,
        avg_daily_volume: None,
        period: "FY".into(),
        fiscal_year,
    }))
}

/// NaN firewall: finite or None. Every value that reaches a profile goes
/// through here (directly or via [`ratio`]).
fn fin(x: f64) -> Option<f64> {
    x.is_finite().then_some(x)
}

/// Divide with both a zero-denominator guard and the NaN firewall.
fn ratio(num: Option<f64>, den: Option<f64>) -> Option<f64> {
    match (num, den) {
        (Some(n), Some(d)) if d != 0.0 => fin(n / d),
        _ => None,
    }
}

/// Best annual point across a fallback list of tags: each tag reduces to its
/// latest annual FY entry, and the candidate with the most recent period end
/// wins (guards against stale legacy tags shadowing current ones).
fn latest_with_fallback(
    gaap: &serde_json::Map<String, serde_json::Value>,
    tags: &[&str],
    unit: &str,
) -> Option<TagLatest> {
    tags.iter()
        .filter_map(|tag| latest_annual(gaap, tag, unit))
        .max_by(|a, b| a.end.cmp(&b.end))
}

fn latest_annual(
    gaap: &serde_json::Map<String, serde_json::Value>,
    tag: &str,
    unit: &str,
) -> Option<TagLatest> {
    let pts = annual_points(gaap, tag, unit);
    let (end, fy, val) = pts.last()?.clone();
    let prior = (pts.len() >= 2).then(|| pts[pts.len() - 2].2);
    Some(TagLatest { val, prior, end, fy })
}

/// All annual (form 10-K*/20-F*, fp "FY") points for one tag/unit, deduped by
/// period end (comparative re-reports overwrite in filing order) and sorted
/// ascending by end date — ISO dates order correctly as strings.
fn annual_points(
    gaap: &serde_json::Map<String, serde_json::Value>,
    tag: &str,
    unit: &str,
) -> Vec<(String, i64, f64)> {
    let Some(entries) = gaap
        .get(tag)
        .and_then(|t| t.get("units"))
        .and_then(|u| u.get(unit))
        .and_then(|a| a.as_array())
    else {
        return Vec::new();
    };
    let mut by_end: BTreeMap<String, (i64, f64)> = BTreeMap::new();
    for e in entries {
        // Annual reports: 10-K (domestic) or 20-F (foreign private issuers
        // like TSM/ASML — excluding them mislabeled real filers as absent).
        let form_ok = e
            .get("form")
            .and_then(|x| x.as_str())
            .is_some_and(|f| f.starts_with("10-K") || f.starts_with("20-F"));
        let fp_ok = e.get("fp").and_then(|x| x.as_str()) == Some("FY");
        if !(form_ok && fp_ok) {
            continue;
        }
        let Some(end) = e.get("end").and_then(|x| x.as_str()) else { continue };
        let Some(val) = e.get("val").and_then(|x| x.as_f64()).filter(|v| v.is_finite()) else {
            continue;
        };
        let fy = e.get("fy").and_then(|x| x.as_i64()).unwrap_or(0);
        by_end.insert(end.to_string(), (fy, val));
    }
    by_end.into_iter().map(|(end, (fy, val))| (end, fy, val)).collect()
}

/// Latest value for one dei tag/unit, chosen by most-recent period `end`.
/// dei cover-page facts (shares outstanding, public float) appear across
/// 10-K and 10-Q filings; we take the freshest by end date (ISO dates order
/// correctly as strings). Non-finite values are skipped (NaN firewall); None
/// when the tag/unit is absent or holds no usable entry.
fn latest_dei(
    dei: &serde_json::Map<String, serde_json::Value>,
    tag: &str,
    unit: &str,
) -> Option<f64> {
    let entries = dei
        .get(tag)
        .and_then(|t| t.get("units"))
        .and_then(|u| u.get(unit))
        .and_then(|a| a.as_array())?;
    let mut best_end = String::new();
    let mut best_val: Option<f64> = None;
    for e in entries {
        let Some(end) = e.get("end").and_then(|x| x.as_str()) else { continue };
        let Some(val) = e.get("val").and_then(|x| x.as_f64()).filter(|v| v.is_finite()) else {
            continue;
        };
        if best_val.is_none() || end > best_end.as_str() {
            best_end = end.to_string();
            best_val = Some(val);
        }
    }
    best_val
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Trimmed but shape-faithful companyfacts payload (AAPL-like numbers):
    /// two FY frames for revenue (YoY), 10-Q and non-USD entries that must
    /// be ignored, and one instant-style balance-sheet tag per line item.
    const FIXTURE: &str = r#"{
      "cik": 320193,
      "entityName": "APPLE INC",
      "facts": {
        "dei": {
          "EntityCommonStockSharesOutstanding": { "units": { "shares": [
            {"end":"2024-01-19","val":14700000000,"fy":2024,"fp":"Q1","form":"10-Q","filed":"2024-02-01"},
            {"end":"2024-10-18","val":15115823000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}},
          "EntityPublicFloat": { "units": { "USD": [
            {"end":"2024-03-29","val":2600000000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}}
        },
        "us-gaap": {
          "RevenueFromContractWithCustomerExcludingAssessedTax": { "units": { "USD": [
            {"start":"2022-09-25","end":"2023-09-30","val":383285000000,"fy":2023,"fp":"FY","form":"10-K","filed":"2023-11-03","frame":"CY2023"},
            {"start":"2022-09-25","end":"2023-09-30","val":383285000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"},
            {"start":"2023-10-01","end":"2024-09-28","val":391035000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01","frame":"CY2024"},
            {"start":"2024-06-30","end":"2024-09-28","val":94930000000,"fy":2025,"fp":"Q1","form":"10-Q","filed":"2025-01-31"}
          ], "EUR": [
            {"start":"2023-10-01","end":"2024-09-28","val":999,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}},
          "NetIncomeLoss": { "units": { "USD": [
            {"start":"2022-09-25","end":"2023-09-30","val":96995000000,"fy":2023,"fp":"FY","form":"10-K","filed":"2023-11-03"},
            {"start":"2023-10-01","end":"2024-09-28","val":93736000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}},
          "GrossProfit": { "units": { "USD": [
            {"start":"2023-10-01","end":"2024-09-28","val":180683000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}},
          "OperatingIncomeLoss": { "units": { "USD": [
            {"start":"2023-10-01","end":"2024-09-28","val":123216000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}},
          "Assets": { "units": { "USD": [
            {"end":"2023-09-30","val":352583000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"},
            {"end":"2024-09-28","val":364980000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}},
          "Liabilities": { "units": { "USD": [
            {"end":"2024-09-28","val":308030000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}},
          "StockholdersEquity": { "units": { "USD": [
            {"end":"2024-09-28","val":56950000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}},
          "EarningsPerShareDiluted": { "units": { "USD/shares": [
            {"start":"2023-10-01","end":"2024-09-28","val":6.08,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}},
          "CashAndCashEquivalentsAtCarryingValue": { "units": { "USD": [
            {"end":"2024-09-28","val":29943000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}},
          "NetCashProvidedByUsedInOperatingActivities": { "units": { "USD": [
            {"start":"2023-10-01","end":"2024-09-28","val":118254000000,"fy":2024,"fp":"FY","form":"10-K","filed":"2024-11-01"}
          ]}}
        }
      }
    }"#;

    fn approx(a: f64, b: f64) {
        assert!((a - b).abs() < 1e-9, "{a} != {b}");
    }

    #[test]
    fn companyfacts_fixture_extracts_latest_fy() {
        let f = parse_companyfacts(FIXTURE).unwrap().unwrap();
        approx(f.revenue.unwrap(), 391_035_000_000.0);
        approx(
            f.revenue_yoy.unwrap(),
            (391_035_000_000.0 - 383_285_000_000.0) / 383_285_000_000.0,
        );
        approx(f.gross_margin.unwrap(), 180_683_000_000.0 / 391_035_000_000.0);
        approx(f.op_margin.unwrap(), 123_216_000_000.0 / 391_035_000_000.0);
        approx(f.net_margin.unwrap(), 93_736_000_000.0 / 391_035_000_000.0);
        approx(f.net_income.unwrap(), 93_736_000_000.0);
        approx(f.eps.unwrap(), 6.08);
        // Latest instant (2024) beats the comparative 2023 balance.
        approx(f.assets.unwrap(), 364_980_000_000.0);
        approx(f.liabilities.unwrap(), 308_030_000_000.0);
        approx(f.equity.unwrap(), 56_950_000_000.0);
        approx(f.cash.unwrap(), 29_943_000_000.0);
        approx(f.ocf.unwrap(), 118_254_000_000.0);
        // dei: latest shares outstanding by end-date (2024-10-18 beats the
        // Q1 cover), and public float as a USD DOLLAR amount (not shares).
        approx(f.shares_outstanding.unwrap(), 15_115_823_000.0);
        approx(f.public_float_usd.unwrap(), 2_600_000_000_000.0);
        assert_eq!(f.period, "FY");
        assert_eq!(f.fiscal_year, "2024");
        // NaN firewall: everything extracted is finite.
        for v in [
            f.revenue, f.revenue_yoy, f.gross_margin, f.op_margin, f.net_income,
            f.net_margin, f.eps, f.assets, f.liabilities, f.equity, f.ocf, f.cash,
        ] {
            assert!(v.is_some_and(f64::is_finite));
        }
    }

    #[test]
    fn companyfacts_distinguishes_malformed_from_no_annual_data() {
        // Malformed JSON is a genuine error.
        assert!(parse_companyfacts("not json {").is_err());
        // Well-formed payloads without annual us-gaap values are Ok(None) —
        // "no annual report data", not a fetch failure.
        assert_eq!(parse_companyfacts("{}").unwrap(), None);
        assert_eq!(parse_companyfacts(r#"{"facts":{"dei":{}}}"#).unwrap(), None);
        // us-gaap present but only quarterly entries -> no annual values.
        let quarterly_only = r#"{"facts":{"us-gaap":{"Revenues":{"units":{"USD":[
            {"start":"2024-01-01","end":"2024-03-31","val":5,"fy":2024,"fp":"Q1","form":"10-Q","filed":"2024-05-01"}
        ]}}}}}"#;
        assert_eq!(parse_companyfacts(quarterly_only).unwrap(), None);
    }

    #[test]
    fn twenty_f_annual_reports_are_accepted() {
        // Foreign private issuers (TSM, ASML) file 20-F, not 10-K.
        let twenty_f = r#"{"facts":{"us-gaap":{"Revenues":{"units":{"USD":[
            {"start":"2023-01-01","end":"2023-12-31","val":70000000000,"fy":2023,"fp":"FY","form":"20-F","filed":"2024-04-15"},
            {"start":"2024-01-01","end":"2024-12-31","val":90000000000,"fy":2024,"fp":"FY","form":"20-F/A","filed":"2025-04-18"}
        ]}}}}}"#;
        let f = parse_companyfacts(twenty_f).unwrap().unwrap();
        approx(f.revenue.unwrap(), 90_000_000_000.0);
        approx(f.revenue_yoy.unwrap(), 2.0 / 7.0);
        assert_eq!(f.fiscal_year, "2024");
    }

    #[test]
    fn zero_denominators_guard_margins_and_yoy() {
        // Latest revenue 0 with a nonzero prior: margins None, yoy = -1.
        let zero_latest = r#"{"facts":{"us-gaap":{
            "Revenues":{"units":{"USD":[
                {"start":"2022-01-01","end":"2022-12-31","val":10,"fy":2022,"fp":"FY","form":"10-K","filed":"2023-02-01"},
                {"start":"2023-01-01","end":"2023-12-31","val":0,"fy":2023,"fp":"FY","form":"10-K","filed":"2024-02-01"}
            ]}},
            "GrossProfit":{"units":{"USD":[
                {"start":"2023-01-01","end":"2023-12-31","val":3,"fy":2023,"fp":"FY","form":"10-K","filed":"2024-02-01"}
            ]}}
        }}}"#;
        let f = parse_companyfacts(zero_latest).unwrap().unwrap();
        assert_eq!(f.revenue, Some(0.0));
        assert_eq!(f.gross_margin, None);
        approx(f.revenue_yoy.unwrap(), -1.0);

        // Prior revenue 0: YoY undefined -> None, not inf/NaN.
        let zero_prior = r#"{"facts":{"us-gaap":{"Revenues":{"units":{"USD":[
            {"start":"2022-01-01","end":"2022-12-31","val":0,"fy":2022,"fp":"FY","form":"10-K","filed":"2023-02-01"},
            {"start":"2023-01-01","end":"2023-12-31","val":5,"fy":2023,"fp":"FY","form":"10-K","filed":"2024-02-01"}
        ]}}}}}"#;
        let f = parse_companyfacts(zero_prior).unwrap().unwrap();
        assert_eq!(f.revenue, Some(5.0));
        assert_eq!(f.revenue_yoy, None);
    }

    #[test]
    fn eps_falls_back_to_basic() {
        let basic_only = r#"{"facts":{"us-gaap":{"EarningsPerShareBasic":{"units":{"USD/shares":[
            {"start":"2023-01-01","end":"2023-12-31","val":2.5,"fy":2023,"fp":"FY","form":"10-K","filed":"2024-02-01"}
        ]}}}}}"#;
        let f = parse_companyfacts(basic_only).unwrap().unwrap();
        approx(f.eps.unwrap(), 2.5);
        assert_eq!(f.fiscal_year, "2023");
        assert_eq!(f.revenue, None);
    }

    #[test]
    fn dei_latest_by_end_date_and_dollar_float_degrade_cleanly() {
        let facts: serde_json::Value = serde_json::from_str(
            r#"{
                "EntityCommonStockSharesOutstanding": { "units": { "shares": [
                    {"end":"2023-10-20","val":100},
                    {"end":"2024-10-18","val":200},
                    {"end":"2024-01-05","val":150}
                ]}},
                "EntityPublicFloat": { "units": { "USD": [
                    {"end":"2024-03-29","val":2600000000000}
                ]}}
            }"#,
        )
        .unwrap();
        let dei = facts.as_object().unwrap();
        // Latest period end wins regardless of array order; the float is a
        // USD dollar amount, honestly a $ value (not a share count).
        assert_eq!(
            latest_dei(dei, "EntityCommonStockSharesOutstanding", "shares"),
            Some(200.0)
        );
        assert_eq!(latest_dei(dei, "EntityPublicFloat", "USD"), Some(2_600_000_000_000.0));
        // Absent tag / wrong unit -> None.
        assert_eq!(latest_dei(dei, "NoSuchTag", "shares"), None);
        assert_eq!(latest_dei(dei, "EntityPublicFloat", "shares"), None);
        // Entries lacking `end` or a finite `val` are skipped -> None.
        let junk: serde_json::Value = serde_json::from_str(
            r#"{"T":{"units":{"shares":[{"end":"2024-01-01"},{"val":5},{"end":"2024-02-01","val":"x"}]}}}"#,
        )
        .unwrap();
        assert_eq!(latest_dei(junk.as_object().unwrap(), "T", "shares"), None);
    }

    /// Shape-faithful EDGAR submissions payload: parallel `recent` arrays,
    /// newest first, with rows that must be skipped (empty primary doc, bad
    /// filing date).
    const SUBMISSIONS_FILINGS_FIXTURE: &str = r#"{
      "cik": 1045810,
      "name": "NVIDIA CORP",
      "filings": { "recent": {
        "form":            ["10-K",                 "8-K",                  "10-Q",                 "4",                    "S-1"],
        "filingDate":      ["2026-02-26",           "2026-02-01",           "not-a-date",           "2026-01-15",           "2025-12-01"],
        "accessionNumber": ["0001045810-26-000012", "0001045810-26-000009", "0001045810-26-000005", "0001045810-26-000003", "0001045810-25-000200"],
        "primaryDocument": ["nvda-20260126.htm",    "",                     "nvda-q.htm",           "xslF345/form4.xml",    "s1.htm"]
      }}
    }"#;

    #[test]
    fn submissions_fixture_builds_filings_with_urls_dates_and_skips() {
        let filings = parse_submissions_filings(1045810, SUBMISSIONS_FILINGS_FIXTURE);
        // 8-K (empty primary doc) and the 10-Q (bad date) are skipped; the
        // 10-K, form 4, and S-1 survive, newest first.
        assert_eq!(filings.len(), 3);
        assert_eq!(filings[0].form, "10-K");
        assert_eq!(filings[0].filed, "2026-02-26");
        // Archive URL: non-padded CIK, dash-free accession, primary document.
        assert_eq!(
            filings[0].primary_doc_url,
            "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000012/nvda-20260126.htm"
        );
        assert_eq!(filings[1].form, "4");
        assert_eq!(
            filings[1].primary_doc_url,
            "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000003/xslF345/form4.xml"
        );
        assert_eq!(filings[2].form, "S-1");
        // Every surviving row carries a real date and a resolvable doc URL.
        assert!(filings.iter().all(|f| f.filed.len() == 10 && !f.primary_doc_url.ends_with('/')));

        // Malformed / empty / partial bodies degrade to an empty list.
        assert!(parse_submissions_filings(320193, "junk").is_empty());
        assert!(parse_submissions_filings(320193, "{}").is_empty());
        assert!(parse_submissions_filings(320193, r#"{"filings":{"recent":{}}}"#).is_empty());
    }

    #[test]
    fn filings_list_is_capped_at_twelve_newest_first() {
        // 15 valid rows (newest first): only the latest MAX_FILINGS survive.
        let n = 15usize;
        let forms: Vec<String> = (0..n).map(|_| "10-Q".to_string()).collect();
        let dates: Vec<String> = (0..n).map(|i| format!("2026-{:02}-01", (i % 12) + 1)).collect();
        let accns: Vec<String> = (0..n).map(|i| format!("0001045810-26-{i:06}")).collect();
        let docs: Vec<String> = (0..n).map(|i| format!("doc{i}.htm")).collect();
        let body = serde_json::json!({
            "filings": { "recent": {
                "form": forms, "filingDate": dates,
                "accessionNumber": accns, "primaryDocument": docs
            }}
        })
        .to_string();
        let filings = parse_submissions_filings(1045810, &body);
        assert_eq!(filings.len(), MAX_FILINGS);
        // The first array row (newest) is kept and correctly linked.
        assert_eq!(
            filings[0].primary_doc_url,
            "https://www.sec.gov/Archives/edgar/data/1045810/000104581026000000/doc0.htm"
        );
    }

    #[test]
    fn cik_url_zero_pads_to_ten_digits() {
        assert_eq!(
            companyfacts_url(320193),
            "https://data.sec.gov/api/xbrl/companyfacts/CIK0000320193.json"
        );
        assert_eq!(
            companyfacts_url(1045810),
            "https://data.sec.gov/api/xbrl/companyfacts/CIK0001045810.json"
        );
    }

    #[test]
    fn cik_map_parses_and_rejects_garbage() {
        let raw = r#"{
            "0": {"cik_str": 320193, "ticker": "AAPL", "title": "Apple Inc."},
            "1": {"cik_str": 1045810, "ticker": "nvda", "title": "NVIDIA CORP"},
            "2": {"broken": true}
        }"#;
        let map = parse_cik_map(raw).unwrap();
        assert_eq!(map.get("AAPL"), Some(&320193));
        assert_eq!(map.get("NVDA"), Some(&1045810)); // uppercased
        assert_eq!(map.len(), 2);
        assert!(parse_cik_map("[]").is_err());
        assert!(parse_cik_map("{ nope").is_err());
        assert!(parse_cik_map(r#"{"0":{"broken":true}}"#).is_err());
    }
}
