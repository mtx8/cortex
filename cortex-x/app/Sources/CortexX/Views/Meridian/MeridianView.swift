// MERIDIAN — the Dalio section: Five Forces gauges, fired causal chains,
// and the geopolitical signal feed. The lines that connect the world.
// Placeholder pending the meridian-view build task; keeps the shell compiling.

import SwiftUI

struct MeridianView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 8) {
            SectionLabel(text: "meridian")
            Text(model.geoPulse == nil ? "listening to the world…" : "meridian pulse")
                .font(.system(size: 13))
                .foregroundStyle(Theme.dim)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ink)
    }
}
