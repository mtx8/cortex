import Foundation

/// Store for ticker symbol search with local filtering and future WebSocket-based search.
@MainActor
@Observable
public final class SearchStore {
    public var results: [(ticker: String, name: String)] = []
    public var isSearching: Bool = false
    public var webSocket: WebSocketClient?

    public init() {}

    /// Quick local filter against a hardcoded list of common tickers.
    /// When connected, also sends a search request via WebSocket.
    public func localSearch(_ query: String) {
        // Send WebSocket search request if connected
        if let ws = webSocket, ws.isConnected {
            let msg: [String: Any] = ["type": "cmd_search_ticker", "payload": ["query": query]]
            Task { try? await ws.send(msg) }
        }
        let allTickers: [(String, String)] = [
            ("AAPL", "Apple Inc"),
            ("MSFT", "Microsoft Corp"),
            ("NVDA", "NVIDIA Corp"),
            ("TSLA", "Tesla Inc"),
            ("META", "Meta Platforms"),
            ("AMZN", "Amazon.com"),
            ("GOOG", "Alphabet Inc"),
            ("SPY", "SPDR S&P 500"),
            ("QQQ", "Invesco QQQ"),
            ("AMD", "Advanced Micro"),
            ("NFLX", "Netflix Inc"),
            ("DIS", "Walt Disney"),
            ("JPM", "JPMorgan Chase"),
            ("V", "Visa Inc"),
            ("BA", "Boeing Co"),
            ("COIN", "Coinbase Global"),
            ("PLTR", "Palantir Tech"),
            ("SOFI", "SoFi Tech"),
            ("BTC-USD", "Bitcoin USD"),
            ("ETH-USD", "Ethereum USD"),
        ]
        let q = query.uppercased()
        if q.isEmpty {
            results = []
            return
        }
        results = allTickers.filter { $0.0.contains(q) || $0.1.uppercased().contains(q) }
    }

    /// Apply results received from the backend via WebSocket.
    public func applyRemoteResults(_ items: [(ticker: String, name: String)]) {
        results = items
        isSearching = false
    }

    public func clear() {
        results = []
        isSearching = false
    }
}
