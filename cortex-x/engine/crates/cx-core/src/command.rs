//! Commands flow one way: UI/operator -> server -> engine. They are the only
//! way anything outside the engine can request action.

use serde::{Deserialize, Serialize};

use crate::config::{BrokerConfig, Secret};
use crate::types::{AutonomyLevel, Interval, OrderType, Side};

/// Default history interval for an old client that omits the field (wire compat).
fn default_history_interval() -> Interval {
    Interval::D1
}

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
    /// Fetch history for a symbol at a given interval (D1 for daily; 1m/5m/15m/1h
    /// intraday, which is how equities get intraday bars without a live feed).
    /// Answered via `EngineEvent::History`.
    GetHistory {
        symbol: String,
        /// WIRE COMPAT: additive `#[serde(default)]` field — an old client that
        /// omits it requests D1, exactly as before.
        #[serde(default = "default_history_interval")]
        interval: Interval,
    },
    /// Start streaming LEVEL 2 market depth (and the Time & Sales tape) for the
    /// symbol the client is actively viewing. The engine streams depth for at
    /// most ONE symbol at a time to bound bandwidth: subscribing a new symbol
    /// implicitly unsubscribes the previous one. Answered by a stream of
    /// `EngineEvent::Depth` (+ `EngineEvent::Tape`); the connect/sync snapshot
    /// also carries the latest `BookDepth` for the subscribed symbol.
    SubscribeDepth {
        symbol: String,
    },
    /// Stop streaming depth for `symbol`. Ignored when it does not match the
    /// currently-subscribed symbol (a stale unsubscribe never clears a newer
    /// subscription).
    UnsubscribeDepth {
        symbol: String,
    },
    /// Runtime broker (re)configuration from the app's Settings: switch the
    /// active order sink between the paper exchange and IBKR, and set the IBKR
    /// connection + LIVE hard limits, WITHOUT restarting the engine. The engine
    /// converts this to the same [`BrokerConfig`] a `[broker]` config load uses
    /// ([`Command::to_broker_config`]) and re-runs the IDENTICAL safety gates
    /// (`BrokerConfig::validate`): a LIVE port refuses without `allow_live`, an
    /// ibkr session needs an account, a live-looking account needs `allow_live`,
    /// and every live limit must be finite > 0. On success it rebuilds and swaps
    /// the sink and publishes an updated `EngineEvent::BrokerStatus`; on any
    /// failure it stays on the previous safe broker with a critical thought
    /// (never silently live, never a crash).
    ///
    /// SECURITY: no password ever transits this command. IBKR API authentication
    /// happens entirely in the operator's own IB Gateway / TWS login — CORTEX
    /// only opens a localhost socket to it. `ibkr_account` is an id, not a
    /// credential; it is wrapped in [`Secret`] on conversion so it is never
    /// logged and appears only MASKED in status.
    SetBrokerConfig {
        /// "paper" (the built-in exchange) or "ibkr".
        mode: String,
        /// Local IB Gateway / TWS host (localhost by default).
        ibkr_host: String,
        /// TWS/Gateway API socket port (7497 TWS paper / 4002 gw paper; the
        /// live ports 7496/4001 additionally require `allow_live`).
        ibkr_port: u16,
        /// API client id the adapter connects with.
        ibkr_client_id: i32,
        /// IBKR account id (e.g. "DU1234567" paper / "U1234567" live). NEVER a
        /// credential and NEVER logged — masked in status via `mask_account`.
        ibkr_account: String,
        /// Order routing venue ("SMART" or a direct venue code for DMA).
        ibkr_route: String,
        /// The real-money master switch (required for a live port/account).
        allow_live: bool,
        /// LIVE hard limit: reject any single order over this notional.
        max_live_order_notional: f64,
        /// LIVE hard limit: reject any order pushing a symbol's live position
        /// notional past this.
        max_live_position_notional: f64,
        /// LIVE hard limit: halt (cancel + flatten) once the live day loss
        /// reaches this.
        max_live_daily_loss: f64,
    },
}

