//! "macro_sentinel" (squadron "macro") — real yield-curve and reference-FX
//! context, refreshed on start and every 6 hours. Invariants:
//! - Truncated or partial Treasury XML is REFUSED outright: on any parse
//!   doubt the cycle is skipped with a Thought(info) — never a half-parsed
//!   curve on the bus.
//! - All network numbers are finite-checked and range-checked before use.
//! - Network failures log a Thought(info) and retry next cycle; the mesh
//!   never crashes on feed trouble.
//! - Caution is tighten-only: inversion publishes a global 0.15 request.

use std::collections::BTreeMap;
use std::sync::Arc;
use std::time::Duration;

use chrono::{Datelike, Months, Utc};
use cx_core::egress::Egress;
use cx_core::events::{CautionUpdate, EngineEvent, MacroSnapshot};
use cx_core::time::now_ms;
use cx_core::types::Severity;
use cx_core::Bus;

use crate::publish_thought;

const AGENT: &str = "macro_sentinel";
const SQUADRON: &str = "macro";
const CYCLE: Duration = Duration::from_secs(6 * 3600);
const FRANKFURTER_URL: &str = "https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR,JPY,GBP";
const INVERSION_THRESHOLD_BPS: f64 = -25.0;
const INVERSION_CAUTION: f64 = 0.15;
/// Sanity range for a par yield in percent; anything outside is refused.
const YIELD_RANGE: std::ops::RangeInclusive<f64> = -10.0..=40.0;

/// The latest daily par-yield observation extracted from the Treasury feed.
#[derive(Debug, Clone, PartialEq)]
pub(crate) struct TreasuryLatest {
    pub date: String,
    pub y3m: f64,
    pub y2y: f64,
    pub y10y: f64,
    pub y30y: f64,
}

pub(crate) fn spawn(bus: Arc<Bus>) {
    tokio::spawn(async move {
        let egress = Egress::new();
        loop {
            run_cycle(&bus, &egress).await;
            tokio::time::sleep(CYCLE).await;
        }
    });
}

