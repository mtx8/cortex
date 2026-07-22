// Reusable Level 2 subviews — a MODERN SIDE-BY-SIDE order-book montage (DAS /
// exchange style: bids in a left column, asks in a right column, best prices at
// the top flanking the spread) and the time & sales tape, rendered beside the
// chart in the trading dock (see Views/Chart/TradingDock.swift). Each renders the
// actively-subscribed symbol's book / tape from the model; the depth
// subscription lifecycle lives in the workspace, not here. All layout + book math
// lives in the pure helpers (Level2Support: DepthMontage / DepthLadder).

import SwiftUI

// MARK: - DOM montage (side-by-side bid | ask columns)

/// The side-by-side Level 2 montage for the subscribed symbol: an inside-market
/// strip (mid · spread · book imbalance) over two columns — BIDS on the left
/// (green, best at top), ASKS on the right (red, best at top) — with a depth
/// histogram fanning inward from each outer rail and the inside market marked by
/// an ember hairline under the top row. Renders the model's `bookDepth`; nil
/// resolves to an honest waiting state, never a stale book. Clicking a level
/// seats its price into the order ticket. The dock wraps it with the labeled
/// header + real/delayed source banner.
struct DomLadder: View {
    @Environment(AppModel.self) private var model

    private var depth: BookDepth? { model.bookDepth }

    /// Derived book: both sides best-first, a shared histogram scale, and the
    /// inside-market summary — resolved ONCE per render (the raw model props are
    /// computed, so re-reading them re-sorts the whole book).
    private struct Book {
        var bids: [BookLevel]
        var asks: [BookLevel]
        var maxSize: Double
        var mid: Double?
        var spread: Double?
        var bidTotal: Double
        var askTotal: Double
        /// True when the venue route-attributes levels (IBKR L2 marketMaker) —
        /// then the montage shows a DAS-style MM route column. False for
        /// anonymous/aggregated books (Coinbase) and delayed L1.
        var hasRoutes: Bool
        var isEmpty: Bool { bids.isEmpty && asks.isEmpty }
    }

    private var book: Book {
        let bids = DepthLadder.sortedBids(depth?.bids ?? [])
        let asks = DepthLadder.sortedAsks(depth?.asks ?? [])
        return Book(
            bids: bids,
            asks: asks,
            maxSize: DepthLadder.maxSize(bids: bids, asks: asks),
            mid: DepthLadder.mid(bestBid: bids.first?.px, bestAsk: asks.first?.px),
            spread: DepthLadder.spread(bestBid: bids.first?.px, bestAsk: asks.first?.px),
            bidTotal: DepthMontage.cumulativeSize(bids),
            askTotal: DepthMontage.cumulativeSize(asks),
            hasRoutes: bids.contains { $0.mm != nil } || asks.contains { $0.mm != nil }
        )
    }

    /// Fixed montage row height — the unit the fit math packs into each column.
    private static let rowHeight: CGFloat = 22
    /// Horizontal inset shared by the column header + rows (insets prices from
    /// the spine and sizes from the outer rails).
    private static let rowInset: CGFloat = 8

