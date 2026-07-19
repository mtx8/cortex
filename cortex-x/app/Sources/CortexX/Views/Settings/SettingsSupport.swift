// Settings support — pure, testable, NaN-safe. The operator's persisted broker
// preferences (BrokerSettings), the IBKR paper/live port classification, the
// allow-live safety gating that decides when a config may be saved / will be
// refused, and the UserDefaults persistence. Nothing here touches SwiftUI —
// every decision is plain data so the SETTINGS view stays declarative and the
// safety rules stay unit-tested. Design law: the app can never arm itself into
// a real-money posture off anything but an explicit, acknowledged opt-in.

import Foundation

// MARK: - IBKR ports

/// TWS / IB Gateway API socket ports. The two PAPER ports are the only safe
/// defaults; the two LIVE (real-money) ports are gated behind allow_live. This
/// mirrors the engine `IBKR_LIVE_PORTS` / `IBKR_PAPER_PORTS` constants exactly.
enum BrokerLivePorts {
    static let live: Set<Int> = [7496, 4001]
    static let paper: Set<Int> = [7497, 4002]

    /// True only for a known LIVE (real-money) port — every other port
    /// (paper ports and non-standard ones) reads false, matching the engine.
    static func isLivePort(_ port: Int) -> Bool { live.contains(port) }

    /// A human note for the port control so a live port can never be mistaken
    /// for a paper one at a glance.
    static func note(for port: Int) -> String {
        switch port {
        case 7497: "TWS paper"
        case 4002: "Gateway paper"
        case 7496: "TWS LIVE — real money"
        case 4001: "Gateway LIVE — real money"
        default: "non-standard port"
        }
    }
}

// MARK: - Persisted broker preferences

/// The operator-set broker preferences, persisted locally and pushed to the
/// engine as a `set_broker_config` command. Field defaults mirror the engine
/// `BrokerConfig` defaults (paper-first, a PAPER port, allow_live off), so a
/// fresh install is the safe internal simulator until the operator changes it.
/// This is only a convenience mirror: it is NEVER auto-applied on launch — the
/// engine owns its own `[broker]` config, and pushing this requires an explicit
/// "Apply & Connect" in SETTINGS.
struct BrokerSettings: Codable, Equatable {
    var mode: BrokerConfigMode = .paper
    var ibkrHost: String = "127.0.0.1"
    var ibkrPort: Int = 7497 // TWS paper — never a live port by default
    var ibkrClientId: Int = 11
    var ibkrAccount: String = "" // "DU..." paper / "U..." live — display only
    var ibkrRoute: String = "SMART"
    var allowLive: Bool = false
    var maxLiveOrderNotional: Double = 2_000
    var maxLivePositionNotional: Double = 5_000
    var maxLiveDailyLoss: Double = 500

    static let `default` = BrokerSettings()
}

// MARK: - Allow-live gating (the safety core)

/// The decision the SETTINGS form makes about a draft broker config: whether it
/// reaches real money, whether the engine will refuse it, whether its live
/// hard-limits are usable, whether the operator still owes a real-money
/// acknowledgement, and — the bottom line — whether "Apply & Connect" may fire.
struct BrokerConfigGate: Equatable {
    /// This config, if accepted, reaches a real-money account (IBKR + a live
    /// port + allow_live). The single truth the loud UI keys off.
    var isLiveConfig: Bool
    /// A live port selected while allow_live is OFF — the engine treats this as
    /// a hard config error and REFUSES it, staying on the previous safe broker.
    /// Surfaced as an inline warning; it never silently reaches live.
    var refusedByEngine: Bool
    /// Any LIVE hard limit is not finite / not strictly positive — the engine
    /// rejects it (a NaN/0/negative cap could otherwise defeat the guard).
    var invalidLimits: Bool
    /// allow_live has been turned on but the real-money confirmation has not
    /// yet been acknowledged — apply is blocked until it is.
    var needsLiveConfirm: Bool
    /// The bottom line: may "Apply & Connect" proceed?
    var canApply: Bool
}

enum BrokerConfigCheck {
    /// A LIVE hard limit is only usable when finite and strictly positive —
    /// matches the engine's `max_live_*` validation exactly.
    static func isUsableLimit(_ v: Double) -> Bool { v.isFinite && v > 0 }

    /// Decide the gate for a draft config and the operator's current
    /// acknowledgement. `confirmedLive` is the SETTINGS "I understand — real
    /// money" acknowledgement; without it an allow_live config can never save.
    static func gate(_ s: BrokerSettings, confirmedLive: Bool) -> BrokerConfigGate {
        let ibkr = s.mode == .ibkr
        let livePort = BrokerLivePorts.isLivePort(s.ibkrPort)

        let isLiveConfig = ibkr && livePort && s.allowLive
        // A live port without allow_live is the engine's hard error — only
        // meaningful in IBKR mode (paper mode never opens a socket).
        let refusedByEngine = ibkr && livePort && !s.allowLive
        // The engine validates the limits regardless of mode, so an unusable
        // cap fails closed everywhere.
        let invalidLimits = !isUsableLimit(s.maxLiveOrderNotional)
            || !isUsableLimit(s.maxLivePositionNotional)
            || !isUsableLimit(s.maxLiveDailyLoss)
        // Turning allow_live on is a real-money arming action: it must be
        // acknowledged before it can be saved, no matter the port.
        let needsLiveConfirm = s.allowLive && !confirmedLive

        // Block apply only on things the app itself must guard: an unacknowledged
        // real-money arm, and limits the engine would reject. A live-port-without-
        // allow config is deliberately NOT blocked here — it is allowed to reach
        // the engine, which refuses it and stays on the previous safe broker
        // (the designed, single-source-of-truth failure path); the inline warning
        // tells the operator that is what will happen.
        let canApply = !needsLiveConfirm && !invalidLimits

        return BrokerConfigGate(
            isLiveConfig: isLiveConfig,
            refusedByEngine: refusedByEngine,
            invalidLimits: invalidLimits,
            needsLiveConfirm: needsLiveConfirm,
            canApply: canApply
        )
    }
}

// MARK: - Persistence

/// Local persistence for `BrokerSettings` (JSON in UserDefaults). Injectable
/// defaults so the roundtrip is unit-tested against a throwaway suite. A
/// missing / corrupt record decodes to the safe `.default` (paper), never a
/// throw — the SETTINGS form must always open on a valid, safe config.
enum BrokerSettingsStore {
    static let key = "cortex.broker.settings.v1"

    static func load(_ defaults: UserDefaults = .standard) -> BrokerSettings {
        guard let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode(BrokerSettings.self, from: data)
        else { return .default }
        return decoded
    }

    static func save(_ settings: BrokerSettings, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
    }
}