async fn run_cycle(bus: &Bus, egress: &Egress) {
    // (a) Treasury daily par yield curve — current month, falling back to
    // the previous month when the current one has no entries yet (the 1st).
    let mut latest: Option<TreasuryLatest> = None;
    for yyyymm in month_candidates() {
        match egress.get_text(&treasury_url(&yyyymm)).await {
            Ok(xml) => match parse_treasury_xml(&xml) {
                Ok(Some(t)) => {
                    latest = Some(t);
                    break;
                }
                Ok(None) => continue, // month empty so far — fall back
                Err(reason) => {
                    publish_thought(
                        bus,
                        AGENT,
                        SQUADRON,
                        Severity::Info,
                        None,
                        0.5,
                        format!("treasury yield feed refused ({reason}); skipping this macro cycle"),
                    );
                    return;
                }
            },
            Err(e) => {
                publish_thought(
                    bus,
                    AGENT,
                    SQUADRON,
                    Severity::Info,
                    None,
                    0.5,
                    format!("treasury fetch failed ({e}); retrying next cycle"),
                );
                return;
            }
        }
    }
    let Some(t) = latest else {
        publish_thought(
            bus,
            AGENT,
            SQUADRON,
            Severity::Info,
            None,
            0.5,
            "treasury feed had no entries for current or previous month; skipping macro cycle",
        );
        return;
    };

    // (b) ECB reference FX via Frankfurter. Optional: a failed FX leg logs
    // an info thought and the snapshot ships with an empty fx map.
    let fx = match egress.get_text(FRANKFURTER_URL).await {
        Ok(body) => match serde_json::from_str::<serde_json::Value>(&body) {
            Ok(v) => match parse_frankfurter(&v) {
                Ok(fx) => fx,
                Err(reason) => {
                    publish_thought(
                        bus,
                        AGENT,
                        SQUADRON,
                        Severity::Info,
                        None,
                        0.5,
                        format!("fx parse failed ({reason}); macro snapshot ships without fx"),
                    );
                    BTreeMap::new()
                }
            },
            Err(_) => {
                publish_thought(
                    bus,
                    AGENT,
                    SQUADRON,
                    Severity::Info,
                    None,
                    0.5,
                    "fx response was not json; macro snapshot ships without fx",
                );
                BTreeMap::new()
            }
        },
        Err(e) => {
            publish_thought(
                bus,
                AGENT,
                SQUADRON,
                Severity::Info,
                None,
                0.5,
                format!("fx fetch failed ({e}); macro snapshot ships without fx"),
            );
            BTreeMap::new()
        }
    };

    let snap = build_snapshot(&t, fx, now_ms());
    let s2 = snap.spread_2s10s_bps.unwrap_or(f64::NAN);
    let s3 = snap.spread_3m10s_bps.unwrap_or(f64::NAN);
    let fx_str = if snap.fx.is_empty() {
        "fx unavailable".to_string()
    } else {
        snap.fx
            .iter()
            .map(|(k, v)| format!("{k} {v:.4}"))
            .collect::<Vec<_>>()
            .join(" ")
    };
    let date = t.date.split('T').next().unwrap_or(&t.date).to_string();
    publish_thought(
        bus,
        AGENT,
        SQUADRON,
        Severity::Insight,
        None,
        0.8,
        format!(
            "macro {date}: 3m {:.2}% 2y {:.2}% 10y {:.2}% 30y {:.2}%; 2s10s {s2:+.1}bps ({}); 3m10s {s3:+.1}bps; {fx_str}",
            t.y3m, t.y2y, t.y10y, t.y30y, snap.curve_regime,
        ),
    );
    if s2.is_finite() && s2 < INVERSION_THRESHOLD_BPS {
        bus.publish(EngineEvent::Caution(CautionUpdate {
            scope: None,
            value: INVERSION_CAUTION,
            reason: "yield curve inverted (2s10s < -25bps)".into(),
            agent: AGENT.into(),
            ts_ms: now_ms(),
        }));
    }
    bus.publish(EngineEvent::Macro(snap));
}

fn treasury_url(yyyymm: &str) -> String {
    format!(
        "https://home.treasury.gov/resource-center/data-chart-center/interest-rates/pages/xml?data=daily_treasury_yield_curve&field_tdr_date_value_month={yyyymm}"
    )
}

/// Current month, then previous month (fallback for the first of the month).
fn month_candidates() -> Vec<String> {
    let today = Utc::now().date_naive();
    let mut out = vec![format!("{:04}{:02}", today.year(), today.month())];
    if let Some(prev) = today.checked_sub_months(Months::new(1)) {
        out.push(format!("{:04}{:02}", prev.year(), prev.month()));
    }
    out
}

/// Parse the Treasury daily par-yield Atom feed and return the LATEST entry.
///
/// Refusal semantics (the invariant): any structural doubt — missing
/// `</feed>` terminator, unbalanced `<entry>` tags, a missing/null/
/// out-of-range required tenor — returns `Err` and the caller skips the
/// cycle. `Ok(None)` means a well-formed feed with zero entries (month has
/// no data yet).
pub(crate) fn parse_treasury_xml(xml: &str) -> Result<Option<TreasuryLatest>, String> {
    let trimmed = xml.trim();
    if !trimmed.contains("<feed") {
        return Err("not an atom feed".into());
    }
    if !trimmed.ends_with("</feed>") {
        return Err("truncated xml (missing </feed> terminator)".into());
    }
    let opens = trimmed.matches("<entry").count();
    let closes = trimmed.matches("</entry>").count();
    if opens != closes {
        return Err(format!(
            "unbalanced entries ({opens} open / {closes} close) — refusing partial feed"
        ));
    }
    if opens == 0 {
        return Ok(None);
    }

    // Pick the entry with the max NEW_DATE (ISO datetimes sort lexically).
    let mut best: Option<(String, &str)> = None;
    for entry in entry_slices(trimmed) {
        let date = tag_text(entry, "NEW_DATE").ok_or("entry missing NEW_DATE")?;
        if best.as_ref().is_none_or(|(d, _)| date > *d) {
            best = Some((date, entry));
        }
    }
    let (date, entry) = best.ok_or("no parseable entries")?;

    let yield_of = |tag: &str| -> Result<f64, String> {
        let raw = tag_text(entry, tag).ok_or_else(|| format!("missing or null {tag}"))?;
        let v: f64 = raw
            .trim()
            .parse()
            .map_err(|_| format!("unparseable {tag} value"))?;
        if !v.is_finite() || !YIELD_RANGE.contains(&v) {
            return Err(format!("out-of-range {tag} value"));
        }
        Ok(v)
    };

    Ok(Some(TreasuryLatest {
        date,
        y3m: yield_of("BC_3MONTH")?,
        y2y: yield_of("BC_2YEAR")?,
        y10y: yield_of("BC_10YEAR")?,
        y30y: yield_of("BC_30YEAR")?,
    }))
}

