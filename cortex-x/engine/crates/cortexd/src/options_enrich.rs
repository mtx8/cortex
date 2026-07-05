//! Greek enrichment for venue option chains: wherever CBOE omits IV or a
//! greek (zero/absent), solve it with the engine's Black-Scholes from the
//! contract mid price and the live risk-free rate. Venue numbers are never
//! overwritten — `greeks_source` records exactly what was computed.

use cx_core::events::{OptionRight, OptionsChain};
use cx_core::time::now_ms;
use cx_ta::bs;

pub fn enrich(chain: &mut OptionsChain, risk_free_rate: f64) {
    let Some(t_years) = bs::years_to_expiry(now_ms(), &chain.expiry) else {
        return;
    };
    let spot = chain.underlying_px;
    for c in &mut chain.contracts {
        let is_call = c.right == OptionRight::Call;
        let mid = if c.bid > 0.0 && c.ask >= c.bid {
            0.5 * (c.bid + c.ask)
        } else if c.last > 0.0 {
            c.last
        } else {
            continue;
        };

        if c.iv.is_none() {
            c.iv = bs::implied_vol(is_call, mid, spot, c.strike, t_years, risk_free_rate);
            if c.iv.is_some() {
                c.greeks_source = "cboe+bs".into();
            }
        }
        let Some(iv) = c.iv else { continue };
        if c.delta.is_none() || c.gamma.is_none() || c.theta.is_none() || c.vega.is_none() {
            if let Some(g) = bs::greeks(is_call, spot, c.strike, t_years, iv, risk_free_rate) {
                c.delta.get_or_insert(g.delta);
                c.gamma.get_or_insert(g.gamma);
                c.theta.get_or_insert(g.theta);
                c.vega.get_or_insert(g.vega);
                if c.greeks_source == "cboe" {
                    c.greeks_source = "cboe+bs".into();
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::OptionContract;

    #[test]
    fn fills_missing_iv_and_greeks_without_touching_venue_values() {
        let mut chain = OptionsChain {
            underlying: "XX".into(),
            underlying_px: 100.0,
            expirations: vec![],
            // ~6 months out relative to any plausible test run date.
            expiry: "2027-06-18".into(),
            contracts: vec![OptionContract {
                symbol: "XX270618C00100000".into(),
                right: OptionRight::Call,
                strike: 100.0,
                expiry: "2027-06-18".into(),
                bid: 11.0,
                ask: 12.0,
                last: 0.0,
                volume: 0.0,
                open_interest: 0.0,
                iv: None,
                delta: Some(0.60),
                gamma: None,
                theta: None,
                vega: None,
                greeks_source: "cboe".into(),
            }],
            source: "test".into(),
            as_of: None,
            ts_ms: 0,
        };
        enrich(&mut chain, 0.04);
        let c = &chain.contracts[0];
        assert!(c.iv.is_some(), "iv solved from mid");
        assert_eq!(c.delta, Some(0.60), "venue delta untouched");
        assert!(c.gamma.is_some() && c.theta.is_some() && c.vega.is_some());
        assert_eq!(c.greeks_source, "cboe+bs");
    }
}
