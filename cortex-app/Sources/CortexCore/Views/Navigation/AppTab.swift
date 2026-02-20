import SwiftUI

/// Navigation tabs for the CORTEX trading platform.
public enum AppTab: String, CaseIterable, Identifiable {
    case warRoom = "War Room"
    case markets = "Markets"
    case scanner = "Scanner"
    case financials = "Financials"
    case watchlist = "Watchlist"
    case squadrons = "Squadrons"
    case performance = "Performance"
    case settings = "Settings"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .warRoom: return "shield.checkered"
        case .markets: return "chart.line.uptrend.xyaxis"
        case .scanner: return "antenna.radiowaves.left.and.right"
        case .financials: return "building.columns.fill"
        case .watchlist: return "eye.circle.fill"
        case .squadrons: return "person.3.sequence.fill"
        case .performance: return "chart.bar.xaxis"
        case .settings: return "gearshape.2.fill"
        }
    }

    public var shortcut: KeyEquivalent? {
        switch self {
        case .warRoom: return "1"
        case .markets: return "2"
        case .scanner: return "3"
        case .financials: return "4"
        case .watchlist: return "5"
        case .squadrons: return "6"
        case .performance: return "7"
        case .settings: return "8"
        }
    }

    /// Context pane sections for each tab.
    public var sections: [(icon: String, label: String)] {
        switch self {
        case .warRoom:
            return [
                ("rectangle.grid.2x2", "Overview"),
                ("shield.lefthalf.filled", "Squadron Status"),
                ("list.bullet.below.rectangle", "Activity Feed"),
                ("exclamationmark.triangle", "Risk Alerts"),
            ]
        case .markets:
            return [
                ("star.fill", "Favorites"),
                ("chart.bar.fill", "Indices"),
                ("dollarsign.circle", "Stocks"),
                ("bitcoinsign.circle", "Crypto"),
                ("doc.text.fill", "Options"),
            ]
        case .scanner:
            return [
                ("sparkle.magnifyingglass", "All Opportunities"),
                ("bolt.fill", "Momentum"),
                ("waveform.path.ecg", "Volume Surges"),
                ("arrow.up.right.circle", "Breakouts"),
                ("arrow.down.right.circle", "Short Candidates"),
                ("calendar.badge.exclamationmark", "Catalyst Events"),
                ("arrow.left.arrow.right.circle", "Options Flow"),
            ]
        case .financials:
            return [
                ("rectangle.grid.2x2", "Overview"),
                ("building.2", "Fundamentals"),
                ("doc.richtext", "SEC Filings"),
                ("newspaper", "News & Catalysts"),
                ("bubble.left.and.bubble.right", "Social Sentiment"),
                ("sparkles", "AI Analysis"),
            ]
        case .watchlist:
            return [
                ("briefcase.fill", "Active Positions"),
                ("list.bullet", "All Symbols"),
                ("bell.fill", "Alerts"),
                ("clock.arrow.circlepath", "Order History"),
            ]
        case .squadrons:
            return [
                ("person.3.fill", "All Squadrons"),
                ("a.circle.fill", "ALPHA"),
                ("b.circle.fill", "BRAVO"),
                ("c.circle.fill", "CHARLIE"),
                ("d.circle.fill", "DELTA"),
                ("e.circle.fill", "ECHO"),
                ("f.circle.fill", "FOXTROT"),
            ]
        case .performance:
            return [
                ("rectangle.grid.2x2", "Dashboard"),
                ("chart.line.uptrend.xyaxis", "Equity Curve"),
                ("list.number", "Trade Log"),
                ("doc.text", "Tax Report"),
            ]
        case .settings:
            return [
                ("wifi", "Connection"),
                ("key.fill", "API Keys"),
                ("exclamationmark.shield", "Risk Limits"),
                ("dial.medium", "Autonomy"),
                ("paintbrush", "Appearance"),
            ]
        }
    }

    /// Default section label for each tab.
    public var defaultSection: String {
        sections.first?.label ?? "Overview"
    }
}
