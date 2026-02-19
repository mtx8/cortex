import Foundation

public struct SignalEvent: Identifiable, Sendable {
    public let id: String
    public var signalType: String
    public var sourceAgent: String
    public var sourceSquadron: String
    public var symbol: String
    public var timestamp: Date
    public var payload: [String: String]

    public init(
        id: String,
        signalType: String,
        sourceAgent: String,
        sourceSquadron: String,
        symbol: String = "",
        timestamp: Date = Date(),
        payload: [String: String] = [:]
    ) {
        self.id = id
        self.signalType = signalType
        self.sourceAgent = sourceAgent
        self.sourceSquadron = sourceSquadron
        self.symbol = symbol
        self.timestamp = timestamp
        self.payload = payload
    }
}

@MainActor
@Observable
public final class SignalFeedStore {
    public var signals: [SignalEvent] = []
    public var maxSignals: Int = 200

    public init() {}

    public func append(_ event: SignalEvent) {
        signals.insert(event, at: 0)
        if signals.count > maxSignals {
            signals.removeLast()
        }
    }

    public func clear() {
        signals.removeAll()
    }

    public var recentSignals: [SignalEvent] {
        Array(signals.prefix(50))
    }
}
