//! A cheap read-only snapshot of portfolio state, passed INTO risk checks so
//! the risk crate holds no position state of its own.

use std::collections::HashMap;

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct PortfolioView {
    pub equity: f64,
    pub cash: f64,
    pub gross_exposure: f64,
    /// symbol -> (signed qty, mark price)
    pub positions: HashMap<String, (f64, f64)>,
    pub open_orders: u32,
    pub daily_trades: u32,
}

impl PortfolioView {
    pub fn position_qty(&self, symbol: &str) -> f64 {
        self.positions.get(symbol).map(|(q, _)| *q).unwrap_or(0.0)
    }

    pub fn position_notional(&self, symbol: &str) -> f64 {
        self.positions
            .get(symbol)
            .map(|(q, m)| (q * m).abs())
            .unwrap_or(0.0)
    }

    pub fn open_position_count(&self) -> u32 {
        self.positions.values().filter(|(q, _)| q.abs() > 1e-12).count() as u32
    }
}
