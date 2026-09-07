// CortexX design tokens — see docs/DESIGN.md. Silo Unison aesthetic:
// ink canvas, hairline panels, bone text, one ember accent.
// Green/red are reserved for money and direction; ember means attention & AI.

import SwiftUI

enum Theme {
    // MARK: Canvas & panels
    static let ink = Color(hex: 0x0A0A0C)
    static let panel = Color(hex: 0x131318)
    static let panelHi = Color(hex: 0x1A1A21)
    static let line = Color(hex: 0x26262E)

    // MARK: Text
    static let bone = Color(hex: 0xF5EFE4)
    static let dim = Color(hex: 0x8B8B96)

    // MARK: Accent
    static let ember = Color(hex: 0xE08A2A)
    static let emberHi = Color(hex: 0xEDA23F)
    static let emberDown = Color(hex: 0xB56F1E)
    static let emberTint = Color(hex: 0xE08A2A).opacity(0.10)
    static let onEmber = Color(hex: 0x141005)
    /// TRUE orange, for the one deliberately neon element (the chart's bar-close
    /// countdown). The whole ember family sits at hue 31-34 deg — amber-gold, not
    /// orange — and `emberHi` in particular is 34 deg at 59% lightness, one step
    /// from `warn` (42 deg). Lit up and bloomed, amber reads YELLOW, which is
    /// exactly how it looked on screen. This is hue 24 deg at full saturation:
    /// unmistakably orange, and far enough from `warn` that a glowing countdown
    /// can never be mistaken for a warning.
    ///
    /// Reserved for that element. It is NOT a second accent — ember remains the
    /// one accent for every other surface.
    static let emberNeon = Color(hex: 0xFF7518)

    // MARK: Semantics
    static let up = Color(hex: 0x3FB68B)
    static let down = Color(hex: 0xD8233A)
    static let warn = Color(hex: 0xD8A123)

    static let cornerRadius: CGFloat = 8
    static let chipRadius: CGFloat = 6
    static let hairline: CGFloat = 1

    static func pnlColor(_ value: Double) -> Color {
        if value > 0 { return up }
        if value < 0 { return down }
        return dim
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255.0,
            green: Double((hex >> 8) & 0xFF) / 255.0,
            blue: Double(hex & 0xFF) / 255.0,
            opacity: 1.0
        )
    }
}

// MARK: - Reusable styles

/// 11pt uppercase tracked section label. Single-line by contract: it heads many
/// horizontally-constrained columns (Regimes board, Company relations, Meridian
/// panes, dock panels), so a two-word title ("entering bull", "latest filings")
/// truncates instead of wrapping to a second line when its column is narrow.
struct SectionLabel: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(2.5)
            .foregroundStyle(Theme.dim)
            .lineLimit(1)
    }
}

struct PanelBackground: ViewModifier {
    var highlighted = false
    func body(content: Content) -> some View {
        content
            .background(highlighted ? Theme.panelHi : Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
            )
    }
}

extension View {
    func panel(highlighted: Bool = false) -> some View {
        modifier(PanelBackground(highlighted: highlighted))
    }

    /// Monospaced-digit numeric text, the default for anything money-shaped.
    func numeric(size: CGFloat = 13, weight: Font.Weight = .regular) -> some View {
        font(.system(size: size, weight: weight)).monospacedDigit()
    }
}

struct EmberButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Theme.onEmber)
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(configuration.isPressed ? Theme.emberDown : Theme.ember)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
    }
}

struct QuietButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.bone)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.panelHi : Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(Theme.line, lineWidth: Theme.hairline)
            )
    }
}
