import SwiftUI

/// Horizontal top tab bar for CORTEX navigation.
/// Left: CORTEX logo. Center: Tab buttons. Right: AI sparkle, connection dot, daily P&L.
public struct TabBarView: View {
    @Binding var selectedTab: AppTab
    let onSparklesTapped: () -> Void
    let isAIPaneVisible: Bool
    let dailyPnL: Double
    let isConnected: Bool

    @State private var hoveredTab: AppTab? = nil

    public init(
        selectedTab: Binding<AppTab>,
        onSparklesTapped: @escaping () -> Void,
        isAIPaneVisible: Bool,
        dailyPnL: Double,
        isConnected: Bool
    ) {
        self._selectedTab = selectedTab
        self.onSparklesTapped = onSparklesTapped
        self.isAIPaneVisible = isAIPaneVisible
        self.dailyPnL = dailyPnL
        self.isConnected = isConnected
    }

    public var body: some View {
        HStack(spacing: 0) {
            // Left: CORTEX logo
            Text("CORTEX")
                .font(.system(size: 15, weight: .black, design: .monospaced))
                .foregroundStyle(.cyan)
                .padding(.leading, 16)
                .padding(.trailing, 20)

            // Center: Tab buttons
            HStack(spacing: 2) {
                ForEach(AppTab.allCases) { tab in
                    TabBarButton(
                        tab: tab,
                        isSelected: selectedTab == tab,
                        isHovered: hoveredTab == tab
                    ) {
                        selectedTab = tab
                    }
                    .onHover { hovering in
                        hoveredTab = hovering ? tab : nil
                    }
                }
            }

            Spacer()

            // Right: AI sparkle + connection + P&L
            HStack(spacing: 14) {
                // AI Overlay toggle
                Button(action: onSparklesTapped) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(isAIPaneVisible ? .cyan : Color(white: 0.5))
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isAIPaneVisible ? Color.cyan.opacity(0.15) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle AI Overlay (Cmd+Shift+A)")

                // Connection status
                HStack(spacing: 5) {
                    Circle()
                        .fill(isConnected ? Color.green : Color.orange)
                        .frame(width: 7, height: 7)
                        .shadow(color: (isConnected ? Color.green : Color.orange).opacity(0.5), radius: 3)
                    Text(isConnected ? "Live" : "Local")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color(white: 0.5))
                }

                // Daily P&L
                HStack(spacing: 4) {
                    Image(systemName: dailyPnL >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(dailyPnL >= 0 ? .green : .red)
                    Text(formatCurrency(dailyPnL))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(dailyPnL >= 0 ? .green : .red)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((dailyPnL >= 0 ? Color.green : Color.red).opacity(0.08))
                )
            }
            .padding(.trailing, 16)
        }
        .frame(height: 52)
        .background(Color(nsColor: NSColor(red: 0.07, green: 0.07, blue: 0.10, alpha: 1.0)))
    }

    private func formatCurrency(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return String(format: "%@$%.0f", sign, abs(value))
    }
}

// MARK: - Tab Bar Button

struct TabBarButton: View {
    let tab: AppTab
    let isSelected: Bool
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: tab.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? .cyan : isHovered ? Color(white: 0.7) : Color(white: 0.45))
                    .frame(height: 18)

                Text(tab.rawValue)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(isSelected ? .cyan : isHovered ? Color(white: 0.7) : Color(white: 0.45))
                    .lineLimit(1)
            }
            .frame(width: 80, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered && !isSelected ? Color(white: 0.12) : Color.clear)
            )
            .overlay(alignment: .bottom) {
                if isSelected {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Color.cyan)
                        .frame(width: 40, height: 2)
                        .offset(y: 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
    }
}