    var body: some View {
        let b = book
        VStack(spacing: 0) {
            insideStrip(b)
            Divider().overlay(Theme.line)
            columnHeader(b.hasRoutes)
            Divider().overlay(Theme.line)
            columns(b)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Inside-market strip (mid · spread · imbalance)

    private func insideStrip(_ b: Book) -> some View {
        HStack(spacing: 14) {
            metric("MID", b.mid.map { DashFormat.price($0) } ?? "—", Theme.bone)
            metric("SPREAD", b.spread.map { DashFormat.price($0) } ?? "—", Theme.dim)
            Spacer(minLength: 0)
            imbalanceBar(bid: b.bidTotal, ask: b.askTotal)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.ink)
    }

    private func metric(_ label: String, _ value: String, _ color: Color) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 8, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Text(value)
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
    }

    /// A compact depth-imbalance bar: green portion ∝ resting bids, red ∝ asks,
    /// with the bid share as a percent. The dominant side — resting buy vs sell
    /// pressure — reads at a glance. Fixed widths (no GeometryReader) so the strip
    /// stays cheap at the 12 Hz book flush.
    private func imbalanceBar(bid: Double, ask: Double) -> some View {
        let total = bid + ask
        let bidFrac = total > 0 ? bid / total : 0.5
        let w: CGFloat = 66
        return HStack(spacing: 6) {
            HStack(spacing: 0) {
                Rectangle().fill(Theme.up.opacity(0.85))
                    .frame(width: w * CGFloat(bidFrac))
                Rectangle().fill(Theme.down.opacity(0.85))
            }
            .frame(width: w, height: 5)
            .clipShape(RoundedRectangle(cornerRadius: 2))
            Text("\(Int((bidFrac * 100).rounded()))%")
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .foregroundStyle(bidFrac >= 0.5 ? Theme.up : Theme.down)
        }
        .help("book imbalance — share of resting size on the bid")
    }

    // MARK: Column header (matches the montage columns exactly)

    /// Column labels matching the montage. When the book is route-attributed
    /// (IBKR L2) an "MM" label sits at each outer rail, DAS-style; otherwise the
    /// outer label is just SIZE.
    private func columnHeader(_ hasRoutes: Bool) -> some View {
        HStack(spacing: 0) {
            // Left (bid) half: [MM] SIZE at the outer rail, BID by the spine.
            HStack(spacing: 0) {
                if hasRoutes {
                    DeckHeaderCell("mm").frame(width: Self.routeWidth, alignment: .leading)
                }
                DeckHeaderCell("size")
                Spacer(minLength: 0)
                Text("BID")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.up.opacity(0.9))
                    .padding(.trailing, 6)
            }
            .frame(maxWidth: .infinity)
            // Right (ask) half: ASK by the spine, SIZE [MM] at the outer rail.
            HStack(spacing: 0) {
                Text("ASK")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(1.1)
                    .foregroundStyle(Theme.down.opacity(0.9))
                    .padding(.leading, 6)
                Spacer(minLength: 0)
                DeckHeaderCell("size")
                if hasRoutes {
                    DeckHeaderCell("mm").frame(width: Self.routeWidth, alignment: .trailing)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Self.rowInset)
        .padding(.vertical, 6)
        .background(Theme.ink)
    }

    /// Width reserved at the outer rail for the DAS-style MM route badge when the
    /// book is attributed (equity IBKR L2). Zero-cost when hidden.
    static let routeWidth: CGFloat = 38

    // MARK: Columns (the montage body)

    @ViewBuilder
    private func columns(_ b: Book) -> some View {
        if depth == nil {
            DeckEmpty(text: "waiting for depth…")
        } else if b.isEmpty {
            DeckEmpty(text: "no book")
        } else {
            GeometryReader { geo in
                let capacity = DepthMontage.rowCapacity(
                    height: Double(geo.size.height), rowHeight: Double(Self.rowHeight)
                )
                let bidRows = DepthMontage.column(
                    b.bids, rowHeight: Double(Self.rowHeight), capacity: capacity, topY: 0
                )
                let askRows = DepthMontage.column(
                    b.asks, rowHeight: Double(Self.rowHeight), capacity: capacity, topY: 0
                )
                // Scale the depth histogram to the largest VISIBLE level, not the
                // whole book — a huge resting size below the fold must not squash
                // every drawn bar to a sliver.
                let visMax = DepthLadder.maxSize(
                    bids: bidRows.map(\.level), asks: askRows.map(\.level)
                )
                Canvas(opaque: true, rendersAsynchronously: false) { ctx, size in
                    MontageCanvas(
                        bidRows: bidRows, askRows: askRows,
                        maxSize: visMax, inset: Self.rowInset,
                        routeWidth: b.hasRoutes ? Self.routeWidth : 0
                    ).draw(in: ctx, size: size)
                }
                .contentShape(Rectangle())
                // Click-to-price: the click's side (x vs the spine) picks the
                // column, then the same drawn rows map y → level → ticket price.
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        let spine = Double(geo.size.width) / 2
                        let rows = Double(value.location.x) < spine ? bidRows : askRows
                        if let level = DepthMontage.level(atY: Double(value.location.y), rows: rows) {
                            model.setTicketPrice(level.px)
                        }
                    }
                )
                .help("click a level to set the order-ticket price")
            }
        }
    }
}

// MARK: - Montage Canvas (two-column renderer)

/// Draws the side-by-side montage into ONE GraphicsContext (near-zero layout
/// cost, like the candle chart). LEFT column = bids (green), RIGHT = asks (red),
/// split by a center spine. In each column a depth-histogram bar fans inward from
/// the outer rail (∝ size vs the shared scale), the SIZE sits at the outer rail,
/// the PRICE by the spine, and the best bid/ask (top row) is bold + full-tone
/// with a faint wash and an ember inside-market hairline. Every row rectangle
/// comes from the shared MontageRow list, so the drawing and the click hit-test
/// agree exactly (bids fan left / green, asks fan right / red — the only
/// direction color).
private struct MontageCanvas {
    let bidRows: [MontageRow]
    let askRows: [MontageRow]
    let maxSize: Double
    let inset: CGFloat
    /// Width of the DAS-style MM route column at each outer rail; 0 = the book
    /// is anonymous (crypto / delayed) and no route badges are drawn.
    var routeWidth: CGFloat = 0

