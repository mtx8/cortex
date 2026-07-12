//! Configuration. Layered load: built-in defaults <- ~/.cortex/secrets.toml
//! (optional) <- environment variables. Secrets never appear in Debug output,
//! logs, or serialized snapshots.

use std::collections::BTreeMap;
use std::fmt;
use std::path::PathBuf;

use serde::Deserialize;

use crate::error::CxError;

/// A secret string whose Debug/Display never reveal the value.
#[derive(Clone, Default, Deserialize)]
#[serde(transparent)]
pub struct Secret(pub String);

impl Secret {
    pub fn expose(&self) -> &str {
        &self.0
    }
    pub fn is_empty(&self) -> bool {
        self.0.is_empty()
    }
}

impl fmt::Debug for Secret {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "Secret(***)")
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct FeedConfig {
    /// "coinbase" (live public websocket) or "synthetic".
    pub primary: String,
    /// When the live feed dies, keep the engine alive on a synthetic feed.
    pub synthetic_fallback: bool,
    /// REST backfill of recent candles at startup.
    pub backfill_bars: u32,
}

impl Default for FeedConfig {
    fn default() -> Self {
        Self {
            primary: "coinbase".into(),
            synthetic_fallback: true,
            backfill_bars: 600,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct RiskConfig {
    /// Max position notional as a fraction of equity (per symbol).
    pub max_position_pct: f64,
    /// Hard cap on a single order's notional in account currency.
    pub max_order_notional: f64,
    pub max_concurrent_positions: u32,
    pub max_daily_trades: u32,
    /// Worst tolerated loss on one trade (account currency) used for sizing.
    pub max_single_trade_loss: f64,
    /// Market orders are collared: reject if last price moved more than this
    /// fraction from the decision price.
    pub price_collar_pct: f64,
    /// Drawdown clocks (fractions of equity peak). Throttle begins at half
    /// the limit, halts new risk at the limit, engages the kill switch past it.
    pub max_daily_drawdown: f64,
    pub max_total_drawdown: f64,
    /// Tighten-only caution: sizing multiplier floor = 1 - max_shrink.
    pub caution_max_shrink: f64,
    /// Caution entries expire after this many seconds (TTL-bounded memory).
    pub caution_ttl_secs: u64,
}

impl Default for RiskConfig {
    fn default() -> Self {
        Self {
            max_position_pct: 0.10,
            max_order_notional: 25_000.0,
            max_concurrent_positions: 10,
            max_daily_trades: 120,
            max_single_trade_loss: 500.0,
            price_collar_pct: 0.01,
            max_daily_drawdown: 0.03,
            max_total_drawdown: 0.10,
            caution_max_shrink: 0.95,
            caution_ttl_secs: 1_800,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct PaperConfig {
    pub starting_cash: f64,
    pub maker_fee_bps: f64,
    pub taker_fee_bps: f64,
    /// Simulated order latency.
    pub latency_ms: u64,
    /// Base slippage applied to market orders, scaled by size.
    pub slippage_bps: f64,
}

impl Default for PaperConfig {
    fn default() -> Self {
        Self {
            starting_cash: 100_000.0,
            maker_fee_bps: 0.0,
            taker_fee_bps: 5.0,
            latency_ms: 15,
            slippage_bps: 1.0,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct AiConfig {
    /// Anthropic API key (env ANTHROPIC_API_KEY overrides).
    pub anthropic_api_key: Secret,
    pub model: String,
    /// Optional local OpenAI-compatible endpoint tried FIRST (local-first).
    pub local_llm_url: String,
    pub local_llm_model: String,
    /// Strategic loop cadence. The LLM is NEVER in the execution hot path.
    pub strategist_cadence_secs: u64,
    pub max_output_tokens: u32,
}

impl Default for AiConfig {
    fn default() -> Self {
        Self {
            anthropic_api_key: Secret::default(),
            model: "claude-sonnet-5".into(),
            local_llm_url: String::new(),
            local_llm_model: "llama3.1".into(),
            strategist_cadence_secs: 300,
            max_output_tokens: 1024,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct IntelConfig {
    /// Universe scanned by the REGIMES board (bare US tickers/ETFs only;
    /// configured `symbols` are always included on top of this list).
    pub universe: Vec<String>,
    /// MERIDIAN GDELT poll cadence (seconds, floor 300).
    pub gdelt_poll_secs: u64,
    /// REGIMES scan cadence (seconds, floor 300).
    pub regime_scan_secs: u64,
    pub enable_company: bool,
    pub enable_regimes: bool,
    pub enable_meridian: bool,
}

/// Liquid US megacaps + core index ETFs. Dashed share classes are excluded
/// on purpose: a dash routes a symbol to the crypto feed.
pub const DEFAULT_UNIVERSE: &[&str] = &[
    "SPY", "QQQ", "IWM", "DIA", "AAPL", "MSFT", "NVDA", "GOOGL", "AMZN", "META",
    "TSLA", "AVGO", "JPM", "V", "MA", "UNH", "HD", "PG", "XOM", "CVX",
    "LLY", "ABBV", "MRK", "COST", "WMT", "KO", "PEP", "BAC", "NFLX", "AMD",
    "CRM", "ORCL", "ADBE", "INTC", "QCOM", "TXN", "CAT", "BA", "GE", "DIS",
];

impl Default for IntelConfig {
    fn default() -> Self {
        Self {
            universe: DEFAULT_UNIVERSE.iter().map(|s| s.to_string()).collect(),
            gdelt_poll_secs: 900,
            regime_scan_secs: 1_800,
            enable_company: true,
            enable_regimes: true,
            enable_meridian: true,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct ServerConfig {
    pub host: String,
    pub port: u16,
}

impl Default for ServerConfig {
    fn default() -> Self {
        Self {
            host: "127.0.0.1".into(),
            port: 9601,
        }
    }
}

#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct Config {
    pub symbols: Vec<String>,
    pub feed: FeedConfig,
    pub risk: RiskConfig,
    pub paper: PaperConfig,
    pub ai: AiConfig,
    pub server: ServerConfig,
    pub intel: IntelConfig,
    /// Extra free-form knobs for strategies, keyed by strategy name.
    pub strategy_params: BTreeMap<String, BTreeMap<String, f64>>,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            symbols: vec![
                "BTC-USD".into(),
                "ETH-USD".into(),
                "SOL-USD".into(),
                "SPY".into(),
                "AAPL".into(),
                "NVDA".into(),
            ],
            feed: FeedConfig::default(),
            risk: RiskConfig::default(),
            paper: PaperConfig::default(),
            ai: AiConfig::default(),
            server: ServerConfig::default(),
            intel: IntelConfig::default(),
            strategy_params: BTreeMap::new(),
        }
    }
}

impl Config {
    pub fn secrets_path() -> Option<PathBuf> {
        dirs::home_dir().map(|h| h.join(".cortex").join("secrets.toml"))
    }

    /// defaults <- ~/.cortex/secrets.toml <- env overrides.
    pub fn load() -> Result<Self, CxError> {
        let mut cfg = match Self::secrets_path() {
            Some(path) if path.exists() => {
                let raw = std::fs::read_to_string(&path)
                    .map_err(|e| CxError::Config(format!("read secrets.toml: {e}")))?;
                toml::from_str::<Config>(&raw)
                    .map_err(|e| CxError::Config(format!("parse secrets.toml: {e}")))?
            }
            _ => Config::default(),
        };
        cfg.apply_env();
        cfg.validate()?;
        Ok(cfg)
    }

    pub fn apply_env(&mut self) {
        if let Ok(v) = std::env::var("ANTHROPIC_API_KEY") {
            if !v.is_empty() {
                self.ai.anthropic_api_key = Secret(v);
            }
        }
        if let Ok(v) = std::env::var("CORTEX_PORT") {
            if let Ok(p) = v.parse() {
                self.server.port = p;
            }
        }
        if let Ok(v) = std::env::var("CORTEX_SYMBOLS") {
            let syms: Vec<String> = v
                .split(',')
                .map(|s| s.trim().to_uppercase())
                .filter(|s| !s.is_empty())
                .collect();
            if !syms.is_empty() {
                self.symbols = syms;
            }
        }
        if let Ok(v) = std::env::var("CORTEX_FEED") {
            if !v.is_empty() {
                self.feed.primary = v;
            }
        }
        if let Ok(v) = std::env::var("CORTEX_LOCAL_LLM_URL") {
            self.ai.local_llm_url = v;
        }
    }

    pub fn validate(&self) -> Result<(), CxError> {
        if self.symbols.is_empty() {
            return Err(CxError::Config("no symbols configured".into()));
        }
        let r = &self.risk;
        for (name, v) in [
            ("max_position_pct", r.max_position_pct),
            ("price_collar_pct", r.price_collar_pct),
            ("max_daily_drawdown", r.max_daily_drawdown),
            ("max_total_drawdown", r.max_total_drawdown),
            ("caution_max_shrink", r.caution_max_shrink),
        ] {
            if !(v.is_finite() && (0.0..=1.0).contains(&v)) {
                return Err(CxError::Config(format!("risk.{name} must be in [0,1]")));
            }
        }
        if self.paper.starting_cash <= 0.0 {
            return Err(CxError::Config("paper.starting_cash must be > 0".into()));
        }
        if self.intel.gdelt_poll_secs < 300 {
            return Err(CxError::Config("intel.gdelt_poll_secs must be >= 300".into()));
        }
        if self.intel.regime_scan_secs < 300 {
            return Err(CxError::Config("intel.regime_scan_secs must be >= 300".into()));
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_valid() {
        Config::default().validate().unwrap();
    }

    #[test]
    fn secret_never_debugs_value() {
        let s = Secret("sk-super-secret".into());
        assert_eq!(format!("{s:?}"), "Secret(***)");
    }

    #[test]
    fn toml_partial_parse_keeps_defaults() {
        let cfg: Config = toml::from_str(
            r#"
            symbols = ["BTC-USD"]
            [risk]
            max_daily_trades = 7
            "#,
        )
        .unwrap();
        assert_eq!(cfg.symbols, vec!["BTC-USD"]);
        assert_eq!(cfg.risk.max_daily_trades, 7);
        assert!((cfg.risk.max_position_pct - 0.10).abs() < 1e-12);
    }
}
