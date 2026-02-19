import Foundation

public enum AutonomyLevel: Int, CaseIterable, Identifiable {
    case fullManual = 0
    case suggestOnly = 1
    case semiAuto = 2
    case fullAuto = 3

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .fullManual: "Full Manual"
        case .suggestOnly: "Suggest Only"
        case .semiAuto: "Semi-Auto"
        case .fullAuto: "Full Auto"
        }
    }

    public var description: String {
        switch self {
        case .fullManual: "All trades require manual approval"
        case .suggestOnly: "System suggests, you approve"
        case .semiAuto: "Small trades auto-execute, large need approval"
        case .fullAuto: "Full autonomous trading"
        }
    }
}

@MainActor
@Observable
public final class SettingsStore {
    public var serverURL: String = "ws://127.0.0.1:8765/ws"
    public var autonomyLevel: AutonomyLevel = .suggestOnly
    public var maxNotional: Double = 500.0
    public var maxDailyLoss: Double = 1000.0
    public var maxDrawdownPct: Double = 7.0
    public var autoThreshold: Double = 250.0
    public var isDarkMode: Bool = true

    public init() {}

    public var isConnected: Bool { false } // Will be wired to WebSocketClient
}
