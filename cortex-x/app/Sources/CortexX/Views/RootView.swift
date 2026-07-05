// Root layout shell — watchlist rail | chart + trading deck | intelligence rail.
// Panels are implemented in Views/*; this file owns only arrangement.

import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 0) {
            TopBar()
            Divider().overlay(Theme.line)
            HStack(spacing: 0) {
                Watchlist()
                    .frame(width: 220)
                Divider().overlay(Theme.line)
                VStack(spacing: 0) {
                    CenterModeBar()
                    Divider().overlay(Theme.line)
                    Group {
                        if model.centerMode == .chart {
                            ChartPanel()
                        } else {
                            OptionsChainView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider().overlay(Theme.line)
                    DashboardPanel()
                        .frame(height: 280)
                }
                .frame(maxWidth: .infinity)
                Divider().overlay(Theme.line)
                IntelligencePanel()
                    .frame(width: 340)
            }
        }
        .background(Theme.ink)
    }
}

/// chart | options switch for the center column.
private struct CenterModeBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 4) {
            ForEach(AppModel.CenterMode.allCases, id: \.rawValue) { mode in
                let active = model.centerMode == mode
                Button {
                    model.centerMode = mode
                } label: {
                    Text(mode.rawValue)
                        .font(.system(size: 10, weight: active ? .semibold : .regular))
                        .foregroundStyle(active ? Theme.ember : Theme.dim)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(active ? Theme.emberTint : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.chipRadius))
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
    }
}