    func draw(in ctx: GraphicsContext, size: CGSize) {
        // Opaque ink base (the Canvas is declared opaque for the perf win).
        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.ink))
        let spine = (size.width / 2).rounded()

        // Center spine hairline dividing bids | asks.
        ctx.fill(
            Path(CGRect(x: spine - Theme.hairline / 2, y: 0, width: Theme.hairline, height: size.height)),
            with: .color(Theme.line)
        )

        for row in bidRows { drawRow(ctx, row, isBid: true, spine: spine, width: size.width) }
        for row in askRows { drawRow(ctx, row, isBid: false, spine: spine, width: size.width) }

        // Inside-market ember hairline beneath the top (best bid | best ask) row.
        let topH = max(bidRows.first?.maxY ?? 0, askRows.first?.maxY ?? 0)
        if topH > 0 {
            let y = CGFloat(topH).rounded()
            ctx.fill(
                Path(CGRect(x: 0, y: y - Theme.hairline, width: size.width, height: Theme.hairline)),
                with: .color(Theme.ember.opacity(0.45))
            )
        }
    }

    /// One level row in one column: faint best-row wash, an inward-fanning depth
    /// bar from the outer rail, the price by the spine, the size at the outer rail.
    private func drawRow(
        _ ctx: GraphicsContext, _ row: MontageRow, isBid: Bool, spine: CGFloat, width: CGFloat
    ) {
        let level = row.level
        let tone = isBid ? Theme.up : Theme.down
        let y = CGFloat(row.minY)
        let h = CGFloat(row.height)
        let cy = y + h / 2

        // Best-row faint wash across its half.
        if row.isBest {
            let x = isBid ? 0 : spine
            ctx.fill(Path(CGRect(x: x, y: y, width: spine, height: h)), with: .color(tone.opacity(0.07)))
        }

        // Depth bar: anchored at the OUTER rail, fanning inward toward the spine,
        // length ∝ size against the shared scale (so a bid bar and an ask bar of
        // equal size read equal).
        let frac = DepthLadder.barFraction(size: level.sz, maxSize: maxSize)
        if frac > 0 {
            let zoneW = max(0, spine - 2 * inset)
            let barW = zoneW * CGFloat(frac)
            let barX = isBid ? inset : (width - inset - barW)
            ctx.fill(
                Path(CGRect(x: barX, y: y + 1, width: barW, height: h - 2)),
                with: .color(tone.opacity(row.isBest ? 0.22 : 0.13))
            )
        }

        // PRICE by the spine (prominent, the direction color).
        let priceText = Text(DashFormat.price(level.px))
            .font(.system(size: 11, weight: row.isBest ? .bold : .regular).monospacedDigit())
            .foregroundStyle(tone.opacity(row.isBest ? 1 : 0.85))
        ctx.draw(
            priceText,
            at: CGPoint(x: isBid ? spine - 6 : spine + 6, y: cy),
            anchor: isBid ? .trailing : .leading
        )

        // MM route badge at the very outer rail (DAS-style), when attributed.
        // Bids: [MM][SIZE]…PRICE ; asks: PRICE…[SIZE][MM] — MM hugs the outer
        // edge, SIZE sits just inside the reserved route column.
        if routeWidth > 0, let mm = level.mm, !mm.isEmpty {
            // GraphicsContext.draw doesn't clip — cap the id so a long MPID can't
            // spill into the SIZE column (MPIDs are ≤4 chars; 5 is a safe bound).
            let badge = mm.count > 5 ? String(mm.prefix(5)) : mm
            let routeText = Text(badge)
                .font(.system(size: 8, weight: .semibold, design: .monospaced))
                .foregroundStyle(row.isBest ? Theme.ember : Theme.ember.opacity(0.7))
            ctx.draw(
                routeText,
                at: CGPoint(x: isBid ? inset + 2 : width - inset - 2, y: cy),
                anchor: isBid ? .leading : .trailing
            )
        }

        // SIZE at the outer rail (secondary), shifted inward past the route
        // column when the book is attributed.
        let sizeText = Text(DashFormat.qty(level.sz))
            .font(.system(size: 10, weight: row.isBest ? .medium : .regular).monospacedDigit())
            .foregroundStyle(row.isBest ? Theme.bone : Theme.dim)
        let sizeInset = inset + 3 + routeWidth
        ctx.draw(
            sizeText,
            at: CGPoint(x: isBid ? sizeInset : width - sizeInset, y: cy),
            anchor: isBid ? .leading : .trailing
        )
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
