// Bottom trading deck: account strip over tabbed positions/orders/fills on
// the left; order ticket over risk HUD in a fixed 300pt column on the right.

import SwiftUI

struct DashboardPanel: View {
    @Environment(AppModel.self) private var model
    @State private var tab: DeckTab = .positions

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 10) {
                AccountStrip()
                TradeDeckTables(tab: $tab)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            ScrollView {
                VStack(spacing: 10) {
                    OrderTicket()
                    RiskHUD()
                }
            }
            .frame(width: 300)
        }
    }
}

enum DeckTab: String, CaseIterable, Identifiable {
    case positions, orders, fills
    var id: String { rawValue }
}

/// Tab strip + the active table, in one panel card.
struct TradeDeckTables: View {
    @Environment(AppModel.self) private var model
    @Binding var tab: DeckTab

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                ForEach(DeckTab.allCases) { t in
                    tabButton(t)
                }
                Spacer(minLength: 0)
                PanelCollapseButton(.deck)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            Rectangle()
                .fill(Theme.line)
                .frame(height: Theme.hairline)
            Group {
                switch tab {
                case .positions: PositionsTable()
                case .orders: OrdersTable()
                case .fills: FillsTable()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .panel()
    }

    private func tabButton(_ t: DeckTab) -> some View {
        Button {
            tab = t
        } label: {
            HStack(spacing: 5) {
                Text(t.rawValue.capitalized)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(tab == t ? Theme.bone : Theme.dim)
                Text("\(count(for: t))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(tab == t ? Theme.ember : Theme.dim.opacity(0.7))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(tab == t ? Theme.panelHi : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(DeckMotion.ease(), value: tab)
    }

    private func count(for t: DeckTab) -> Int {
        switch t {
        case .positions: model.positions.count
        case .orders: model.orders.count
        case .fills: model.fills.count
        }
    }
}
