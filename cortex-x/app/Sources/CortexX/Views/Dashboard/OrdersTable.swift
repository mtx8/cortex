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
            if case .rejectedByRisk(let reason) = u.status, !reason.isEmpty {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.down.opacity(0.85))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, 66)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .deckHover()
        .deckRowRule()
    }

    private func statusCell(_ u: OrderUpdate) -> some View {
        HStack(spacing: 6) {
            DeckChip(text: u.status.label, color: statusColor(u.status))
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
        case .rejectedByRisk: Theme.down
        case .canceled: Theme.dim
        default: Theme.ember // pending risk / accepted / working / partial
        }
    }
}
