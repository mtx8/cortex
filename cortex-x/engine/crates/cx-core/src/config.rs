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
    /// REST backfill of recent candles at startup. Must cover the equity
    /// extended-hours intraday windows (M5 5d = 960 bars, H1 3mo ≈ 1,055
    /// with includePrePost) — the store keeps up to 3,000 per series.
    pub backfill_bars: u32,
}

impl Default for FeedConfig {
    fn default() -> Self {
        Self {
            primary: "coinbase".into(),
            synthetic_fallback: true,
            backfill_bars: 1_200,
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
    /// ATR trailing protective exit: close an open position when price
    /// retraces this many ATRs from its high-water mark (reduce-only).
    pub trail_atr_mult: f64,
    /// Master switch for the ATR trailing protective exit.
    pub trail_enabled: bool,
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
            trail_atr_mult: 2.5,
            trail_enabled: true,
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

/// TWS / IB Gateway API ports. The two PAPER ports are the only safe
/// defaults; the two LIVE (real-money) ports are gated behind `allow_live`.
pub const IBKR_LIVE_PORTS: [u16; 2] = [7496, 4001];
pub const IBKR_PAPER_PORTS: [u16; 2] = [7497, 4002];

/// True when `port` is a known LIVE (real-money) TWS/Gateway API port. Any
/// other port (including the paper ports and non-standard ones) reads false —
/// only the two documented live ports arm the real-money gate.
pub fn is_ibkr_live_port(port: u16) -> bool {
    IBKR_LIVE_PORTS.contains(&port)
}

/// Live-trading broker routing. PAPER-FIRST: with the defaults (mode "paper",
/// a PAPER port, `allow_live` false) the engine never reaches a live account.
///
/// Reaching a real-money account requires TWO explicit gates:
/// 1. `mode = "ibkr"`, and
/// 2. a LIVE port (7496 TWS / 4001 Gateway) WITH `allow_live = true`.
///
/// A live port with `allow_live = false` is a hard [`Config`] error (and the
/// adapter refuses to connect) — never a silent live reach.
#[derive(Debug, Clone, Deserialize)]
#[serde(default)]
pub struct BrokerConfig {
    /// "paper" (default — the built-in paper exchange) or "ibkr".
    pub mode: String,
    /// The user's local TWS / IB Gateway host. Localhost by default: the
    /// IBKR socket is a direct localhost connection to the operator's own
    /// Gateway, NOT through the hardened HTTP egress.
    pub ibkr_host: String,
    /// TWS/Gateway API socket port. Default 7497 = TWS PAPER. Live ports
    /// (7496 TWS / 4001 Gateway) additionally require `allow_live`.
    pub ibkr_port: u16,
    /// API client id the adapter connects with.
    pub ibkr_client_id: i32,
    /// IBKR account id to trade (e.g. "DU1234567" paper / "U1234567" live).
    /// Held as a [`Secret`]: an account id is never logged (invariant).
    pub ibkr_account: Secret,
    /// Order routing venue. "SMART" = IBKR SmartRouting (default); a direct
    /// venue code ("ARCA", "ISLAND", "NYSE", "IEX", ...) routes for true DMA.
    pub ibkr_route: String,
    /// The real-money master switch. Must be `true` to connect on a LIVE port.
    pub allow_live: bool,
    /// LIVE hard limit: reject any single order whose notional exceeds this.
    pub max_live_order_notional: f64,
    /// LIVE hard limit: reject any order that would push a symbol's live
    /// position notional past this.
    pub max_live_position_notional: f64,
    /// LIVE hard limit: once the live realized day loss reaches this, HALT
    /// (cancel working orders + flatten, then block new orders for the day).
    pub max_live_daily_loss: f64,
}

impl Default for BrokerConfig {
    fn default() -> Self {
        Self {
            mode: "paper".into(),
            ibkr_host: "127.0.0.1".into(),
            ibkr_port: 7497, // TWS PAPER — never a live port by default
            ibkr_client_id: 11,
            ibkr_account: Secret::default(),
            ibkr_route: "SMART".into(),
            allow_live: false,
            max_live_order_notional: 2_000.0,
            max_live_position_notional: 5_000.0,
            max_live_daily_loss: 500.0,
        }
    }
}

impl BrokerConfig {
    /// True only when BOTH live gates are satisfied: a live port AND the
    /// operator's explicit `allow_live`. The adapter uses this to decide
    /// whether a connection is a real-money one.
    pub fn is_live(&self) -> bool {
        is_ibkr_live_port(self.ibkr_port) && self.allow_live
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
    /// AUTORESEARCH cadence: how often the engine replays bounded recipe
    /// experiments over stored history (paper-only, off the hot path).
    /// 0 disables the loop entirely; anything else must be >= 3600.
    pub autoresearch_secs: u64,
    /// Copilot WEB RESEARCH master switch: "search:" and live-info questions
    /// may fetch public web pages through the SEPARATE research channel
    /// (`cx_core::webfetch` — the hardened trading egress is untouched).
    pub enable_web_research: bool,
    /// Max outbound requests one research cycle may spend (the search page
    /// plus result-page fetches). Validated to [1, 32].
    pub web_budget_per_query: u32,
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
            autoresearch_secs: 21_600,
            enable_web_research: true,
            web_budget_per_query: crate::webfetch::DEFAULT_RESEARCH_BUDGET as u32,
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
    /// SCANNER recompute cadence (seconds, floor 60).
    pub scanner_secs: u64,
    /// NEWS poll cadence (seconds, floor 300).
    pub news_poll_secs: u64,
    pub enable_scanner: bool,
    pub enable_company: bool,
    pub enable_regimes: bool,
    pub enable_meridian: bool,
    pub enable_news: bool,
    /// Multi-source RSS/Atom + Google-News-relay layer inside NEWS (on top of
    /// GDELT). When false, NEWS runs GDELT + EDGAR only. Master `enable_news`
    /// still gates the whole poller.
    pub enable_news_rss: bool,
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
            scanner_secs: 300,
            news_poll_secs: 900,
            enable_scanner: true,
            enable_company: true,
            enable_regimes: true,
            enable_meridian: true,
            enable_news: true,
            enable_news_rss: true,
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
    /// Live-trading broker routing. Defaults to the paper exchange.
    pub broker: BrokerConfig,
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
            broker: BrokerConfig::default(),
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
        if !(r.trail_atr_mult.is_finite() && (0.5..=10.0).contains(&r.trail_atr_mult)) {
            return Err(CxError::Config(
                "risk.trail_atr_mult must be in [0.5, 10]".into(),
            ));
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
        if self.intel.scanner_secs < 60 {
            return Err(CxError::Config("intel.scanner_secs must be >= 60".into()));
        }
        if self.intel.news_poll_secs < 300 {
            return Err(CxError::Config("intel.news_poll_secs must be >= 300".into()));
        }
        if self.ai.autoresearch_secs != 0 && self.ai.autoresearch_secs < 3_600 {
            return Err(CxError::Config(
                "ai.autoresearch_secs must be 0 (disabled) or >= 3600".into(),
            ));
        }
        if !(1..=32).contains(&self.ai.web_budget_per_query) {
            return Err(CxError::Config(
                "ai.web_budget_per_query must be in [1, 32]".into(),
            ));
        }
        self.broker.validate()?;
        Ok(())
    }
}

impl BrokerConfig {
    /// Fails closed on any live-safety misconfiguration. Invariants:
    /// a LIVE port ALWAYS requires `allow_live` (else refuse); an IBKR session
    /// ALWAYS requires an account id (the daily-loss halt subscribes to it); a
    /// live-LOOKING account (not `DU...`) requires `allow_live` regardless of
    /// port; and every LIVE hard limit must be a finite, strictly positive
    /// number so the real-money guard can never be defeated by a NaN / 0 /
    /// negative cap.
    pub fn validate(&self) -> Result<(), CxError> {
        match self.mode.as_str() {
            "paper" | "ibkr" => {}
            other => {
                return Err(CxError::Config(format!(
                    "broker.mode must be \"paper\" or \"ibkr\", got {other:?}"
                )))
            }
        }
        // The real-money gate: a LIVE port without `allow_live` is a hard
        // error at load, regardless of mode — a live port must never sit in
        // the config as a one-typo-from-live foot-gun.
        if is_ibkr_live_port(self.ibkr_port) && !self.allow_live {
            return Err(CxError::Config(format!(
                "broker.ibkr_port {} is a LIVE (real-money) port; set broker.allow_live = true \
                 to trade live, or use a PAPER port (7497 TWS / 4002 Gateway)",
                self.ibkr_port
            )));
        }
        // An IBKR session (paper OR live) REQUIRES an account id: the
        // max_live_daily_loss circuit breaker subscribes to that account's
        // PnL, and without it the daily-loss halt is silently unarmed while
        // orders still route (a single-account login infers the account). Fail
        // closed at load rather than trade live with the breaker disarmed.
        if self.mode == "ibkr" {
            let acct = self.ibkr_account.expose().trim();
            if acct.is_empty() {
                return Err(CxError::Config(
                    "broker.ibkr_account is required when broker.mode = \"ibkr\" — the \
                     max_live_daily_loss circuit breaker subscribes to it; set your paper \
                     (DU...) or live (U...) account id"
                        .into(),
                ));
            }
            // Account-identity gate (defense in depth with the port gate): a
            // live-LOOKING account (paper accounts start "DU"; live start "U")
            // reachable without `allow_live` is a real-money foot-gun even on a
            // paper port (a live TWS set to 7497). Make the gate depend on the
            // account identity, not just a mutable port number.
            if !acct.starts_with("DU") && !self.allow_live {
                // Never echo the account id itself (invariant: it is never
                // logged, and a Config error is surfaced/logged).
                return Err(CxError::Config(
                    "broker.ibkr_account looks like a LIVE account (does not start with \"DU\"); \
                     set broker.allow_live = true to trade real money, or use a paper (DU...) \
                     account"
                        .into(),
                ));
            }
        }
        for (name, v) in [
            ("max_live_order_notional", self.max_live_order_notional),
            ("max_live_position_notional", self.max_live_position_notional),
            ("max_live_daily_loss", self.max_live_daily_loss),
        ] {
            if !(v.is_finite() && v > 0.0) {
                return Err(CxError::Config(format!(
                    "broker.{name} must be a finite number > 0"
                )));
            }
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

    /// The equity backfill promises "three months of hourlies, five days of
    /// 5-minute bars" WITH extended hours: M5 = 192 bars/day -> 960 per 5d,
    /// H1 3mo ≈ 1,055. A cap below those silently truncates chart depth.
    #[test]
    fn backfill_default_covers_prepost_intraday_windows() {
        assert!(FeedConfig::default().backfill_bars >= 1_100);
    }

    #[test]
    fn secret_never_debugs_value() {
        let s = Secret("sk-super-secret".into());
        assert_eq!(format!("{s:?}"), "Secret(***)");
    }

    #[test]
    fn trail_atr_mult_bounds_enforced() {
        let mut cfg = Config::default();
        cfg.risk.trail_atr_mult = 0.49;
        assert!(cfg.validate().is_err());
        cfg.risk.trail_atr_mult = 10.01;
        assert!(cfg.validate().is_err());
        cfg.risk.trail_atr_mult = f64::NAN;
        assert!(cfg.validate().is_err());
        cfg.risk.trail_atr_mult = f64::INFINITY;
        assert!(cfg.validate().is_err());
        cfg.risk.trail_atr_mult = 0.5;
        assert!(cfg.validate().is_ok());
        cfg.risk.trail_atr_mult = 10.0;
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn autoresearch_cadence_bounds_enforced() {
        let mut cfg = Config::default();
        cfg.ai.autoresearch_secs = 0; // disabled is valid
        assert!(cfg.validate().is_ok());
        cfg.ai.autoresearch_secs = 3_599; // below the floor
        assert!(cfg.validate().is_err());
        cfg.ai.autoresearch_secs = 3_600; // at the floor
        assert!(cfg.validate().is_ok());
        cfg.ai.autoresearch_secs = 21_600; // the default
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn web_research_defaults_on_and_budget_bounds_enforced() {
        let cfg = Config::default();
        assert!(cfg.ai.enable_web_research, "web research must default ON");
        assert_eq!(cfg.ai.web_budget_per_query, 6);
        assert!(cfg.validate().is_ok());

        let mut cfg = Config::default();
        cfg.ai.web_budget_per_query = 0; // a zero budget is a misconfig, not "off"
        assert!(cfg.validate().is_err());
        cfg.ai.web_budget_per_query = 33; // runaway fan-out
        assert!(cfg.validate().is_err());
        cfg.ai.web_budget_per_query = 1;
        assert!(cfg.validate().is_ok());
        cfg.ai.web_budget_per_query = 32;
        assert!(cfg.validate().is_ok());
        // Disabling the feature doesn't excuse an invalid budget.
        cfg.ai.enable_web_research = false;
        cfg.ai.web_budget_per_query = 0;
        assert!(cfg.validate().is_err());
    }

    #[test]
    fn news_defaults_and_cadence_floor() {
        let cfg = Config::default();
        assert!(cfg.intel.enable_news, "news must default on");
        assert!(cfg.intel.enable_news_rss, "rss/atom news layer must default on");
        assert_eq!(cfg.intel.news_poll_secs, 900);

        let mut cfg = Config::default();
        cfg.intel.news_poll_secs = 299; // below the floor
        assert!(cfg.validate().is_err());
        cfg.intel.news_poll_secs = 300; // at the floor
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn intel_toml_without_rss_flag_keeps_it_on() {
        // Older config files predate `enable_news_rss`; the container-level
        // serde(default) must fill it from IntelConfig::default() (on).
        let cfg: Config = toml::from_str(
            r#"
            symbols = ["BTC-USD"]
            [intel]
            news_poll_secs = 600
            "#,
        )
        .unwrap();
        assert_eq!(cfg.intel.news_poll_secs, 600);
        assert!(cfg.intel.enable_news_rss, "missing flag must default on");
    }

    #[test]
    fn broker_defaults_are_paper_and_safe() {
        let b = BrokerConfig::default();
        assert_eq!(b.mode, "paper");
        assert_eq!(b.ibkr_host, "127.0.0.1");
        assert_eq!(b.ibkr_port, 7497); // TWS PAPER
        assert!(!is_ibkr_live_port(b.ibkr_port), "default port must be paper");
        assert!(!b.allow_live);
        assert!(!b.is_live(), "the default config must never be a live reach");
        assert_eq!(b.ibkr_route, "SMART");
        assert_eq!(b.max_live_order_notional, 2_000.0);
        assert_eq!(b.max_live_position_notional, 5_000.0);
        assert_eq!(b.max_live_daily_loss, 500.0);
        Config::default().validate().unwrap();
    }

    #[test]
    fn live_port_requires_allow_live() {
        // Both live ports are rejected without the explicit allow_live gate.
        for port in IBKR_LIVE_PORTS {
            let mut cfg = Config::default();
            cfg.broker.ibkr_port = port;
            cfg.broker.allow_live = false;
            let err = cfg.validate().unwrap_err().to_string();
            assert!(err.contains("LIVE"), "expected a loud live-port refusal: {err}");
            assert!(!cfg.broker.is_live());

            // Same live port WITH allow_live now validates and reads live.
            cfg.broker.allow_live = true;
            assert!(cfg.validate().is_ok());
            assert!(cfg.broker.is_live());
        }
    }

    #[test]
    fn paper_ports_never_require_allow_live() {
        for port in IBKR_PAPER_PORTS {
            let mut cfg = Config::default();
            cfg.broker.ibkr_port = port;
            cfg.broker.allow_live = false;
            assert!(cfg.validate().is_ok(), "paper port {port} must not gate");
            assert!(!cfg.broker.is_live());
        }
    }

    #[test]
    fn broker_mode_and_limits_are_validated() {
        let mut cfg = Config::default();
        cfg.broker.mode = "live".into(); // not a valid mode string
        assert!(cfg.validate().is_err());
        cfg.broker.mode = "ibkr".into();
        // ibkr mode requires an account id; a paper (DU...) one validates.
        cfg.broker.ibkr_account = Secret("DU1234567".into());
        assert!(cfg.validate().is_ok());

        for bad in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            let mut cfg = Config::default();
            cfg.broker.max_live_order_notional = bad;
            assert!(cfg.validate().is_err(), "order notional {bad} must reject");
            let mut cfg = Config::default();
            cfg.broker.max_live_position_notional = bad;
            assert!(cfg.validate().is_err(), "position notional {bad} must reject");
            let mut cfg = Config::default();
            cfg.broker.max_live_daily_loss = bad;
            assert!(cfg.validate().is_err(), "daily loss {bad} must reject");
        }
    }

    #[test]
    fn broker_toml_without_section_defaults_to_paper() {
        // An older config file predates [broker]; the container-level
        // serde(default) fills it from BrokerConfig::default() (paper).
        let cfg: Config = toml::from_str(
            r#"
            symbols = ["BTC-USD"]
            "#,
        )
        .unwrap();
        assert_eq!(cfg.broker.mode, "paper");
        assert_eq!(cfg.broker.ibkr_port, 7497);
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn broker_account_id_never_debug_prints() {
        // Invariant: account ids are never logged. The Secret wrapper masks
        // it even if the whole BrokerConfig is Debug-formatted.
        let cfg: Config = toml::from_str(
            r#"
            symbols = ["BTC-USD"]
            [broker]
            ibkr_account = "DU1234567"
            "#,
        )
        .unwrap();
        assert_eq!(cfg.broker.ibkr_account.expose(), "DU1234567");
        let dump = format!("{:?}", cfg.broker);
        assert!(!dump.contains("DU1234567"), "account id leaked into Debug: {dump}");
        assert!(dump.contains("Secret(***)"));
    }

    #[test]
    fn ibkr_mode_requires_an_account() {
        // The daily-loss circuit breaker subscribes to the account's PnL; with
        // no account it is silently unarmed, so mode=="ibkr" refuses at load.
        let mut cfg = Config::default();
        cfg.broker.mode = "ibkr".into();
        assert!(cfg.broker.ibkr_account.is_empty());
        let err = cfg.validate().unwrap_err().to_string();
        assert!(err.contains("ibkr_account"), "expected an account requirement: {err}");

        // A paper account id satisfies it.
        cfg.broker.ibkr_account = Secret("DU1234567".into());
        assert!(cfg.validate().is_ok());

        // Paper mode never requires an account.
        let mut cfg = Config::default();
        cfg.broker.mode = "paper".into();
        assert!(cfg.broker.ibkr_account.is_empty());
        assert!(cfg.validate().is_ok());
    }

    #[test]
    fn live_looking_account_requires_allow_live() {
        // A live-looking account (no "DU" prefix) on a PAPER port, without
        // allow_live, is refused — the real-money gate depends on the account
        // identity, not just a mutable port number.
        let mut cfg = Config::default();
        cfg.broker.mode = "ibkr".into();
        cfg.broker.ibkr_port = 7497; // paper port
        cfg.broker.allow_live = false;
        cfg.broker.ibkr_account = Secret("U1234567".into()); // looks live
        let err = cfg.validate().unwrap_err().to_string();
        assert!(err.contains("LIVE account"), "expected an identity refusal: {err}");
        assert!(!err.contains("U1234567"), "the account id must never appear in the error");

        // The same live account WITH allow_live validates (operator opted in).
        cfg.broker.allow_live = true;
        assert!(cfg.validate().is_ok());

        // A paper (DU...) account never trips the identity gate.
        let mut cfg = Config::default();
        cfg.broker.mode = "ibkr".into();
        cfg.broker.ibkr_account = Secret("DU7654321".into());
        assert!(cfg.validate().is_ok());
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
