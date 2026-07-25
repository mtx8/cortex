// Positions table: symbol / qty / avg px / mark / unrealized / realized /
// notional with a per-row market close. Empty state: "flat".
//
// The per-row Close is a REAL-MONEY market order on a live broker, so it goes
// through the same confirmation gate the order ticket enforces (LiveOrderConfirm
// + the shared `ticket.confirmBeforeLiveOrder` preference). It used to fire
// straight from the click: one stray hit on a 5pt-tall hover row liquidated a
// live position at market, and the engine marks the order reduce_only so the
// live guard waves it through unconditionally — nothing downstream could catch
// the mis-click.

import SwiftUI

struct PositionsTable: View {
    @Environment(AppModel.self) private var model

    /// Non-nil while a Close is awaiting its explicit real-money confirmation.
    @State private var pendingClose: Position?
    /// The symbol of a Close the transport refused. A close that never reached
    /// the engine must not look like it fired — the position stays open, so say
    /// so here as well as in the global undelivered-command banner.
    @State private var undeliveredClose: String?

    /// SETTINGS ▸ PREFERENCES — the SAME key the order ticket reads, so the
    /// operator's real-money backstop covers every unwind path, not just FLATTEN.
    @AppStorage("ticket.confirmBeforeLiveOrder") private var confirmBeforeLiveOrder = true

    private var rows: [Position] {
        model.positions.values.sorted { $0.symbol < $1.symbol }
    }

    /// Sum of the fixed columns + spacing + padding — the floor below which the
    /// table scrolls horizontally instead of crushing its columns.
    private static let minTableWidth: CGFloat = 660