/// All `<entry>…</entry>` inner slices (callers verified balance already).
fn entry_slices(xml: &str) -> Vec<&str> {
    let mut out = Vec::new();
    let mut from = 0;
    while let Some(rel) = xml[from..].find("<entry") {
        let start = from + rel;
        let Some(end_rel) = xml[start..].find("</entry>") else {
            break;
        };
        let end = start + end_rel;
        out.push(&xml[start..end]);
        from = end + "</entry>".len();
    }
    out
}

/// Inner text of `<d:NAME …>text</d:NAME>`. Returns `None` for absent tags,
/// self-closed null tags (`m:null="true" />`), and exact-name mismatches
/// (`BC_30YEAR` never matches `BC_30YEARDISPLAY`).
fn tag_text(entry: &str, name: &str) -> Option<String> {
    let open = format!("<d:{name}");
    let close = format!("</d:{name}>");
    let mut from = 0;
    while let Some(rel) = entry[from..].find(&open) {
        let after = from + rel + open.len();
        let rest = &entry[after..];
        let next = rest.chars().next()?;
        if next == '>' {
            let body = &rest[1..];
            let end = body.find(&close)?;
            return Some(body[..end].trim().to_string());
        }
        if next.is_whitespace() || next == '/' {
            let gt = rest.find('>')?;
            if rest[..gt].ends_with('/') {
                return None; // self-closing null value
            }
            let body = &rest[gt + 1..];
            let end = body.find(&close)?;
            return Some(body[..end].trim().to_string());
        }
        // Prefix of a longer tag name — keep searching.
        from = after;
    }
    None
}

/// Frankfurter returns per-USD rates; convert to conventional pairs:
/// EURUSD = 1/rate_EUR, USDJPY = rate_JPY, GBPUSD = 1/rate_GBP.
pub(crate) fn parse_frankfurter(v: &serde_json::Value) -> Result<BTreeMap<String, f64>, String> {
    let rates = v
        .get("rates")
        .and_then(|r| r.as_object())
        .ok_or("missing rates object")?;
    let rate = |k: &str| -> Result<f64, String> {
        rates
            .get(k)
            .and_then(|x| x.as_f64())
            .filter(|x| x.is_finite() && *x > 0.0)
            .ok_or_else(|| format!("missing or invalid rate {k}"))
    };
    let eur = rate("EUR")?;
    let jpy = rate("JPY")?;
    let gbp = rate("GBP")?;
    let mut fx = BTreeMap::new();
    fx.insert("EURUSD".to_string(), 1.0 / eur);
    fx.insert("USDJPY".to_string(), jpy);
    fx.insert("GBPUSD".to_string(), 1.0 / gbp);
    Ok(fx)
}

