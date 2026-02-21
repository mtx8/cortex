import SwiftUI

/// Horizontal top tab bar for CORTEX navigation.
/// Left: CORTEX logo. Center: Text-only pill tab buttons. Right: AI sparkle, connection dot, daily P&L.
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
                .foregroundStyle(CortexDesign.accentPrimary)
                .padding(.leading, 16)
                .padding(.trailing, 20)

            // Center: Text-only pill tab buttons
            HStack(spacing: 4) {
                ForEach(AppTab.allCases) { tab in
                    TabBarPillButton(
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
                        .foregroundStyle(isAIPaneVisible ? .cyan : CortexDesign.neutral)
                        .frame(width: 30, height: 30)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isAIPaneVisible ? CortexDesign.accentPrimary.opacity(0.15) : Color.clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle AI Overlay (Cmd+Shift+A)")

                // Connection status
                HStack(spacing: 5) {
                    Circle()
                        .fill(isConnected ? CortexDesign.profit : CortexDesign.warning)
                        .frame(width: 7, height: 7)
                        .shadow(color: (isConnected ? CortexDesign.profit : CortexDesign.warning).opacity(0.5), radius: 3)
                    Text(isConnected ? "Live" : "Local")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(CortexDesign.neutral)
                }

                // Daily P&L
                HStack(spacing: 4) {
                    Image(systemName: dailyPnL >= 0 ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(dailyPnL >= 0 ? CortexDesign.profit : CortexDesign.loss)
                    Text(formatCurrency(dailyPnL))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(dailyPnL >= 0 ? CortexDesign.profit : CortexDesign.loss)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill((dailyPnL >= 0 ? CortexDesign.profit : CortexDesign.loss).opacity(0.08))
                )
            }
            .padding(.trailing, 16)
        }
        .frame(height: 44)
        .background(CortexDesign.bgDeepest)
    }

    private func formatCurrency(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return String(format: "%@$%.0f", sign, abs(value))
    }
}

// MARK: - Tab Bar Pill Button (text-only, no icons)

struct TabBarPillButton: View {
    let tab: AppTab
    let isSelected: Bool
    let isHovered: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(tab.rawValue)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    isSelected ? .white : CortexDesign.neutral
                )
                .lineLimit(1)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(pillBackground)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(tab.rawValue)
    }

    private var pillBackground: Color {
        if isSelected {
            return CortexDesign.accentPrimary
        } else if isHovered {
            return CortexDesign.bgCard
        } else {
            return .clear
        }
    }
}
