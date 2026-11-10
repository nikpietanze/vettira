import Foundation

/// Opens WebSocket connections: the one place a stream touches the network, so tests can answer in
/// its place with recorded messages.
public protocol WebSocketClient: Sendable {
    /// A connection for `request`. The handshake finishes, or fails, at its first send or receive.
    func connect(_ request: URLRequest) -> any WebSocketConnection
}

/// One WebSocket connection.
public protocol WebSocketConnection: Sendable {
    /// Sends a text message.
    func send(_ text: String) async throws
    /// Waits for the next message, as text.
    func receive() async throws -> String
    /// The HTTP status the server answered the handshake with, once it has: 101 when it opened.
    var handshakeStatus: Int? { get }
    /// Closes the connection. A receive waiting on it throws.
    func close()
}

/// The real network, through a `URLSession` that keeps nothing: no cookies sent or stored, no
/// cache. It pings the server every 30 seconds, and closes the connection when no answer comes
/// within 15, so a connection that died quietly fails instead of waiting for good.
public struct URLSessionWebSocketClient: WebSocketClient {
    private let session: URLSession

    public init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 90
        session = URLSession(configuration: configuration)
    }

    public func connect(_ request: URLRequest) -> any WebSocketConnection {
        let task = session.webSocketTask(with: request)
        task.resume()
        return Connection(task: task)
    }

    private final class Connection: WebSocketConnection, @unchecked Sendable {
        // URLSessionWebSocketTask is thread-safe; the keepalive task is set once, in init.
        private let task: URLSessionWebSocketTask
        private var keepalive: Task<Void, Never>?

        init(task: URLSessionWebSocketTask) {
            self.task = task
            keepalive = Task { [task] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(30))
                    if Task.isCancelled || task.state != .running { return }
                    let answered = await Self.ping(task, within: .seconds(15))
                    if !answered { task.cancel(with: .goingAway, reason: nil) }
                }
            }
        }

        deinit {
            keepalive?.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }

        func send(_ text: String) async throws {
            try await task.send(.string(text))
        }

        func receive() async throws -> String {
            switch try await task.receive() {
            case .string(let text): return text
            case .data(let data): return String(decoding: data, as: UTF8.self)
            @unknown default: throw URLError(.cannotParseResponse)
            }
        }

        var handshakeStatus: Int? { (task.response as? HTTPURLResponse)?.statusCode }

        func close() {
            keepalive?.cancel()
            task.cancel(with: .normalClosure, reason: nil)
        }

        /// Whether the server answered a ping within `limit`.
        private static func ping(_ task: URLSessionWebSocketTask, within limit: Duration) async -> Bool {
            let answer = Answer()
            return await withCheckedContinuation { continuation in
                answer.wait(continuation)
                task.sendPing { error in answer.give(error == nil) }
                Task {
                    try? await Task.sleep(for: limit)
                    answer.give(false)
                }
            }
        }
    }

    /// The first of a ping's two outcomes, its answer or the time limit; the other is ignored.
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?

        func wait(_ continuation: CheckedContinuation<Bool, Never>) {
            lock.withLock { self.continuation = continuation }
        }

        func give(_ answered: Bool) {
            lock.withLock {
                continuation?.resume(returning: answered)
                continuation = nil
            }
        }
    }
}
