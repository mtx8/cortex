// CORTEX X — AI-native trading terminal.
// (c) 2026 MTX Labs. All rights reserved.

import SwiftUI

@main
struct CortexXApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .background(Theme.ink)
                .frame(minWidth: 1180, minHeight: 720)
                .task { model.start() }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
