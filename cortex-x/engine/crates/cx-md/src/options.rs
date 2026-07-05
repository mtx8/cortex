//! Option chain fetch from CBOE delayed quotes (keyless). Returns the raw
//! venue chain for ONE expiry; greek enrichment happens in cortexd where a
//! risk-free rate is known. Payloads can exceed the default egress cap
//! (SPY ~6 MB) so this path uses an explicit larger cap.

use cx_core::egress::Egress;
use cx_core::error::CxError;
use cx_core::events::{OptionContract, OptionRight, OptionsChain};
use cx_core::time::now_ms;

const CHAIN_CAP_BYTES: usize = 24 * 1024 * 1024;

fn chain_url(underlying: &str) -> String {
    format!("https://cdn.cboe.com/api/global/delayed_quotes/options/{underlying}.json")
}

/// OCC symbol: ROOT + YYMMDD + C|P + strike*1000 zero-padded to 8.
/// Parsed from the END so variable-length roots never matter.
pub(crate) fn parse_occ(occ: &str) -> Option<(String, OptionRight, f64)> {
    if occ.len() < 16 {
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
    parse_chain(&symbol, &raw, want_expiry)
}

pub(crate) fn parse_chain(
    symbol: &str,
    raw: &str,
    want_expiry: Option<&str>,
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
        _ => expirations.first().cloned().unwrap_or_default(),
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

    #[test]
    fn chain_parses_selects_expiry_and_sorts() {
        let raw = r#"{"data":{"current_price":100.0,"options":[
            {"option":"XX260710C00110000","bid":1.0,"ask":1.2,"iv":0.3,"delta":0.4,"volume":5,"open_interest":10},
            {"option":"XX260710C00090000","bid":10.0,"ask":10.5,"iv":0.0,"volume":1,"open_interest":2},
            {"option":"XX260807P00100000","bid":3.0,"ask":3.3,"iv":0.25,"volume":7,"open_interest":9}
        ]}}"#;
        let chain = parse_chain("XX", raw, None).unwrap();
        assert_eq!(chain.expirations, vec!["2026-07-10", "2026-08-07"]);
        assert_eq!(chain.expiry, "2026-07-10");
        assert_eq!(chain.contracts.len(), 2);
        assert!(chain.contracts[0].strike < chain.contracts[1].strike);
        // iv 0.0 is treated as absent -> engine will backfill via BS.
        assert!(chain.contracts[0].iv.is_none());

        let aug = parse_chain("XX", raw, Some("2026-08-07")).unwrap();
        assert_eq!(aug.contracts.len(), 1);
        assert_eq!(aug.contracts[0].right, OptionRight::Put);

        assert!(parse_chain("XX", "{}", None).is_err());
    }
}
