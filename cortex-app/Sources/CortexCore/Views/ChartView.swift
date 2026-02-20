import SwiftUI
import WebKit

/// Chart View -- embeds a TradingView advanced chart widget via WKWebView.
/// Responds to the left-pane `selectedSection` environment value to show
/// section-specific symbol lists (Indices, Crypto, Stocks, Favorites, Options).
@MainActor
public struct ChartView: View {
    @Environment(\.cortexSelectedSection) private var section
    @State private var displayedSymbol: String = "SPY"
    @State private var timeframe: String = "D"
    @State private var searchText: String = ""
    @State private var searchResults: [(ticker: String, name: String)] = []
    @State private var isSearchFocused: Bool = false

    private let searchStore = SearchStore()
    private var chatStore: ChatStore?

    public init(chatStore: ChatStore? = nil) {
        self.chatStore = chatStore
    }

    // MARK: - Section Symbol Data

    private static let indicesSymbols  = ["SPY", "QQQ", "DIA", "IWM", "VIX"]
    private static let cryptoSymbols   = ["BTCUSD", "ETHUSD", "SOLUSD", "ADAUSD", "DOGEUSD"]
    private static let stocksSymbols   = ["AAPL", "MSFT", "NVDA", "AMZN", "TSLA", "META", "GOOG"]
    private static let forexSymbols    = ["EURUSD", "GBPUSD", "USDJPY", "AUDUSD", "USDCAD"]
    private static let favoritesSymbols = ["SPY", "AAPL", "NVDA", "BTCUSD", "TSLA"]

    /// Returns the symbol list for the current section.
    private var sectionSymbols: [String] {
        switch section {
        case "Indices":   return Self.indicesSymbols
        case "Crypto":    return Self.cryptoSymbols
        case "Stocks":    return Self.stocksSymbols
        case "Favorites": return Self.favoritesSymbols
        default:          return Self.indicesSymbols
        }
    }

    /// Default symbol for each section.
    private static func defaultSymbol(for section: String) -> String {
        switch section {
        case "Indices":   return "SPY"
        case "Crypto":    return "BTCUSD"
        case "Stocks":    return "AAPL"
        case "Favorites": return "SPY"
        default:          return "SPY"
        }
    }

    /// Section header label and icon.
    private var sectionMeta: (label: String, icon: String) {
        switch section {
        case "Indices":   return ("MAJOR INDICES", "chart.bar.fill")
        case "Crypto":    return ("CRYPTO", "bitcoinsign.circle")
        case "Stocks":    return ("STOCKS", "dollarsign.circle")
        case "Favorites": return ("FAVORITES", "star.fill")
        case "Options":   return ("OPTIONS", "doc.text.fill")
        default:          return ("MARKETS", "chart.line.uptrend.xyaxis")
        }
    }

    // MARK: - Body

    public var body: some View {
        VStack(spacing: 0) {
            // Section-specific content
            switch section {
            case "Options":
                optionsPlaceholder
            default:
                symbolPillStrip
            }

            // Search bar + timeframe toolbar
            searchAndTimeframeBar

            Divider()

            // TradingView chart
            ZStack(alignment: .topLeading) {
                TradingViewWebView(symbol: displayedSymbol, timeframe: timeframe)

                // Search results dropdown
                if !searchResults.isEmpty && isSearchFocused {
                    searchResultsDropdown
                }
            }
        }
        .onChange(of: section) { _, newSection in
            displayedSymbol = Self.defaultSymbol(for: newSection)
            chatStore?.selectedSymbol = displayedSymbol
        }
        .onAppear {
            displayedSymbol = Self.defaultSymbol(for: section)
            chatStore?.selectedSymbol = displayedSymbol
        }
    }

    // MARK: - Symbol Pill Strip

    @ViewBuilder
    private var symbolPillStrip: some View {
        let meta = sectionMeta

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: meta.icon)
                    .font(.system(size: 10))
                    .foregroundStyle(CortexDesign.neutral)

                Text(meta.label)
                    .font(CortexDesign.sectionFont)
                    .foregroundStyle(CortexDesign.neutral)
            }
            .padding(.horizontal, CortexDesign.sectionSpacing)
            .padding(.top, 8)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(sectionSymbols, id: \.self) { sym in
                        Button(action: { selectSymbol(sym) }) {
                            Text(sym)
                                .font(CortexDesign.badgeFont)
                                .foregroundStyle(
                                    displayedSymbol == sym
                                        ? .white
                                        : CortexDesign.accentPrimary
                                )
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                                        .fill(
                                            displayedSymbol == sym
                                                ? CortexDesign.accentPrimary.opacity(0.25)
                                                : CortexDesign.bgElevated
                                        )
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                                        .strokeBorder(
                                            displayedSymbol == sym
                                                ? CortexDesign.accentPrimary.opacity(0.6)
                                                : CortexDesign.border,
                                            lineWidth: 1
                                        )
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, CortexDesign.sectionSpacing)
            }
            .padding(.bottom, 6)
        }
        .background(CortexDesign.bgDeepest)

        Rectangle()
            .fill(CortexDesign.bgHover)
            .frame(height: 1)
    }

    // MARK: - Search & Timeframe Bar

    private var searchAndTimeframeBar: some View {
        HStack(spacing: 12) {
            // Symbol search
            symbolSearchField

            Divider()
                .frame(height: 24)

            // Current symbol display
            Text(displayedSymbol)
                .font(.system(.title2, design: .monospaced, weight: .bold))

            Spacer()

            // Timeframe selector
            ForEach(["1m", "5m", "15m", "1H", "4H", "D", "W"], id: \.self) { tf in
                Button(tf) { timeframe = tf }
                    .buttonStyle(.bordered)
                    .tint(timeframe == tf ? CortexDesign.accentPrimary : CortexDesign.neutral)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    // MARK: - Options Placeholder

    @ViewBuilder
    private var optionsPlaceholder: some View {
        HStack(spacing: 10) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 14))
                .foregroundStyle(CortexDesign.neutral)

            Text("Options chain coming soon")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(CortexDesign.neutral)

            Spacer()
        }
        .padding(.horizontal, CortexDesign.sectionSpacing)
        .padding(.vertical, 10)
        .background(CortexDesign.warning.opacity(0.04))

        Rectangle()
            .fill(CortexDesign.bgHover)
            .frame(height: 1)
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
            RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                .fill(CortexDesign.bgElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CortexDesign.badgeRadius)
                .strokeBorder(CortexDesign.borderHover, lineWidth: 1)
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
                    if hovering {
                        NSCursor.pointingHand.push()
                    } else {
                        NSCursor.pop()
                    }
                }

                if result.ticker != searchResults.last?.ticker {
                    Divider().overlay(CortexDesign.borderHover)
                }
            }
        }
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                .fill(CortexDesign.bgCard)
                .shadow(color: .black.opacity(0.4), radius: 12, y: 4)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CortexDesign.cardRadius)
                .strokeBorder(CortexDesign.borderHover, lineWidth: 1)
        )
        .padding(.leading, CortexDesign.sectionSpacing)
        .padding(.top, 4)
    }

    // MARK: - Actions

    private func selectSymbol(_ ticker: String) {
        displayedSymbol = ticker
        searchText = ""
        searchResults = []
        isSearchFocused = false
        chatStore?.selectedSymbol = ticker
    }
}
