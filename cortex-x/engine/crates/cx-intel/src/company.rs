//! COMPANY: merge the curated supply-chain graph with live SEC EDGAR
//! fundamentals into one `CompanyProfile`.
//!
//! EDGAR endpoints (keyless, UA identifies the client):
//!   https://www.sec.gov/files/company_tickers.json         ticker -> CIK
//!   https://data.sec.gov/api/xbrl/companyfacts/CIK{10}.json  us-gaap facts
//!
//! Both sides degrade independently: no curated entry -> honest
//! "no curated graph"; EDGAR unreachable/unknown ticker -> fundamentals
//! stay None with `fundamentals_source: "unavailable"`.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cx_core::egress::Egress;
use cx_core::error::CxError;
use cx_core::events::{CompanyProfile, Fundamentals};
use cx_core::time::now_ms;

use crate::splc_data;

const SEC_TICKERS_URL: &str = "https://www.sec.gov/files/company_tickers.json";
/// The ticker map is ~2 MB today; leave generous headroom.
const TICKER_MAP_CAP: usize = 8 * 1024 * 1024;
/// companyfacts payloads for megacaps run well past the default 4 MB cap.
const COMPANYFACTS_CAP: usize = 24 * 1024 * 1024;
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
            Ok(Some(f)) => {
                profile.fundamentals = Some(f);
                profile.fundamentals_source = "sec-edgar (10-K/10-Q)".into();
            }
            Ok(None) => profile.fundamentals_source = "unavailable (not an SEC filer)".into(),
            Err(e) => {
                tracing::warn!(symbol = %symbol, error = %e, "edgar fetch failed");
                profile.fundamentals_source = "unavailable (fetch failed)".into();
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
        graph_source: "no curated graph".into(),
        fundamentals_source: "unavailable".into(),
        ts_ms: 0,
    }
}

/// Latest annual fundamentals from EDGAR company facts.
/// `Ok(None)` when the ticker is not in the SEC map (ETFs, non-filers).
pub async fn fetch_fundamentals(
    egress: &Egress,
    symbol: &str,
) -> Result<Option<Fundamentals>, CxError> {
    let Some(cik) = cik_for(egress, symbol).await? else {
        return Ok(None);
    };
    let raw = egress
        .get_text_with_cap(&companyfacts_url(cik), COMPANYFACTS_CAP)
        .await?;
    parse_companyfacts(&raw).map(Some)
}

/// EDGAR requires the 10-digit zero-padded CIK in the path.
pub(crate) fn companyfacts_url(cik: u64) -> String {
    format!("https://data.sec.gov/api/xbrl/companyfacts/CIK{cik:010}.json")
}

/// Resolve a ticker to its CIK, refreshing the shared map at most once
/// per 24h. `Ok(None)` = ticker unknown to the SEC (honest, not an error).
async fn cik_for(egress: &Egress, symbol: &str) -> Result<Option<u64>, CxError> {
    if let Some(map) = cached_cik_map() {
        return Ok(map.get(symbol).copied());
    }
    let raw = egress.get_text_with_cap(SEC_TICKERS_URL, TICKER_MAP_CAP).await?;
    let map = Arc::new(parse_cik_map(&raw)?);
    *CIK_CACHE.lock().unwrap() = Some((Instant::now(), Arc::clone(&map)));
    Ok(map.get(symbol).copied())
}

fn cached_cik_map() -> Option<Arc<HashMap<String, u64>>> {
    let guard = CIK_CACHE.lock().unwrap();
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

/// One us-gaap tag reduced to its latest annual (10-K, fp "FY") point, plus
/// the prior fiscal year's value for YoY math.
#[derive(Debug, Clone)]
struct TagLatest {
    val: f64,
    prior: Option<f64>,
    end: String,
    fy: i64,
}

/// Extract `Fundamentals` from a companyfacts payload. Malformed JSON or a
/// payload without extractable annual us-gaap values -> Err (the caller
/// discloses "unavailable"). Every number passes the NaN firewall.
pub(crate) fn parse_companyfacts(raw: &str) -> Result<Fundamentals, CxError> {
    let v: serde_json::Value = serde_json::from_str(raw)?;
    let gaap = v
        .get("facts")
        .and_then(|f| f.get("us-gaap"))
        .and_then(|g| g.as_object())
        .ok_or_else(|| CxError::Serde("companyfacts: no us-gaap facts".into()))?;

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

    let frame = revenue
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
        .ok_or_else(|| CxError::Serde("companyfacts: no annual us-gaap values".into()))?;
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

    Ok(Fundamentals {
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
        period: "FY".into(),
        fiscal_year,
    })
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
/// latest 10-K/FY entry, and the candidate with the most recent period end
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

/// All annual (form 10-K*, fp "FY") points for one tag/unit, deduped by
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
        let form_ok = e
            .get("form")
            .and_then(|x| x.as_str())
            .is_some_and(|f| f.starts_with("10-K"));
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
        "dei": { "EntityCommonStockSharesOutstanding": { "units": { "shares": [] } } },
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
        let f = parse_companyfacts(FIXTURE).unwrap();
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
    fn companyfacts_rejects_malformed_and_missing_gaap() {
        assert!(parse_companyfacts("not json {").is_err());
        assert!(parse_companyfacts("{}").is_err());
        assert!(parse_companyfacts(r#"{"facts":{"dei":{}}}"#).is_err());
        // us-gaap present but only quarterly entries -> no annual values.
        let quarterly_only = r#"{"facts":{"us-gaap":{"Revenues":{"units":{"USD":[
            {"start":"2024-01-01","end":"2024-03-31","val":5,"fy":2024,"fp":"Q1","form":"10-Q","filed":"2024-05-01"}
        ]}}}}}"#;
        assert!(parse_companyfacts(quarterly_only).is_err());
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
        let f = parse_companyfacts(zero_latest).unwrap();
        assert_eq!(f.revenue, Some(0.0));
        assert_eq!(f.gross_margin, None);
        approx(f.revenue_yoy.unwrap(), -1.0);

        // Prior revenue 0: YoY undefined -> None, not inf/NaN.
        let zero_prior = r#"{"facts":{"us-gaap":{"Revenues":{"units":{"USD":[
            {"start":"2022-01-01","end":"2022-12-31","val":0,"fy":2022,"fp":"FY","form":"10-K","filed":"2023-02-01"},
            {"start":"2023-01-01","end":"2023-12-31","val":5,"fy":2023,"fp":"FY","form":"10-K","filed":"2024-02-01"}
        ]}}}}}"#;
        let f = parse_companyfacts(zero_prior).unwrap();
        assert_eq!(f.revenue, Some(5.0));
        assert_eq!(f.revenue_yoy, None);
    }

    #[test]
    fn eps_falls_back_to_basic() {
        let basic_only = r#"{"facts":{"us-gaap":{"EarningsPerShareBasic":{"units":{"USD/shares":[
            {"start":"2023-01-01","end":"2023-12-31","val":2.5,"fy":2023,"fp":"FY","form":"10-K","filed":"2024-02-01"}
        ]}}}}}"#;
        let f = parse_companyfacts(basic_only).unwrap();
        approx(f.eps.unwrap(), 2.5);
        assert_eq!(f.fiscal_year, "2023");
        assert_eq!(f.revenue, None);
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
