import SwiftUI

/// Navigation tabs for the CORTEX trading platform.
public enum AppTab: String, CaseIterable, Identifiable {
    case warRoom = "War Room"
    case charts = "Charts"
    case scanner = "Scanner"
    case squadrons = "Squadrons"
    case watchlist = "Watchlist"
    case chat = "CORTEX AI"
    case performance = "Performance"
    case settings = "Settings"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .warRoom: return "shield.fill"
        case .charts: return "chart.xyaxis.line"
        case .scanner: return "dot.radiowaves.left.and.right"
        case .squadrons: return "person.3.fill"
        case .watchlist: return "list.bullet.rectangle"
        case .chat: return "brain.head.profile"
        case .performance: return "chart.line.uptrend.xyaxis"
        case .settings: return "gear"
        }
    }

    public var shortcut: KeyEquivalent? {
        switch self {
        case .warRoom: return "1"
        case .charts: return "2"
        case .scanner: return "3"
        case .squadrons: return "4"
        case .watchlist: return "5"
        case .chat: return "6"
        case .performance: return "7"
        case .settings: return "8"
        }
    }

    /// Whether this tab appears in the bottom section of the sidebar.
    public var isBottomItem: Bool {
        self == .settings
    }
}

/// Professional collapsible sidebar for CORTEX navigation.
/// Supports expanded (200px with icons + labels) and collapsed (48px icons only) states.
/// Toggle with Cmd+B.
public struct SidebarView: View {
    @Binding var selectedTab: AppTab
    @Binding var isExpanded: Bool
    let dailyPnL: Double

    public init(selectedTab: Binding<AppTab>, isExpanded: Binding<Bool>, dailyPnL: Double) {
        self._selectedTab = selectedTab
        self._isExpanded = isExpanded
        self.dailyPnL = dailyPnL
    }

    private var mainTabs: [AppTab] {
        AppTab.allCases.filter { !$0.isBottomItem }
    }

    private var bottomTabs: [AppTab] {
        AppTab.allCases.filter { $0.isBottomItem }
    }

    public var body: some View {
        VStack(spacing: 0) {
            // Header
            sidebarHeader

            Divider()
                .overlay(Color(white: 0.2))

            // Main navigation items
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(mainTabs) { tab in
                        SidebarNavItem(
                            tab: tab,
                            isSelected: selectedTab == tab,
                            isExpanded: isExpanded
                        ) {
                            selectedTab = tab
                        }
                    }
                }
                .padding(.vertical, 8)
                .padding(.horizontal, 6)
            }

            Spacer()

            Divider()
                .overlay(Color(white: 0.2))

            // Bottom section: Daily P&L + Settings
            VStack(spacing: 4) {
                if isExpanded {
                    dailyPnLDisplay
                } else {
                    compactPnLDisplay
                }

                ForEach(bottomTabs) { tab in
                    SidebarNavItem(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        isExpanded: isExpanded
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 6)
        }
        .frame(width: isExpanded ? 200 : 48)
        .background(Color(nsColor: NSColor(red: 0.08, green: 0.08, blue: 0.12, alpha: 1.0)))
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
    }

    // MARK: - Header

    private var sidebarHeader: some View {
        HStack(spacing: 8) {
            if isExpanded {
                Text("CORTEX")
                    .font(.system(size: 16, weight: .black, design: .monospaced))
                    .foregroundStyle(.white)
                Spacer()
            }

            Button(action: { isExpanded.toggle() }) {
                Image(systemName: isExpanded ? "sidebar.left" : "sidebar.right")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Toggle sidebar (Cmd+B)")
        }
        .padding(.horizontal, isExpanded ? 12 : 10)
        .frame(height: 48)
    }

    // MARK: - P&L Display

    private var dailyPnLDisplay: some View {
        HStack(spacing: 6) {
            Image(systemName: dailyPnL >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.caption2)
                .foregroundStyle(dailyPnL >= 0 ? .green : .red)

            VStack(alignment: .leading, spacing: 1) {
                Text("Daily P&L")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(formatCurrency(dailyPnL))
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(dailyPnL >= 0 ? .green : .red)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((dailyPnL >= 0 ? Color.green : Color.red).opacity(0.08))
        )
    }

    private var compactPnLDisplay: some View {
        VStack(spacing: 2) {
            Image(systemName: dailyPnL >= 0 ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 10))
                .foregroundStyle(dailyPnL >= 0 ? .green : .red)
        }
        .frame(width: 36, height: 28)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill((dailyPnL >= 0 ? Color.green : Color.red).opacity(0.08))
        )
    }

    private func formatCurrency(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return String(format: "%@$%.0f", sign, abs(value))
    }
}

// MARK: - Sidebar Navigation Item

struct SidebarNavItem: View {
    let tab: AppTab
    let isSelected: Bool
    let isExpanded: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20, height: 20)
                    .foregroundStyle(isSelected ? .white : .secondary)

                if isExpanded {
                    Text(tab.rawValue)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? .white : Color(white: 0.65))
                        .lineLimit(1)
                    Spacer()
                }
            }
            .padding(.horizontal, isExpanded ? 10 : 0)
            .frame(width: isExpanded ? nil : 36, height: 32)
            .frame(maxWidth: isExpanded ? .infinity : nil, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isSelected ? Color.accentColor.opacity(0.25) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
    }
}
