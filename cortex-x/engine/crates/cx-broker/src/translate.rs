//! OrderIntent -> IBKR contract + order translation.
//!
//! This is a PURE, always-compiled intermediate representation: it never
//! touches `ibapi` or a socket, so the mapping is fully unit-tested offline.
//! The feature-gated wire layer ([`crate::ibkr`]) converts this IR into
//! `ibapi::contracts::Contract` / `ibapi::orders::Order` right before the
//! send — keeping the risky, untestable socket surface as thin as possible.

use cx_core::events::OrderIntent;
use cx_core::types::{asset_class_of, AssetClass, OrderType, Side, Tif};

/// The venue used when no explicit route is configured — IBKR SmartRouting.
pub const SMART: &str = "SMART";
/// IBKR's crypto venue. Crypto symbols always route here regardless of the
/// configured equity route.
pub const CRYPTO_VENUE: &str = "PAXOS";

/// A translated IBKR contract. `sec_type` / order-type / action / tif are
/// drawn from IBKR's fixed wire vocabulary so they are `&'static str`.
#[derive(Debug, Clone, PartialEq)]
pub struct IbkrContract {
    /// The IBKR symbol: bare ticker for stocks ("AAPL"); the base asset for
    /// crypto ("BTC" from "BTC-USD").
    pub symbol: String,
    /// "STK" for equities, "CRYPTO" for crypto.
    pub sec_type: &'static str,
    /// Destination exchange: the configured route ("SMART" or a direct venue
    /// like "ARCA"/"ISLAND"/"IEX" for true DMA) for stocks; PAXOS for crypto.
    pub exchange: String,
    /// Settlement currency ("USD"; the quote leg for a crypto pair).
    pub currency: String,
}

/// A translated IBKR order. Maps our [`OrderType`] onto IBKR's four order-type
/// strings and carries the two price legs IBKR expects: `limit_price` (LMT /
/// STP LMT) and `aux_price` (the STP / STP LMT trigger).
#[derive(Debug, Clone, PartialEq)]
pub struct IbkrOrder {
    /// "BUY" or "SELL".
    pub action: &'static str,
    pub total_qty: f64,
    /// "MKT" | "LMT" | "STP" | "STP LMT".
    pub order_type: &'static str,
    /// The LMT price (LMT and STP LMT only); None otherwise.
    pub limit_price: Option<f64>,
    /// The STP trigger (STP and STP LMT only); None otherwise.
    pub aux_price: Option<f64>,
    /// "GTC" | "IOC" | "DAY".
    pub tif: &'static str,
    /// Whether the order may trigger/fill outside regular trading hours.
    pub outside_rth: bool,
    /// Carried through from the intent. IBKR has no native reduce-only flag
    /// for stocks; the adapter enforces reduce-only by clamping qty to the
    /// live position before it ever calls translate (mirroring the paper OMS
    /// fill-time clamp), and this flag documents that provenance downstream.
    pub reduce_only: bool,
}

fn action_str(side: Side) -> &'static str {
    match side {
        Side::Buy => "BUY",
        Side::Sell => "SELL",
    }
}

fn tif_str(tif: Tif) -> &'static str {
    match tif {
        Tif::Gtc => "GTC",
        Tif::Ioc => "IOC",
        Tif::Day => "DAY",
    }
}

/// Split a dashed crypto product ("BTC-USD") into (base, quote). A symbol with
/// no dash returns (symbol, "USD").
fn split_crypto(symbol: &str) -> (String, String) {
    match symbol.split_once('-') {
        Some((base, quote)) if !base.is_empty() && !quote.is_empty() => {
            (base.to_string(), quote.to_string())
        }
        _ => (symbol.to_string(), "USD".to_string()),
    }
}

/// Translate an [`OrderIntent`] into an IBKR contract + order pair. `route` is
/// the configured equity routing venue ("SMART" or a direct exchange code);
/// crypto ignores it and routes to PAXOS.
///
/// The order-type mapping is total over our four [`OrderType`]s:
/// - `Market`    -> "MKT"     (no prices)
/// - `Limit`     -> "LMT"     (limit_price)
/// - `Stop`      -> "STP"     (aux_price = trigger)
/// - `StopLimit` -> "STP LMT" (aux_price = trigger, limit_price = cap)
pub fn translate(intent: &OrderIntent, route: &str) -> (IbkrContract, IbkrOrder) {
    let contract = match asset_class_of(&intent.symbol) {
        AssetClass::Crypto => {
            let (base, quote) = split_crypto(&intent.symbol);
            IbkrContract {
                symbol: base,
                sec_type: "CRYPTO",
                exchange: CRYPTO_VENUE.to_string(),
                currency: quote,
            }
        }
        _ => IbkrContract {
            symbol: intent.symbol.clone(),
            sec_type: "STK",
            exchange: route_or_smart(route),
            currency: "USD".to_string(),
        },
    };

    let (order_type, limit_price, aux_price) = match intent.order_type {
        OrderType::Market => ("MKT", None, None),
        OrderType::Limit => ("LMT", intent.limit_px, None),
        OrderType::Stop => ("STP", None, intent.stop_px),
        OrderType::StopLimit => ("STP LMT", intent.limit_px, intent.stop_px),
    };

    let order = IbkrOrder {
        action: action_str(intent.side),
        total_qty: intent.qty,
        order_type,
        limit_price,
        aux_price,
        tif: tif_str(intent.tif),
        outside_rth: false,
        reduce_only: intent.reduce_only,
    };
    (contract, order)
}

