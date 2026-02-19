import Foundation

public struct ActivityEvent: Identifiable, Sendable {
    public let id: String
    public var eventType: String  // "order_submitted", "order_filled", "risk_breach", "kill_switch"
    public var message: String
    public var symbol: String
    public var timestamp: Date
    public var severity: Severity

    public enum Severity: String, Sendable {
        case info
        case warning
        case critical
    }

    public init(
        id: String,
        eventType: String,
        message: String,
        symbol: String = "",
        timestamp: Date = Date(),
        severity: Severity = .info
    ) {
        self.id = id
        self.eventType = eventType
        self.message = message
        self.symbol = symbol
        self.timestamp = timestamp
        self.severity = severity
    }
}

@MainActor
@Observable
public final class ActivityStore {
    public var events: [ActivityEvent] = []
    public var maxEvents: Int = 500

    public init() {}

    public func loadMockData() {
        let mockEvents: [(String, String, String, ActivityEvent.Severity)] = [
            ("order_filled", "AAPL BUY 3 @ $185.02 — filled", "AAPL", .info),
            ("signal_detected", "NVDA breakout signal detected by signal_hunter", "NVDA", .info),
            ("risk_check", "Pre-trade check passed for NVDA", "NVDA", .info),
            ("drawdown_update", "Daily drawdown: 2.1% (limit: 7%)", "", .info),
            ("order_filled", "NVDA BUY 1 @ $880.05 — filled", "NVDA", .info),
            ("volume_alert", "TSLA volume surge: 2.3x average", "TSLA", .warning),
            ("system_start", "CORTEX system initialized — 14 agents online", "", .info),
            ("order_filled", "SPY BUY 1 @ $510.00 — filled", "SPY", .info),
            ("wash_sale_check", "Wash sale check passed for AAPL", "AAPL", .info),
            ("risk_update", "Risk Guardian: All positions within limits", "", .info),
        ]
        for (i, (type, msg, sym, sev)) in mockEvents.enumerated() {
            append(ActivityEvent(
                id: "mock_evt_\(i)",
                eventType: type,
                message: msg,
                symbol: sym,
                timestamp: Date().addingTimeInterval(Double(-i * 180)),
                severity: sev
            ))
        }
    }

    public func append(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > maxEvents {
            events.removeLast()
        }
    }

    public var recentEvents: [ActivityEvent] {
        Array(events.prefix(100))
    }

    public var criticalEvents: [ActivityEvent] {
        events.filter { $0.severity == .critical }
    }
}
