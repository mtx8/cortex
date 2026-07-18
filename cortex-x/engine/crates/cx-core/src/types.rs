//! Core market vocabulary shared by every crate and mirrored by the macOS app.

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Side {
    Buy,
    Sell,
}

impl Side {
    pub fn sign(self) -> f64 {
        match self {
            Side::Buy => 1.0,
            Side::Sell => -1.0,
        }
    }
    pub fn flip(self) -> Side {
        match self {
            Side::Buy => Side::Sell,
            Side::Sell => Side::Buy,
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum OrderType {
    Market,
    Limit,
    /// Rests until price reaches its `stop_px` trigger, then fills as a market
    /// order (serde: "stop").
    Stop,
    /// Rests until price reaches its `stop_px` trigger, then becomes a resting
    /// limit at `limit_px` (serde: "stop_limit").
    StopLimit,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Tif {
    Gtc,
    Ioc,
    Day,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AssetClass {
    Crypto,
    Equity,
    Future,
    Fx,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Venue {
    Paper,
    Coinbase,
    Binance,
    Cboe,
    Synthetic,
}

/// Crude but reliable symbol-class routing: Coinbase products carry a dash
/// ("BTC-USD"); bare tickers ("AAPL", "SPY") are equities.
pub fn asset_class_of(symbol: &str) -> AssetClass {
    if symbol.contains('-') {
        AssetClass::Crypto
    } else {
        AssetClass::Equity
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Liquidity {
    Maker,
    Taker,
}

/// Bar interval. `ms()` is the bucket width used by aggregators.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Interval {
    S1,
    M1,
    M5,
    M15,
    H1,
    D1,
}

impl Interval {
    pub fn ms(self) -> i64 {
        match self {
            Interval::S1 => 1_000,
            Interval::M1 => 60_000,
            Interval::M5 => 300_000,
            Interval::M15 => 900_000,
            Interval::H1 => 3_600_000,
            Interval::D1 => 86_400_000,
        }
    }
    pub fn label(self) -> &'static str {
        match self {
            Interval::S1 => "1s",
            Interval::M1 => "1m",
            Interval::M5 => "5m",
            Interval::M15 => "15m",
            Interval::H1 => "1h",
            Interval::D1 => "1d",
        }
    }
    pub const ALL: [Interval; 6] = [
        Interval::S1,
        Interval::M1,
        Interval::M5,
        Interval::M15,
        Interval::H1,
        Interval::D1,
    ];
}

/// How far the engine may act without a human. CRITICAL risk actions
/// (kill switch, drawdown halt, flatten-on-breach) bypass the dial at
/// every level — safety is never gated behind autonomy.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AutonomyLevel {
    Manual,
    SuggestOnly,
    SemiAuto,
    FullAuto,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Info,
    Insight,
    Warning,
    Critical,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn order_type_wire_strings_are_snake_case() {
        // The Swift mirror decodes these raw values 1:1 — market/limit are
        // unchanged and the additive stop variants join them as "stop" /
        // "stop_limit".
        for (variant, wire) in [
            (OrderType::Market, "\"market\""),
            (OrderType::Limit, "\"limit\""),
            (OrderType::Stop, "\"stop\""),
            (OrderType::StopLimit, "\"stop_limit\""),
        ] {
            let json = serde_json::to_string(&variant).unwrap();
            assert_eq!(json, wire);
            let back: OrderType = serde_json::from_str(&json).unwrap();
            assert_eq!(back, variant);
        }
    }
}
