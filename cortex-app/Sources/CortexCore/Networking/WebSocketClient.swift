import Foundation
import Logging

@MainActor
@Observable
public final class WebSocketClient {
    public let url: String
    public private(set) var isConnected: Bool = false
    public private(set) var lastError: String?
    public private(set) var messagesReceived: Int = 0

    private var webSocketTask: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private let logger = Logger(label: "cortex.websocket")
    private var shouldReconnect: Bool = true
    private let maxReconnectDelay: Double = 30.0

    public var onMessage: (([String: Any]) -> Void)?

    public init(url: String = "ws://127.0.0.1:8765/ws") {
        self.url = url
    }

    public func connect() {
        guard let wsURL = URL(string: url) else {
            lastError = "Invalid URL: \(url)"
            return
        }
        shouldReconnect = true
        let session = URLSession(configuration: .default)
        webSocketTask = session.webSocketTask(with: wsURL)
        webSocketTask?.resume()
        isConnected = true
        lastError = nil
        receiveMessages()
    }

    public func disconnect() {
        shouldReconnect = false
        reconnectTask?.cancel()
        reconnectTask = nil
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    public func send(_ data: [String: Any]) async throws {
        // Simple JSON encoding for commands
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        try await webSocketTask?.send(.data(jsonData))
    }

    private func receiveMessages() {
        webSocketTask?.receive { [weak self] result in
            Task { @MainActor in
                guard let self = self else { return }
                switch result {
                case .success(let message):
                    self.messagesReceived += 1
                    self.handleMessage(message)
                    self.receiveMessages() // Continue listening
                case .failure(let error):
                    self.logger.error("WebSocket error: \(error.localizedDescription)")
                    self.lastError = error.localizedDescription
                    self.isConnected = false
                    if self.shouldReconnect {
                        self.scheduleReconnect()
                    }
                }
            }
        }
    }

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .data(let data):
            if let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                onMessage?(dict)
            }
        case .string(let text):
            if let data = text.data(using: .utf8),
               let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                onMessage?(dict)
            }
        @unknown default:
            break
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            guard !Task.isCancelled, self.shouldReconnect else { return }
            self.logger.info("Attempting WebSocket reconnect...")
            self.connect()
        }
    }
}
