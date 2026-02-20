import SwiftUI

public struct FinancialsView: View {
    @Bindable var store: FinancialsStore

    public enum Section: String, CaseIterable {
        case fundamentals = "Fundamentals"
        case news = "News"
        case filings = "SEC Filings"
        case sentiment = "Sentiment"
        case aiAnalysis = "AI Analysis"
    }

    @State private var selectedSection: Section = .fundamentals

    public init(store: FinancialsStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchBar

            Divider()
                .overlay(Color(white: 0.15))

            if store.isLoading {
                Spacer()
                ProgressView("Loading financial data...")
                    .foregroundStyle(.secondary)
                Spacer()
            } else if let profile = store.profile {
                ScrollView {
                    VStack(spacing: 16) {
                        profileHeader(profile)
                        keyStatsGrid(profile)
                        sectionPicker

                        switch selectedSection {
                        case .fundamentals:
                            fundamentalsPanel(profile)
                        case .news:
                            newsPanel
                        case .filings:
                            filingsPanel
                        case .sentiment:
                            sentimentPanel
                        case .aiAnalysis:
                            aiAnalysisPanel
                        }
                    }
                    .padding(20)
                }
            } else {
                emptyState
            }
        }
        .background(Color(nsColor: NSColor(red: 0.06, green: 0.06, blue: 0.09, alpha: 1.0)))
    }

    // MARK: - Search Bar

    private var searchBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)

                TextField("Search by ticker symbol (e.g., AAPL, TSLA)...", text: $store.searchQuery)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .onSubmit {
                        store.search(store.searchQuery)
                    }

                if store.isLoading {
                    ProgressView()
                        .scaleEffect(0.6)
                }

                if !store.searchQuery.isEmpty {
                    Button(action: { store.searchQuery = "" }) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: NSColor(red: 0.10, green: 0.10, blue: 0.14, alpha: 1.0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color(white: 0.18), lineWidth: 1)
            )

            // Recent searches
            if !store.recentSearches.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Text("Recent:")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)

                        ForEach(store.recentSearches, id: \.self) { ticker in
                            Button(action: {
                                store.searchQuery = ticker
                                store.search(ticker)
                            }) {
                                Text(ticker)
                                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.blue.opacity(0.12))
                                    )
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 6)
                                            .strokeBorder(Color.blue.opacity(0.25), lineWidth: 1)
                                    )
                                    .foregroundStyle(.blue)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
    }

    // MARK: - Profile Header

    private func profileHeader(_ profile: StockProfile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(profile.symbol)
                            .font(.system(size: 24, weight: .bold, design: .monospaced))
                            .foregroundStyle(.white)

                        Text(profile.name)
                            .font(.system(size: 15))
                            .foregroundStyle(.secondary)
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(formatCurrency(profile.price))
                            .font(.system(size: 20, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white)

                        let isPositive = profile.change >= 0
                        HStack(spacing: 4) {
                            Image(systemName: isPositive ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                                .font(.system(size: 10))
                            Text(String(format: "%@%.2f (%@%.2f%%)",
                                        isPositive ? "+" : "", profile.change,
                                        isPositive ? "+" : "", profile.changePercent))
                                .font(.system(size: 13, weight: .medium, design: .monospaced))
                        }
                        .foregroundStyle(isPositive ? Color.green : Color.red)
                    }
                }

                Spacer()

                HStack(spacing: 6) {
                    badge(profile.exchange, color: .blue)
                    badge(profile.sector, color: .purple)
                }
            }

            HStack(spacing: 16) {
                labelValue("Market Cap", formatLargeNumber(profile.marketCap))
                labelValue("Avg Volume", formatVolume(profile.avgVolume))
                if let pe = profile.peRatio {
                    labelValue("P/E", String(format: "%.1f", pe))
                }
                if let beta = profile.beta {
                    labelValue("Beta", String(format: "%.2f", beta))
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(white: 0.15), lineWidth: 1)
        )
    }

    // MARK: - Key Stats Grid

    private func keyStatsGrid(_ profile: StockProfile) -> some View {
        let stats: [(String, String)] = [
            ("Shares Outstanding", formatLargeNumber(profile.sharesOutstanding)),
            ("Float", formatLargeNumber(profile.float)),
            ("Short Interest", String(format: "%.2f%%", profile.shortInterest)),
            ("Short Ratio", String(format: "%.1f days", profile.shortRatio)),
            ("Avg Volume", formatVolume(profile.avgVolume)),
            ("Beta", profile.beta.map { String(format: "%.2f", $0) } ?? "--"),
            ("52-Week High", formatCurrency(profile.week52High)),
            ("52-Week Low", formatCurrency(profile.week52Low)),
            ("P/E Ratio", profile.peRatio.map { String(format: "%.1f", $0) } ?? "--"),
            ("Forward P/E", profile.forwardPE.map { String(format: "%.1f", $0) } ?? "--"),
            ("Dividend Yield", profile.dividendYield.map { String(format: "%.2f%%", $0) } ?? "--"),
            ("Market Cap", formatLargeNumber(profile.marketCap)),
        ]

        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
            ForEach(Array(stats.enumerated()), id: \.offset) { _, stat in
                statCell(label: stat.0, value: stat.1)
            }
        }
    }

    private func statCell(label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
        )
    }

    // MARK: - Section Picker

    private var sectionPicker: some View {
        HStack(spacing: 0) {
            ForEach(Section.allCases, id: \.self) { section in
                Button(action: { selectedSection = section }) {
                    Text(section.rawValue)
                        .font(.system(size: 12, weight: selectedSection == section ? .bold : .medium))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .foregroundStyle(selectedSection == section ? .white : .secondary)
                        .background(
                            selectedSection == section
                                ? Color(nsColor: NSColor(red: 0.14, green: 0.14, blue: 0.20, alpha: 1.0))
                                : Color.clear
                        )
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color(white: 0.15), lineWidth: 1)
        )
    }

    // MARK: - Fundamentals Panel

    private func fundamentalsPanel(_ profile: StockProfile) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            // 52-Week Range
            sectionHeader("52-Week Range")
            VStack(spacing: 6) {
                GeometryReader { geo in
                    let range = profile.week52High - profile.week52Low
                    let position = range > 0
                        ? (profile.price - profile.week52Low) / range
                        : 0.5

                    ZStack(alignment: .leading) {
                        // Track
                        RoundedRectangle(cornerRadius: 3)
                            .fill(
                                LinearGradient(
                                    colors: [.red.opacity(0.4), .yellow.opacity(0.4), .green.opacity(0.4)],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 6)

                        // Price indicator
                        Circle()
                            .fill(.white)
                            .frame(width: 12, height: 12)
                            .shadow(color: .black.opacity(0.3), radius: 2)
                            .offset(x: max(0, min(geo.size.width - 12, geo.size.width * position - 6)))
                    }
                }
                .frame(height: 12)

                HStack {
                    Text(formatCurrency(profile.week52Low))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.red)
                    Spacer()
                    Text(formatCurrency(profile.price))
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                    Spacer()
                    Text(formatCurrency(profile.week52High))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.green)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
            )

            // Volume Comparison
            sectionHeader("Volume Analysis")
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Average Volume")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(formatVolume(profile.avgVolume))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Shares Outstanding")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(formatLargeNumber(profile.sharesOutstanding))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 4) {
                    Text("Float")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(formatLargeNumber(profile.float))
                        .font(.system(size: 14, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
            )

            // Valuation Metrics
            sectionHeader("Valuation")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                metricCard("P/E Ratio", profile.peRatio.map { String(format: "%.1f", $0) } ?? "--")
                metricCard("Forward P/E", profile.forwardPE.map { String(format: "%.1f", $0) } ?? "--")
                metricCard("Market Cap", formatLargeNumber(profile.marketCap))
                metricCard("Dividend Yield", profile.dividendYield.map { String(format: "%.2f%%", $0) } ?? "--")
                metricCard("Beta", profile.beta.map { String(format: "%.2f", $0) } ?? "--")
                metricCard("Exchange", profile.exchange)
            }

            // Short Interest
            sectionHeader("Short Interest")
            HStack(spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Short % of Float")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.2f%%", profile.shortInterest))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(profile.shortInterest > 5 ? .red : profile.shortInterest > 2 ? .orange : .green)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Days to Cover")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text(String(format: "%.1f days", profile.shortRatio))
                        .font(.system(size: 16, weight: .bold, design: .monospaced))
                        .foregroundStyle(profile.shortRatio > 3 ? .orange : .white)
                }

                Spacer()

                // Short interest bar
                VStack(alignment: .leading, spacing: 2) {
                    Text("Short Squeeze Risk")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Color(white: 0.15))
                            RoundedRectangle(cornerRadius: 3)
                                .fill(squeezeColor(profile.shortInterest))
                                .frame(width: max(0, geo.size.width * min(profile.shortInterest / 20.0, 1.0)))
                        }
                    }
                    .frame(height: 8)
                }
                .frame(width: 140)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
            )
        }
    }

    // MARK: - News Panel

    private var newsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("Latest News")

            if store.news.isEmpty {
                emptySection("No news available", icon: "newspaper")
            } else {
                ForEach(store.news) { item in
                    newsRow(item)
                }
            }
        }
    }

    private func newsRow(_ item: NewsItem) -> some View {
        Button(action: {
            if let url = URL(string: item.url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            VStack(alignment: .leading, spacing: 6) {
                Text(item.title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    Text(item.source)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text(timeAgo(item.publishedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    sentimentBadge(item.sentiment)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(white: 0.13), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func sentimentBadge(_ sentiment: NewsItem.Sentiment) -> some View {
        let (text, color): (String, Color) = switch sentiment {
        case .bullish: ("Bullish", .green)
        case .bearish: ("Bearish", .red)
        case .neutral: ("Neutral", .gray)
        }

        return Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    // MARK: - Filings Panel

    private var filingsPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeader("SEC Filings")

            if store.filings.isEmpty {
                emptySection("No SEC filings available", icon: "doc.text")
            } else {
                ForEach(store.filings) { filing in
                    filingRow(filing)
                }
            }
        }
    }

    private func filingRow(_ filing: SECFiling) -> some View {
        Button(action: {
            if let url = URL(string: filing.url) {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 12) {
                filingTypeBadge(filing.type)

                VStack(alignment: .leading, spacing: 3) {
                    Text(filing.description)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(formatDate(filing.filedDate))
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "arrow.up.right.square")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(white: 0.13), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private func filingTypeBadge(_ type: String) -> some View {
        let color: Color = switch type {
        case "10-K": .blue
        case "10-Q": .green
        case "8-K": .orange
        case "4": .purple
        default: .gray
        }

        let displayType = type == "4" ? "Form 4" : type

        return Text(displayType)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(minWidth: 50)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Sentiment Panel

    private var sentimentPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("Market Sentiment")

            if let sentiment = store.sentiment {
                // Sentiment Gauge
                VStack(spacing: 12) {
                    HStack {
                        Text("BEARISH")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.red)
                        Spacer()
                        Text("NEUTRAL")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.gray)
                        Spacer()
                        Text("BULLISH")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                    }

                    GeometryReader { geo in
                        let normalizedScore = (sentiment.sentimentScore + 1.0) / 2.0 // Convert -1..1 to 0..1

                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6)
                                .fill(
                                    LinearGradient(
                                        colors: [.red, .orange, .yellow, .green.opacity(0.7), .green],
                                        startPoint: .leading,
                                        endPoint: .trailing
                                    )
                                )
                                .frame(height: 16)

                            // Indicator
                            Circle()
                                .fill(.white)
                                .frame(width: 20, height: 20)
                                .shadow(color: .black.opacity(0.4), radius: 3)
                                .overlay(
                                    Circle()
                                        .strokeBorder(.black.opacity(0.2), lineWidth: 1)
                                )
                                .offset(x: max(0, min(geo.size.width - 20, geo.size.width * normalizedScore - 10)))
                        }
                    }
                    .frame(height: 20)

                    Text(String(format: "Score: %.2f", sentiment.sentimentScore))
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundStyle(sentimentColor(sentiment.sentimentScore))
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
                )

                // Mention Volume and Trend
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Mention Volume (24h)")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        HStack(spacing: 6) {
                            Text(formatNumber(sentiment.mentionVolume))
                                .font(.system(size: 22, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)

                            let trendIcon: String = switch sentiment.trend {
                            case .rising: "arrow.up.right"
                            case .falling: "arrow.down.right"
                            case .stable: "arrow.right"
                            }
                            let trendColor: Color = switch sentiment.trend {
                            case .rising: .green
                            case .falling: .red
                            case .stable: .gray
                            }

                            Image(systemName: trendIcon)
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(trendColor)
                        }
                    }

                    Spacer()

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Trend")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)

                        Text(sentiment.trend.rawValue.capitalized)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(trendTextColor(sentiment.trend))
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
                )

                // Top Keywords
                VStack(alignment: .leading, spacing: 8) {
                    Text("Top Keywords")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)

                    FlowLayout(spacing: 6) {
                        ForEach(sentiment.topKeywords, id: \.self) { keyword in
                            Text(keyword)
                                .font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(
                                    RoundedRectangle(cornerRadius: 14)
                                        .fill(Color.cyan.opacity(0.10))
                                )
                                .overlay(
                                    RoundedRectangle(cornerRadius: 14)
                                        .strokeBorder(Color.cyan.opacity(0.25), lineWidth: 1)
                                )
                                .foregroundStyle(.cyan)
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
                )
            } else {
                emptySection("No sentiment data available", icon: "chart.bar")
            }
        }
    }

    // MARK: - AI Analysis Panel

    private var aiAnalysisPanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            sectionHeader("AI Analysis")

            if let analysis = store.aiAnalysis {
                // Recommendation Badge
                HStack(spacing: 16) {
                    VStack(spacing: 6) {
                        Text("RECOMMENDATION")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)

                        Text(analysis.recommendation.rawValue)
                            .font(.system(size: 18, weight: .bold))
                            .padding(.horizontal, 16)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(recommendationColor(analysis.recommendation).opacity(0.15))
                            )
                            .foregroundStyle(recommendationColor(analysis.recommendation))
                    }

                    if analysis.shortOpportunity {
                        VStack(spacing: 6) {
                            Text("SHORT OPPORTUNITY")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)

                            HStack(spacing: 4) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 14))
                                Text("Yes")
                                    .font(.system(size: 14, weight: .bold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color.red.opacity(0.15))
                            )
                            .foregroundStyle(.red)
                        }
                    }

                    Spacer()

                    // Confidence
                    VStack(spacing: 6) {
                        Text("CONFIDENCE")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)

                        ZStack {
                            Circle()
                                .stroke(Color(white: 0.15), lineWidth: 4)
                                .frame(width: 52, height: 52)
                            Circle()
                                .trim(from: 0, to: analysis.confidence)
                                .stroke(confidenceColor(analysis.confidence), lineWidth: 4)
                                .frame(width: 52, height: 52)
                                .rotationEffect(.degrees(-90))

                            Text(String(format: "%.0f%%", analysis.confidence * 100))
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
                )

                // Summary
                VStack(alignment: .leading, spacing: 8) {
                    Text("Summary")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.secondary)

                    Text(analysis.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
                )

                // Key Catalysts
                if !analysis.keyCatalysts.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.green)
                            Text("Key Catalysts")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                        }

                        ForEach(Array(analysis.keyCatalysts.enumerated()), id: \.offset) { _, catalyst in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Color.green.opacity(0.6))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)

                                Text(catalyst)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: NSColor(red: 0.06, green: 0.09, blue: 0.07, alpha: 1.0)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.green.opacity(0.15), lineWidth: 1)
                    )
                }

                // Key Risks
                if !analysis.keyRisks.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 6) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.red)
                            Text("Key Risks")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.secondary)
                        }

                        ForEach(Array(analysis.keyRisks.enumerated()), id: \.offset) { _, risk in
                            HStack(alignment: .top, spacing: 8) {
                                Circle()
                                    .fill(Color.red.opacity(0.6))
                                    .frame(width: 6, height: 6)
                                    .padding(.top, 5)

                                Text(risk)
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                        }
                    }
                    .padding(16)
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color(nsColor: NSColor(red: 0.09, green: 0.06, blue: 0.06, alpha: 1.0)))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.red.opacity(0.15), lineWidth: 1)
                    )
                }

                // Technical Levels
                HStack(spacing: 12) {
                    if let support = analysis.supportLevel {
                        technicalLevel("Support", formatCurrency(support), .red)
                    }
                    if let resistance = analysis.resistanceLevel {
                        technicalLevel("Resistance", formatCurrency(resistance), .orange)
                    }
                    if let target = analysis.targetPrice {
                        technicalLevel("Target Price", formatCurrency(target), .green)
                    }
                }
            } else {
                emptySection("No AI analysis available", icon: "brain")
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "building.columns")
                .font(.system(size: 48))
                .foregroundStyle(Color(white: 0.3))

            Text("Search for a stock")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)

            Text("Enter a ticker symbol to view comprehensive financial data,\nnews, SEC filings, and AI analysis.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Popular tickers
            HStack(spacing: 8) {
                ForEach(["AAPL", "TSLA", "NVDA", "META", "AMZN", "MSFT", "SPY"], id: \.self) { ticker in
                    Button(action: {
                        store.searchQuery = ticker
                        store.search(ticker)
                    }) {
                        Text(ticker)
                            .font(.system(size: 12, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(Color.blue.opacity(0.12))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .strokeBorder(Color.blue.opacity(0.3), lineWidth: 1)
                            )
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Shared Components

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func labelValue(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white)
        }
    }

    private func metricCard(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
        )
    }

    private func technicalLevel(_ label: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(color.opacity(0.2), lineWidth: 1)
        )
    }

    private func emptySection(_ message: String, icon: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundStyle(Color(white: 0.3))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Formatting Helpers

    private func formatCurrency(_ value: Double) -> String {
        if value == 0 { return "--" }
        if value >= 1000 {
            return String(format: "$%,.0f", value)
        }
        return String(format: "$%.2f", value)
    }

    private func formatLargeNumber(_ value: Double) -> String {
        if value >= 1_000_000_000_000 {
            return String(format: "$%.2fT", value / 1_000_000_000_000)
        }
        if value >= 1_000_000_000 {
            return String(format: "$%.2fB", value / 1_000_000_000)
        }
        if value >= 1_000_000 {
            return String(format: "$%.1fM", value / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "$%.0fK", value / 1_000)
        }
        return String(format: "$%.0f", value)
    }

    private func formatVolume(_ vol: Double) -> String {
        if vol >= 1_000_000_000 { return String(format: "%.1fB", vol / 1_000_000_000) }
        if vol >= 1_000_000 { return String(format: "%.1fM", vol / 1_000_000) }
        if vol >= 1_000 { return String(format: "%.1fK", vol / 1_000) }
        return String(format: "%.0f", vol)
    }

    private func formatNumber(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        return formatter.string(from: date)
    }

    private func timeAgo(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "just now" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    // MARK: - Color Helpers

    private func sentimentColor(_ score: Double) -> Color {
        if score > 0.3 { return .green }
        if score < -0.3 { return .red }
        return .yellow
    }

    private func trendTextColor(_ trend: SentimentData.Trend) -> Color {
        switch trend {
        case .rising: return .green
        case .falling: return .red
        case .stable: return .gray
        }
    }

    private func squeezeColor(_ shortInterest: Double) -> Color {
        if shortInterest > 10 { return .red }
        if shortInterest > 5 { return .orange }
        return .green
    }

    private func recommendationColor(_ rec: AIStockAnalysis.Recommendation) -> Color {
        switch rec {
        case .strongBuy: return .green
        case .buy: return Color(nsColor: NSColor(red: 0.4, green: 0.85, blue: 0.4, alpha: 1.0))
        case .hold: return .yellow
        case .sell: return .orange
        case .strongSell: return .red
        }
    }

    private func confidenceColor(_ confidence: Double) -> Color {
        if confidence >= 0.7 { return .green }
        if confidence >= 0.4 { return .yellow }
        return .red
    }
}

// MARK: - Flow Layout

/// Simple flow layout for keyword tags
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrangeSubviews(proposal: proposal, subviews: subviews)
        for (index, position) in result.positions.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + position.x, y: bounds.minY + position.y),
                proposal: ProposedViewSize(subviews[index].sizeThatFits(.unspecified))
            )
        }
    }

    private func arrangeSubviews(proposal: ProposedViewSize, subviews: Subviews)
        -> (size: CGSize, positions: [CGPoint])
    {
        let maxWidth = proposal.width ?? .infinity
        var positions: [CGPoint] = []
        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var maxX: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if currentX + size.width > maxWidth, currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }
            positions.append(CGPoint(x: currentX, y: currentY))
            lineHeight = max(lineHeight, size.height)
            currentX += size.width + spacing
            maxX = max(maxX, currentX)
        }

        return (
            size: CGSize(width: maxX, height: currentY + lineHeight),
            positions: positions
        )
    }
}
