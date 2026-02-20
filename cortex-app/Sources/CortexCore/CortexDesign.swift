import SwiftUI

/// Centralized design system tokens for consistent styling across CORTEX.
public enum CortexDesign {
    // MARK: - Background Colors
    public static let bgDeepest = Color(white: 0.06)
    public static let bgCard = Color(white: 0.08)
    public static let bgHover = Color(white: 0.10)
    public static let bgElevated = Color(white: 0.12)

    // MARK: - Border Colors
    public static let border = Color(white: 0.12)
    public static let borderHover = Color(white: 0.18)

    // MARK: - Accent Colors
    public static let accentPrimary = Color.cyan
    public static let accentSecondary = Color.blue

    // MARK: - Semantic Colors
    public static let profit = Color.green
    public static let loss = Color.red
    public static let warning = Color.orange
    public static let neutral = Color(white: 0.5)

    // MARK: - Typography
    public static let dataFont = Font.system(.body, design: .monospaced)
    public static let labelFont = Font.system(.caption)
    public static let headerFont = Font.system(.title3, weight: .bold)
    public static let kpiFont = Font.system(size: 24, weight: .bold, design: .monospaced)
    public static let sectionFont = Font.system(size: 11, weight: .semibold)
    public static let badgeFont = Font.system(size: 10, weight: .medium, design: .monospaced)

    // MARK: - Spacing & Radii
    public static let cardRadius: CGFloat = 8
    public static let badgeRadius: CGFloat = 6
    public static let inputRadius: CGFloat = 12
    public static let cardPadding: CGFloat = 12
    public static let sectionSpacing: CGFloat = 16

    // MARK: - Shared Components

    /// Standard card background with border stroke.
    public static func cardBackground() -> some View {
        RoundedRectangle(cornerRadius: cardRadius)
            .fill(bgCard)
            .overlay(
                RoundedRectangle(cornerRadius: cardRadius)
                    .strokeBorder(border, lineWidth: 1)
            )
    }

    /// Elevated card background (for hover states, modals).
    public static func elevatedBackground() -> some View {
        RoundedRectangle(cornerRadius: cardRadius)
            .fill(bgElevated)
            .overlay(
                RoundedRectangle(cornerRadius: cardRadius)
                    .strokeBorder(borderHover, lineWidth: 1)
            )
    }

    /// Color for a numeric value (green if positive, red if negative, neutral if zero).
    public static func pnlColor(_ value: Double) -> Color {
        if value > 0 { return profit }
        if value < 0 { return loss }
        return neutral
    }

    /// Formatted P&L string with sign.
    public static func pnlString(_ value: Double, prefix: String = "$") -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(prefix)\(String(format: "%.2f", value))"
    }

    /// Formatted percentage string.
    public static func pctString(_ value: Double) -> String {
        let sign = value >= 0 ? "+" : ""
        return "\(sign)\(String(format: "%.2f", value))%"
    }
}
