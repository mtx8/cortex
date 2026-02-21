import SwiftUI

/// Dual-column bid/ask Level 2 order book with color-coded depth bars.
public struct Level2View: View {
    let store: Level2Store
    private let visibleRows: Int

    public init(store: Level2Store, visibleRows: Int = 15) {
        self.store = store
        self.visibleRows = visibleRows
    }

    public var body: some View {
        VStack(spacing: 0) {
            header

            Divider().overlay(CortexDesign.border)

            if store.bids.isEmpty && store.asks.isEmpty {
                emptyState
            } else {
                bookContent
            }
        }
        .background(CortexDesign.bgDeepest)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 10))
                .foregroundStyle(CortexDesign.accentPrimary)

            Text("LEVEL 2")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            if !store.activeSymbol.isEmpty {
                Text(store.activeSymbol)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.white)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(CortexDesign.bgCard)
    }

    // MARK: - Book Content

    private var bookContent: some View {
        HStack(spacing: 0) {
            // Bids (left side)
            VStack(spacing: 0) {
                columnHeaders(isBid: true)
                Divider().overlay(CortexDesign.border)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.bids.prefix(visibleRows))) { row in
                            bidRow(row)
                        }
                    }
                }
            }

            // Center divider
            Rectangle()
                .fill(CortexDesign.border)
                .frame(width: 1)

            // Asks (right side)
            VStack(spacing: 0) {
                columnHeaders(isBid: false)
                Divider().overlay(CortexDesign.border)

                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 0) {
                        ForEach(Array(store.asks.prefix(visibleRows))) { row in
                            askRow(row)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Column Headers

    private func columnHeaders(isBid: Bool) -> some View {
        HStack(spacing: 0) {
            if isBid {
                Text("SIZE")
                    .frame(maxWidth: .infinity, alignment: .trailing)
                Text("BID")
                    .frame(maxWidth: .infinity, alignment: .trailing)
            } else {
                Text("ASK")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("SIZE")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(.system(size: 9, weight: .bold, design: .monospaced))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(CortexDesign.bgCard)
    }

    // MARK: - Rows

    private func bidRow(_ row: Level2Row) -> some View {
        let maxSize = store.maxSize
        let depthFraction = maxSize > 0 ? CGFloat(row.size) / CGFloat(maxSize) : 0

        return HStack(spacing: 0) {
            Text(formatSize(row.size))
                .frame(maxWidth: .infinity, alignment: .trailing)
            Text(formatPrice(row.price))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(CortexDesign.profit)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(alignment: .trailing) {
            GeometryReader { geo in
                Rectangle()
                    .fill(CortexDesign.profit.opacity(0.08))
                    .frame(width: geo.size.width * depthFraction)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }

    private func askRow(_ row: Level2Row) -> some View {
        let maxSize = store.maxSize
        let depthFraction = maxSize > 0 ? CGFloat(row.size) / CGFloat(maxSize) : 0

        return HStack(spacing: 0) {
            Text(formatPrice(row.price))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(formatSize(row.size))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 11, design: .monospaced))
        .foregroundStyle(CortexDesign.loss)
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(alignment: .leading) {
            GeometryReader { geo in
                Rectangle()
                    .fill(CortexDesign.loss.opacity(0.08))
                    .frame(width: geo.size.width * depthFraction)
            }
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 24))
                .foregroundStyle(CortexDesign.border)
            Text("No Level 2 data")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text("Connect to IBKR for live order book")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Formatting

    private func formatPrice(_ price: Double) -> String {
        String(format: "%.2f", price)
    }

    private func formatSize(_ size: Int) -> String {
        if size >= 1000 {
            return String(format: "%.1fK", Double(size) / 1000)
        }
        return "\(size)"
    }
}
