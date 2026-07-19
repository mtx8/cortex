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

    /// The centered ladder, drawn as a SINGLE Canvas (near-zero layout cost —
    /// the ~40 nested SwiftUI stack rows this replaced saturated the layout
    /// engine at the ~12 Hz flush). A GeometryReader hands the pure fill math
    /// the pane height; it returns how many levels fit each side and the outer
    /// padding that keeps the spread band dead-center. `LadderGeometry.rows`
    /// turns that into the exact top→bottom row rectangles the Canvas paints,
    /// and the SAME rows drive the click hit-test, so the pixels and the
    /// click-to-price target can never drift.
    @ViewBuilder
    private var ladderBody: some View {
        // Sort both sides + resolve the shared histogram scale ONCE per render.
        // `ladder` is a computed property, so every access re-sorts the whole
        // book — bind it here and thread the scale down.
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
                let rows = LadderGeometry.rows(
                    layout: layout, asks: asks, bids: bids,
                    rowHeight: Double(Self.rowHeight),
                    spreadHeight: Double(Self.spreadHeight)
                )
                Canvas(opaque: true, rendersAsynchronously: false) { ctx, size in
                    LadderCanvas(
                        rows: rows, maxSize: data.maxSize,
                        mid: data.mid, spread: data.spread,
                        priceWidth: Self.priceWidth, inset: Self.rowInset
                    ).draw(in: ctx, size: size)
                }
                .contentShape(Rectangle())
                // Click-to-price by hit-testing the click y against the same
                // drawn rows (map y -> level -> px -> model.setTicketPrice).
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        if let level = LadderGeometry.level(
                            atY: Double(value.location.y), rows: rows
                        ) {
                            model.setTicketPrice(level.px)
                        }
                    }
                )
                .help("click a level to set the order-ticket price")
            }
        }
    }
}

// MARK: - Depth ladder Canvas (centered DOM)

/// Draws the whole centered order-book ladder into ONE GraphicsContext — price
/// column, sizes, order counts, the inside-market spread band, and the
/// outward-fanning depth histogram — exactly like the candle chart draws candles
/// in a Canvas (near-zero layout cost, no per-row SwiftUI stacks). Bids fan left
/// / green, asks fan right / red (the only direction color); the best bid/ask is
/// bold + full-tone with a faint wash. Every row rectangle comes from the shared
/// `LadderRowLayout` list, so the drawing and the click hit-test agree exactly.
private struct LadderCanvas {
    let rows: [LadderRowLayout]
    let maxSize: Double
    let mid: Double?
    let spread: Double?
    let priceWidth: CGFloat
    let inset: CGFloat

