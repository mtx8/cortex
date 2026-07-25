//! Option chain fetch from CBOE delayed quotes (keyless). Returns the raw
//! venue chain for ONE expiry; greek enrichment happens in cortexd where a
//! risk-free rate is known. Payloads can exceed the default egress cap
//! (SPY ~6 MB) so this path uses an explicit larger cap.
//!
//! Expiry selection: an explicit `want_expiry` present on the board is
//! honored exactly. With NO expiry requested the default is the first
//! expiry at least [`MIN_DEFAULT_EXPIRY_DAYS`] calendar days out —
//! "nearest weekly, not 0DTE" — because heavily-listed underlyings (SPY)
//! put a 0DTE chain first, and a recurring desk read pinned to
//! `expirations.first()` would roll its tenor daily, corrupting IV/skew
//! comparisons across cycles. Fallback when the whole board is nearer
//! than that: the last available expiry.

use cx_core::egress::Egress;
use cx_core::error::CxError;
use cx_core::events::{OptionContract, OptionRight, OptionsChain};
use cx_core::time::now_ms;

const CHAIN_CAP_BYTES: usize = 24 * 1024 * 1024;
const DAY_MS: i64 = 86_400_000;
/// Default-expiry floor: with `want_expiry: None` the chosen expiry is the
/// first at least this many calendar days out (fallback: last available).
const MIN_DEFAULT_EXPIRY_DAYS: i64 = 7;

fn chain_url(underlying: &str) -> String {
    format!("https://cdn.cboe.com/api/global/delayed_quotes/options/{underlying}.json")
}

/// OCC symbol: ROOT + YYMMDD + C|P + strike*1000 zero-padded to 8.
/// Parsed from the END so variable-length roots never matter.
pub(crate) fn parse_occ(occ: &str) -> Option<(String, OptionRight, f64)> {
    // ASCII gate before ANY byte-offset slicing. `occ` is third-party text from
    // the venue's JSON, and the checks below index by byte; a multi-byte
    // character landing on one of those offsets makes `split_at` panic on a
    // non-char-boundary. The release profile sets `panic = "abort"`
    // (engine/Cargo.toml), so that panic would not merely kill the options task —
    // it would take down the whole engine process, mid-session. OCC symbology is
    // ASCII by definition (root, 6 date digits, C|P, 8 strike digits), so
    // anything else is malformed input to be refused, not parsed.
    if !occ.is_ascii() || occ.len() < 16 {
        return None;
    }
    let (head, strike_s) = occ.split_at(occ.len() - 8);
    let strike: f64 = strike_s.parse::<u64>().ok()? as f64 / 1000.0;
    let (head, right_s) = head.split_at(head.len() - 1);
    let right = match right_s {
        "C" => OptionRight::Call,
        "P" => OptionRight::Put,
        _ => return None,
    };
    let (_root, date_s) = head.split_at(head.len().checked_sub(6)?);
    if !date_s.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let expiry = format!("20{}-{}-{}", &date_s[0..2], &date_s[2..4], &date_s[4..6]);
    Some((expiry, right, strike))
}

/// Days since 1970-01-01 for a civil date (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let doy = (153 * ((m + 9) % 12) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

/// UTC day number of a `YYYY-MM-DD` expiry; None for malformed strings.
fn expiry_day(expiry: &str) -> Option<i64> {
    let b = expiry.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let y: i64 = expiry[0..4].parse().ok()?;
    let m: i64 = expiry[5..7].parse().ok()?;
    let d: i64 = expiry[8..10].parse().ok()?;
    if !(1..=12).contains(&m) || !(1..=31).contains(&d) {
        return None;
    }
    Some(days_from_civil(y, m, d))
}

/// Default expiry when none is requested: the first (sorted) expiry at
/// least [`MIN_DEFAULT_EXPIRY_DAYS`] calendar days out; when the whole
/// board is nearer than that, the last available expiry.
fn default_expiry(expirations: &[String], now: i64) -> Option<&String> {
    let cutoff = now.div_euclid(DAY_MS) + MIN_DEFAULT_EXPIRY_DAYS;
    expirations
        .iter()
        .find(|e| expiry_day(e).is_some_and(|d| d >= cutoff))
        .or_else(|| expirations.last())
}

