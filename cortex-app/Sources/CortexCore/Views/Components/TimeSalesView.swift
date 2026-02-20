import SwiftUI

/// Scrolling tick-by-tick time & sales feed.
public struct TimeSalesView: View {
    let store: Level2Store

    public init(store: Level2Store) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(CortexDesign.border)
            columnHeaders

            if store.timeSales.isEmpty {
                emptyState
            } else {
                tickList
            }
        }
        .background(CortexDesign.bgDeepest)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 10))
                .foregroundStyle(CortexDesign.accentPrimary)

            Text("TIME & SALES")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Text("\(store.timeSales.count) ticks")
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CortexDesign.bgCard)
    }

    // MARK: - Column Headers

    private var columnHeaders: some View {
        HStack(spacing: 0) {
            Text("TIME")
                .frame(width: 60, alignment: .leading)
            Text("PRICE")
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text("SIZE")
                .frame(width: 60, alignment: .trailing)
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(CortexDesign.bgCard)
    }

    // MARK: - Tick List

    private var tickList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(spacing: 0) {
                ForEach(store.timeSales) { tick in
                    tickRow(tick)
                }
            }
        }
    }

    private func tickRow(_ tick: TimeSalesTick) -> some View {
        let color = tick.side == "buy" ? CortexDesign.profit : CortexDesign.loss

        return HStack(spacing: 0) {
            Text(formatTime(tick.time))
                .frame(width: 60, alignment: .leading)
                .foregroundStyle(.secondary)

            Text(String(format: "%.2f", tick.price))
                .frame(maxWidth: .infinity, alignment: .trailing)
                .foregroundStyle(color)

            Text(formatSize(tick.size))
                .frame(width: 60, alignment: .trailing)
                .foregroundStyle(.white.opacity(0.7))
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(color.opacity(0.03))
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 24))
                .foregroundStyle(Color(white: 0.2))
            Text("No time & sales data")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Formatting

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }

    private func formatSize(_ size: Int) -> String {
        if size >= 1000 {
            return String(format: "%.1fK", Double(size) / 1000)
        }
        return "\(size)"
    }
}
