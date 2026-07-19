// LEVEL 2 — a DAS-style montage: a two-column order-book depth ladder (bids on
// the left, asks on the right, each best-first with a muted depth-histogram bar
// behind every level) beside a streaming time & sales tape. The header carries
// the symbol plus a live mid/spread and an honest real/delayed source banner —
// delayed L1 is NEVER styled as live. Clicking a price level offers it to the
// order ticket via the model's price-set hook. The montage auto-subscribes
// depth for the selected symbol (one book at a time, to bound bandwidth) and
// unsubscribes when it leaves the screen. All math lives in the pure helpers
// (Level2Support); this file is arrangement + rows only.

import SwiftUI

struct Level2View: View {
    @Environment(AppModel.self) private var model

    private var symbol: String { model.selectedSymbol }
    private var depth: BookDepth? { model.bookDepth }

    // MARK: Derived ladder (sorted best-first + shared histogram scale)

    private struct LadderData {
        var bids: [BookLevel]
        var asks: [BookLevel]
        var maxSize: Double
        var bestBid: Double?
        var bestAsk: Double?
        var mid: Double?
        var spread: Double?
    }

    private var ladder: LadderData {
        let bids = DepthLadder.sortedBids(depth?.bids ?? [])
        let asks = DepthLadder.sortedAsks(depth?.asks ?? [])
        return LadderData(
            bids: bids,
            asks: asks,
            maxSize: DepthLadder.maxSize(bids: bids, asks: asks),
            bestBid: bids.first?.px,
            bestAsk: asks.first?.px,
            mid: DepthLadder.mid(bestBid: bids.first?.px, bestAsk: asks.first?.px),
            spread: DepthLadder.spread(bestBid: bids.first?.px, bestAsk: asks.first?.px)
        )
    }

