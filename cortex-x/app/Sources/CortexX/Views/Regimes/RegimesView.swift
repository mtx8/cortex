// REGIMES — market-wide bull/bear state board with breadth gauges.
// Placeholder pending the regimes-view build task; keeps the shell compiling.

import SwiftUI

struct RegimesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            SectionLabel(text: "regimes")
            Text(model.regimeBoard == nil ? "scanning the universe…" : "regime board")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }
}
