//! FINRA consolidated bi-monthly SHORT INTEREST (Rule 4560) — the authoritative,
//! KEYLESS source for shares-sold-short per symbol. One public CSV per settlement
//! date on cdn.finra.org (all exchange-listed since ~2021); no token, no OAuth,
//! no login. We probe the newest available file into an in-memory snapshot and
//! enrich the scanner rows + company profile from it. Short % of float is
//! computed downstream in the Swift client as `current / float_shares`, where
//! `float_shares` is ESTIMATED as `public_float_usd ÷ last_price` — EDGAR
//! supplies only the DOLLAR float (`dei:EntityPublicFloat`) and shares
//! outstanding, never a float-share COUNT — so the client honesty-gates the
//! result (floatPct ≤ ~1.02) and marks it approximate. The engine only supplies
//! the honest short-position shares + settlement date, or nothing (UI "—").
//!
//! Yahoo Finance and Scanz are NOT used: both merely redistribute THIS FINRA
//! number, Yahoo behind a ToS-violating cookie/crumb scrape and Scanz behind a
//! paid GUI with no API — so they add legal risk with zero data advantage.
//!
//! File: `https://cdn.finra.org/equity/otcmarket/biweekly/shrt{YYYYMMDD}.csv`
//! Pipe-delimited, one header row. Columns (verified live 2026-07):
//!   accountingYearMonthNumber|symbolCode|issueName|issuerServicesGroupExchangeCode|
//!   marketClassCode|currentShortPositionQuantity|previousShortPositionQuantity|
//!   stockSplitFlag|averageDailyVolumeQuantity|daysToCoverQuantity|revisionFlag|
//!   changePercent|changePreviousNumber|settlementDate
//! Do NOT confuse with the daily short-VOLUME file (regsho/daily) — a different
//! metric FINRA explicitly warns not to relabel as short interest.

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use chrono::{Datelike, Duration, NaiveDate, Weekday};

use cx_core::egress::Egress;
use cx_core::error::CxError;

const BASE_URL: &str = "https://cdn.finra.org/equity/otcmarket/biweekly/";
/// The live file is ~2 MB; 16 MB is generous headroom that still bounds egress.
const CAP: usize = 16 * 1024 * 1024;
/// Bi-monthly data — a few probes a day is plenty to catch a fresh release.
const REFRESH_SECS: u64 = 6 * 60 * 60;
/// Dissemination lags settlement by ~8 business days and there are two
/// settlements per month, so a 45-day window always contains a published file.
const LOOKBACK_DAYS: i64 = 45;

/// One symbol's reading from the bi-monthly consolidated file.
#[derive(Clone, Debug, PartialEq)]
pub struct ShortInterest {
    /// `currentShortPositionQuantity` — shares sold short as of settlement.
    pub current: f64,
    /// `previousShortPositionQuantity` — the prior settlement's figure.
    pub previous: Option<f64>,
    /// `averageDailyVolumeQuantity` — FINRA's ADV behind days-to-cover.
    pub avg_daily_volume: Option<f64>,
    /// `daysToCoverQuantity` — current / ADV, as FINRA computes it.
    pub days_to_cover: Option<f64>,
    /// `settlementDate` (ISO yyyy-mm-dd) — the honest as-of for the reading.
    pub settlement_date: String,
}

/// A parsed file: every symbol's reading plus the file's settlement date.
#[derive(Clone, Debug, Default)]
pub struct Snapshot {
    pub by_symbol: HashMap<String, ShortInterest>,
    pub settlement_date: String,
}

/// Shared, refreshable short-interest cache. The refresh task owns writes; the
/// scanner and company readers clone the small per-symbol struct out. A failed
/// refresh leaves the last good snapshot untouched.
#[derive(Default)]
pub struct ShortInterestStore {
    inner: RwLock<Snapshot>,
}

impl ShortInterestStore {
    pub fn new() -> Self {
        Self::default()
    }

    /// The reading for `symbol`, if the current snapshot has one.
    pub fn get(&self, symbol: &str) -> Option<ShortInterest> {
        self.inner.read().ok()?.by_symbol.get(symbol).cloned()
    }

    /// The settlement date of the loaded file (for freshness disclosure).
    pub fn settlement_date(&self) -> Option<String> {
        let s = self.inner.read().ok()?;
        (!s.settlement_date.is_empty()).then(|| s.settlement_date.clone())
    }

    /// Swap in a freshly fetched snapshot.
    pub fn replace(&self, snap: Snapshot) {
        if let Ok(mut w) = self.inner.write() {
            *w = snap;
        }
    }

    pub fn len(&self) -> usize {
        self.inner.read().map(|s| s.by_symbol.len()).unwrap_or(0)
    }