    var body: some View {
        // Fill-or-scroll: the content width is max(viewport, column floor) — a
        // FIXED number, so the flexible symbol column resolves and the table fills
        // the panel edge-to-edge (no dead band); below the floor it scrolls
        // horizontally. minHeight fills so the empty state occupies the region
        // instead of floating top-left.
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    header
                    // The notice is only true while that position is still open,
                    // so it retires itself once the symbol leaves the book
                    // (closed on a retry, or from the ticket) — no stale warning.
                    if let symbol = undeliveredClose, model.positions[symbol] != nil {
                        undeliveredNotice(symbol)
                    }
                    if rows.isEmpty {
                        DeckEmpty(text: "flat")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row($0) }
                        }
                    }
                }
                .frame(width: max(geo.size.width, Self.minTableWidth))
                .frame(minHeight: geo.size.height, alignment: .topLeading)
            }
        }
        // One explicit confirmation before a real-money close, mirroring the
        // ticket's live gate. Paper / IBKR-paper never reaches here — the gate
        // returns `.dispatch` and the order goes out on the click as before.
        .confirmationDialog(
            "Close this position at market?",
            isPresented: Binding(
                get: { pendingClose != nil },
                set: { if !$0 { pendingClose = nil } }
            ),
            titleVisibility: .visible,
            presenting: pendingClose
        ) { p in
            Button(closeLabel(p), role: .destructive) {
                performClose(p)
                pendingClose = nil
            }
            Button("Cancel", role: .cancel) { pendingClose = nil }
        } message: { _ in
            Text("This routes to your live broker account. Real money — the position closes at market.")
        }
    }

    /// The action label spells out side · size · symbol: the confirmation must
    /// name exactly what is about to be sold or bought back, because the row the
    /// operator clicked may not be the row they meant.
    private func closeLabel(_ p: Position) -> String {
        guard let a = PositionAction.flatten(positionQty: p.qty) else {
            return "Close \(p.symbol) — real money"
        }
        let side = a.side == .buy ? "BUY" : "SELL"
        return "\(side) \(DashFormat.qty(a.qty)) \(p.symbol) at market — real money"
    }

    /// Ember dot + bone text, per the warning convention — no coloured block.
    private func undeliveredNotice(_ symbol: String) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Theme.ember)
                .frame(width: 5, height: 5)
            Text("close for \(symbol) never reached the engine — the position is still open")
                .font(.system(size: 10))
                .foregroundStyle(Theme.bone)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .deckRowRule()
    }

    private var header: some View {
        HStack(spacing: 8) {
            DeckHeaderCell("symbol")
                .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
            DeckHeaderCell("qty").frame(width: 70, alignment: .trailing)
            DeckHeaderCell("avg px").frame(width: 76, alignment: .trailing)
            DeckHeaderCell("mark").frame(width: 76, alignment: .trailing)
            DeckHeaderCell("unreal").frame(width: 84, alignment: .trailing)
            DeckHeaderCell("real").frame(width: 72, alignment: .trailing)
            DeckHeaderCell("notional").frame(width: 84, alignment: .trailing)
            Color.clear.frame(width: 46, height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .deckRowRule(1.0)
    }

    private func row(_ p: Position) -> some View {
        HStack(spacing: 8) {
            Text(p.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.bone)
                .lineLimit(1)
                .frame(minWidth: 64, maxWidth: .infinity, alignment: .leading)
            Text(DashFormat.signedQty(p.qty))
                .numeric(size: 11)
                .foregroundStyle(qtyColor(p.qty))
                .frame(width: 70, alignment: .trailing)
            Text(DashFormat.price(p.avg_px))
                .numeric(size: 11)
                .foregroundStyle(Theme.bone)
                .frame(width: 76, alignment: .trailing)
            Text(DashFormat.price(p.mark_px))
                .numeric(size: 11)
                .foregroundStyle(Theme.bone)
                .frame(width: 76, alignment: .trailing)
            Text(DashFormat.money(p.unrealized_pnl, signed: true))
                .numeric(size: 11)
                .foregroundStyle(Theme.pnlColor(p.unrealized_pnl))
                .frame(width: 84, alignment: .trailing)
            Text(DashFormat.money(p.realized_pnl, signed: true))
                .numeric(size: 11)
                .foregroundStyle(Theme.pnlColor(p.realized_pnl))
                .frame(width: 72, alignment: .trailing)
            Text(DashFormat.money(p.notional))
                .numeric(size: 11)
                .foregroundStyle(Theme.dim)
                .frame(width: 84, alignment: .trailing)
            closeButton(p)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .deckHover()
        .deckRowRule()
    }

    /// The per-row close. Inert (not merely ignored) when the position is flat or
    /// the engine is unreachable — a control that cannot act must not look armed.
    private func closeButton(_ p: Position) -> some View {
        let decision = PositionCloseGate.decide(
            positionQty: p.qty,
            engineReachable: model.engineReachable,
            isLiveVenue: TicketVenueTag.make(for: model.broker).isLive,
            confirmBeforeLive: confirmBeforeLiveOrder
        )
        let blocked = decision == .blocked
        return Button("Close") { closePosition(p, decision) }
            .buttonStyle(DeckMiniButtonStyle())
            .disabled(blocked)
            .opacity(blocked ? 0.35 : 1)
            .frame(width: 46, alignment: .trailing)
            .help(closeHelp(decision, p))
    }

    private func closeHelp(_ decision: PositionCloseGate.Decision, _ p: Position) -> String {
        switch decision {
        case .blocked:
            return model.engineReachable
                ? "no position on \(p.symbol)"
                : "engine unreachable — a close cannot be sent"
        case .confirm: return "close \(p.symbol) at market — real money, confirms first"
        case .dispatch: return "close \(p.symbol) at market"
        }
    }

    private func qtyColor(_ q: Double) -> Color {
        if q > 0 { return Theme.up }
        if q < 0 { return Theme.down }
        return Theme.dim
    }

    private func closePosition(_ p: Position, _ decision: PositionCloseGate.Decision) {
        switch decision {
        case .blocked: return
        case .confirm: pendingClose = p
        case .dispatch: performClose(p)
        }
    }

    /// The final send — after any live confirmation. Re-derives side/qty through
    /// the shared `PositionAction.flatten` (the same builder the ticket's FLATTEN
    /// uses) so the two unwind paths cannot drift. `send` is used rather than
    /// `model.placeOrder` because only `send` reports DELIVERY: a close the
    /// transport refused must not be presented as if it fired.
    private func performClose(_ p: Position) {
        guard let a = PositionAction.flatten(positionQty: p.qty) else { return }
        let delivered = model.send(.placeOrder(
            symbol: p.symbol,
            side: a.side,
            qty: a.qty,
            orderType: .market,
            limitPx: nil,
            stopPx: nil
        ))
        undeliveredClose = delivered ? nil : p.symbol
    }
}

// MARK: - Close gate

/// What the positions-table Close button may do right now — the one place that
/// decides it, so the button's enabled state and its click can never disagree.
/// Pure so the real-money gate is unit-tested away from SwiftUI, and built on
/// `LiveOrderConfirm` (the order ticket's rule) so the table and the ticket can
/// never drift on when real money needs a second look.
enum PositionCloseGate {
    enum Decision: Equatable {
        /// Nothing to close, or no engine to close it at.
        case blocked
        /// Real money at a live venue with the backstop on: confirm first.
        case confirm
        /// Paper / IBKR-paper (or the backstop deliberately lowered): send now.
        case dispatch
    }

    static func decide(
        positionQty: Double,
        engineReachable: Bool,
        isLiveVenue: Bool,
        confirmBeforeLive: Bool
    ) -> Decision {
        guard engineReachable, PositionAction.flatten(positionQty: positionQty) != nil else {
            return .blocked
        }
        return LiveOrderConfirm.required(
            isLiveVenue: isLiveVenue, confirmBeforeLive: confirmBeforeLive
        ) ? .confirm : .dispatch
    }
}
