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