    pub fn is_empty(&self) -> bool {
        self.len() == 0
    }
}

/// Parse the pipe-delimited consolidated file into a snapshot. Header-driven:
/// columns are resolved BY NAME so a reordered file still parses; a file whose
/// schema lacks the two required columns yields an empty snapshot (better empty
/// than wrong). Rows with a blank symbol or unparseable current position are
/// skipped rather than fabricated.
pub fn parse_consolidated(raw: &str) -> Snapshot {
    let mut lines = raw.lines();
    let Some(header) = lines.next() else {
        return Snapshot::default();
    };
    let cols: HashMap<&str, usize> = header
        .split('|')
        .enumerate()
        .map(|(i, name)| (name.trim(), i))
        .collect();
    let idx = |name: &str| cols.get(name).copied();
    let (Some(i_sym), Some(i_cur)) = (idx("symbolCode"), idx("currentShortPositionQuantity"))
    else {
        return Snapshot::default();
    };
    let i_prev = idx("previousShortPositionQuantity");
    let i_adv = idx("averageDailyVolumeQuantity");
    let i_dtc = idx("daysToCoverQuantity");
    let i_date = idx("settlementDate");

    // Every field we extract (short position, prior, ADV, days-to-cover) is a
    // non-negative quantity — a negative is corrupt data, so drop it to None
    // rather than surface a nonsensical negative short interest.
    let num = |parts: &[&str], i: Option<usize>| -> Option<f64> {
        let v = parts.get(i?)?.trim();
        if v.is_empty() {
            return None;
        }
        v.parse::<f64>().ok().filter(|x| x.is_finite() && *x >= 0.0)
    };

    let mut by_symbol = HashMap::new();
    let mut settlement_date = String::new();
    for line in lines {
        if line.trim().is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split('|').collect();
        let Some(sym) = parts.get(i_sym).map(|s| s.trim()).filter(|s| !s.is_empty()) else {
            continue;
        };
        let Some(current) = num(&parts, Some(i_cur)) else {
            continue;
        };
        let date = i_date
            .and_then(|i| parts.get(i))
            .map(|s| s.trim().to_string())
            .unwrap_or_default();
        if settlement_date.is_empty() && !date.is_empty() {
            settlement_date = date.clone();
        }
        by_symbol.insert(
            sym.to_string(),
            ShortInterest {
                current,
                previous: num(&parts, i_prev),
                avg_daily_volume: num(&parts, i_adv),
                days_to_cover: num(&parts, i_dtc),
                settlement_date: date,
            },
        );
    }
    Snapshot {
        by_symbol,
        settlement_date,
    }
}

/// The CDN URL for a given settlement date's file.
fn url_for(d: NaiveDate) -> String {
    format!("{BASE_URL}shrt{:04}{:02}{:02}.csv", d.year(), d.month(), d.day())
}

/// Step back to the nearest weekday. FINRA settlement dates fall on business
/// days; holidays aren't modeled here — the -1-day fallbacks in
/// [`candidate_dates`] absorb those.
fn to_business_day(mut d: NaiveDate) -> NaiveDate {
    while matches!(d.weekday(), Weekday::Sat | Weekday::Sun) {
        d -= Duration::days(1);
    }
    d
}

fn last_day_of_month(y: i32, m: u32) -> NaiveDate {
    let (ny, nm) = if m == 12 { (y + 1, 1) } else { (y, m + 1) };
    NaiveDate::from_ymd_opt(ny, nm, 1).unwrap() - Duration::days(1)
}

/// The 1st of the month `months` before `d` (calendar arithmetic, no overflow).
fn month_anchor_back(d: NaiveDate, months: u32) -> NaiveDate {
    let mut y = d.year();
    let mut m = d.month() as i32 - months as i32;
    while m < 1 {
        m += 12;
        y -= 1;
    }
    NaiveDate::from_ymd_opt(y, m as u32, 1).unwrap()
}

/// Newest-first settlement-date candidates within the last [`LOOKBACK_DAYS`].
/// For each of the last three months we take the business day on/before the
/// 15th and the last business day of the month, each with a -1-day holiday
/// fallback, then keep only dates in `[today-LOOKBACK, today]`, deduped and
/// sorted newest first.
pub fn candidate_dates(today: NaiveDate) -> Vec<NaiveDate> {
    let mut out: Vec<NaiveDate> = Vec::new();
    for back in 0..3 {
        let anchor = month_anchor_back(today, back);
        let (y, m) = (anchor.year(), anchor.month());
        if let Some(mid) = NaiveDate::from_ymd_opt(y, m, 15) {
            let b = to_business_day(mid);
            out.push(b);
            out.push(b - Duration::days(1));
        }
        let b = to_business_day(last_day_of_month(y, m));
        out.push(b);
        out.push(b - Duration::days(1));
    }
    let lo = today - Duration::days(LOOKBACK_DAYS);
    out.retain(|d| *d <= today && *d >= lo);
    out.sort_unstable();
    out.dedup();
    out.reverse();
    out
}

