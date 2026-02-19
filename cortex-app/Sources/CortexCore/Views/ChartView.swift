import SwiftUI
import WebKit

/// Chart View -- embeds a TradingView advanced chart widget via WKWebView.
/// Provides a symbol search bar, timeframe selector toolbar, and renders candlestick data
/// with RSI, MACD, and Volume studies.
@MainActor
public struct ChartView: View {
    @State var symbol: String = "AAPL"
    @State private var timeframe: String = "D"
    @State private var searchText: String = ""
    @State private var searchResults: [(ticker: String, name: String)] = []
    @State private var isSearchFocused: Bool = false

    private let searchStore = SearchStore()

    public init() {}

    public var body: some View {
        VStack(spacing: 0) {
            // Search bar + timeframe toolbar
            HStack(spacing: 12) {
                // Symbol search
                symbolSearchField

                Divider()
                    .frame(height: 24)

                // Current symbol display
                Text(symbol)
                    .font(.system(.title2, design: .monospaced, weight: .bold))

                Spacer()

                // Timeframe selector
                ForEach(["1m", "5m", "15m", "1H", "4H", "D", "W"], id: \.self) { tf in
                    Button(tf) { timeframe = tf }
                        .buttonStyle(.bordered)
                        .tint(timeframe == tf ? .blue : .gray)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // TradingView chart
            ZStack(alignment: .topLeading) {
                TradingViewWebView(symbol: symbol, timeframe: timeframe)

                // Search results dropdown
                if !searchResults.isEmpty && isSearchFocused {
                    searchResultsDropdown
                }
            }
        }
    }

    // MARK: - Symbol Search Field

    private var symbolSearchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)

            TextField("Search symbol...", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13, design: .monospaced))
                .frame(width: 160)
                .onSubmit {
                    if let first = searchResults.first {
                        selectSymbol(first.ticker)
                    }
                }
                .onChange(of: searchText) { _, newValue in
                    searchStore.localSearch(newValue)
                    searchResults = searchStore.results
                    isSearchFocused = !newValue.isEmpty
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color(white: 0.15))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color(white: 0.25), lineWidth: 1)
        )
    }

    // MARK: - Search Results Dropdown

    private var searchResultsDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(searchResults.prefix(8).enumerated()), id: \.offset) { _, result in
                Button(action: { selectSymbol(result.ticker) }) {
                    HStack(spacing: 10) {
                        Text(result.ticker)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)
                            .frame(width: 80, alignment: .leading)

                        Text(result.name)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer()
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(Color.clear)
                .onHover { hovering in
                    // Visual feedback handled by SwiftUI
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                if result.ticker != searchResults.last?.ticker {
                    Divider().overlay(Color(white: 0.2))
                }
            }
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: NSColor(red: 0.12, green: 0.12, blue: 0.16, alpha: 0.98)))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(white: 0.2), lineWidth: 1)
        )
        .padding(.leading, 16)
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func selectSymbol(_ ticker: String) {
        symbol = ticker
        searchText = ""
        searchResults = []
        isSearchFocused = false
    }
}
