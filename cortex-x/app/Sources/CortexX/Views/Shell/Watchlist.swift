// Left rail: live watchlist + feed health footer.

import SwiftUI

struct Watchlist: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: "watchlist")
                .padding(.horizontal, 4)
            VStack(spacing: 4) {
                ForEach(model.symbols, id: \.self) { symbol in
                    WatchlistRow(symbol: symbol)
                }
            }
            if model.symbols.isEmpty {
                Text("waiting for engine")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.dim)
                    .padding(.horizontal, 4)
            }
            Spacer()
            FeedFooter()
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct WatchlistRow: View {
    @Environment(AppModel.self) private var model
    let symbol: String
    @State private var hovering = false

    private var isSelected: Bool { model.selectedSymbol == symbol }

    var body: some View {
        Button {
            model.selectedSymbol = symbol
        } label: {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(symbol)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(Theme.bone)
                    if let pos = model.positions[symbol], abs(pos.qty) > 1e-12 {
                        Text(pos.qty > 0 ? "Long \(Fmt.qty(abs(pos.qty)))" : "Short \(Fmt.qty(abs(pos.qty)))")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(pos.qty > 0 ? Theme.up : Theme.down)
                    }
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(model.lastPrice(symbol).map(Fmt.price) ?? "—")
                        .numeric(size: 12, weight: .medium)
                        .foregroundStyle(Theme.bone)
                    if let pct = model.sessionChangePct(symbol) {
                        Text(Fmt.signedPct(pct))
                            .numeric(size: 10)
                            .foregroundStyle(Theme.pnlColor(pct))
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isSelected || hovering ? Theme.panelHi : .clear)
        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
        .onHover { hovering = $0 }
    }
}

private struct FeedFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: "feeds")
            ForEach(model.feeds.values.sorted { $0.feed < $1.feed }, id: \.feed) { feed in
                HStack(spacing: 6) {
                    Circle()
                        .fill(color(feed.health))
                        .frame(width: 6, height: 6)
                    Text(feed.feed)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.bone)
                    Spacer()
                    Text(label(feed.health))
                        .font(.system(size: 9))
                        .foregroundStyle(Theme.dim)
                }
                .help(feed.detail)
            }
            if model.feeds.isEmpty {
                Text("no feeds yet")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    private func color(_ h: FeedHealth) -> Color {
        switch h {
        case .live: Theme.up
        case .degraded: Theme.warn
        case .synthetic_fallback: Theme.warn
        case .down: Theme.down
        }
    }

    private func label(_ h: FeedHealth) -> String {
        switch h {
        case .live: "live"
        case .degraded: "degraded"
        case .synthetic_fallback: "synthetic"
        case .down: "down"
        }
    }
}

/// Shared number formatting for the shell (panels may keep their own).
enum Fmt {
    static func price(_ v: Double) -> String {
        let a = abs(v)
        let dp = a >= 100 ? 2 : (a >= 1 ? 4 : 6)
        return v.formatted(.number.precision(.fractionLength(dp)).grouping(.automatic))
    }
    static func qty(_ v: Double) -> String {
        v.formatted(.number.precision(.fractionLength(0...6)))
    }
    static func signedPct(_ v: Double) -> String {
        (v >= 0 ? "+" : "") + v.formatted(.number.precision(.fractionLength(2))) + "%"
    }
    static func money(_ v: Double) -> String {
        (v < 0 ? "-$" : "$") + abs(v).formatted(.number.precision(.fractionLength(2)).grouping(.automatic))
    }
    static func signedMoney(_ v: Double) -> String {
        (v >= 0 ? "+$" : "-$") + abs(v).formatted(.number.precision(.fractionLength(2)).grouping(.automatic))
    }
}
