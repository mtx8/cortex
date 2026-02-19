import SwiftUI
import CortexCore

@main
struct CortexApp: App {
    @State private var environment = AppEnvironment()
    @State private var router: MessageRouter?

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
    }
}
