//! Commands flow one way: UI/operator -> server -> engine. They are the only
//! way anything outside the engine can request action.

use serde::{Deserialize, Serialize};

use crate::types::{AutonomyLevel, OrderType, Side};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "cmd", rename_all = "snake_case")]
pub enum Command {
    PlaceOrder {
        symbol: String,
        side: Side,
        qty: f64,
        order_type: OrderType,
        limit_px: Option<f64>,
        /// Trigger price for `Stop` / `StopLimit` orders.
        ///
        /// WIRE COMPAT: additive `#[serde(default)]` field — an old client's
        /// `place_order` frame (which never sends `stop_px`) still decodes to
        /// None, so nothing breaks. Clients encode it only when present.
        #[serde(default)]
        stop_px: Option<f64>,
    },
    CancelOrder {
        order_id: u64,
    },
    /// Engaging is always honored instantly. Disengaging requires a reason
    /// and is logged as a critical thought.
    SetKillSwitch {
        engaged: bool,
        reason: String,
    },
    SetAutonomy {
        level: AutonomyLevel,
    },
    SetStrategyEnabled {
        strategy: String,
        enabled: bool,
    },
    FlattenAll {
        reason: String,
    },
    /// Copilot question; answered asynchronously via `EngineEvent::AiAnswer`.
    AskAi {
        request_id: String,
        question: String,
    },
    /// Client asks for a state snapshot replay (bars, positions, risk).
    Sync {
        bars_per_symbol: u32,
    },
    /// Foundry: replay strategy rules over stored history and project
    /// outcomes. Answered via `EngineEvent::Sim`.
    RunSimulation {},
    /// Fetch a full option chain for an equity underlying. Answered via
    /// `EngineEvent::OptionsChain`; expiry None means nearest.
    GetOptionsChain {
        underlying: String,
        expiry: Option<String>,
    },
    /// Fetch the COMPANY intelligence card (supply-chain graph + EDGAR
    /// fundamentals). Answered via `EngineEvent::Company`.
    GetCompany {
        symbol: String,
    },
    /// Browse a filer's SEC EDGAR filings (dedicated, richer than the COMPANY
    /// card's cadence summary). `query` is a ticker, company name, or raw CIK;
    /// `form_filter` keeps only forms with that prefix (empty = all);
    /// `text` runs an EDGAR full-text search over the filer's filings (empty =
    /// the recent-submissions list). Answered via `EngineEvent::Filings`.
    GetFilings {
        query: String,
        form_filter: String,
        text: String,
    },
    /// Fetch daily history for any symbol (searched tickers outside the
    /// configured feed set). Answered via `EngineEvent::History`.
    GetHistory {
        symbol: String,
    },
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn place_order_stop_px_is_additive_and_optional() {
        // An old client omits `stop_px` entirely — the frame must still decode
        // (stop_px = None), so a market/limit order from a pre-stop client is
        // unaffected.
        let market = r#"{"cmd":"place_order","symbol":"BTC-USD","side":"buy",
            "qty":1.0,"order_type":"market","limit_px":null}"#;
        assert_eq!(
            serde_json::from_str::<Command>(market).unwrap(),
            Command::PlaceOrder {
                symbol: "BTC-USD".into(),
                side: Side::Buy,
                qty: 1.0,
                order_type: OrderType::Market,
                limit_px: None,
                stop_px: None,
            }
        );

        // A stop-limit frame carries both prices and round-trips with the
        // snake_case field names the Swift mirror sends.
        let raw = r#"{"cmd":"place_order","symbol":"ETH-USD","side":"sell",
            "qty":2.0,"order_type":"stop_limit","limit_px":95.0,"stop_px":96.0}"#;
        let cmd: Command = serde_json::from_str(raw).unwrap();
        assert_eq!(
            cmd,
            Command::PlaceOrder {
                symbol: "ETH-USD".into(),
                side: Side::Sell,
                qty: 2.0,
                order_type: OrderType::StopLimit,
                limit_px: Some(95.0),
                stop_px: Some(96.0),
            }
        );
        let json = serde_json::to_string(&cmd).unwrap();
        assert!(json.contains("\"cmd\":\"place_order\""));
        assert!(json.contains("\"stop_px\":96.0"));
        assert!(json.contains("\"order_type\":\"stop_limit\""));
        let back: Command = serde_json::from_str(&json).unwrap();
        assert_eq!(back, cmd);
    }

    #[test]
    fn get_filings_decodes_from_the_wire_contract() {
        // The exact client -> server frame the Swift mirror sends.
        let raw = r#"{"cmd":"get_filings","query":"AAPL","form_filter":"10-K","text":""}"#;
        let cmd: Command = serde_json::from_str(raw).unwrap();
        assert_eq!(
            cmd,
            Command::GetFilings {
                query: "AAPL".into(),
                form_filter: "10-K".into(),
                text: String::new(),
            }
        );
        // Round-trips with the `cmd` tag and snake_case fields.
        let json = serde_json::to_string(&cmd).unwrap();
        assert!(json.contains("\"cmd\":\"get_filings\""));
        assert!(json.contains("\"form_filter\":\"10-K\""));
        let back: Command = serde_json::from_str(&json).unwrap();
        assert_eq!(back, cmd);
    }
}
