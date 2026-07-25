// Orders table: time / id / source / symbol / side / qty / type / status.
// Working orders get a cancel button; rejections show the risk reason.
// model.orders is already newest-first.

import SwiftUI

struct OrdersTable: View {
    @Environment(AppModel.self) private var model

    /// Column floor below which the table scrolls horizontally instead of
    /// crushing its columns (fixed cols + symbol min + spacing + padding).
    private static let minTableWidth: CGFloat = 620

    var body: some View {
        // Fill-or-scroll (see PositionsTable): content width = max(viewport, floor)
        // so columns fill the panel; below the floor it scrolls horizontally.
        GeometryReader { geo in
            ScrollView([.horizontal, .vertical]) {
                VStack(spacing: 0) {
                    header
                    if model.orders.isEmpty {
                        DeckEmpty(text: "no orders")
                    } else {
                        LazyVStack(spacing: 0) {
                            ForEach(model.orders) { row($0) }
                        }
                    }
                }
                .frame(width: max(geo.size.width, Self.minTableWidth))
                .frame(minHeight: geo.size.height, alignment: .topLeading)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            DeckHeaderCell("time").frame(width: 58, alignment: .leading)
            DeckHeaderCell("id").frame(width: 44, alignment: .leading)
            DeckHeaderCell("source").frame(width: 88, alignment: .leading)
            DeckHeaderCell("symbol")
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
            DeckHeaderCell("side").frame(width: 34, alignment: .leading)
            DeckHeaderCell("qty").frame(width: 56, alignment: .trailing)
            DeckHeaderCell("type").frame(width: 92, alignment: .leading)
            DeckHeaderCell("status").frame(width: 128, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .deckRowRule(1.0)
    }

    private func row(_ u: OrderUpdate) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Text(DashFormat.time(u.ts_ms))
                    .numeric(size: 11)
                    .foregroundStyle(Theme.dim)
                    .frame(width: 58, alignment: .leading)
                Text("#\(u.order_id)")
                    .numeric(size: 11)
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .frame(width: 44, alignment: .leading)
                Text(u.intent.source.label)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.dim)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(width: 88, alignment: .leading)
                Text(u.intent.symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.bone)
                    .lineLimit(1)
                    .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                Text(u.intent.side.rawValue)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(u.intent.side == .buy ? Theme.up : Theme.down)
                    .frame(width: 34, alignment: .leading)
                Text(DashFormat.qty(u.intent.qty))
                    .numeric(size: 11)
                    .foregroundStyle(Theme.bone)
                    .frame(width: 56, alignment: .trailing)
                Text(typeText(u.intent))
                    .numeric(size: 11)
                    .foregroundStyle(u.intent.order_type == .market ? Theme.dim : Theme.bone)
                    .lineLimit(1)
                    .frame(width: 92, alignment: .leading)
                statusCell(u)
            }
            // Show the engine's reason for EVERY status that carries one — not
            // just `.rejectedByRisk`. A broker/OMS refusal arrives as
            // `.canceled(reason:)`, and with the reason dropped it was
            // indistinguishable from the operator's own cancel.
            if let detail = OrderStatusPresentation.detailText(u.status) {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(
                        OrderStatusPresentation.isRefusal(u.status)
                            ? Theme.down.opacity(0.85) : Theme.dim
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 66)
                    .help(detail) // full text on hover — the line truncates
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .deckHover()
        .deckRowRule()
    }

    private func statusCell(_ u: OrderUpdate) -> some View {
        HStack(spacing: 6) {
            DeckChip(
                text: OrderStatusPresentation.label(u.status),
                color: statusColor(u.status)
            )
            if !u.status.isTerminal {
                Button("Cancel") {
                    model.send(.cancelOrder(orderId: u.order_id))
                }
                .buttonStyle(DeckMiniButtonStyle())
            }
            Spacer(minLength: 0)
        }
        .frame(width: 128, alignment: .leading)
    }

    private func typeText(_ i: OrderIntent) -> String {
        switch i.order_type {
        case .market: "market"
        case .limit: i.limit_px.map { "limit \(DashFormat.price($0))" } ?? "limit"
        case .stop: i.stop_px.map { "stop \(DashFormat.price($0))" } ?? "stop"
        case .stop_limit:
            (i.stop_px.map { "stop \(DashFormat.price($0))" } ?? "stop")
                + (i.limit_px.map { " · lmt \(DashFormat.price($0))" } ?? "")
        }
    }

    private func statusColor(_ s: OrderStatus) -> Color {
        switch s {
        case .filled: Theme.up
        // A refusal reads as a refusal whether it came from the risk engine
        // (`rejected_by_risk`) or from the broker/OMS (`canceled` + reason).
        // Only a cancel somebody ASKED for stays dim.
        case .rejectedByRisk: Theme.down
        case .canceled: OrderStatusPresentation.isRefusal(s) ? Theme.down : Theme.dim
        default: Theme.ember // pending risk / accepted / working / partial
        }
    }
}

// MARK: - Terminal status presentation

/// How a terminal order status reads in the table.
///
/// A `canceled(reason:)` is NOT necessarily the operator's own cancel. The LIVE
/// notional guard, the IBKR position-reconciliation hold, the equities-only
/// gate, reduce-only-with-nothing-to-reduce and the OMS's own validation all
/// report themselves as `canceled` with a reason (`publish_canceled` in
/// cx-broker/src/ibkr.rs; the submit/fill paths in cx-oms/src/lib.rs). Rendering
/// every one of them as a bare dim "canceled" chip with the reason discarded
/// made a BLOCKED real-money order look exactly like a cancel the operator had
/// asked for — so the operator re-sent it believing it was a UI glitch.
///
/// Pure and internal so the mapping is unit-tested without a live model.
enum OrderStatusPresentation {
    /// Cancel reasons that mean "this cancel was REQUESTED" — the engine's own
    /// cancel / cancel_all / flatten_all / kill-switch paths, which are the only
    /// non-refusal producers of `canceled`. Anything else is the broker or the
    /// OMS refusing the order. Matched case-insensitively after trimming, so a
    /// reason string that gains capitalisation upstream still classifies.
    static let requestedCancelReasons: Set<String> = [
        "",                     // no reason at all
        "cancel",
        "broker cancel",        // cx-broker/src/paper.rs — the row's Cancel button
        "operator",             // explicit operator cancel_all
        "operator flatten",     // RISK ▸ FLATTEN ALL
        "flatten",
        "flatten all",
        "kill switch",          // operator kill switch (cortexd/pipeline.rs)
        "drawdown kill switch", // automatic drawdown halt
    ]

