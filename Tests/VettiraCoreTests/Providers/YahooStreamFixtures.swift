import Foundation
import Testing
import VettiraCore

/// Messages from Yahoo Finance's streaming quote feed, for the stream's tests.
///
/// The `recorded` ones are real text frames, market data only, each received on one connection to
/// `?version=2` with Vettira's User-Agent. The crypto and overnight ones came on Monday 9 November
/// 2026, between 20:30 and 20:40 New York time, when crypto was in its regular session
/// (`marketHours` 1) and SPY and AAPL in overnight trading (`marketHours` 4). The SPY and QQQ ones
/// came in the regular session on Tuesday 10 November 2026, from 09:42 New York time. Prices
/// outside the regular session that weren't recorded (pre-market, post-market) and broken messages
/// are made by hand in the same shape by `pricing(...)`.
enum YahooStreamFixtures {
    /// BTC-USD at 74958.40625 (float32), 01:30:55 UTC on 10 November 2026, regular session, with
    /// every field crypto sends (real).
    static let btc = #"{"type":"pricing","message":"CgdCVEMtVVNEFTRnkkcYsIKjsbhoIgNVU0QqA0NDQzApOAFFzgchvkiAwN+BxwFVnRqTR13zSpJHZQAg7MJ97vqSR7ABgMDfgccB2AEE4AGAwN+BxwHoAYDA34HHAfIBA0JUQ4ECAAAA4K8tc0GJAgAAPX/I9nVC9QIAIOzC/QLOByG+"}"#
    static let btcTime = Date(timeIntervalSince1970: 1_794_274_255)

    /// BTC-USD six seconds later, at 74958.421875 (real).
    static let btcLater = #"{"type":"pricing","message":"CgdCVEMtVVNEFTZnkkcYkOCjsbhoIgNVU0QqA0NDQzApOAFFWQIhvkiAwN+BxwFVnRqTR13zSpJHZQAY7MJ97vqSR7ABgMDfgccB2AEE4AGAwN+BxwHoAYDA34HHAfIBA0JUQ4ECAAAA4K8tc0GJAgAAPX/I9nVC9QIAGOzC/QJZAiG+"}"#
    static let btcLaterTime = Date(timeIntervalSince1970: 1_794_274_261)

    /// SPY at 753.42 in overnight trading, 01:31:03 UTC (real): only the fields an ETF sends
    /// outside regular hours.
    static let spyOvernight = #"{"type":"pricing","message":"CgNTUFkV4Vo8RBiw/6OxuGgqA1BDWDAUOARF9p7GPWUA4Do/2AEE9QJACpFB/QLxzR1A"}"#

    /// AAPL at 350.62 in overnight trading, 01:31:19 UTC (real).
    static let aaplOvernight = #"{"type":"pricing","message":"CgRBQVBMFVxPr0MYsPmlsbhoKgNOTVMwCDgEReWIo7xlAGCPvdgBBPUCAAAEQf0CGTgaQA=="}"#

    /// SPY at 748.24 (float32) in the regular session, 14:42:09 UTC on 10 November 2026 (real):
    /// every field an ETF sends in regular hours but the day's high and low.
    static let spyRegular = #"{"type":"pricing","message":"CgNTUFkVXA87RBjQl8beuGgqA1BDWDAUOAFFI6kVv0jA8pYEZQDNjMCwAVDYAQT1AgDNjMD9AiOpFb8="}"#
    /// QQQ at 673.37 in the regular session, the same second as `spyRegular` (real).
    static let qqqRegular = #"{"type":"pricing","message":"CgNRUVEVrlcoRBjQl8beuGgqA05HTTAUOAFFFlhhv0imq7kFZQBcv8CwAWTYAQT1AgBcv8D9AhZYYb8="}"#
    /// QQQ at 673.325, the next message for it, a second later but with the same time: the feed
    /// sends its time to the whole second (real).
    static let qqqSameSecond = #"{"type":"pricing","message":"CgNRUVEVzVQoRBjQl8beuGgqA05HTTAUOAFFCApjv0jWtrkFZYDMwMCwAcgB2AEE9QKAzMDA/QIICmO/"}"#
    static let regularTime = Date(timeIntervalSince1970: 1_794_321_729)

