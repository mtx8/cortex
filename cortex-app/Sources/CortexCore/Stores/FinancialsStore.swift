import Foundation

// MARK: - Models

public struct StockProfile: Sendable {
    public let symbol: String
    public let name: String
    public let sector: String
    public let industry: String
    public let marketCap: Double
    public let sharesOutstanding: Double
    public let float: Double
    public let shortInterest: Double
    public let shortRatio: Double
    public let avgVolume: Double
    public let week52High: Double
    public let week52Low: Double
    public let peRatio: Double?
    public let forwardPE: Double?
    public let dividendYield: Double?
    public let beta: Double?
    public let exchange: String
    public let price: Double
    public let change: Double
    public let changePercent: Double

    public init(
        symbol: String,
        name: String,
        sector: String,
        industry: String,
        marketCap: Double,
        sharesOutstanding: Double,
        float: Double,
        shortInterest: Double,
        shortRatio: Double,
        avgVolume: Double,
        week52High: Double,
        week52Low: Double,
        peRatio: Double?,
        forwardPE: Double?,
        dividendYield: Double?,
        beta: Double?,
        exchange: String,
        price: Double = 0,
        change: Double = 0,
        changePercent: Double = 0
    ) {
        self.symbol = symbol
        self.name = name
        self.sector = sector
        self.industry = industry
        self.marketCap = marketCap
        self.sharesOutstanding = sharesOutstanding
        self.float = float
        self.shortInterest = shortInterest
        self.shortRatio = shortRatio
        self.avgVolume = avgVolume
        self.week52High = week52High
        self.week52Low = week52Low
        self.peRatio = peRatio
        self.forwardPE = forwardPE
        self.dividendYield = dividendYield
        self.beta = beta
        self.exchange = exchange
        self.price = price
        self.change = change
        self.changePercent = changePercent
    }
}

public struct NewsItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public let source: String
    public let publishedAt: Date
    public let url: String
    public let sentiment: Sentiment
    public let tickers: [String]

    public enum Sentiment: String, Sendable {
        case bullish, bearish, neutral
    }

    public init(
        id: String = UUID().uuidString,
        title: String,
        source: String,
        publishedAt: Date,
        url: String,
        sentiment: Sentiment,
        tickers: [String] = []
    ) {
        self.id = id
        self.title = title
        self.source = source
        self.publishedAt = publishedAt
        self.url = url
        self.sentiment = sentiment
        self.tickers = tickers
    }
}

public struct SECFiling: Identifiable, Sendable {
    public let id: String
    public let type: String
    public let filedDate: Date
    public let description: String
    public let url: String

    public init(
        id: String = UUID().uuidString,
        type: String,
        filedDate: Date,
        description: String,
        url: String
    ) {
        self.id = id
        self.type = type
        self.filedDate = filedDate
        self.description = description
        self.url = url
    }
}

public struct SentimentData: Sendable {
    public let mentionVolume: Int
    public let sentimentScore: Double
    public let trend: Trend
    public let topKeywords: [String]

    public enum Trend: String, Sendable {
        case rising, falling, stable
    }

    public init(
        mentionVolume: Int,
        sentimentScore: Double,
        trend: Trend,
        topKeywords: [String]
    ) {
        self.mentionVolume = mentionVolume
        self.sentimentScore = sentimentScore
        self.trend = trend
        self.topKeywords = topKeywords
    }
}

public struct AIStockAnalysis: Sendable {
    public let recommendation: Recommendation
    public let shortOpportunity: Bool
    public let summary: String
    public let keyRisks: [String]
    public let keyCatalysts: [String]
    public let supportLevel: Double?
    public let resistanceLevel: Double?
    public let targetPrice: Double?
    public let confidence: Double

    public enum Recommendation: String, Sendable, CaseIterable {
        case strongBuy = "Strong Buy"
        case buy = "Buy"
        case hold = "Hold"
        case sell = "Sell"
        case strongSell = "Strong Sell"
    }

