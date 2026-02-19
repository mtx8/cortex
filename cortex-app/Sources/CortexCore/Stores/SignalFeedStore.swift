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

    public func loadMockData() {
        let mockSignals: [(String, String, String, String, String)] = [
            ("alpha.entry_signal", "signal_hunter", "alpha", "NVDA", "Breakout above resistance"),
            ("alpha.volume_surge", "volume_profiler", "alpha", "AAPL", "Volume 1.8x average"),
            ("delta.catalyst_detected", "news_catalyst", "delta", "MSFT", "Earnings beat estimates"),
            ("echo.position_size", "position_sizer", "echo", "NVDA", "Sized: 1 share @ $892"),
            ("alpha.entry_signal", "signal_hunter", "alpha", "META", "RSI bounce from 30"),
            ("echo.drawdown_warning", "drawdown_shield", "echo", "", "Daily drawdown: 2.1%"),
            ("bravo.order_submitted", "order_sniper", "bravo", "AAPL", "BUY 3 @ $185.00"),
            ("bravo.order_filled", "order_sniper", "bravo", "AAPL", "Filled 3 @ $185.02"),
            ("charlie.sweep_detected", "flow_intelligence", "charlie", "NVDA", "Large call sweep $900C"),
            ("alpha.gap_detected", "gap_scanner", "alpha", "TSLA", "Gap down -3.1%"),
        ]
        for (i, (type, agent, squad, sym, _)) in mockSignals.enumerated() {
            let event = SignalEvent(
                id: "mock_sig_\(i)",
                signalType: type,
                sourceAgent: agent,
                sourceSquadron: squad,
                symbol: sym,
                timestamp: Date().addingTimeInterval(Double(-i * 120))
            )
            append(event)
        }
    }

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
