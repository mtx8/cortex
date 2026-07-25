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
    /// A command that did NOT reach the engine, with why. Never nil-handled
    /// silently: an undelivered command must always be visible to the operator.
    var onSendFailure: ((Command, String) -> Void)?
    /// Test seam: when set, `send` hands the command here and reports whatever
    /// the closure returns instead of touching a socket. This exists so the
    /// command layer — order placement, kill switch, request spinners — can be
    /// tested against a DELIVERING link, which is the case where most of the
    /// interesting state machinery runs. Never set in production.
    var sendInterceptor: ((Command) -> Bool)?

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

    /// Send a command, reporting whether it actually went out.
    ///
    /// This used to return Void and swallow every failure mode: an offline link
    /// dropped the command on the floor, an encoding failure did the same, and
    /// the completion handler discarded the transport error. For a trading
    /// terminal that is the worst possible default — the operator clicks "Engage
    /// Kill Switch" or "Flatten All", the control gives no feedback, and nothing
    /// happened. Callers now learn immediately (the return value) and
    /// asynchronously (`onSendFailure`, for a socket that fails after accepting
    /// the write).
    @discardableResult
    func send(_ command: Command) -> Bool {
        if let sendInterceptor {
            let delivered = sendInterceptor(command)
            if !delivered { onSendFailure?(command, "send refused") }
            return delivered
        }
        guard let task, state == .connected else {
            onSendFailure?(command, "engine not connected")
            return false
        }
        let data: Data
        do {
            data = try command.encoded()
        } catch {
            // Report WHY, not just "could not be encoded". The realistic cause is
            // a field the engine's serde would reject outright — an IBKR port
            // above 65535 fails the WHOLE internally-tagged frame — and the
            // operator can only act on that if they are told which value is bad.
            // `CommandEncodingError` is a LocalizedError, so its detail comes
            // through `localizedDescription`.
            onSendFailure?(command, error.localizedDescription)
            return false
        }
        guard let text = String(data: data, encoding: .utf8) else {
            onSendFailure?(command, "command could not be encoded")
            return false
        }
        task.send(.string(text)) { [weak self] error in
            guard let error else { return }
            Task { @MainActor [weak self] in
                self?.onSendFailure?(command, error.localizedDescription)
            }
        }
        return true
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
            await handle(first)
            while !Task.isCancelled {
                await handle(try await ws.receive())
            }
        } catch {
            // fall through to reconnect
        }
        task = nil
        setState(.disconnected)
    }

    /// Parse a message OFF the main actor, then apply it ON the main actor.
    ///
    /// The parse used to run right here on the main actor, and the deep-sync
    /// snapshot is not small: 3 000 bars for every watchlist and universe symbol,
    /// megabytes of JSON (hence `maximumMessageSize` above). Every connect and
    /// every long range-preset click therefore froze the whole window for a third
    /// to two thirds of a second — charts stopped repainting, the tape stalled,
    /// and clicks including the RiskHUD kill switch were not delivered until the
    /// decode finished. `decodeFrame` is `nonisolated async`, so calling it from
    /// this main-actor method hops to the cooperative pool and the window stays
    /// live while the snapshot parses.
    ///
    /// Order is still exact. The receive loop awaits this method to completion
    /// before it calls `receive()` again, so at most ONE frame is ever in flight
    /// and frames reach `onFrame` strictly in arrival order — which the model
    /// depends on: a snapshot followed by ticks must not apply as ticks followed
    /// by a snapshot. `URLSessionWebSocketTask` buffers messages that arrive while
    /// we are not receiving, so nothing is dropped by the wait.
    private func handle(_ message: URLSessionWebSocketTask.Message) async {
        let frame: ServerFrame?
        switch message {
        case .string(let text):
            frame = await Self.decodeFrame(text: text)
        case .data(let d):
            frame = await Self.decodeFrame(payload: d)
        @unknown default:
            return
        }
        guard let frame else { return }
        // The decode suspended, so the link could have gone away while it parsed
        // (`stop()` sets `.disconnected` synchronously from outside this loop).
        // A frame from a connection that no longer exists must not be applied:
        // AppModel resets tape, book and broker posture on disconnect, and a late
        // snapshot would silently repopulate them from a dead session.
        guard state == .connected, !Task.isCancelled else { return }
        onFrame?(frame)
    }

    /// `nonisolated` + `async` is what puts this on the cooperative thread pool
    /// instead of the main actor's executor (SE-0338): a non-isolated async
    /// function never inherits its caller's actor.
    private nonisolated static func decodeFrame(payload: Data) async -> ServerFrame? {
        // Malformed frames are ignored exactly as before — a garbled message must
        // not take down the receive loop or the connection.
        try? ServerFrame.decode(payload)
    }

    /// Text overload: `Data(text.utf8)` is a full copy of the payload, so for a
    /// multi-megabyte snapshot that copy belongs off the main thread too. A
    /// `String` is a Sendable value, so it is the cheap thing to hand across.
    private nonisolated static func decodeFrame(text: String) async -> ServerFrame? {
        try? ServerFrame.decode(Data(text.utf8))
    }
}
