// Fills table: time / symbol / side / qty @ px / fee / liquidity / venue.
// model.fills is already newest-first.

import SwiftUI

struct FillsTable: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            header
            if model.fills.isEmpty {
                DeckEmpty(text: "no fills")
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.fills) { row($0) }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 8) {
            DeckHeaderCell("time").frame(width: 58, alignment: .leading)
            DeckHeaderCell("symbol")
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
            DeckHeaderCell("side").frame(width: 34, alignment: .leading)
            DeckHeaderCell("qty @ px").frame(width: 150, alignment: .trailing)
            DeckHeaderCell("fee").frame(width: 56, alignment: .trailing)
            DeckHeaderCell("liq").frame(width: 50, alignment: .leading)
            DeckHeaderCell("venue").frame(width: 62, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .deckRowRule(1.0)
    }

    private func row(_ f: Fill) -> some View {
        HStack(spacing: 8) {
            Text(DashFormat.time(f.ts_ms))
                .numeric(size: 11)
                .foregroundStyle(Theme.dim)
                .frame(width: 58, alignment: .leading)
            Text(f.symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.bone)
                .lineLimit(1)
                .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
            Text(f.side.rawValue)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(f.side == .buy ? Theme.up : Theme.down)
                .frame(width: 34, alignment: .leading)
            Text("\(DashFormat.qty(f.qty)) @ \(DashFormat.price(f.px))")
                .numeric(size: 11)
                .foregroundStyle(Theme.bone)
                .lineLimit(1)
                .frame(width: 150, alignment: .trailing)
            Text(DashFormat.money(f.fee))
                .numeric(size: 11)
                .foregroundStyle(Theme.dim)
                .frame(width: 56, alignment: .trailing)
            DeckChip(
                text: f.liquidity.rawValue,
                color: f.liquidity == .maker ? Theme.dim : Theme.bone
            )
            .frame(width: 50, alignment: .leading)
            Text(f.venue.rawValue)
                .font(.system(size: 10))
                .foregroundStyle(Theme.dim)
                .lineLimit(1)
                .frame(width: 62, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .deckHover()
        .deckRowRule()
    }
}
