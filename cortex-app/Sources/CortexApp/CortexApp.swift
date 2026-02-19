import SwiftUI
import AppKit
import CortexCore

@main
struct CortexApp: App {
    @State private var environment = AppEnvironment()
    @State private var router: MessageRouter?

    init() {
        // SPM executable targets produce bare binaries without an .app bundle.
        // macOS defaults such processes to the .prohibited activation policy,
        // which means no dock icon, no menu bar, and no windows shown.
        // Force the process to behave as a regular GUI application.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup {
            ContentView(environment: environment)
                .frame(minWidth: 1200, minHeight: 800)
                .onAppear {
                    if router == nil {
                        let r = MessageRouter(environment: environment)
                        r.start()
                        router = r
                    }
                }
        }
        .defaultSize(width: 1400, height: 900)
    }
}