    public init(
        recommendation: Recommendation,
        shortOpportunity: Bool,
        summary: String,
        keyRisks: [String],
        keyCatalysts: [String],
        supportLevel: Double?,
        resistanceLevel: Double?,
        targetPrice: Double?,
        confidence: Double
    ) {
        self.recommendation = recommendation
        self.shortOpportunity = shortOpportunity
        self.summary = summary
        self.keyRisks = keyRisks
        self.keyCatalysts = keyCatalysts
        self.supportLevel = supportLevel
        self.resistanceLevel = resistanceLevel
        self.targetPrice = targetPrice
        self.confidence = confidence
    }
}

// MARK: - Store

@MainActor
@Observable
public final class FinancialsStore {
    public var searchQuery: String = ""
    public var selectedSymbol: String?
    public var profile: StockProfile?
    public var news: [NewsItem] = []
    public var filings: [SECFiling] = []
    public var sentiment: SentimentData?
    public var aiAnalysis: AIStockAnalysis?
    public var isLoading: Bool = false
    public var errorMessage: String?
    public var recentSearches: [String] = []

    public var webSocket: WebSocketClient?

    private var searchTimeoutTask: Task<Void, Never>?

    public init() {
        // Empty state on launch -- real data only, no mock data
    }

    // MARK: - Search

