import Foundation

/// Prices pushed by Yahoo Finance's unofficial streaming quote feed: the WebSocket Yahoo's own web
/// pages get their prices from, which the yfinance project also reads.
///
/// It's undocumented and not licensed or endorsed by Yahoo; it can change or be blocked without
/// notice, and Yahoo's terms govern its use (docs/providers.md). No key, no account, no cookie: one
/// connection for the whole watchlist, with a User-Agent that names Vettira. Each message is a
/// base64 protobuf `PricingData`; Vettira reads its symbol, price, time and market-hours fields, and
/// keeps only regular-session prices, so an extended-hours price is never read.
public struct YahooQuoteStream: QuoteStream {
    public let name = "Yahoo Finance (unofficial)"

    static let url = URL(string: "wss://streamer.finance.yahoo.com/?version=2")!

    private let webSocket: any WebSocketClient

    public init(webSocket: any WebSocketClient = URLSessionWebSocketClient()) {
        self.webSocket = webSocket
    }

    public func connect() -> any QuoteStreamConnection {
        var request = URLRequest(url: Self.url)
        request.setValue(YahooFinanceProvider.userAgent, forHTTPHeaderField: "User-Agent")
        return Connection(socket: webSocket.connect(request), source: name)
    }

    struct Connection: QuoteStreamConnection {
        let socket: any WebSocketConnection
        let source: String

        func subscribe(_ symbols: [String]) async throws(ProviderError) {
            try await send(Subscription(subscribe: symbols))
        }

        func unsubscribe(_ symbols: [String]) async throws(ProviderError) {
            try await send(Subscription(unsubscribe: symbols))
        }

        func next() async throws(ProviderError) -> Quote {
            while true {
                let text: String
                do {
                    text = try await socket.receive()
                } catch {
                    throw failure()
                }
                if let quote = try quote(from: text) { return quote }
            }
        }

        func close() {
            socket.close()
        }

        /// The message's quote; `nil` for a message that isn't a price, or a price outside the
        /// regular session.
        func quote(from text: String) throws(ProviderError) -> Quote? {
            guard let envelope = try? JSONDecoder().decode(Envelope.self, from: Data(text.utf8)) else {
                throw .malformedResponse(detail: "a stream message that isn't the JSON Vettira expects")
            }
            guard envelope.type == "pricing" else { return nil }
            guard let encoded = envelope.message, let bytes = Data(base64Encoded: encoded),
                  let pricing = try? PricingData(bytes)
            else {
                throw .malformedResponse(detail: "a stream price Vettira couldn't decode")
            }
            guard pricing.marketHours == PricingData.regularMarket else { return nil }
            guard let symbol = pricing.id, !symbol.isEmpty,
                  let price = pricing.price, price.isFinite, price > 0,
                  let time = pricing.time, time > 0
            else { return nil }
            return Quote(
                symbol: symbol,
                // float32 on the wire: its shortest decimal form, so 753.42 isn't 753.4199829…
                price: Double(price.description) ?? Double(price),
                timestamp: Date(timeIntervalSince1970: Double(time) / 1000),
                source: source,
                session: .regular)
        }

        private func send(_ subscription: Subscription) async throws(ProviderError) {
            let text = String(decoding: try! JSONEncoder().encode(subscription), as: UTF8.self)
            do {
                try await socket.send(text)
            } catch {
                throw failure()
            }
        }

        /// Why the connection failed: what its handshake answered, when it didn't open.
        private func failure() -> ProviderError {
            switch socket.handshakeStatus {
            case 403: .blocked
            case 429: .rateLimited(retryAfter: nil)
            default: .unavailable
            }
        }
    }

    private struct Subscription: Encodable {
        var subscribe: [String]?
        var unsubscribe: [String]?
    }

    private struct Envelope: Decodable {
        let type: String?
        let message: String?
    }
}

/// The fields Vettira reads from Yahoo's `PricingData` protobuf message, the one yfinance's
/// `pricing.proto` describes: `id` (1, string), `price` (2, float), `time` (3, sint64 milliseconds
/// since 1970) and `marketHours` (7, an enum: 0 pre-market, 1 regular, 2 post-market, others for
/// extended and overnight trading). Every other field is skipped.
struct PricingData: Equatable {
    static let regularMarket: UInt64 = 1

    var id: String?
    var price: Float?
    var time: Int64?
    var marketHours: UInt64?

    struct Malformed: Error {}

    init(_ data: Data) throws(Malformed) {
        var reader = Reader(bytes: [UInt8](data))
        while !reader.atEnd {
            let key = try reader.varint()
            switch (key >> 3, key & 7) {
            case (1, 2): id = String(bytes: try reader.lengthDelimited(), encoding: .utf8)
            case (2, 5): price = Float(bitPattern: try reader.fixed32())
            case (3, 0): time = Reader.zigzag(try reader.varint())
            case (7, 0): marketHours = try reader.varint()
            case (_, 0): _ = try reader.varint()
            case (_, 1): try reader.skip(8)
            case (_, 2): _ = try reader.lengthDelimited()
            case (_, 5): try reader.skip(4)
            default: throw Malformed()
            }
        }
    }

    /// Reads protobuf's wire format, never past the end.
    private struct Reader {
        let bytes: [UInt8]
        var index = 0

        var atEnd: Bool { index >= bytes.count }

        mutating func varint() throws(Malformed) -> UInt64 {
            var value: UInt64 = 0
            for shift in stride(from: UInt64(0), to: 64, by: 7) {
                guard index < bytes.count else { throw Malformed() }
                let byte = bytes[index]
                index += 1
                value |= UInt64(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
            }
            throw Malformed()
        }

        mutating func fixed32() throws(Malformed) -> UInt32 {
            guard bytes.count - index >= 4 else { throw Malformed() }
            defer { index += 4 }
            return (0..<4).reduce(UInt32(0)) { $0 | UInt32(bytes[index + $1]) << (8 * UInt32($1)) }
        }

        mutating func lengthDelimited() throws(Malformed) -> ArraySlice<UInt8> {
            let length = try varint()
            guard length <= UInt64(bytes.count - index) else { throw Malformed() }
            defer { index += Int(length) }
            return bytes[index..<index + Int(length)]
        }

        mutating func skip(_ count: Int) throws(Malformed) {
            guard bytes.count - index >= count else { throw Malformed() }
            index += count
        }

        /// A `sint64`'s value from its zigzag encoding.
        static func zigzag(_ raw: UInt64) -> Int64 {
            Int64(bitPattern: raw >> 1) ^ -Int64(bitPattern: raw & 1)
        }
    }
}