/// Fetch the newest available consolidated file, probing candidate settlement
/// dates newest-first and returning the first that resolves to a non-empty
/// parse. Returns the last fetch error if none resolved (caller keeps prior
/// data / shows "—").
pub async fn fetch_latest(egress: &Egress, today: NaiveDate) -> Result<Snapshot, CxError> {
    // Candidates are newest-first; keep the FIRST (newest) failure so a total
    // miss reports the most relevant error, not the oldest candidate's.
    let mut first_err: Option<CxError> = None;
    for d in candidate_dates(today) {
        match egress.get_text_with_cap(&url_for(d), CAP).await {
            Ok(raw) => {
                let snap = parse_consolidated(&raw);
                if !snap.by_symbol.is_empty() {
                    return Ok(snap);
                }
            }
            Err(e) => {
                if first_err.is_none() {
                    first_err = Some(e);
                }
            }
        }
    }
    Err(first_err
        .unwrap_or_else(|| CxError::EgressFailed("cdn.finra.org: no candidate file resolved".into())))
}

fn today_utc() -> NaiveDate {
    chrono::Utc::now().date_naive()
}

/// Whether an incoming snapshot's settlement date is fresh enough to replace the
/// held one. Accepts when nothing is held, when the incoming date is unknown
/// (can't prove it's stale), or when it is >= the held date. Settlement dates are
/// ISO `yyyy-mm-dd`, so lexicographic order == chronological order.
fn accepts(held: Option<&str>, incoming: &str) -> bool {
    match held {
        Some(h) if !h.is_empty() && !incoming.is_empty() => incoming >= h,
        _ => true,
    }
}