impl Command {
    /// Convert a [`Command::SetBrokerConfig`] into the engine's [`BrokerConfig`]
    /// so a runtime reconfigure reuses the EXACT same type — and therefore the
    /// EXACT same live-safety gates as a `[broker]` config loaded from disk. The
    /// account id is wrapped in [`Secret`] so it inherits the never-logged
    /// invariant. Returns `None` for any other command. The caller MUST still
    /// call [`BrokerConfig::validate`] on the result before acting on it — this
    /// only maps the fields, it does not gate them.
    pub fn to_broker_config(&self) -> Option<BrokerConfig> {
        match self {
            Command::SetBrokerConfig {
                mode,
                ibkr_host,
                ibkr_port,
                ibkr_client_id,
                ibkr_account,
                ibkr_route,
                allow_live,
                max_live_order_notional,
                max_live_position_notional,
                max_live_daily_loss,
            } => Some(BrokerConfig {
                mode: mode.clone(),
                ibkr_host: ibkr_host.clone(),
                ibkr_port: *ibkr_port,
                ibkr_client_id: *ibkr_client_id,
                ibkr_account: Secret(ibkr_account.clone()),
                ibkr_route: ibkr_route.clone(),
                allow_live: *allow_live,
                max_live_order_notional: *max_live_order_notional,
                max_live_position_notional: *max_live_position_notional,
                max_live_daily_loss: *max_live_daily_loss,
            }),
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn get_history_interval_is_additive_and_defaults_to_d1() {
        // An old client omits `interval` — the frame must still decode as a D1
        // request, exactly as before.
        let legacy = r#"{"cmd":"get_history","symbol":"TSLA"}"#;
        assert_eq!(
            serde_json::from_str::<Command>(legacy).unwrap(),
            Command::GetHistory { symbol: "TSLA".into(), interval: Interval::D1 }
        );
        // A new client requests an intraday interval explicitly (snake_case wire).
        let intraday = r#"{"cmd":"get_history","symbol":"TSLA","interval":"m5"}"#;
        assert_eq!(
            serde_json::from_str::<Command>(intraday).unwrap(),
            Command::GetHistory { symbol: "TSLA".into(), interval: Interval::M5 }
        );
    }

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

    #[test]
    fn subscribe_depth_decodes_from_the_wire_contract() {
        // The exact client -> server frames the Swift mirror sends.
        let sub = r#"{"cmd":"subscribe_depth","symbol":"BTC-USD"}"#;
        assert_eq!(
            serde_json::from_str::<Command>(sub).unwrap(),
            Command::SubscribeDepth { symbol: "BTC-USD".into() }
        );
        let unsub = r#"{"cmd":"unsubscribe_depth","symbol":"BTC-USD"}"#;
        assert_eq!(
            serde_json::from_str::<Command>(unsub).unwrap(),
            Command::UnsubscribeDepth { symbol: "BTC-USD".into() }
        );
        // Round-trips with the `cmd` tag and snake_case fields; neither yields
        // a BrokerConfig.
        let cmd = Command::SubscribeDepth { symbol: "ETH-USD".into() };
        let json = serde_json::to_string(&cmd).unwrap();
        assert!(json.contains("\"cmd\":\"subscribe_depth\""));
        assert_eq!(serde_json::from_str::<Command>(&json).unwrap(), cmd);
        assert!(cmd.to_broker_config().is_none());
        assert!(Command::UnsubscribeDepth { symbol: "ETH-USD".into() }
            .to_broker_config()
            .is_none());
    }

    #[test]
    fn set_broker_config_decodes_from_the_wire_contract() {
        // The EXACT client -> server frame the Swift mirror sends, additive
        // under the `cmd` tag with snake_case fields.
        let raw = r#"{"cmd":"set_broker_config","mode":"paper","ibkr_host":"127.0.0.1",
            "ibkr_port":7497,"ibkr_client_id":11,"ibkr_account":"","ibkr_route":"SMART",
            "allow_live":false,"max_live_order_notional":2000.0,
            "max_live_position_notional":5000.0,"max_live_daily_loss":500.0}"#;
        let cmd: Command = serde_json::from_str(raw).unwrap();
        assert_eq!(
            cmd,
            Command::SetBrokerConfig {
                mode: "paper".into(),
                ibkr_host: "127.0.0.1".into(),
                ibkr_port: 7497,
                ibkr_client_id: 11,
                ibkr_account: String::new(),
                ibkr_route: "SMART".into(),
                allow_live: false,
                max_live_order_notional: 2_000.0,
                max_live_position_notional: 5_000.0,
                max_live_daily_loss: 500.0,
            }
        );
        // Round-trips with the tag + snake_case field names.
        let json = serde_json::to_string(&cmd).unwrap();
        assert!(json.contains("\"cmd\":\"set_broker_config\""));
        assert!(json.contains("\"ibkr_port\":7497"));
        assert!(json.contains("\"max_live_daily_loss\":500.0"));
        let back: Command = serde_json::from_str(&json).unwrap();
        assert_eq!(back, cmd);
    }

    /// Helper: a `SetBrokerConfig` command with sane paper defaults, overridable
    /// per test. Mirrors `BrokerConfig::default()` so the base always validates.
    fn set_broker(mut mutate: impl FnMut(&mut Command)) -> Command {
        let mut cmd = Command::SetBrokerConfig {
            mode: "paper".into(),
            ibkr_host: "127.0.0.1".into(),
            ibkr_port: 7497,
            ibkr_client_id: 11,
            ibkr_account: String::new(),
            ibkr_route: "SMART".into(),
            allow_live: false,
            max_live_order_notional: 2_000.0,
            max_live_position_notional: 5_000.0,
            max_live_daily_loss: 500.0,
        };
        mutate(&mut cmd);
        cmd
    }

    #[test]
    fn set_broker_config_converts_to_broker_config_and_validates() {
        // The paper default converts and passes the SAME gate as disk config.
        let cmd = set_broker(|_| {});
        let cfg = cmd.to_broker_config().expect("SetBrokerConfig converts");
        assert_eq!(cfg.mode, "paper");
        assert_eq!(cfg.ibkr_port, 7497);
        assert!(cfg.validate().is_ok());
        // Non-broker commands never yield a BrokerConfig.
        assert!(Command::FlattenAll { reason: "x".into() }
            .to_broker_config()
            .is_none());
    }

    #[test]
    fn set_broker_config_reuses_the_live_port_gate() {
        // A LIVE port without allow_live is refused by the EXACT same
        // BrokerConfig::validate gate a disk config faces — never bypassed by
        // the runtime command path. (The gate fires regardless of mode.)
        for port in [7496u16, 4001] {
            let cmd = set_broker(|c| {
                if let Command::SetBrokerConfig { ibkr_port, allow_live, .. } = c {
                    *ibkr_port = port;
                    *allow_live = false;
                }
            });
            let err = cmd
                .to_broker_config()
                .unwrap()
                .validate()
                .unwrap_err()
                .to_string();
            assert!(err.contains("LIVE"), "live port must refuse without allow_live: {err}");

            // The same live port WITH allow_live (+ a live account id) validates.
            let cmd = set_broker(|c| {
                if let Command::SetBrokerConfig {
                    mode, ibkr_port, allow_live, ibkr_account, ..
                } = c
                {
                    *mode = "ibkr".into();
                    *ibkr_port = port;
                    *allow_live = true;
                    *ibkr_account = "U1234567".into();
                }
            });
            assert!(cmd.to_broker_config().unwrap().validate().is_ok());
        }
    }

    #[test]
    fn set_broker_config_reuses_the_live_limit_gate() {
        // Every live hard limit must be finite > 0 — the runtime path re-runs
        // the identical NaN/0/negative rejection the guard depends on.
        for bad in [0.0, -1.0, f64::NAN, f64::INFINITY] {
            for field in 0..3 {
                let cmd = set_broker(|c| {
                    if let Command::SetBrokerConfig {
                        max_live_order_notional,
                        max_live_position_notional,
                        max_live_daily_loss,
                        ..
                    } = c
                    {
                        match field {
                            0 => *max_live_order_notional = bad,
                            1 => *max_live_position_notional = bad,
                            _ => *max_live_daily_loss = bad,
                        }
                    }
                });
                assert!(
                    cmd.to_broker_config().unwrap().validate().is_err(),
                    "limit field {field} = {bad} must reject"
                );
            }
        }
    }

    #[test]
    fn set_broker_config_masks_the_account_on_conversion() {
        // The raw command carries a plain-string account (wire necessity), but
        // the moment it becomes a BrokerConfig it is a Secret — so a Debug dump
        // of the converted config never leaks the id (never-logged invariant).
        let cmd = set_broker(|c| {
            if let Command::SetBrokerConfig { mode, ibkr_account, .. } = c {
                *mode = "ibkr".into();
                *ibkr_account = "DU1234567".into();
            }
        });
        let cfg = cmd.to_broker_config().unwrap();
        assert_eq!(cfg.ibkr_account.expose(), "DU1234567");
        let dump = format!("{cfg:?}");
        assert!(!dump.contains("DU1234567"), "account leaked into Debug: {dump}");
        assert!(dump.contains("Secret(***)"));
    }
}