    private var banner: DepthBanner { DepthBanner.make(for: depth) }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            header
            if banner.kind == .delayed { delayedNote }
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                ladderPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Rectangle().fill(Theme.line).frame(width: Theme.hairline)
                tapePane
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
        // Auto-subscribe the selected symbol; one book at a time. Re-subscribe
        // on symbol change and on reconnect (a dropped link cleared the old
        // subscription); free the bandwidth when the montage leaves the screen.
        .onAppear { model.subscribeDepth(symbol) }
        .onDisappear { model.unsubscribeDepth() }
        .onChange(of: model.selectedSymbol) { _, s in model.subscribeDepth(s) }
        .onChange(of: model.connection) { _, c in
            if c == .connected { model.subscribeDepth(model.selectedSymbol) }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 14) {
            SectionLabel(text: "level 2")
            Text(symbol)
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .foregroundStyle(Theme.bone)
                .lineLimit(1)
            headerStat("mid", ladder.mid.map { DashFormat.price($0) } ?? "—",
                       ladder.mid == nil ? Theme.dim : Theme.bone)
            headerStat("spread", ladder.spread.map { DashFormat.price($0) } ?? "—", Theme.dim)
            Spacer()
            sourceBanner
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func headerStat(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.dim)
            Text(value)
                .numeric(size: 12, weight: .medium)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    /// Honest source + real/delayed posture. Good data stays quiet (a calm dim
    /// "REAL-TIME"); a delayed feed draws an ember attention dot and reads
    /// "DELAYED L1" — never green/live styling on delayed depth.
    private var sourceBanner: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(banner.isLive ? Theme.dim : (banner.kind == .delayed ? Theme.ember : Theme.dim))
                .frame(width: 6, height: 6)
            Text(banner.isLive ? "REAL-TIME" : (banner.kind == .delayed ? "DELAYED L1" : "WAITING"))
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.0)
                .foregroundStyle(banner.kind == .delayed ? Theme.ember : Theme.dim)
            if banner.kind != .waiting {
                Text("·")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.dim)
                Text(banner.source)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
        }
        .help(banner.note)
        .accessibilityLabel("depth feed \(banner.isLive ? "real time" : "delayed") \(banner.source)")
    }

    /// A full-width honest note under the header whenever depth is delayed L1,
    /// so the operator can never mistake it for real-time book. Calm chrome (an
    /// ember attention dot + dim text), never a loud warning color.
    private var delayedNote: some View {
        HStack(spacing: 8) {
            Circle().fill(Theme.ember).frame(width: 5, height: 5)
            Text(banner.note)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(Theme.panel)
    }

    // MARK: Depth ladder (two columns: bids | asks, best-first)

    private var ladderPane: some View {
        VStack(spacing: 0) {
            ladderHeaderRow
            Divider().overlay(Theme.line)
            ladderBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var ladderHeaderRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                DeckHeaderCell("size")
                Spacer(minLength: 0)
                DeckHeaderCell("bid")
            }
            .frame(maxWidth: .infinity)
            Rectangle().fill(Theme.line).frame(width: Theme.hairline)
            HStack(spacing: 0) {
                DeckHeaderCell("ask")
                Spacer(minLength: 0)
                DeckHeaderCell("size")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.ink)
    }

    @ViewBuilder
    private var ladderBody: some View {
        if depth == nil {
            DeckEmpty(text: "waiting for depth…")
        } else if ladder.bids.isEmpty && ladder.asks.isEmpty {
            DeckEmpty(text: "no book")
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                HStack(alignment: .top, spacing: 0) {
                    depthColumn(ladder.bids, side: .buy)
                    Rectangle().fill(Theme.line).frame(width: Theme.hairline)
                    depthColumn(ladder.asks, side: .sell)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private func depthColumn(_ levels: [BookLevel], side: Side) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(levels.enumerated()), id: \.offset) { index, level in
                DepthRow(
                    level: level,
                    side: side,
                    isBest: index == 0,
                    fraction: DepthLadder.barFraction(size: level.sz, maxSize: ladder.maxSize),
                    onClick: { model.setTicketPrice(level.px) }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    // MARK: Time & sales tape

    private var tapePane: some View {
        VStack(spacing: 0) {
            tapeHeaderRow
            Divider().overlay(Theme.line)
            if model.tape.isEmpty {
                DeckEmpty(text: depth == nil ? "waiting for prints…" : "no prints yet")
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        // Newest-first already; enumerated offset keeps identity
                        // stable across a fast prepending stream (duplicate
                        // prints never collide on a composite id).
                        ForEach(Array(model.tape.enumerated()), id: \.offset) { _, item in
                            TapeRow(print: item)
                        }
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(width: 320)
        .frame(maxHeight: .infinity)
    }

    private var tapeHeaderRow: some View {
        HStack(spacing: 0) {
            DeckHeaderCell("time")
                .frame(width: 68, alignment: .leading)
            DeckHeaderCell("price")
                .frame(maxWidth: .infinity, alignment: .leading)
            DeckHeaderCell("size")
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.ink)
    }
}

// MARK: - Depth ladder row

/// One order-book level: a muted depth-histogram bar (shared scale across both
/// sides) grows from the center gutter, with the size / order-count / price
/// laid over it. Bids color the green side, asks the red side (the only
/// direction color); the best bid/ask is bold + full-tone. The whole row is a
/// click target that seats its price into the order ticket.
private struct DepthRow: View {
    let level: BookLevel
    /// .buy = bid column (green side, bar to the right toward the gutter),
    /// .sell = ask column (red side, bar to the left toward the gutter).
    let side: Side
    let isBest: Bool
    let fraction: Double
    let onClick: () -> Void
    @State private var hovering = false

    private var isBid: Bool { side == .buy }
    private var tone: Color { isBid ? Theme.up : Theme.down }
    private var barAlignment: Alignment { isBid ? .trailing : .leading }

    private var sizeText: some View {
        Text(DashFormat.qty(level.sz))
            .numeric(size: 10)
            .foregroundStyle(Theme.dim)
            .lineLimit(1)
    }

    private var priceText: some View {
        Text(DashFormat.price(level.px))
            .numeric(size: 11, weight: isBest ? .bold : .regular)
            .foregroundStyle(tone.opacity(isBest ? 1 : 0.85))
            .lineLimit(1)
    }

    private var orderCount: some View {
        // Only when the venue reported a count (0 = omitted).
        Group {
            if level.count > 0 {
                Text("\(level.count)")
                    .font(.system(size: 8, weight: .medium, design: .monospaced))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
        }
    }

    var body: some View {
        Button(action: onClick) {
            content
                .padding(.horizontal, 10)
                .frame(height: 20)
                .frame(maxWidth: .infinity)
                .background(alignment: barAlignment) { bar }
                .background(rowWash)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
        .help("set ticket price \(DashFormat.price(level.px))")
    }

    /// Bids read size → price (price toward the center gutter); asks mirror it,
    /// price → size, so the two price columns meet in the middle.
    @ViewBuilder
    private var content: some View {
        if isBid {
            HStack(spacing: 6) {
                sizeText
                orderCount
                Spacer(minLength: 4)
                priceText
            }
        } else {
            HStack(spacing: 6) {
                priceText
                Spacer(minLength: 4)
                orderCount
                sizeText
            }
        }
    }

    private var bar: some View {
        GeometryReader { geo in
            Rectangle()
                .fill(tone.opacity(0.14))
                .frame(width: max(0, geo.size.width * fraction))
                .frame(maxWidth: .infinity, alignment: barAlignment)
        }
    }

    private var rowWash: some View {
        Rectangle()
            .fill(hovering ? Theme.panelHi : (isBest ? tone.opacity(0.06) : Color.clear))
    }
}

// MARK: - Tape row

/// One time & sales print: time · price · size, the price colored by aggressor
/// (buy = up, sell = down, unknown = dim) with a matching direction glyph.
/// Monospaced throughout so the tape reads as a clean column.
private struct TapeRow: View {
    let print: TapePrint

    private var tone: AggressorTone { AggressorTone.tone(for: print.aggressor) }

    private var color: Color {
        switch tone {
        case .up: Theme.up
        case .down: Theme.down
        case .neutral: Theme.dim
        }
    }

    private var glyph: String {
        switch tone {
        case .up: "arrow.up"
        case .down: "arrow.down"
        case .neutral: "minus"
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: glyph)
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(color)
                    .frame(width: 8)
                Text(DashFormat.time(print.ts_ms))
                    .numeric(size: 10)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
            }
            .frame(width: 68, alignment: .leading)
            Text(DashFormat.price(print.px))
                .numeric(size: 11, weight: .medium)
                .foregroundStyle(color)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(DashFormat.qty(print.sz))
                .numeric(size: 10)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .frame(width: 72, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .frame(height: 18)
        .frame(maxWidth: .infinity)
        .deckRowRule(0.4)
    }
}
