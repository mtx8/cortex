import SwiftUI

/// Trade View — IBKR-style trading interface with Level 2, orders, and positions.
/// Placeholder until Phase C implementation.
public struct TradeView: View {
    let environment: AppEnvironment

    public init(environment: AppEnvironment) {
        self.environment = environment
    }

    public var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "chart.bar.doc.horizontal")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Trade View")
                .font(CortexDesign.headerFont)
                .foregroundStyle(.primary)
            Text("Level 2, Orders, Positions, Simulation")
                .font(CortexDesign.labelFont)
                .foregroundStyle(.secondary)
            Text("Coming in Phase C")
                .font(.system(size: 11))
                .foregroundStyle(CortexDesign.accentPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(CortexDesign.bgDeepest)
    }
}
