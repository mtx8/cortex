// Self-contained launch: if no engine is reachable shortly after startup,
// spawn the cortexd bundled inside the app (Contents/Resources/cortexd).
// The engine is left running when the app quits — it is the trading system;
// the window is just a view onto it.

import Foundation

enum EngineBootstrap {
    private static var launched = false

    /// Called when the client has failed to connect for a few seconds.
    @MainActor
    static func launchBundledEngineIfNeeded() {
        guard !launched else { return }
        let path = Bundle.main.bundlePath + "/Contents/Resources/cortexd"
        guard FileManager.default.isExecutableFile(atPath: path) else { return }
        launched = true

        let logDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs")
        let logURL = logDir.appendingPathComponent("CortexX-engine.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try? FileHandle(forWritingTo: logURL)
        _ = try? log?.seekToEnd()

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.environment = ProcessInfo.processInfo.environment
            .merging(["RUST_LOG": "info"]) { _, new in new }
        if let log {
            proc.standardOutput = log
            proc.standardError = log
        }
        do {
            try proc.run()
            NSLog("CortexX: launched bundled engine (pid \(proc.processIdentifier)), log at \(logURL.path)")
        } catch {
            NSLog("CortexX: failed to launch bundled engine: \(error)")
            launched = false
        }
    }
}