/// Spawn the background refresh: fetch the newest file now, then every
/// [`REFRESH_SECS`]. A failed fetch leaves the last good snapshot in place; a
/// cold miss simply leaves the cache empty and the UI shows "—".
pub fn spawn_refresh(store: Arc<ShortInterestStore>) {
    tokio::spawn(async move {
        let egress = Egress::new();
        let mut iv = tokio::time::interval(std::time::Duration::from_secs(REFRESH_SECS));
        iv.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            iv.tick().await;
            match fetch_latest(&egress, today_utc()).await {
                Ok(snap) => {
                    // Monotonic guard: a transient failure on the newest file
                    // can let `fetch_latest` succeed on an OLDER candidate, so
                    // only accept a snapshot at least as fresh as the one held.
                    let regressed = !accepts(store.settlement_date().as_deref(), &snap.settlement_date);
                    if regressed {
                        tracing::warn!(
                            fetched = %snap.settlement_date,
                            held = %store.settlement_date().unwrap_or_default(),
                            "short interest fetch resolved an OLDER file; keeping fresher snapshot"
                        );
                    } else {
                        let n = snap.by_symbol.len();
                        let date = snap.settlement_date.clone();
                        store.replace(snap);
                        tracing::info!(
                            symbols = n,
                            settlement = %date,
                            "short interest refreshed (FINRA Rule 4560)"
                        );
                    }
                }
                Err(e) => tracing::warn!(
                    error = %e,
                    "short interest refresh failed; keeping prior snapshot"
                ),
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    // The exact header + two data rows verified live from
    // cdn.finra.org/equity/otcmarket/biweekly/shrt20260630.csv (2026-07-23).
    const FIXTURE: &str = "accountingYearMonthNumber|symbolCode|issueName|issuerServicesGroupExchangeCode|marketClassCode|currentShortPositionQuantity|previousShortPositionQuantity|stockSplitFlag|averageDailyVolumeQuantity|daysToCoverQuantity|revisionFlag|changePercent|changePreviousNumber|settlementDate\n20260630|A|Agilent Technologies Inc.|A|NYSE|5331733|5662129||2510868|2.12||-5.84|-330396|2026-06-30\n20260630|AA|Alcoa Corporation|A|NYSE|8425769|8091919||6201435|1.36||4.13|333850|2026-06-30\n";

    #[test]
    fn parses_verified_finra_schema() {
        let snap = parse_consolidated(FIXTURE);
        assert_eq!(snap.settlement_date, "2026-06-30");
        assert_eq!(snap.by_symbol.len(), 2);
        let a = snap.by_symbol.get("A").expect("A present");
        assert_eq!(a.current, 5_331_733.0);
        assert_eq!(a.previous, Some(5_662_129.0));
        assert_eq!(a.avg_daily_volume, Some(2_510_868.0));
        assert_eq!(a.days_to_cover, Some(2.12));
        assert_eq!(a.settlement_date, "2026-06-30");
    }

    #[test]
    fn header_driven_survives_column_reorder() {
        let reordered = "symbolCode|currentShortPositionQuantity|settlementDate\nTSLA|12345|2026-06-30\n";
        let snap = parse_consolidated(reordered);
        let t = snap.by_symbol.get("TSLA").unwrap();
        assert_eq!(t.current, 12_345.0);
        assert_eq!(t.previous, None); // absent column → None, not a guess
        assert_eq!(t.settlement_date, "2026-06-30");
    }

    #[test]
    fn unknown_schema_or_garbage_is_empty_not_wrong() {
        assert!(parse_consolidated("").by_symbol.is_empty());
        // header lacks the required columns → refuse to parse
        assert!(parse_consolidated("foo|bar\n1|2\n").by_symbol.is_empty());
        // blank symbol + non-numeric current are skipped, never panicked
        let s = parse_consolidated("symbolCode|currentShortPositionQuantity\n|999\nBAD|abc\n");
        assert!(s.by_symbol.is_empty());
    }

    #[test]
    fn candidate_dates_are_newest_first_and_in_window() {
        let today = NaiveDate::from_ymd_opt(2026, 7, 23).unwrap();
        let cands = candidate_dates(today);
        assert!(!cands.is_empty());
        for w in cands.windows(2) {
            assert!(w[0] > w[1], "candidates must be strictly newest-first");
        }
        let lo = today - Duration::days(LOOKBACK_DAYS);
        assert!(cands.iter().all(|d| *d <= today && *d >= lo));
        // the window holds two settlements/month, so ≥2 distinct candidates exist
        assert!(cands.len() >= 2);
    }

    #[test]
    fn url_shape_is_exact() {
        let f = url_for(NaiveDate::from_ymd_opt(2026, 6, 30).unwrap());
        assert_eq!(
            f,
            "https://cdn.finra.org/equity/otcmarket/biweekly/shrt20260630.csv"
        );
    }

    #[test]
    fn weekend_settlement_steps_back_to_a_weekday() {
        // Find the first Saturday in a known month, no calendar constant baked in.
        let mut sat = NaiveDate::from_ymd_opt(2026, 8, 1).unwrap();
        while sat.weekday() != Weekday::Sat {
            sat += Duration::days(1);
        }
        let b = to_business_day(sat);
        assert_eq!(b, sat - Duration::days(1)); // Sat → Fri
        assert!(!matches!(b.weekday(), Weekday::Sat | Weekday::Sun));
        // A Sunday steps back to Friday too.
        let sun = sat + Duration::days(1);
        assert_eq!(to_business_day(sun), sat - Duration::days(1));
    }

    #[test]
    fn negative_short_position_is_rejected_not_surfaced() {
        // A negative currentShortPositionQuantity is corrupt → the row is dropped,
        // never surfaced as a nonsensical negative short interest.
        let s = parse_consolidated(
            "symbolCode|currentShortPositionQuantity|previousShortPositionQuantity\nBAD|-100|50\nOK|200|-5\n",
        );
        assert!(s.by_symbol.get("BAD").is_none(), "negative current → row dropped");
        let ok = s.by_symbol.get("OK").expect("valid current kept");
        assert_eq!(ok.current, 200.0);
        assert_eq!(ok.previous, None, "negative previous → None, not a negative");
    }

    #[test]
    fn refresh_never_regresses_to_an_older_settlement() {
        // Monotonic guard: a fresher held snapshot is kept when an older file
        // resolves; equal/newer replaces; a cold cache always accepts.
        assert!(accepts(None, "2026-06-30"), "cold cache accepts anything");
        assert!(accepts(Some("2026-06-30"), "2026-07-15"), "newer replaces");
        assert!(accepts(Some("2026-07-15"), "2026-07-15"), "equal replaces (idempotent)");
        assert!(!accepts(Some("2026-07-15"), "2026-06-30"), "older is REJECTED");
        assert!(accepts(Some(""), "2026-06-30"), "empty held → accept");
        assert!(accepts(Some("2026-07-15"), ""), "unknown incoming → cannot prove stale, accept");
    }

    #[test]
    fn store_roundtrips_and_reports_freshness() {
        let store = ShortInterestStore::new();
        assert!(store.is_empty());
        assert_eq!(store.settlement_date(), None);
        store.replace(parse_consolidated(FIXTURE));
        assert_eq!(store.len(), 2);
        assert_eq!(store.settlement_date().as_deref(), Some("2026-06-30"));
        assert_eq!(store.get("AA").unwrap().current, 8_425_769.0);
        assert!(store.get("ZZZZ").is_none());
    }
}
