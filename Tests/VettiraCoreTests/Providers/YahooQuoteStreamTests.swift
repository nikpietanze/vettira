import Foundation
import Testing
import VettiraCore

// Expected values come from the recorded messages' own fields (docs/providers.md, "Streamed
// prices"), read off the wire by hand: BTC-USD's price is the float32 nearest 74958.41 and its
// time 1794274255000 ms; SPY's and AAPL's are in overnight trading. The rules are AGENTS.md's: one
// connection, an honest User-Agent, and an extended-hours price never read.

// A broken test fails within a minute instead of hanging the run.
@Suite(.timeLimit(.minutes(1))) struct YahooQuoteStreamTests {
    private typealias Fixtures = YahooStreamFixtures

    private func connect(_ connection: FakeSocketConnection) -> (FakeWebSocket, any QuoteStreamConnection) {
        let socket = FakeWebSocket([connection])
        return (socket, YahooQuoteStream(webSocket: socket).connect())
    }

    @Test func itConnectsToTheStreamerWithVettirasOwnUserAgent() {
        let (socket, _) = connect(FakeSocketConnection(messages: []))
        #expect(socket.requests.map(\.url?.absoluteString) == ["wss://streamer.finance.yahoo.com/?version=2"])
        #expect(socket.requests.first?.value(forHTTPHeaderField: "User-Agent")
            == "Vettira (https://github.com/nikpietanze/vettira)")
        #expect(socket.requests.first?.value(forHTTPHeaderField: "Cookie") == nil)
    }

    @Test func itSubscribesAndUnsubscribesWithTheFeedsJSONMessages() async throws {
        let socket = FakeSocketConnection(messages: [])
        let (_, connection) = connect(socket)
        try await connection.subscribe(["SPY", "BRK-B"])
        try await connection.unsubscribe(["SPY"])
        #expect(socket.sent == [#"{"subscribe":["SPY","BRK-B"]}"#, #"{"unsubscribe":["SPY"]}"#])
    }

    @Test func aRecordedRegularSessionMessageBecomesAQuote() async throws {
        let (_, connection) = connect(FakeSocketConnection(messages: [Fixtures.btc, Fixtures.btcLater]))
        let first = try await connection.next()
        #expect(first == Quote(
            symbol: "BTC-USD", price: 74958.41, timestamp: Fixtures.btcTime, source: "Yahoo Finance (unofficial)",
            session: .regular))
        let second = try await connection.next()
        #expect(second.price == 74958.42)
        #expect(second.timestamp == Fixtures.btcLaterTime)
    }

    @Test func aStreamedQuoteBringsNoHighCloseOrBars() async throws {
        // The feed's day high and previous close aren't the regular session's for certain, so
        // they're left to the chart endpoint.
        let (_, connection) = connect(FakeSocketConnection(messages: [Fixtures.btc]))
        let quote = try await connection.next()
        #expect(quote.sessionHigh == nil)
        #expect(quote.previousClose == nil)
        #expect(quote.intraday.isEmpty)
        #expect(quote.providerDelay == nil)
    }

    @Test func anExtendedHoursPriceIsNeverRead() async throws {
        let regular = Fixtures.pricing("SPY", price: 512.25, time: Fixtures.btcTime)
        let (_, connection) = connect(FakeSocketConnection(messages: [
            Fixtures.spyOvernight, Fixtures.aaplOvernight,
            Fixtures.pricing("SPY", price: 511, time: Fixtures.btcTime, marketHours: 0),
            Fixtures.pricing("SPY", price: 511, time: Fixtures.btcTime, marketHours: 2),
            Fixtures.pricing("SPY", price: 511, time: Fixtures.btcTime, marketHours: 3),
            regular,
        ]))
        let quote = try await connection.next()
        #expect(quote.symbol == "SPY")
        #expect(quote.price == 512.25)
        #expect(quote.session == .regular)
    }

    @Test func messagesThatArentPricesAreSkipped() async throws {
        let (_, connection) = connect(FakeSocketConnection(messages: [
            #"{"type":"heartbeat"}"#,
            Fixtures.pricing("SPY", price: 0, time: Fixtures.btcTime),
            Fixtures.pricing("", price: 500, time: Fixtures.btcTime),
            Fixtures.pricing("SPY", price: 500, time: Date(timeIntervalSince1970: 0)),
            Fixtures.btc,
        ]))
        #expect(try await connection.next().symbol == "BTC-USD")
    }

    // Not JSON, not base64, and a protobuf cut off inside its symbol.
    @Test(arguments: ["not json", #"{"type":"pricing","message":"%%%"}"#, #"{"type":"pricing","message":"CgNTUA=="}"#])
    func aMessageThatIsntTheFeedsShapeFailsTheConnection(_ message: String) async {
        let (_, connection) = connect(FakeSocketConnection(messages: [message]))
        do {
            _ = try await connection.next()
            Issue.record("expected a failure")
        } catch {
            guard case .malformedResponse = error else {
                Issue.record("got \(error)")
                return
            }
        }
    }

    @Test func aDroppedConnectionIsUnavailable() async {
        let (_, connection) = connect(FakeSocketConnection(messages: []))
        do {
            _ = try await connection.next()
            Issue.record("expected a failure")
        } catch {
            #expect(error == .unavailable)
        }
    }

    @Test func aRefusedHandshakeSaysWhy() async {
        for (status, expected) in [(403, ProviderError.blocked), (429, .rateLimited(retryAfter: nil)), (503, .unavailable)] {
            let (_, connection) = connect(FakeSocketConnection(messages: [], status: status, sendFails: true))
            do {
                try await connection.subscribe(["SPY"])
                Issue.record("expected a failure")
            } catch {
                #expect(error == expected)
            }
        }
    }

    @Test func closingTheConnectionClosesTheSocket() {
        let socket = FakeSocketConnection(messages: [])
        let (_, connection) = connect(socket)
        connection.close()
        #expect(socket.closed)
    }
}