    /// Requested-cancel reasons that add nothing to the "canceled" chip, so the
    /// second line is suppressed and the dense table keeps its one-line rows.
    /// A requested cancel with a MEANINGFUL reason (kill switch, flatten) still
    /// prints — the operator wants to know a halt closed their order.
    private static let redundantReasons: Set<String> = [
        "", "cancel", "broker cancel", "operator",
    ]

    /// The reason payload, trimmed. nil when the status carries none.
    static func reason(_ status: OrderStatus) -> String? {
        let raw: String
        switch status {
        case .rejectedByRisk(let r), .canceled(let r): raw = r
        default: return nil
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// True when the order was REFUSED (risk engine, broker guard, or OMS
    /// validation) rather than canceled on request. Drives the chip label, the
    /// chip colour and the reason line's tint, so one classification decides all
    /// three and they cannot drift apart.
    static func isRefusal(_ status: OrderStatus) -> Bool {
        switch status {
        case .rejectedByRisk: return true
        case .canceled(let r):
            let key = r.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return !requestedCancelReasons.contains(key)
        default: return false
        }
    }

    /// Chip text. Three distinct terminal words so the SOURCE of the stop is
    /// legible at a glance: "rejected" = the risk engine, "blocked" = the
    /// broker/OMS refused it, "canceled" = somebody asked for it.
    static func label(_ status: OrderStatus) -> String {
        if case .canceled = status, isRefusal(status) { return "blocked" }
        return status.label
    }

    /// The reason line under the row, or nil when there is nothing worth a line.
    static func detailText(_ status: OrderStatus) -> String? {
        guard let reason = reason(status) else { return nil }
        if isRefusal(status) { return reason }
        return redundantReasons.contains(reason.lowercased()) ? nil : reason
    }
}