/// Curve regime by the 2s10s spread in bps: >150 steep, 25..150 normal,
/// -25..25 flat, <-25 inverted.
pub(crate) fn curve_regime(spread_2s10s_bps: f64) -> &'static str {
    if !spread_2s10s_bps.is_finite() {
        "unknown"
    } else if spread_2s10s_bps > 150.0 {
        "steep"
    } else if spread_2s10s_bps >= 25.0 {
        "normal"
    } else if spread_2s10s_bps >= -25.0 {
        "flat"
    } else {
        "inverted"
    }
}

pub(crate) fn build_snapshot(
    t: &TreasuryLatest,
    fx: BTreeMap<String, f64>,
    ts_ms: i64,
) -> MacroSnapshot {
    let s2 = (t.y10y - t.y2y) * 100.0;
    let s3 = (t.y10y - t.y3m) * 100.0;
    let mut yields = BTreeMap::new();
    yields.insert("3m".to_string(), t.y3m);
    yields.insert("2y".to_string(), t.y2y);
    yields.insert("10y".to_string(), t.y10y);
    yields.insert("30y".to_string(), t.y30y);
    MacroSnapshot {
        yields,
        spread_2s10s_bps: Some(s2),
        spread_3m10s_bps: Some(s3),
        curve_regime: curve_regime(s2).to_string(),
        fx,
        source: "treasury.gov + frankfurter.dev".into(),
        ts_ms,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const VALID_FEED: &str = r#"<?xml version="1.0" encoding="utf-8" standalone="yes"?>
<feed xmlns="http://www.w3.org/2005/Atom" xmlns:d="http://schemas.microsoft.com/ado/2007/08/dataservices" xmlns:m="http://schemas.microsoft.com/ado/2007/08/dataservices/metadata">
  <title type="text">DailyTreasuryYieldCurveRateData</title>
  <entry>
    <content type="application/xml">
      <m:properties>
        <d:NEW_DATE m:type="Edm.DateTime">2026-07-01T00:00:00</d:NEW_DATE>
        <d:BC_3MONTH m:type="Edm.Double">5.10</d:BC_3MONTH>
        <d:BC_2YEAR m:type="Edm.Double">4.60</d:BC_2YEAR>
        <d:BC_10YEAR m:type="Edm.Double">4.20</d:BC_10YEAR>
        <d:BC_30YEAR m:type="Edm.Double">4.40</d:BC_30YEAR>
        <d:BC_30YEARDISPLAY m:type="Edm.Double">4.40</d:BC_30YEARDISPLAY>
      </m:properties>
    </content>
  </entry>
  <entry>
    <content type="application/xml">
      <m:properties>
        <d:NEW_DATE m:type="Edm.DateTime">2026-07-02T00:00:00</d:NEW_DATE>
        <d:BC_3MONTH m:type="Edm.Double">5.20</d:BC_3MONTH>
        <d:BC_2YEAR m:type="Edm.Double">4.71</d:BC_2YEAR>
        <d:BC_10YEAR m:type="Edm.Double">4.36</d:BC_10YEAR>
        <d:BC_30YEAR m:type="Edm.Double">4.51</d:BC_30YEAR>
        <d:BC_30YEARDISPLAY m:type="Edm.Double">4.51</d:BC_30YEARDISPLAY>
      </m:properties>
    </content>
  </entry>
</feed>"#;

    #[test]
    fn treasury_valid_feed_parses_latest_entry() {
        let t = parse_treasury_xml(VALID_FEED).unwrap().unwrap();
        assert!(t.date.starts_with("2026-07-02"));
        assert!((t.y3m - 5.20).abs() < 1e-12);
        assert!((t.y2y - 4.71).abs() < 1e-12);
        assert!((t.y10y - 4.36).abs() < 1e-12);
        assert!((t.y30y - 4.51).abs() < 1e-12);
    }

    #[test]
    fn treasury_truncated_feed_is_refused() {
        let truncated = &VALID_FEED[..VALID_FEED.len() / 2];
        assert!(parse_treasury_xml(truncated).is_err());
        // Balanced entries but missing the feed terminator: also refused.
        let no_terminator = VALID_FEED.replace("</feed>", "");
        assert!(parse_treasury_xml(&no_terminator).is_err());
    }

    #[test]
    fn treasury_unbalanced_entries_are_refused() {
        // An <entry> whose close tag was cut, but </feed> survives.
        let broken = VALID_FEED.replacen("</entry>", "", 1);
        assert!(parse_treasury_xml(&broken).is_err());
    }

    #[test]
    fn treasury_null_yield_is_refused() {
        let with_null = VALID_FEED.replace(
            r#"<d:BC_30YEAR m:type="Edm.Double">4.51</d:BC_30YEAR>"#,
            r#"<d:BC_30YEAR m:type="Edm.Double" m:null="true" />"#,
        );
        let err = parse_treasury_xml(&with_null).unwrap_err();
        assert!(err.contains("BC_30YEAR"), "unexpected error: {err}");
    }

    #[test]
    fn treasury_empty_feed_returns_none_for_month_fallback() {
        let empty = r#"<?xml version="1.0"?><feed xmlns="http://www.w3.org/2005/Atom"><title>x</title></feed>"#;
        assert_eq!(parse_treasury_xml(empty).unwrap(), None);
    }

    #[test]
    fn treasury_out_of_range_yield_is_refused() {
        let hostile = VALID_FEED.replace(">4.36<", ">936.0<");
        assert!(parse_treasury_xml(&hostile).is_err());
    }

    #[test]
    fn frankfurter_parses_and_converts_pairs() {
        let v: serde_json::Value = serde_json::from_str(
            r#"{"amount":1.0,"base":"USD","date":"2026-07-03","rates":{"EUR":0.9,"GBP":0.8,"JPY":160.0}}"#,
        )
        .unwrap();
        let fx = parse_frankfurter(&v).unwrap();
        assert!((fx["EURUSD"] - 1.0 / 0.9).abs() < 1e-12);
        assert!((fx["GBPUSD"] - 1.25).abs() < 1e-12);
        assert!((fx["USDJPY"] - 160.0).abs() < 1e-12);
    }

    #[test]
    fn frankfurter_rejects_missing_or_invalid_rates() {
        let missing: serde_json::Value =
            serde_json::from_str(r#"{"rates":{"EUR":0.9,"GBP":0.8}}"#).unwrap();
        assert!(parse_frankfurter(&missing).is_err());
        let zero: serde_json::Value =
            serde_json::from_str(r#"{"rates":{"EUR":0.0,"GBP":0.8,"JPY":160.0}}"#).unwrap();
        assert!(parse_frankfurter(&zero).is_err());
        let junk: serde_json::Value = serde_json::from_str(r#"{"hello":"world"}"#).unwrap();
        assert!(parse_frankfurter(&junk).is_err());
    }

    #[test]
    fn curve_regime_boundaries() {
        assert_eq!(curve_regime(200.0), "steep");
        assert_eq!(curve_regime(150.0), "normal");
        assert_eq!(curve_regime(25.0), "normal");
        assert_eq!(curve_regime(0.0), "flat");
        assert_eq!(curve_regime(-25.0), "flat");
        assert_eq!(curve_regime(-26.0), "inverted");
        assert_eq!(curve_regime(f64::NAN), "unknown");
    }

    #[test]
    fn snapshot_spreads_and_regime() {
        let t = TreasuryLatest {
            date: "2026-07-02T00:00:00".into(),
            y3m: 5.20,
            y2y: 4.71,
            y10y: 4.36,
            y30y: 4.51,
        };
        let snap = build_snapshot(&t, BTreeMap::new(), 1);
        assert!((snap.spread_2s10s_bps.unwrap() + 35.0).abs() < 1e-9);
        assert!((snap.spread_3m10s_bps.unwrap() + 84.0).abs() < 1e-9);
        assert_eq!(snap.curve_regime, "inverted");
        assert_eq!(snap.yields.len(), 4);
        assert_eq!(snap.yields["10y"], 4.36);
    }
}
