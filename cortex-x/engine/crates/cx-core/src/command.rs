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
    /// Fetch a full option chain for an equity underlying. Answered via
    /// `EngineEvent::OptionsChain`; expiry None means nearest.
    GetOptionsChain {
        underlying: String,
        expiry: Option<String>,
    },
}
