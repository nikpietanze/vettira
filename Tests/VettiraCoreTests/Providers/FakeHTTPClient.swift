import Foundation
import Testing
import VettiraCore

/// Answers each request with the next scripted reply, after checking it went where the script
/// says, and keeps every request it got. Never touches the network.
actor FakeHTTPClient: HTTPClient {
    struct Reply {
        /// The URL the request must be for, up to its query.
        var expected: String
        var status: Int
        var body: String = ""
        var headers: [String: String] = [:]
        /// Where the response says it came from, when a redirect took the request elsewhere.
        var finalURL: String? = nil
        /// Fails the request as the network would, instead of answering.
        var networkError: URLError.Code? = nil
    }

    private var replies: [Reply]
    private(set) var requests: [URLRequest] = []
    private var inFlight = 0
    /// The most requests that were ever in flight at once.
    private(set) var mostInFlight = 0

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else {
            Issue.record("unscripted request to \(request.url?.absoluteString ?? "nowhere")")
            throw URLError(.cannotConnectToHost)
        }
        let reply = replies.removeFirst()
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        defer { inFlight -= 1 }
        // Gives a concurrent caller the chance to send while this request is in flight.
        for _ in 0..<5 { await Task.yield() }
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.query = nil
        #expect(components.string == reply.expected)
        if let code = reply.networkError { throw URLError(code) }
        let url = URL(string: reply.finalURL ?? reply.expected)!
        let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        return (Data(reply.body.utf8), response)
    }

    var unusedReplies: Int { replies.count }
}

/// Replies from Yahoo's chart endpoint.
enum Yahoo {
    static func chartURL(_ symbol: String) -> String {
        "https://query1.finance.yahoo.com/v8/finance/chart/\(symbol)"
    }

    static func chart(
        _ symbol: String, _ body: String, status: Int = 200, headers: [String: String] = [:]
    ) -> FakeHTTPClient.Reply {
        FakeHTTPClient.Reply(
            expected: chartURL(symbol), status: status, body: body,
            headers: ["Content-Type": "application/json;charset=utf-8"].merging(headers) { $1 })
    }
}

/// A clock for `RequestPacing` that moves only when the provider sleeps, and keeps each sleep.
final class PacingClock: @unchecked Sendable {
    private let lock = NSLock()
    private let start = ContinuousClock.now
    private var elapsed = Duration.zero
    private var _sleeps: [Duration] = []

    var sleeps: [Duration] { lock.withLock { _sleeps } }

    func advance(by duration: Duration) {
        lock.withLock { elapsed += duration }
    }

    var pacing: RequestPacing {
        RequestPacing(
            interval: .seconds(1),
            now: { [self] in lock.withLock { start + elapsed } },
            sleep: { [self] duration in
                lock.withLock {
                    _sleeps.append(duration)
                    elapsed += duration
                }
            })
    }
}