    func draw(in ctx: GraphicsContext, size: CGSize) {
        // Opaque ink base (the Canvas is declared opaque for the perf win, so
        // every pixel must be filled).
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.ink))

        let centerX = size.width / 2
        let priceLeft = centerX - priceWidth / 2
        let priceRight = centerX + priceWidth / 2
        let leftZoneW = max(0, priceLeft - inset)
        let rightZoneW = max(0, (size.width - inset) - priceRight)

        for row in rows {
            switch row.kind {
            case .ask:
                drawLevel(
                    ctx, row, isBid: false, width: size.width, centerX: centerX,
                    priceLeft: priceLeft, priceRight: priceRight,
                    leftZoneW: leftZoneW, rightZoneW: rightZoneW
                )
            case .bid:
                drawLevel(
                    ctx, row, isBid: true, width: size.width, centerX: centerX,
                    priceLeft: priceLeft, priceRight: priceRight,
                    leftZoneW: leftZoneW, rightZoneW: rightZoneW
                )
            case .spread:
                drawSpread(ctx, row, width: size.width, centerX: centerX)
            }
        }
    }

    /// One order-book level: an outward-fanning depth bar (shared scale) behind
    /// the centered price, with the size hugging the axis and the order count
    /// (when reported) just outside it. Bids fan left; asks fan right.
    private func drawLevel(
        _ ctx: GraphicsContext, _ row: LadderRowLayout, isBid: Bool,
        width: CGFloat, centerX: CGFloat, priceLeft: CGFloat, priceRight: CGFloat,
        leftZoneW: CGFloat, rightZoneW: CGFloat
    ) {
        guard let level = row.level else { return }
        let tone = isBid ? Theme.up : Theme.down
        let y = CGFloat(row.minY)
        let h = CGFloat(row.height)
        let cy = y + h / 2

        // Best inside-market row: a faint full-width wash.
        if row.isBest {
            ctx.fill(
                Path(CGRect(x: 0, y: y, width: width, height: h)),
                with: .color(tone.opacity(0.06))
            )
        }

        // Outward-fanning depth histogram.
        let fraction = DepthLadder.barFraction(size: level.sz, maxSize: maxSize)
        if fraction > 0 {
            let barColor = tone.opacity(0.16)
            if isBid {
                let barW = leftZoneW * CGFloat(fraction)
                ctx.fill(
                    Path(CGRect(x: priceLeft - barW, y: y, width: barW, height: h)),
                    with: .color(barColor)
                )
            } else {
                let barW = rightZoneW * CGFloat(fraction)
                ctx.fill(
                    Path(CGRect(x: priceRight, y: y, width: barW, height: h)),
                    with: .color(barColor)
                )
            }
        }

        // Center price (bid green / ask red — the only direction color).
        let priceText = Text(DashFormat.price(level.px))
            .font(.system(size: 11, weight: row.isBest ? .bold : .regular).monospacedDigit())
            .foregroundStyle(tone.opacity(row.isBest ? 1 : 0.82))
        ctx.draw(priceText, at: CGPoint(x: centerX, y: cy), anchor: .center)

        // Size hugging the axis; order count (when reported) just outside it.
        let sizeText = Text(DashFormat.qty(level.sz))
            .font(.system(size: 10, weight: row.isBest ? .medium : .regular).monospacedDigit())
            .foregroundStyle(row.isBest ? Theme.bone : Theme.dim)
        let resolvedSize = ctx.resolve(sizeText)
        let hasCount = level.count > 0
        if isBid {
            let sizeX = priceLeft - 8
            ctx.draw(resolvedSize, at: CGPoint(x: sizeX, y: cy), anchor: .trailing)
            if hasCount {
                let sw = resolvedSize.measure(in: CGSize(width: 1000, height: h)).width
                ctx.draw(countText(level.count), at: CGPoint(x: sizeX - sw - 5, y: cy), anchor: .trailing)
            }
        } else {
            let sizeX = priceRight + 8
            ctx.draw(resolvedSize, at: CGPoint(x: sizeX, y: cy), anchor: .leading)
            if hasCount {
                let sw = resolvedSize.measure(in: CGSize(width: 1000, height: h)).width
                ctx.draw(countText(level.count), at: CGPoint(x: sizeX + sw + 5, y: cy), anchor: .leading)
            }
        }
    }

    private func countText(_ count: UInt32) -> Text {
        Text("\(count)")
            .font(.system(size: 8, weight: .medium, design: .monospaced))
            .foregroundStyle(Theme.dim)
    }

    /// The thin inside-market band seated dead-center: mid + spread, dim and
    /// calm, framed top and bottom by a subtle ember hairline that marks the
    /// best bid/ask straddling it as the inside market.
    private func drawSpread(_ ctx: GraphicsContext, _ row: LadderRowLayout, width: CGFloat, centerX: CGFloat) {
        let y = CGFloat(row.minY)
        let h = CGFloat(row.height)
        ctx.fill(Path(CGRect(x: 0, y: y, width: width, height: h)), with: .color(Theme.panel))
        let edge = Theme.ember.opacity(0.5)
        ctx.fill(Path(CGRect(x: 0, y: y, width: width, height: Theme.hairline)), with: .color(edge))
        ctx.fill(
            Path(CGRect(x: 0, y: y + h - Theme.hairline, width: width, height: Theme.hairline)),
            with: .color(edge)
        )
        let spreadStr = spread.map { DashFormat.price($0) } ?? "—"
        let midStr = mid.map { DashFormat.price($0) } ?? "—"
        let labelFont = Font.system(size: 8, weight: .semibold)
        let valueFont = Font.system(size: 11, weight: .medium).monospacedDigit()
        let composed =
            Text("SPREAD ").font(labelFont).tracking(1.2).foregroundStyle(Theme.dim)
            + Text(spreadStr).font(valueFont).foregroundStyle(Theme.dim)
            + Text("   ·   ").font(labelFont).foregroundStyle(Theme.dim)
            + Text("MID ").font(labelFont).tracking(1.2).foregroundStyle(Theme.dim)
            + Text(midStr).font(valueFont).foregroundStyle(Theme.bone)
        ctx.draw(composed, at: CGPoint(x: centerX, y: y + h / 2), anchor: .center)
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
/// Monospaced throughout so the tape reads as a clean column. Deliberately a
/// SINGLE flat HStack of fixed-width columns at a FIXED height — no nested
/// stacks, no per-row overlay/padding pyramid — so the LazyVStack lays out only
/// the visible rows and each costs the layout engine almost nothing at the
/// ~12 Hz flush.
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
        HStack(spacing: 6) {
            // Glyph + time fold into the header's 68-wide time column
            // (8 + 6 + 54 = 68) without a nested stack.
            Image(systemName: glyph)
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(color)
                .frame(width: 8, alignment: .center)
            Text(DashFormat.time(print.ts_ms))
                .numeric(size: 10)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .frame(width: 54, alignment: .leading)
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
    }
}
