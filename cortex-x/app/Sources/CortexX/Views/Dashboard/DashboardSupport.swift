// Trading deck shared chrome: adaptive number formatting, table headers,
// hover rows, hairline rules, 4px gauges, status chips, and compact button
// styles. Everything here is scoped to the dashboard deck (Deck*/Dash*).

import Foundation
import SwiftUI

// MARK: - Formatting

enum DashFormat {
    /// Adaptive price: >= 100 -> grouped 2dp; >= 1 -> 2-4dp; < 1 -> 4 significant digits.
    static func price(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        let a = abs(v)
        if a >= 100 { return grouped(v, decimals: 2) }
        if a >= 1 { return trimmed(v, maxDecimals: 4, minDecimals: 2) }
        if a == 0 { return "0.00" }
        let leading = max(Int(ceil(-log10(a))), 1)
        let decimals = min(leading + 3, 10)
        return String(format: "%.\(decimals)f", v)
    }

    /// Money-shaped value: grouped, 2dp, optional forced "+" sign.
    static func money(_ v: Double, signed: Bool = false) -> String {
        grouped(v, decimals: 2, signed: signed)
    }

    /// Quantity: adaptive precision so values never wrap their column.
    static func qty(_ v: Double) -> String {
        guard v.isFinite else { return "—" }
        let a = abs(v)
        let decimals = a >= 1_000 ? 1 : (a >= 10 ? 2 : (a >= 1 ? 4 : 5))
        var s = String(format: "%.\(decimals)f", v)
        while s.contains("."), s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Quantity with explicit "+" for longs.
    static func signedQty(_ v: Double) -> String {
        v > 0 ? "+" + qty(v) : qty(v)
    }

    /// Fraction (0.012) shown as percent ("1.2%").
    static func pct(_ fraction: Double, decimals: Int = 1) -> String {
        guard fraction.isFinite else { return "—" }
        return String(format: "%.\(decimals)f%%", fraction * 100)
    }

    /// Editable (parse-safe, no grouping) rendering of a price for text fields.
    static func editable(_ v: Double) -> String {
        guard v.isFinite else { return "" }
        if abs(v) >= 100 { return String(format: "%.2f", v) }
        return price(v)
    }

    /// HH:mm:ss from engine millisecond timestamps.
    static func time(_ ms: Int64) -> String {
        timeFormatter.string(from: Date(timeIntervalSince1970: Double(ms) / 1000))
    }

    // MARK: internals

    static func grouped(_ v: Double, decimals: Int = 2, signed: Bool = false) -> String {
        guard v.isFinite else { return "—" }
        let magnitude = abs(v)
        // Sign decided after rounding so "-0.001" at 2dp doesn't print "-0.00".
        let scaled = (magnitude * pow(10, Double(decimals))).rounded()
        var sign = ""
        if scaled > 0 {
            if v < 0 { sign = "-" } else if signed { sign = "+" }
        }
        let plain = String(format: "%.\(decimals)f", magnitude)
        let parts = plain.split(separator: ".", maxSplits: 1)
        var intPart = String(parts[0])
        var groupedInt = ""
        while intPart.count > 3 {
            groupedInt = "," + String(intPart.suffix(3)) + groupedInt
            intPart = String(intPart.dropLast(3))
        }
        groupedInt = intPart + groupedInt
        let frac = parts.count > 1 ? "." + String(parts[1]) : ""
        return sign + groupedInt + frac
    }

    static func trimmed(_ v: Double, maxDecimals: Int, minDecimals: Int) -> String {
        guard v.isFinite else { return "—" }
        var s = String(format: "%.\(maxDecimals)f", v)
        guard let dot = s.firstIndex(of: ".") else { return s }
        var decimals = s.distance(from: s.index(after: dot), to: s.endIndex)
        while decimals > minDecimals, s.hasSuffix("0") {
            s.removeLast()
            decimals -= 1
        }
        if decimals == 0, s.hasSuffix(".") { s.removeLast() }
        return s
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()
}

// MARK: - Motion

enum DeckMotion {
    /// The one sanctioned easing: cubic-bezier(0.22, 1, 0.36, 1).
    static func ease(_ duration: Double = 0.2) -> Animation {
        .timingCurve(0.22, 1, 0.36, 1, duration: duration)
    }
}

// MARK: - Table chrome

/// 10pt dim uppercase tracked column header.
struct DeckHeaderCell: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.1)
            .foregroundStyle(Theme.dim)
            .lineLimit(1)
    }
}

