//! # cx-core — the CORTEX X contract crate
//!
//! Every other crate in the engine depends on this one and ONLY this one for
//! shared vocabulary. Squadron crates never depend on each other; the [`bus::Bus`]
//! is the sole nervous system (carrying [`events::EngineEvent`]).
//!
//! Invariants enforced at this layer:
//! - Kill switch Phase 1 is synchronous and in-memory ([`kill::KillSwitch`]).
//! - All trading/market/AI-provider HTTP flows through the hardened
//!   [`egress`] chokepoint (exact-host allowlist, unchanged). The copilot's
//!   WEB RESEARCH rides a SEPARATE, secret-free channel ([`webfetch`]) that
//!   no market-data or order path ever touches.
//! - Secrets load from `~/.cortex/secrets.toml` / environment, never hardcoded.

pub mod autonomy;
pub mod bus;
pub mod command;
pub mod config;
pub mod egress;
pub mod error;
pub mod events;
pub mod ids;
pub mod kill;
pub mod portfolio;
pub mod store;
pub mod time;
pub mod types;
pub mod webfetch;

pub use bus::Bus;
pub use command::Command;
pub use config::Config;
pub use error::CxError;
pub use events::EngineEvent;
pub use kill::KillSwitch;
