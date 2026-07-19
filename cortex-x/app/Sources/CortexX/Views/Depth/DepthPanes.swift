// Reusable Level 2 subviews — the centered price-ladder DOM and the time &
// sales tape, decomposed out of the retired standalone LEVEL 2 section so they
// can be stacked BESIDE the chart in the trading dock (see Views/Chart/
// TradingDock.swift). Each renders the actively-subscribed symbol's book/tape
// from the model; the depth subscription lifecycle lives in the workspace, not
// here. The DOM redesign (centered inside-market ladder with an outward-fanning
// depth histogram) is preserved verbatim — only the outer section chrome
// (labeled header, collapse affordance, source banner) moved up to the dock.
// All layout math still lives in the pure helpers (Level2Support).

import SwiftUI

// MARK: - DOM ladder (centered price ladder)

/// The centered order-book ladder for the subscribed symbol: a single price
/// axis down the middle, asks stacked above the inside market (best ask nearest
/// the center), bids below, a thin spread row seated dead-center, and a muted
/// depth histogram fanning OUTWARD from the axis. Renders the model's
/// `bookDepth` — nil resolves to an honest waiting state, never a stale book.
/// Clicking a level offers its price to the order ticket. Grid only; the dock
/// wraps it with the labeled header + real/delayed source banner.
struct DomLadder: View {
    @Environment(AppModel.self) private var model

    private var depth: BookDepth? { model.bookDepth }

    // MARK: Derived ladder (sorted best-first + shared histogram scale)

    private struct LadderData {
        var bids: [BookLevel]
        var asks: [BookLevel]
        var maxSize: Double
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
            mid: DepthLadder.mid(bestBid: bids.first?.px, bestAsk: asks.first?.px),
            spread: DepthLadder.spread(bestBid: bids.first?.px, bestAsk: asks.first?.px)
        )
    }

    // MARK: Ladder geometry (shared by the fill math + the rows)

    /// Fixed level-row height — the unit the fill math packs into the pane.
    private static let rowHeight: CGFloat = 22
    /// The centered inside-market spread row; a touch taller to seat the mid.
    private static let spreadHeight: CGFloat = 26
    /// Fixed center price-axis width, so bids/asks meet on one aligned column.
    private static let priceWidth: CGFloat = 92
    /// Horizontal inset shared by the ladder header + rows (keeps the price
    /// axis aligned and insets the depth bars a hair from the pane edge).
    private static let rowInset: CGFloat = 8

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            ladderHeaderRow
            Divider().overlay(Theme.line)
            ladderBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Column labels directly above the rows: bids fan left, asks fan right, the
    /// price axis in the center — the same three-zone grid the level rows use,
    /// so every label sits over its column.
    private var ladderHeaderRow: some View {
        HStack(spacing: 0) {
            HStack(spacing: 0) {
                DeckHeaderCell("bids")
                Spacer(minLength: 0)
                // Match the 8px axis inset of the row size values (sizeCluster).
                DeckHeaderCell("size")
                    .padding(.trailing, 8)
            }
            .frame(maxWidth: .infinity)
            DeckHeaderCell("price")
                .frame(width: Self.priceWidth)
            HStack(spacing: 0) {
                // Match the 8px axis inset of the row size values (sizeCluster).
                DeckHeaderCell("size")
                    .padding(.leading, 8)
                Spacer(minLength: 0)
                DeckHeaderCell("asks")
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Self.rowInset)
        .padding(.vertical, 6)
        .background(Theme.ink)
    }

    /// The centered ladder. A GeometryReader hands the pure fill math the pane
    /// height; it returns how many levels fit each side and the outer padding
    /// that keeps the spread row dead-center — so the book fills top-to-bottom
    /// with the inside market in the middle (never bottom-anchored, no void).
    @ViewBuilder
    private var ladderBody: some View {
        // Sort both sides + resolve the shared histogram scale ONCE per render.
        // `ladder` is a computed property, so every access re-sorts the whole
        // book — reading it per row (for the shared maxSize) meant ~20+ full
        // sorts every ~12 Hz flush. Bind it here and thread `maxSize` down.
        let data = ladder
        if depth == nil {
            DeckEmpty(text: "waiting for depth…")
        } else if data.bids.isEmpty && data.asks.isEmpty {
            DeckEmpty(text: "no book")
        } else {
            GeometryReader { geo in
                let layout = LadderLayout.fit(
                    height: Double(geo.size.height),
                    rowHeight: Double(Self.rowHeight),
                    spreadHeight: Double(Self.spreadHeight),
                    askCount: data.asks.count,
                    bidCount: data.bids.count
                )
                let asks = DepthLadder.visibleAskRows(data.asks, count: layout.visibleAsks)
                let bids = DepthLadder.visibleBidRows(data.bids, count: layout.visibleBids)
                VStack(spacing: 0) {
                    Color.clear.frame(height: CGFloat(layout.topPad))
                    // Asks top→bottom: highest shown ask down to the best ask,
                    // which lands directly above the spread row.
                    ForEach(asks.indices, id: \.self) { i in
                        depthRow(asks[i], side: .sell, isBest: i == asks.count - 1, maxSize: data.maxSize)
                    }
                    spreadRow(data)
                    // Bids top→bottom: best bid directly below the spread, lower
                    // bids beneath it.
                    ForEach(bids.indices, id: \.self) { i in
                        depthRow(bids[i], side: .buy, isBest: i == 0, maxSize: data.maxSize)
                    }
                    Color.clear.frame(height: CGFloat(layout.bottomPad))
                }
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
        }
    }

    private func depthRow(_ level: BookLevel, side: Side, isBest: Bool, maxSize: Double) -> some View {
        DepthRow(
            level: level,
            side: side,
            isBest: isBest,
            fraction: DepthLadder.barFraction(size: level.sz, maxSize: maxSize),
            priceWidth: Self.priceWidth,
            rowHeight: Self.rowHeight,
            inset: Self.rowInset,
            onClick: { model.setTicketPrice(level.px) }
        )
    }

    /// The thin inside-market band seated dead-center: mid + spread, dim and
    /// calm, framed top and bottom by a subtle ember hairline that marks the
    /// best bid/ask straddling it as the inside market.
    private func spreadRow(_ data: LadderData) -> some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            spreadStat("spread", data.spread.map { DashFormat.price($0) } ?? "—", Theme.dim)
            Text("·").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.dim)
            spreadStat("mid", data.mid.map { DashFormat.price($0) } ?? "—", Theme.bone)
            Spacer(minLength: 0)
        }
        .frame(height: Self.spreadHeight)
        .frame(maxWidth: .infinity)
        .background(Theme.panel)
        .overlay(alignment: .top) { emberEdge }
        .overlay(alignment: .bottom) { emberEdge }
    }

    private func spreadStat(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(label.uppercased())
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.dim)
            Text(value)
                .numeric(size: 11, weight: .medium)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private var emberEdge: some View {
        Rectangle().fill(Theme.ember.opacity(0.5)).frame(height: Theme.hairline)
    }
}