/// Centered dim empty-state ("flat", "no orders", ...).
struct DeckEmpty: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Theme.dim)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct DeckHoverHighlight: ViewModifier {
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(hovering ? Theme.panelHi : Color.clear)
            .animation(DeckMotion.ease(), value: hovering)
            .onHover { hovering = $0 }
    }
}

extension View {
    /// Row hover highlight (panelHi wash).
    func deckHover() -> some View { modifier(DeckHoverHighlight()) }

    /// Hairline rule pinned to the bottom edge.
    func deckRowRule(_ opacity: Double = 0.5) -> some View {
        overlay(alignment: .bottom) {
            Rectangle()
                .fill(Theme.line.opacity(opacity))
                .frame(height: Theme.hairline)
        }
    }
}

// MARK: - Chips & gauges

/// Small tinted status chip (filled / rejected / working / maker / taker).
struct DeckChip: View {
    let text: String
    var color: Color = Theme.dim
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .lineLimit(1)
    }
}

/// 4px progress bar on a line track. Fill style is masked to the fraction,
/// so gradients read left-to-right across the whole 0..1 range.
struct DeckGaugeBar: View {
    let fraction: Double
    let style: AnyShapeStyle

    init(fraction: Double, style: AnyShapeStyle) {
        self.fraction = fraction
        self.style = style
    }

    init(fraction: Double, color: Color) {
        self.init(fraction: fraction, style: AnyShapeStyle(color))
    }

    private var clamped: Double {
        fraction.isFinite ? min(max(fraction, 0), 1) : 0
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.line)
                RoundedRectangle(cornerRadius: 2)
                    .fill(style)
                    .mask(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 2)
                            .frame(width: max(0, geo.size.width * clamped))
                    }
            }
            // No implicit width animation: these gauges show LIVE values that
            // change continuously, so an ease would be perpetually in-flight —
            // driving 60fps layout inside this GeometryReader forever (a CPU
            // peg). Live bars update instantly.
        }
        .frame(height: 4)
    }
}

// MARK: - Segments & compact buttons

/// One cell of a segmented control. Ember tint = selection by default;
/// buy/sell segments pass up/down.
/// Calm segmented control: selection is ONE emphasis (raised fill + brighter
/// text). Semantic tint (buy/sell) colors the text only — never fill+border.
struct DeckSegment: View {
    let title: String
    let isOn: Bool
    var tint: Color = Theme.bone
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? tint : Theme.dim)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 5)
                .background(isOn ? Theme.panelHi : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DeckMotion.ease(), value: isOn)
    }
}

/// Row-sized quiet button ("close", "cancel", "disengage").
struct DeckMiniButtonStyle: ButtonStyle {
    var tint: Color = Theme.bone
    var border: Color = Theme.line
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(tint)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(configuration.isPressed ? Theme.panelHi : Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.chipRadius)
                    .strokeBorder(border, lineWidth: Theme.hairline)
            )
    }
}

/// Full-size quiet button with a configurable tint/border (kill switch,
/// flatten confirm). Matches QuietButtonStyle metrics.
struct DeckTintedButtonStyle: ButtonStyle {
    var tint: Color = Theme.bone
    var border: Color = Theme.line
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(configuration.isPressed ? Theme.panelHi : Theme.panel)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius)
                    .strokeBorder(border, lineWidth: Theme.hairline)
            )
    }
}
