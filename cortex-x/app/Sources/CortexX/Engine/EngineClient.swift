// WebSocket client for cortexd. Owns the connection lifecycle: connect,
// decode, dispatch to AppModel, reconnect with capped exponential backoff.

import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    var label: String {
        switch self {
        case .disconnected: "offline"
        case .connecting: "connecting"
        case .connected: "live"
        }
    }
}

@MainActor
final class EngineClient {
    private(set) var state: ConnectionState = .disconnected
    var onFrame: ((ServerFrame) -> Void)?
    var onStateChange: ((ConnectionState) -> Void)?

    private var task: URLSessionWebSocketTask?
    private var runLoop: Task<Void, Never>?
    private var backoff: TimeInterval = 1
    private let url: URL

    nonisolated init(host: String = "127.0.0.1", port: Int = 9601) {
        self.url = URL(string: "ws://\(host):\(port)")!
    }

    func start() {
        guard runLoop == nil else { return }
        runLoop = Task { [weak self] in
            while let self, !Task.isCancelled {
                await self.runOnce()
                guard !Task.isCancelled else { break }
                let delay = self.backoff
                self.backoff = min(self.backoff * 2, 15)
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func stop() {
        runLoop?.cancel()
        runLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        setState(.disconnected)
    }

    func send(_ command: Command) {
        guard let task, state == .connected else { return }
        guard let data = try? command.encoded(),
              let text = String(data: data, encoding: .utf8) else { return }
        task.send(.string(text)) { _ in }
    }

    private func setState(_ new: ConnectionState) {
        guard state != new else { return }
        state = new
        onStateChange?(new)
    }

    private func runOnce() async {
        setState(.connecting)
        let ws = URLSession.shared.webSocketTask(with: url)
        // The connect snapshot (bars for every symbol/interval) far exceeds
        // the 1 MiB default message cap.
        ws.maximumMessageSize = 64 * 1024 * 1024
        task = ws
        ws.resume()
        do {
            // First frame proves the engine is really there.
            let first = try await ws.receive()
            backoff = 1
            setState(.connected)
            handle(first)
            while !Task.isCancelled {
                handle(try await ws.receive())
            }
        } catch {
            // fall through to reconnect
        }
        task = nil
        setState(.disconnected)
    }

    private func handle(_ message: URLSessionWebSocketTask.Message) {
        let data: Data
        switch message {
        case .string(let text):
            data = Data(text.utf8)
        case .data(let d):
            data = d
        @unknown default:
            return
        }
        guard let frame = try? ServerFrame.decode(data) else { return }
        onFrame?(frame)
    }
}