// MARK: - Depth ladder row (centered DOM)

/// One order-book level in the centered ladder: a three-zone row sharing a fixed
/// center price axis. The price sits in the middle (bids green, asks red — the
/// only direction color); the size + order-count cluster hugs the axis on the
/// level's own side; and a muted depth-histogram bar (shared scale across both
/// sides) fans OUTWARD from the axis as background density — bids to the left,
/// asks to the right. The opposite side stays empty so the axis reads straight.
/// The best bid/ask is bold + full-tone with a faint wash. The whole row is a
/// click target that seats its price into the order ticket.
private struct DepthRow: View {
    let level: BookLevel
    /// .buy = bid (green side, bar fans left), .sell = ask (red side, bar fans right).
    let side: Side
    let isBest: Bool
    let fraction: Double
    let priceWidth: CGFloat
    let rowHeight: CGFloat
    let inset: CGFloat
    let onClick: () -> Void
    @State private var hovering = false

    private var isBid: Bool { side == .buy }
    private var tone: Color { isBid ? Theme.up : Theme.down }

    var body: some View {
        Button(action: onClick) {
            HStack(spacing: 0) {
                zone(isBidSide: true)      // left — bid density
                priceText
                    .frame(width: priceWidth)
                zone(isBidSide: false)     // right — ask density
            }
            .padding(.horizontal, inset)
            .frame(height: rowHeight)
            .frame(maxWidth: .infinity)
            .background(rowWash)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(DeckMotion.ease(), value: hovering)
        .help("set ticket price \(DashFormat.price(level.px))")
    }

    private var priceText: some View {
        Text(DashFormat.price(level.px))
            .numeric(size: 11, weight: isBest ? .bold : .regular)
            .foregroundStyle(tone.opacity(isBest ? 1 : 0.82))
            .lineLimit(1)
    }

    /// One side's zone. The side matching this level shows the outward-fanning
    /// depth bar with its size/count laid over the inner edge (nearest the price
    /// axis); the opposite side is empty space so the axis stays straight.
    @ViewBuilder
    private func zone(isBidSide: Bool) -> some View {
        if isBidSide == isBid {
            ZStack(alignment: isBidSide ? .trailing : .leading) {
                GeometryReader { geo in
                    Rectangle()
                        .fill(tone.opacity(0.16))
                        .frame(width: max(0, geo.size.width * fraction))
                        .frame(
                            maxWidth: .infinity, maxHeight: .infinity,
                            alignment: isBidSide ? .trailing : .leading
                        )
                }
                sizeCluster
                    .padding(isBidSide ? .trailing : .leading, 8)
            }
            .frame(maxWidth: .infinity)
        } else {
            Color.clear.frame(maxWidth: .infinity)
        }
    }

    /// Size nearest the price axis, order-count (when reported) just outside it.
    private var sizeCluster: some View {
        HStack(spacing: 5) {
            if isBid {
                orderCount
                sizeText
            } else {
                sizeText
                orderCount
            }
        }
    }

    private var sizeText: some View {
        Text(DashFormat.qty(level.sz))
            .numeric(size: 10, weight: isBest ? .medium : .regular)
            .foregroundStyle(isBest ? Theme.bone : Theme.dim)
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

    private var rowWash: some View {
        Rectangle()
            .fill(hovering ? Theme.panelHi : (isBest ? tone.opacity(0.06) : Color.clear))
    }
}

// MARK: - Time & sales tape

/// The streaming time & sales tape for the subscribed symbol: newest-first
/// prints, each colored by aggressor (buy = up, sell = down, unknown = dim).
/// Reads the model's ring-capped `tape`; the header/collapse chrome lives in
/// the dock. Grid only.
struct TimeSalesPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            tapeHeaderRow
            Divider().overlay(Theme.line)
            if model.tape.isEmpty {
                DeckEmpty(text: model.bookDepth == nil ? "waiting for prints…" : "no prints yet")
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