    /// Search for a symbol -- sends request to backend via WebSocket
    public func search(_ symbol: String) {
        let ticker = symbol.uppercased().trimmingCharacters(in: .whitespaces)
        guard !ticker.isEmpty else { return }
        selectedSymbol = ticker
        isLoading = true

        // Add to recent searches (max 10)
        if let idx = recentSearches.firstIndex(of: ticker) {
            recentSearches.remove(at: idx)
        }
        recentSearches.insert(ticker, at: 0)
        if recentSearches.count > 10 { recentSearches.removeLast() }

        // Cancel any previous timeout
        searchTimeoutTask?.cancel()
        errorMessage = nil

        // Send request to backend if connected
        if let ws = webSocket, ws.isConnected {
            let msg: [String: Any] = [
                "type": "cmd_financials_lookup",
                "payload": ["symbol": ticker],
            ]
            Task { @MainActor in
                do {
                    try await ws.send(msg)
                } catch {
                    // Backend unavailable -- fall back to mock data
                    loadMockData(for: ticker)
                }
            }

            // Start a 10-second timeout in case the backend never responds
            searchTimeoutTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { return }
                if isLoading {
                    isLoading = false
                    errorMessage = "Request timed out. Please try again."
                }
            }
        } else {
            // No WebSocket -- use mock data
            loadMockData(for: ticker)
        }
    }

    // MARK: - Apply Methods (from backend)

    /// Apply profile data from backend
    public func applyProfile(_ data: [String: Any]) {
        searchTimeoutTask?.cancel()
        errorMessage = nil
        let symbol = data["symbol"] as? String ?? selectedSymbol ?? ""
        let name = data["name"] as? String ?? symbol
        let sector = data["sector"] as? String ?? "Unknown"
        let industry = data["industry"] as? String ?? "Unknown"
        let marketCap = data["market_cap"] as? Double ?? 0
        let sharesOutstanding = data["shares_outstanding"] as? Double ?? 0
        let floatVal = data["float"] as? Double ?? 0
        let shortInterest = data["short_interest"] as? Double ?? 0
        let shortRatio = data["short_ratio"] as? Double ?? 0
        let avgVolume = data["avg_volume"] as? Double ?? 0
        let week52High = data["week_52_high"] as? Double ?? 0
        let week52Low = data["week_52_low"] as? Double ?? 0
        let peRatio = data["pe_ratio"] as? Double
        let forwardPE = data["forward_pe"] as? Double
        let dividendYield = data["dividend_yield"] as? Double
        let beta = data["beta"] as? Double
        let exchange = data["exchange"] as? String ?? "NASDAQ"
        let price = data["price"] as? Double ?? 0
        let change = data["change"] as? Double ?? 0
        let changePercent = data["change_percent"] as? Double ?? 0

        profile = StockProfile(
            symbol: symbol,
            name: name,
            sector: sector,
            industry: industry,
            marketCap: marketCap,
            sharesOutstanding: sharesOutstanding,
            float: floatVal,
            shortInterest: shortInterest,
            shortRatio: shortRatio,
            avgVolume: avgVolume,
            week52High: week52High,
            week52Low: week52Low,
            peRatio: peRatio,
            forwardPE: forwardPE,
            dividendYield: dividendYield,
            beta: beta,
            exchange: exchange,
            price: price,
            change: change,
            changePercent: changePercent
        )
        selectedSymbol = symbol
        isLoading = false
    }

    /// Apply news data from backend
    public func applyNews(_ items: [[String: Any]]) {
        searchTimeoutTask?.cancel()
        errorMessage = nil
        news = items.map { item in
            let sentimentRaw = item["sentiment"] as? String ?? "neutral"
            let sentiment: NewsItem.Sentiment = NewsItem.Sentiment(rawValue: sentimentRaw) ?? .neutral
            let publishedStr = item["published_at"] as? String ?? ""
            let published = ISO8601DateFormatter().date(from: publishedStr) ?? Date()
            let tickers = item["tickers"] as? [String] ?? []

            return NewsItem(
                id: item["id"] as? String ?? UUID().uuidString,
                title: item["title"] as? String ?? "Untitled",
                source: item["source"] as? String ?? "Unknown",
                publishedAt: published,
                url: item["url"] as? String ?? "",
                sentiment: sentiment,
                tickers: tickers
            )
        }
    }

    /// Apply SEC filings from backend
    public func applyFilings(_ items: [[String: Any]]) {
        searchTimeoutTask?.cancel()
        errorMessage = nil
        filings = items.map { item in
            let filedStr = item["filed_date"] as? String ?? ""
            let filedDate = ISO8601DateFormatter().date(from: filedStr) ?? Date()

            return SECFiling(
                id: item["id"] as? String ?? UUID().uuidString,
                type: item["type"] as? String ?? "8-K",
                filedDate: filedDate,
                description: item["description"] as? String ?? "",
                url: item["url"] as? String ?? ""
            )
        }
    }

    /// Apply sentiment data from backend
    public func applySentiment(_ data: [String: Any]) {
        searchTimeoutTask?.cancel()
        errorMessage = nil
        let trendRaw = data["trend"] as? String ?? "stable"
        let trend = SentimentData.Trend(rawValue: trendRaw) ?? .stable
        let keywords = data["top_keywords"] as? [String] ?? []

        sentiment = SentimentData(
            mentionVolume: data["mention_volume"] as? Int ?? 0,
            sentimentScore: data["sentiment_score"] as? Double ?? 0,
            trend: trend,
            topKeywords: keywords
        )
    }

    /// Apply error from backend — clears loading state
    public func applyError(_ error: String) {
        searchTimeoutTask?.cancel()
        isLoading = false
        errorMessage = error
    }

    /// Apply AI analysis from backend
    public func applyAIAnalysis(_ data: [String: Any]) {
        searchTimeoutTask?.cancel()
        errorMessage = nil
        let recRaw = data["recommendation"] as? String ?? "Hold"
        let recommendation = AIStockAnalysis.Recommendation(rawValue: recRaw) ?? .hold
        let risks = data["key_risks"] as? [String] ?? []
        let catalysts = data["key_catalysts"] as? [String] ?? []

        aiAnalysis = AIStockAnalysis(
            recommendation: recommendation,
            shortOpportunity: data["short_opportunity"] as? Bool ?? false,
            summary: data["summary"] as? String ?? "",
            keyRisks: risks,
            keyCatalysts: catalysts,
            supportLevel: data["support_level"] as? Double,
            resistanceLevel: data["resistance_level"] as? Double,
            targetPrice: data["target_price"] as? Double,
            confidence: data["confidence"] as? Double ?? 0.5
        )
    }

    // MARK: - Mock Data

    /// Load mock data for development
    public func loadMockData(for symbol: String) {
        let ticker = symbol.uppercased()
        selectedSymbol = ticker

        switch ticker {
        case "AAPL":
            loadAAPLMockData()
        case "TSLA":
            loadTSLAMockData()
        case "NVDA":
            loadNVDAMockData()
        default:
            loadGenericMockData(for: ticker)
        }

        isLoading = false
    }

    private func loadAAPLMockData() {
        profile = StockProfile(
            symbol: "AAPL", name: "Apple Inc.", sector: "Technology",
            industry: "Consumer Electronics", marketCap: 2_890_000_000_000,
            sharesOutstanding: 15_460_000_000, float: 15_330_000_000,
            shortInterest: 0.72, shortRatio: 1.2, avgVolume: 54_320_000,
            week52High: 199.62, week52Low: 164.08, peRatio: 29.4,
            forwardPE: 27.1, dividendYield: 0.55, beta: 1.24,
            exchange: "NASDAQ", price: 189.84, change: 2.36, changePercent: 1.26
        )

        let now = Date()
        news = [
            NewsItem(title: "Apple Vision Pro Sales Surpass Expectations in Q1",
                     source: "Bloomberg", publishedAt: now.addingTimeInterval(-3600),
                     url: "https://bloomberg.com/apple-vision-pro", sentiment: .bullish,
                     tickers: ["AAPL"]),
            NewsItem(title: "Apple Services Revenue Hits All-Time High",
                     source: "Reuters", publishedAt: now.addingTimeInterval(-7200),
                     url: "https://reuters.com/apple-services", sentiment: .bullish,
                     tickers: ["AAPL"]),
            NewsItem(title: "EU Regulators Fine Apple $2B Over App Store Practices",
                     source: "Financial Times", publishedAt: now.addingTimeInterval(-14400),
                     url: "https://ft.com/apple-eu-fine", sentiment: .bearish,
                     tickers: ["AAPL"]),
            NewsItem(title: "Apple AI Strategy: What We Know So Far",
                     source: "The Verge", publishedAt: now.addingTimeInterval(-28800),
                     url: "https://theverge.com/apple-ai", sentiment: .neutral,
                     tickers: ["AAPL"]),
            NewsItem(title: "iPhone Demand Softens in China Market",
                     source: "Nikkei Asia", publishedAt: now.addingTimeInterval(-43200),
                     url: "https://nikkei.com/apple-china", sentiment: .bearish,
                     tickers: ["AAPL"]),
        ]

        filings = [
            SECFiling(type: "10-K", filedDate: now.addingTimeInterval(-86400 * 30),
                      description: "Annual Report for fiscal year ended September 2025",
                      url: "https://sec.gov/aapl/10k"),
            SECFiling(type: "10-Q", filedDate: now.addingTimeInterval(-86400 * 60),
                      description: "Quarterly Report for Q4 2025",
                      url: "https://sec.gov/aapl/10q"),
            SECFiling(type: "8-K", filedDate: now.addingTimeInterval(-86400 * 14),
                      description: "Current Report - Results of Operations and Financial Condition",
                      url: "https://sec.gov/aapl/8k"),
            SECFiling(type: "4", filedDate: now.addingTimeInterval(-86400 * 7),
                      description: "Statement of Changes - Tim Cook, CEO",
                      url: "https://sec.gov/aapl/form4-cook"),
            SECFiling(type: "4", filedDate: now.addingTimeInterval(-86400 * 5),
                      description: "Statement of Changes - Luca Maestri, CFO",
                      url: "https://sec.gov/aapl/form4-maestri"),
        ]

        sentiment = SentimentData(
            mentionVolume: 12450,
            sentimentScore: 0.62,
            trend: .rising,
            topKeywords: ["Vision Pro", "AI", "Services", "iPhone", "China", "EU fine", "buyback"]
        )

        aiAnalysis = AIStockAnalysis(
            recommendation: .buy,
            shortOpportunity: false,
            summary: "Apple maintains strong fundamentals with growing Services revenue offsetting hardware cyclicality. The Vision Pro launch adds a new growth vector, though near-term headwinds from EU regulation and China demand softening warrant monitoring. The stock trades at a slight premium to historical averages but the quality of the business and capital return program justify the valuation. Technical setup is constructive above the 50-day moving average.",
            keyRisks: [
                "EU regulatory actions could reduce App Store margins by 5-8%",
                "China demand weakness amid local competition from Huawei",
                "Consumer spending slowdown could impact iPhone upgrade cycle",
                "Valuation premium limits upside if growth decelerates",
            ],
            keyCatalysts: [
                "AI integration across product lineup (Apple Intelligence)",
                "Services segment growing 15%+ YoY with expanding margins",
                "Vision Pro creating new spatial computing category",
                "$90B+ annual share buyback program supporting EPS growth",
                "Potential India manufacturing expansion reducing China risk",
            ],
            supportLevel: 182.50,
            resistanceLevel: 195.00,
            targetPrice: 210.00,
            confidence: 0.78
        )
    }

    private func loadTSLAMockData() {
        profile = StockProfile(
            symbol: "TSLA", name: "Tesla, Inc.", sector: "Consumer Discretionary",
            industry: "Auto Manufacturers", marketCap: 568_000_000_000,
            sharesOutstanding: 3_190_000_000, float: 2_680_000_000,
            shortInterest: 3.12, shortRatio: 2.8, avgVolume: 112_500_000,
            week52High: 299.29, week52Low: 138.80, peRatio: 48.6,
            forwardPE: 62.3, dividendYield: nil, beta: 2.06,
            exchange: "NASDAQ", price: 178.22, change: -5.63, changePercent: -3.06
        )

        let now = Date()
        news = [
            NewsItem(title: "Tesla Cybertruck Deliveries Ramp to 2,500/Week",
                     source: "Electrek", publishedAt: now.addingTimeInterval(-5400),
                     url: "https://electrek.co/cybertruck", sentiment: .bullish,
                     tickers: ["TSLA"]),
            NewsItem(title: "Tesla Cuts Model Y Prices Across Europe",
                     source: "Reuters", publishedAt: now.addingTimeInterval(-18000),
                     url: "https://reuters.com/tesla-prices", sentiment: .bearish,
                     tickers: ["TSLA"]),
            NewsItem(title: "Musk Confirms Robotaxi Launch Timeline for Late 2026",
                     source: "CNBC", publishedAt: now.addingTimeInterval(-36000),
                     url: "https://cnbc.com/tesla-robotaxi", sentiment: .bullish,
                     tickers: ["TSLA"]),
            NewsItem(title: "Tesla Energy Storage Deployments Triple YoY",
                     source: "Bloomberg", publishedAt: now.addingTimeInterval(-54000),
                     url: "https://bloomberg.com/tesla-energy", sentiment: .bullish,
                     tickers: ["TSLA"]),
        ]

        filings = [
            SECFiling(type: "10-K", filedDate: now.addingTimeInterval(-86400 * 45),
                      description: "Annual Report for fiscal year ended December 2025",
                      url: "https://sec.gov/tsla/10k"),
            SECFiling(type: "10-Q", filedDate: now.addingTimeInterval(-86400 * 20),
                      description: "Quarterly Report for Q4 2025",
                      url: "https://sec.gov/tsla/10q"),
            SECFiling(type: "4", filedDate: now.addingTimeInterval(-86400 * 3),
                      description: "Statement of Changes - Elon Musk, CEO",
                      url: "https://sec.gov/tsla/form4-musk"),
        ]

        sentiment = SentimentData(
            mentionVolume: 28900,
            sentimentScore: 0.15,
            trend: .falling,
            topKeywords: ["Robotaxi", "FSD", "price cuts", "Cybertruck", "margins", "Musk", "China"]
        )

        aiAnalysis = AIStockAnalysis(
            recommendation: .hold,
            shortOpportunity: true,
            summary: "Tesla faces near-term margin pressure from aggressive price cuts while spending heavily on AI and robotaxi development. The energy storage business is a bright spot with triple-digit growth. Valuation remains stretched at 48x earnings with automotive gross margins compressing. The stock is in a wide trading range and sentiment is mixed. Robotaxi timeline is a key binary event -- success could justify the premium, but delays would pressure the stock significantly.",
            keyRisks: [
                "Auto gross margins declining from price war -- could fall below 15%",
                "Growing EV competition from BYD, Rivian, and legacy OEMs",
                "Regulatory risk around FSD and autonomous driving claims",
                "CEO distraction with multiple ventures impacting execution",
                "High beta stock vulnerable to broader market correction",
            ],
            keyCatalysts: [
                "Robotaxi launch could unlock $500B+ TAM",
                "Energy storage growing 200%+ YoY with high margins",
                "FSD v12 neural net approach showing improved capabilities",
                "Cybertruck ramp approaching profitability",
                "Next-gen affordable platform could restart volume growth",
            ],
            supportLevel: 165.00,
            resistanceLevel: 200.00,
            targetPrice: 190.00,
            confidence: 0.52
        )
    }

    private func loadNVDAMockData() {
        profile = StockProfile(
            symbol: "NVDA", name: "NVIDIA Corporation", sector: "Technology",
            industry: "Semiconductors", marketCap: 2_240_000_000_000,
            sharesOutstanding: 24_600_000_000, float: 24_210_000_000,
            shortInterest: 1.15, shortRatio: 0.9, avgVolume: 328_000_000,
            week52High: 974.00, week52Low: 473.20, peRatio: 65.2,
            forwardPE: 38.4, dividendYield: 0.02, beta: 1.68,
            exchange: "NASDAQ", price: 893.45, change: 18.72, changePercent: 2.14
        )

        let now = Date()
        news = [
            NewsItem(title: "NVIDIA Blackwell GPUs Ship to Major Cloud Providers",
                     source: "Reuters", publishedAt: now.addingTimeInterval(-2700),
                     url: "https://reuters.com/nvidia-blackwell", sentiment: .bullish,
                     tickers: ["NVDA"]),
            NewsItem(title: "Data Center Revenue Expected to Hit $30B in Q1",
                     source: "Bloomberg", publishedAt: now.addingTimeInterval(-10800),
                     url: "https://bloomberg.com/nvidia-datacenter", sentiment: .bullish,
                     tickers: ["NVDA"]),
            NewsItem(title: "China Export Restrictions Could Impact 8% of NVIDIA Revenue",
                     source: "Financial Times", publishedAt: now.addingTimeInterval(-21600),
                     url: "https://ft.com/nvidia-china", sentiment: .bearish,
                     tickers: ["NVDA"]),
            NewsItem(title: "Jensen Huang Keynote Unveils Next-Gen Rubin Architecture",
                     source: "The Verge", publishedAt: now.addingTimeInterval(-43200),
                     url: "https://theverge.com/nvidia-rubin", sentiment: .bullish,
                     tickers: ["NVDA"]),
        ]

        filings = [
            SECFiling(type: "10-K", filedDate: now.addingTimeInterval(-86400 * 35),
                      description: "Annual Report for fiscal year ended January 2026",
                      url: "https://sec.gov/nvda/10k"),
            SECFiling(type: "10-Q", filedDate: now.addingTimeInterval(-86400 * 15),
                      description: "Quarterly Report for Q4 FY2026",
                      url: "https://sec.gov/nvda/10q"),
            SECFiling(type: "8-K", filedDate: now.addingTimeInterval(-86400 * 10),
                      description: "Current Report - Earnings Release",
                      url: "https://sec.gov/nvda/8k"),
        ]

        sentiment = SentimentData(
            mentionVolume: 34200,
            sentimentScore: 0.81,
            trend: .rising,
            topKeywords: ["Blackwell", "AI", "data center", "GPU", "Rubin", "Jensen", "hyperscaler"]
        )

        aiAnalysis = AIStockAnalysis(
            recommendation: .strongBuy,
            shortOpportunity: false,
            summary: "NVIDIA remains the dominant AI infrastructure play with an unassailable competitive moat in GPU computing. Blackwell shipments are ramping faster than expected with data center revenue on track to exceed $100B annually. The forward P/E of 38x is reasonable given 80%+ revenue growth and expanding margins. Every major hyperscaler is increasing capex on NVIDIA hardware. The Rubin architecture roadmap provides multi-year visibility. Primary risk is demand normalization after the current build-out cycle.",
            keyRisks: [
                "AI spending cycle could decelerate in 2027 as capacity catches up",
                "China export restrictions reducing addressable market",
                "AMD and custom ASIC competition in inference workloads",
                "Concentration risk -- top 5 customers represent 50%+ of revenue",
            ],
            keyCatalysts: [
                "Blackwell GPU cycle driving 80%+ revenue growth",
                "Sovereign AI initiatives creating new demand pools globally",
                "Software/CUDA ecosystem creating deep vendor lock-in",
                "Automotive and robotics as emerging growth verticals",
                "Networking (Spectrum-X) adding $5B+ revenue stream",
            ],
            supportLevel: 850.00,
            resistanceLevel: 950.00,
            targetPrice: 1100.00,
            confidence: 0.88
        )
    }

    private func loadGenericMockData(for ticker: String) {
        profile = StockProfile(
            symbol: ticker, name: "\(ticker) Inc.", sector: "Technology",
            industry: "Software", marketCap: 50_000_000_000,
            sharesOutstanding: 500_000_000, float: 480_000_000,
            shortInterest: 2.5, shortRatio: 1.8, avgVolume: 15_000_000,
            week52High: 120.00, week52Low: 75.00, peRatio: 25.0,
            forwardPE: 22.0, dividendYield: nil, beta: 1.10,
            exchange: "NASDAQ", price: 98.50, change: 1.20, changePercent: 1.23
        )

        news = [
            NewsItem(title: "\(ticker) Reports Better Than Expected Quarterly Earnings",
                     source: "MarketWatch", publishedAt: Date().addingTimeInterval(-7200),
                     url: "https://marketwatch.com/\(ticker.lowercased())", sentiment: .bullish,
                     tickers: [ticker]),
        ]

        filings = [
            SECFiling(type: "10-Q", filedDate: Date().addingTimeInterval(-86400 * 15),
                      description: "Quarterly Report", url: "https://sec.gov/\(ticker.lowercased())/10q"),
        ]

        sentiment = SentimentData(
            mentionVolume: 1200,
            sentimentScore: 0.35,
            trend: .stable,
            topKeywords: ["earnings", "growth", "guidance"]
        )

        aiAnalysis = AIStockAnalysis(
            recommendation: .hold,
            shortOpportunity: false,
            summary: "Limited data available for detailed analysis. The stock appears fairly valued based on available metrics. Monitor for upcoming earnings reports and industry developments for more actionable insights.",
            keyRisks: ["Limited analyst coverage", "Sector-specific headwinds possible"],
            keyCatalysts: ["Upcoming earnings report", "Potential sector rotation tailwinds"],
            supportLevel: 90.00,
            resistanceLevel: 110.00,
            targetPrice: 105.00,
            confidence: 0.40
        )
    }
}