/// Fetch the venue chain for one expiry. An explicit `want_expiry` present
/// on the board is honored exactly (on-demand UI requests pass these and
/// are unaffected). `want_expiry: None` — the recurring desk read — now
/// means "nearest weekly, not 0DTE": the first expiry >= 7 calendar days
/// out, falling back to the last available.
pub async fn fetch_chain(
    egress: &Egress,
    underlying: &str,
    want_expiry: Option<&str>,
) -> Result<OptionsChain, CxError> {
    let symbol = underlying.trim().to_uppercase();
    if symbol.is_empty() || !symbol.bytes().all(|b| b.is_ascii_alphanumeric()) {
        return Err(CxError::Feed("invalid underlying".into()));
    }
    let raw = egress
        .get_text_with_cap(&chain_url(&symbol), CHAIN_CAP_BYTES)
        .await?;
    parse_chain(&symbol, &raw, want_expiry, now_ms())
}

pub(crate) fn parse_chain(
    symbol: &str,
    raw: &str,
    want_expiry: Option<&str>,
    now: i64,
) -> Result<OptionsChain, CxError> {
    let v: serde_json::Value =
        serde_json::from_str(raw).map_err(|_| CxError::Feed("chain: invalid json".into()))?;
    let data = v
        .get("data")
        .ok_or_else(|| CxError::Feed("chain: no data".into()))?;
    let spot = data
        .get("current_price")
        .and_then(|x| x.as_f64())
        .filter(|p| p.is_finite() && *p > 0.0)
        .ok_or_else(|| CxError::Feed("chain: no underlying price".into()))?;
    let options = data
        .get("options")
        .and_then(|o| o.as_array())
        .ok_or_else(|| CxError::Feed("chain: no options array".into()))?;

    let mut expirations: Vec<String> = Vec::new();
    let mut rows: Vec<(String, OptionContract)> = Vec::with_capacity(options.len());
    for o in options {
        let Some(occ) = o.get("option").and_then(|x| x.as_str()) else {
            continue;
        };
        let Some((expiry, right, strike)) = parse_occ(occ) else {
            continue;
        };
        if !expirations.contains(&expiry) {
            expirations.push(expiry.clone());
        }
        let f = |k: &str| o.get(k).and_then(|x| x.as_f64()).unwrap_or(f64::NAN);
        let opt = |k: &str| {
            o.get(k)
                .and_then(|x| x.as_f64())
                .filter(|v| v.is_finite() && *v != 0.0)
        };
        rows.push((
            expiry.clone(),
            OptionContract {
                symbol: occ.to_string(),
                right,
                strike,
                expiry,
                bid: f("bid").max(0.0),
                ask: f("ask").max(0.0),
                last: f("last_trade_price").max(0.0),
                volume: f("volume").max(0.0),
                open_interest: f("open_interest").max(0.0),
                iv: opt("iv"),
                delta: opt("delta"),
                gamma: opt("gamma"),
                theta: opt("theta"),
                vega: opt("vega"),
                greeks_source: "cboe".into(),
            },
        ));
    }
    if rows.is_empty() {
        return Err(CxError::Feed("chain: no parseable contracts".into()));
    }
    expirations.sort();

    let chosen = match want_expiry {
        Some(e) if expirations.iter().any(|x| x == e) => e.to_string(),
        _ => default_expiry(&expirations, now)
            .cloned()
            .unwrap_or_default(),
    };
    let mut contracts: Vec<OptionContract> = rows
        .into_iter()
        .filter(|(e, _)| *e == chosen)
        .map(|(_, c)| c)
        .collect();
    contracts.sort_by(|a, b| {
        a.strike
            .partial_cmp(&b.strike)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    let as_of = data
        .get("last_trade_time")
        .and_then(|x| x.as_str())
        .map(|s| s.replace('T', " "));

    Ok(OptionsChain {
        underlying: symbol.to_string(),
        underlying_px: spot,
        expirations,
        expiry: chosen,
        contracts,
        source: "cboe delayed 15m".into(),
        as_of,
        ts_ms: now_ms(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn occ_parses_from_the_end() {
        let (exp, right, strike) = parse_occ("SPY260706C00500000").unwrap();
        assert_eq!(exp, "2026-07-06");
        assert_eq!(right, OptionRight::Call);
        assert_eq!(strike, 500.0);
        let (exp, right, strike) = parse_occ("BRKB261218P00420500").unwrap();
        assert_eq!(exp, "2026-12-18");
        assert_eq!(right, OptionRight::Put);
        assert_eq!(strike, 420.5);
        assert!(parse_occ("junk").is_none());
        assert!(parse_occ("SPY260706X00500000").is_none());
    }

    /// `parse_occ` slices by BYTE offset, so a multi-byte character sitting on
    /// one of those offsets used to panic on a non-char-boundary — and with
    /// `panic = "abort"` in the release profile that aborts the entire engine
    /// process, not just the options refresh. Venue JSON is third-party text, so
    /// malformed input must be refused rather than trusted.
    #[test]
    fn non_ascii_occ_is_refused_instead_of_panicking() {
        // 'é' is two bytes: these are long enough to pass the length check and
        // land a multi-byte boundary on the strike / right / date split points.
        for occ in [
            "SPYé60706C00500000",
            "SPY260706C0050é000",
            "SPY26070éC00500000",
            "é",
            "ééééééééééééééééé",
        ] {
            assert!(parse_occ(occ).is_none(), "must refuse {occ:?}, not panic");
        }
    }

    #[test]
    fn chain_parses_selects_expiry_and_sorts() {
        let raw = r#"{"data":{"current_price":100.0,"options":[
            {"option":"XX260710C00110000","bid":1.0,"ask":1.2,"iv":0.3,"delta":0.4,"volume":5,"open_interest":10},
            {"option":"XX260710C00090000","bid":10.0,"ask":10.5,"iv":0.0,"volume":1,"open_interest":2},
            {"option":"XX260807P00100000","bid":3.0,"ask":3.3,"iv":0.25,"volume":7,"open_interest":9}
        ]}}"#;
        // Well before both expiries: 2026-07-10 is >= 7 days out -> default.
        let now = expiry_day("2026-06-01").unwrap() * DAY_MS;
        let chain = parse_chain("XX", raw, None, now).unwrap();
        assert_eq!(chain.expirations, vec!["2026-07-10", "2026-08-07"]);
        assert_eq!(chain.expiry, "2026-07-10");
        assert_eq!(chain.contracts.len(), 2);
        assert!(chain.contracts[0].strike < chain.contracts[1].strike);
        // iv 0.0 is treated as absent -> engine will backfill via BS.
        assert!(chain.contracts[0].iv.is_none());

        let aug = parse_chain("XX", raw, Some("2026-08-07"), now).unwrap();
        assert_eq!(aug.contracts.len(), 1);
        assert_eq!(aug.contracts[0].right, OptionRight::Put);

        assert!(parse_chain("XX", "{}", None, now).is_err());
    }

    #[test]
    fn default_expiry_is_nearest_weekly_never_0dte() {
        let raw = r#"{"data":{"current_price":100.0,"options":[
            {"option":"XX260710C00100000","bid":1.0,"ask":1.2,"iv":0.5},
            {"option":"XX260714C00100000","bid":1.0,"ask":1.2,"iv":0.4},
            {"option":"XX260717C00100000","bid":1.0,"ask":1.2,"iv":0.3},
            {"option":"XX260807C00100000","bid":1.0,"ask":1.2,"iv":0.25}
        ]}}"#;
        // "Today" IS the first listed expiry (the SPY 0DTE shape): the
        // default skips 0DTE and the 4-day chain for the first expiry
        // >= 7 calendar days out (exactly 7 qualifies).
        let now = expiry_day("2026-07-10").unwrap() * DAY_MS;
        let chain = parse_chain("XX", raw, None, now).unwrap();
        assert_eq!(chain.expiry, "2026-07-17");
        // Intraday (mid-Saturday of the same day number) is identical.
        let chain = parse_chain("XX", raw, None, now + DAY_MS / 2).unwrap();
        assert_eq!(chain.expiry, "2026-07-17");
        // Explicit requests are honored exactly, 0DTE included.
        let zero = parse_chain("XX", raw, Some("2026-07-10"), now).unwrap();
        assert_eq!(zero.expiry, "2026-07-10");
        // Whole board nearer than 7 days: fall back to the LAST available.
        let late = expiry_day("2026-08-05").unwrap() * DAY_MS;
        let chain = parse_chain("XX", raw, None, late).unwrap();
        assert_eq!(chain.expiry, "2026-08-07");
    }

    #[test]
    fn expiry_day_maps_civil_dates() {
        assert_eq!(expiry_day("1970-01-01"), Some(0));
        assert_eq!(expiry_day("1970-01-02"), Some(1));
        // 10957 days to 2000-01-01, +31 (Jan) +29 (leap Feb) = 11017.
        assert_eq!(expiry_day("2000-03-01"), Some(11017));
        assert_eq!(expiry_day("2026-7-10"), None);
        assert_eq!(expiry_day("2026-13-01"), None);
        assert_eq!(expiry_day("garbage"), None);
    }
}
