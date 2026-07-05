// Positions table: symbol / qty / avg px / mark / unrealized / realized /
// notional with a per-row market close. Empty state: "flat".

import SwiftUI

struct PositionsTable: View {
    @Environment(AppModel.self) private var model

    private var rows: [Position] {
        model.positions.values.sorted { $0.symbol < $1.symbol }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            if rows.isEmpty {
                DeckEmpty(text: "flat")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows) { row($0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
            Button("close") { closePosition(p) }
                .buttonStyle(DeckMiniButtonStyle())
                .disabled(abs(p.qty) < 1e-12)
                .opacity(abs(p.qty) < 1e-12 ? 0.35 : 1)
                .frame(width: 46, alignment: .trailing)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .deckHover()
        .deckRowRule()
    }

    private func qtyColor(_ q: Double) -> Color {
        if q > 0 { return Theme.up }
        if q < 0 { return Theme.down }
        return Theme.dim
    }

    private func closePosition(_ p: Position) {
        guard abs(p.qty) > 1e-12 else { return }
        model.send(.placeOrder(
            symbol: p.symbol,
            side: p.qty > 0 ? .sell : .buy,
            qty: abs(p.qty),
            orderType: .market,
            limitPx: nil
        ))
    }
}