/// The configured route, or SMART when the operator left it blank.
pub fn route_or_smart(route: &str) -> String {
    let r = route.trim();
    if r.is_empty() {
        SMART.to_string()
    } else {
        r.to_string()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use cx_core::events::OrderSource;
    use cx_core::time::now_ms;

    fn intent(
        symbol: &str,
        side: Side,
        qty: f64,
        order_type: OrderType,
        limit_px: Option<f64>,
        stop_px: Option<f64>,
    ) -> OrderIntent {
        OrderIntent {
            id: 0,
            symbol: symbol.into(),
            side,
            qty,
            order_type,
            limit_px,
            stop_px,
            tif: Tif::Gtc,
            reduce_only: false,
            source: OrderSource::Manual,
            rationale: "test".into(),
            ts_ms: now_ms(),
        }
    }

    #[test]
    fn market_maps_to_mkt_with_no_prices() {
        let (c, o) = translate(
            &intent("AAPL", Side::Buy, 10.0, OrderType::Market, None, None),
            SMART,
        );
        assert_eq!(c.symbol, "AAPL");
        assert_eq!(c.sec_type, "STK");
        assert_eq!(c.exchange, "SMART");
        assert_eq!(c.currency, "USD");
        assert_eq!(o.action, "BUY");
        assert_eq!(o.order_type, "MKT");
        assert_eq!(o.total_qty, 10.0);
        assert_eq!(o.limit_price, None);
        assert_eq!(o.aux_price, None);
        assert_eq!(o.tif, "GTC");
    }

    #[test]
    fn limit_maps_to_lmt_with_limit_price() {
        let (_c, o) = translate(
            &intent("MSFT", Side::Sell, 5.0, OrderType::Limit, Some(410.5), None),
            SMART,
        );
        assert_eq!(o.action, "SELL");
        assert_eq!(o.order_type, "LMT");
        assert_eq!(o.limit_price, Some(410.5));
        assert_eq!(o.aux_price, None);
    }

    #[test]
    fn stop_maps_to_stp_with_trigger_in_aux() {
        let (_c, o) = translate(
            &intent("NVDA", Side::Sell, 3.0, OrderType::Stop, None, Some(95.0)),
            SMART,
        );
        assert_eq!(o.order_type, "STP");
        assert_eq!(o.aux_price, Some(95.0)); // trigger lives in aux_price
        assert_eq!(o.limit_price, None);
    }

    #[test]
    fn stop_limit_maps_to_stp_lmt_with_both_legs() {
        let (_c, o) = translate(
            &intent(
                "SPY",
                Side::Buy,
                2.0,
                OrderType::StopLimit,
                Some(101.0),
                Some(100.0),
            ),
            SMART,
        );
        assert_eq!(o.order_type, "STP LMT");
        assert_eq!(o.aux_price, Some(100.0)); // stop trigger
        assert_eq!(o.limit_price, Some(101.0)); // limit cap
    }

    #[test]
    fn direct_route_is_used_for_dma_vs_smart_default() {
        // Explicit direct venue -> true DMA route on the contract.
        let (c, _o) = translate(
            &intent("AAPL", Side::Buy, 1.0, OrderType::Market, None, None),
            "ARCA",
        );
        assert_eq!(c.exchange, "ARCA");
        // Blank route falls back to SMART, never empty.
        let (c, _o) = translate(
            &intent("AAPL", Side::Buy, 1.0, OrderType::Market, None, None),
            "   ",
        );
        assert_eq!(c.exchange, "SMART");
    }

    #[test]
    fn crypto_routes_to_paxos_and_splits_the_pair() {
        // Crypto ignores the equity route and always routes to PAXOS.
        let (c, o) = translate(
            &intent("BTC-USD", Side::Buy, 0.5, OrderType::Market, None, None),
            "ARCA",
        );
        assert_eq!(c.symbol, "BTC");
        assert_eq!(c.sec_type, "CRYPTO");
        assert_eq!(c.exchange, "PAXOS");
        assert_eq!(c.currency, "USD");
        assert_eq!(o.action, "BUY");
    }

    #[test]
    fn tif_and_reduce_only_are_carried_through() {
        let mut i = intent("AAPL", Side::Sell, 4.0, OrderType::Market, None, None);
        i.tif = Tif::Ioc;
        i.reduce_only = true;
        let (_c, o) = translate(&i, SMART);
        assert_eq!(o.tif, "IOC");
        assert!(o.reduce_only);
    }
}
