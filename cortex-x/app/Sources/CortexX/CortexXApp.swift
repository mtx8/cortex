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
                .task {
                    model.start()
                    // Double-click experience: if no engine answers within a
                    // few seconds, start the one bundled inside this app.
                    try? await Task.sleep(for: .seconds(3))
                    if model.connection != .connected {
                        EngineBootstrap.launchBundledEngineIfNeeded()
                    }
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
    }
}