    /// QQQ at 674.68, a new high for the day, 14:43:39 UTC (real): it also carries the feed's day
    /// high and low, which it sends only when one changes.
    static let qqqNewHigh = #"{"type":"pricing","message":"CgNRUVEVhasoRBjwldHeuGgqA05HTTAUOAFFtvovv0jCndMFVYWrKERd4XonRGWAcJXAsAFQ2AEE9QKAcJXA/QK2+i+/"}"#
    static let qqqNewHighTime = Date(timeIntervalSince1970: 1_794_321_819)

    /// A `PricingData` message as the feed sends it, made by hand: `id` (1), `price` (2, float),
    /// `time` (3, sint64 milliseconds) and `marketHours` (7), wrapped in the `pricing` envelope.
    static func pricing(_ id: String, price: Float, time: Date, marketHours: UInt64 = 1) -> String {
        var bytes: [UInt8] = []
        func varint(_ value: UInt64) {
            var value = value
            while value >= 0x80 {
                bytes.append(UInt8(value & 0x7F) | 0x80)
                value >>= 7
            }
            bytes.append(UInt8(value))
        }
        let name = Array(id.utf8)
        varint(1 << 3 | 2)
        varint(UInt64(name.count))
        bytes += name
        varint(2 << 3 | 5)
        withUnsafeBytes(of: price.bitPattern.littleEndian) { bytes += $0 }
        let millis = Int64((time.timeIntervalSince1970 * 1000).rounded())
        varint(3 << 3 | 0)
        varint(UInt64(bitPattern: (millis << 1) ^ (millis >> 63)))
        varint(7 << 3 | 0)
        varint(marketHours)
        return #"{"type":"pricing","message":"\#(Data(bytes).base64EncodedString())"}"#
    }
}

/// A WebSocket that answers with scripted messages and keeps everything sent to it. Never touches
/// the network.
final class FakeWebSocket: WebSocketClient, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [FakeSocketConnection]
    private var _requests: [URLRequest] = []

    /// One connection per script, in order: the messages it receives, then a failure.
    init(_ scripts: [FakeSocketConnection]) {
        self.scripts = scripts
    }

    var requests: [URLRequest] { lock.withLock { _requests } }

    func connect(_ request: URLRequest) -> any WebSocketConnection {
        lock.withLock {
            _requests.append(request)
            guard !scripts.isEmpty else {
                Issue.record("unscripted connection")
                return FakeSocketConnection(messages: [])
            }
            return scripts.removeFirst()
        }
    }
}

final class FakeSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String]
    private var _sent: [String] = []
    private var _closed = false
    private let status: Int
    private let sendFails: Bool

    /// Receives `messages`, then fails as a dropped connection does. `status` is the handshake's
    /// answer; with `sendFails`, every send fails, as when the handshake was refused.
    init(messages: [String], status: Int = 101, sendFails: Bool = false) {
        self.messages = messages
        self.status = status
        self.sendFails = sendFails
    }

    var sent: [String] { lock.withLock { _sent } }
    var closed: Bool { lock.withLock { _closed } }

    func send(_ text: String) async throws {
        try lock.withLock {
            if sendFails { throw URLError(.badServerResponse) }
            _sent.append(text)
        }
    }

    func receive() async throws -> String {
        try lock.withLock {
            guard !messages.isEmpty, !_closed else { throw URLError(.networkConnectionLost) }
            return messages.removeFirst()
        }
    }

    var handshakeStatus: Int? { status }

    func close() {
        lock.withLock { _closed = true }
    }
}
