import Foundation
import Testing
import VettiraCore

// Expected values come from the issue and AGENTS.md's light-client rule: one connection for the
// watchlist, subscriptions changed on that connection as the watchlist changes, closed when there's
// nothing to stream, a reconnect with backoff after a failure (5 s, doubling, up to 5 minutes,
// honouring a provider's wait), and prices handed on at most once a second. New York is UTC-5 in
// November 2026.

private func at(_ time: String) -> Date {
    ISO8601DateFormatter().date(from: "2026-11-10T\(time)-05:00")!
}

private func quote(_ symbol: String, _ price: Double, at time: String) -> Quote {
    Quote(symbol: symbol, price: price, timestamp: at(time), source: "Test stream", session: .regular)
}

/// A stream whose connections the test drives: each one records what it's subscribed to, and
/// hands `next()` the quotes and failures the test sends it.
final class FakeQuoteStream: QuoteStream, @unchecked Sendable {
    let name = "Test stream"
    private let lock = NSLock()
    private var _connections: [FakeStreamConnection] = []
    private var refusals: [ProviderError]
    private var watchers: [CheckedContinuation<FakeStreamConnection, Never>] = []
    private var seen = 0

    /// The first connections' subscribes fail with `refusals`, one each.
    init(refusals: [ProviderError] = []) {
        self.refusals = refusals
    }

    var connections: [FakeStreamConnection] { lock.withLock { _connections } }

    func connect() -> any QuoteStreamConnection {
        let (connection, watcher) = lock.withLock {
            let connection = FakeStreamConnection(refusal: refusals.isEmpty ? nil : refusals.removeFirst())
            _connections.append(connection)
            return (connection, watchers.isEmpty ? nil : watchers.removeFirst())
        }
        if let watcher {
            lock.withLock { seen += 1 }
            watcher.resume(returning: connection)
        }
        return connection
    }

    /// Waits for the next connection the streamer opens.
    func nextConnection() async -> FakeStreamConnection {
        await withCheckedContinuation { continuation in
            let ready: FakeStreamConnection? = lock.withLock {
                guard seen < _connections.count else {
                    watchers.append(continuation)
                    return nil
                }
                seen += 1
                return _connections[seen - 1]
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }
}

final class FakeStreamConnection: QuoteStreamConnection, @unchecked Sendable {
    enum Event {
        case quote(Quote)
        case failure(ProviderError)
    }

    private let lock = NSLock()
    private let refusal: ProviderError?
    private var _messages: [String] = []
    private var _closed = false
    private var events: [Event] = []
    private var receiver: CheckedContinuation<Event, Never>?
    /// Callers of `drained()`, resumed when `next()` waits with nothing left to hand it.
    private var drainWatchers: [CheckedContinuation<Void, Never>] = []

    init(refusal: ProviderError?) {
        self.refusal = refusal
    }

    /// What was sent, in order: `+SPY` subscribes, `-SPY` unsubscribes.
    var messages: [String] { lock.withLock { _messages } }
    var closed: Bool { lock.withLock { _closed } }

    func subscribe(_ symbols: [String]) async throws(ProviderError) {
        if let refusal { throw refusal }
        lock.withLock { _messages += symbols.map { "+\($0)" } }
    }

    func unsubscribe(_ symbols: [String]) async throws(ProviderError) {
        lock.withLock { _messages += symbols.map { "-\($0)" } }
    }

    func send(_ event: Event) {
        let waiting: CheckedContinuation<Event, Never>? = lock.withLock {
            guard let receiver else {
                events.append(event)
                return nil
            }
            self.receiver = nil
            return receiver
        }
        waiting?.resume(returning: event)
    }

    func next() async throws(ProviderError) -> Quote {
        let event = await withCheckedContinuation { (continuation: CheckedContinuation<Event, Never>) in
            let (ready, watchers): (Event?, [CheckedContinuation<Void, Never>]) = lock.withLock {
                if _closed { return (.failure(.unavailable), []) }
                if !events.isEmpty { return (events.removeFirst(), []) }
                receiver = continuation
                defer { drainWatchers = [] }
                return (nil, drainWatchers)
            }
            if let ready { continuation.resume(returning: ready) }
            watchers.forEach { $0.resume() }
        }
        switch event {
        case .quote(let quote): return quote
        case .failure(let error): throw error
        }
    }

    /// Waits until the streamer has taken every event sent and waits for the next.
    func drained() async {
        await withCheckedContinuation { continuation in
            let idle = lock.withLock {
                guard receiver != nil, events.isEmpty else {
                    drainWatchers.append(continuation)
                    return false
                }
                return true
            }
            if idle { continuation.resume() }
        }
    }

    func close() {
        let waiting: CheckedContinuation<Event, Never>? = lock.withLock {
            _closed = true
            defer { receiver = nil }
            return receiver
        }
        waiting?.resume(returning: .failure(.unavailable))
    }
}

/// A streamer on a suspending test clock, run in a task the test ends.
private struct StreamHarness {
    let clock = MonitorTestClock(at: at("10:00:00"), suspending: true)
    let stream: FakeQuoteStream
    let streamer: QuoteStreamer
    let task: Task<Void, Never>
    var updates: AsyncStream<QuoteStreamer.Update>.Iterator

    init(refusals: [ProviderError] = []) {
        stream = FakeQuoteStream(refusals: refusals)
        let streamer = QuoteStreamer(stream: stream, clock: clock.monitorClock)
        self.streamer = streamer
        updates = streamer.updates.makeAsyncIterator()
        task = Task { await streamer.run() }
    }

    mutating func next() async -> QuoteStreamer.Update? {
        await updates.next()
    }

    /// Watches `symbols`, then waits for the connection to open and go live.
    mutating func connect(_ symbols: [String]) async -> FakeStreamConnection {
        await streamer.watch(symbols)
        let connection = await stream.nextConnection()
        while let update = await next(), update != .status(.live(since: clock.now)) {}
        return connection
    }
}

// A broken test fails within a minute instead of hanging the run.
@Suite(.timeLimit(.minutes(1))) struct QuoteStreamerTests {
    @Test func withNothingToStreamItsOffAndConnectsToNothing() async {
        var harness = StreamHarness()
        #expect(await harness.next() == .status(.off))
        #expect(harness.stream.connections.isEmpty)
        harness.task.cancel()
        await harness.task.value
    }

    @Test func itOpensOneConnectionSubscribedToTheWatchlist() async {
        var harness = StreamHarness()
        #expect(await harness.next() == .status(.off))
        await harness.streamer.watch(["SPY", "aapl", "SPY"])
        #expect(await harness.next() == .status(.connecting))
        #expect(await harness.next() == .status(.live(since: at("10:00:00"))))
        #expect(harness.stream.connections.count == 1)
        #expect(harness.stream.connections[0].messages == ["+SPY", "+AAPL"])
        harness.task.cancel()
        await harness.task.value
        #expect(harness.stream.connections[0].closed)
    }

    @Test func aWatchlistChangeChangesTheSubscriptionsOnTheSameConnection() async {
        var harness = StreamHarness()
        let connection = await harness.connect(["SPY", "AAPL"])
        await harness.streamer.watch(["AAPL", "QQQ"])
        #expect(connection.messages == ["+SPY", "+AAPL", "-SPY", "+QQQ"])
        #expect(harness.stream.connections.count == 1)
        harness.task.cancel()
        await harness.task.value
    }

    @Test func nothingLeftToStreamClosesTheConnectionUntilThereIs() async {
        var harness = StreamHarness()
        let first = await harness.connect(["SPY"])
        await harness.streamer.watch([])
        #expect(await harness.next() == .status(.off))
        #expect(first.closed)
        // No backoff: closing it wasn't a failure.
        #expect(harness.clock.sleeps.isEmpty)
        let second = await harness.connect(["QQQ"])
        #expect(second.messages == ["+QQQ"])
        harness.task.cancel()
        await harness.task.value
    }

    @Test func pricesGoToTheMonitorAtMostOnceASecondTheLatestForEachSymbol() async {
        var harness = StreamHarness()
        let connection = await harness.connect(["SPY", "AAPL"])
        connection.send(.quote(quote("SPY", 500.10, at: "09:59:59")))
        // The first goes straight away.
        #expect(await harness.next() == .quotes([quote("SPY", 500.10, at: "09:59:59")]))
        connection.send(.quote(quote("SPY", 500.20, at: "10:00:00")))
        connection.send(.quote(quote("AAPL", 250.00, at: "10:00:00")))
        connection.send(.quote(quote("SPY", 500.30, at: "10:00:00")))
        // An older price that arrives late doesn't replace a newer one.
        connection.send(.quote(quote("SPY", 499.00, at: "09:59:58")))
        await connection.drained()
        #expect(await harness.clock.nextSleep() == 1)
        harness.clock.advance(by: 1)
        #expect(await harness.next() == .quotes([
            quote("AAPL", 250.00, at: "10:00:00"), quote("SPY", 500.30, at: "10:00:00"),
        ]))
        harness.task.cancel()
        await harness.task.value
    }

    @Test func pricesForSymbolsNoLongerWatchedAreDropped() async {
        var harness = StreamHarness()
        let connection = await harness.connect(["SPY", "AAPL"])
        connection.send(.quote(quote("SPY", 500, at: "09:59:59")))
        #expect(await harness.next() == .quotes([quote("SPY", 500, at: "09:59:59")]))
        connection.send(.quote(quote("AAPL", 250, at: "10:00:00")))
        await connection.drained()
        await harness.streamer.watch(["SPY"])
        connection.send(.quote(quote("AAPL", 251, at: "10:00:00")))
        connection.send(.quote(quote("SPY", 501, at: "10:00:00")))
        await connection.drained()
        _ = await harness.clock.nextSleep()
        harness.clock.advance(by: 1)
        #expect(await harness.next() == .quotes([quote("SPY", 501, at: "10:00:00")]))
        harness.task.cancel()
        await harness.task.value
    }

    @Test func aDroppedConnectionReconnectsAfterABackoffThatDoubles() async {
        let harness = StreamHarness(refusals: [.unavailable, .unavailable, .blocked])
        await harness.streamer.watch(["SPY"])
        var waits: [TimeInterval] = []
        for _ in 0..<3 {
            _ = await harness.stream.nextConnection()
            let wait = await harness.clock.nextSleep()
            waits.append(wait)
            harness.clock.advance(by: wait)
        }
        #expect(waits == [5, 10, 20])
        let connection = await harness.stream.nextConnection()
        #expect(connection.messages == ["+SPY"])
        harness.task.cancel()
        await harness.task.value
    }

    @Test func itSaysWhyItsReconnectingAndWhen() async {
        var harness = StreamHarness(refusals: [.blocked])
        #expect(await harness.next() == .status(.off))
        await harness.streamer.watch(["SPY"])
        #expect(await harness.next() == .status(.connecting))
        #expect(await harness.next() == .status(.reconnecting(.blocked, retryAt: at("10:00:05"))))
        harness.task.cancel()
        await harness.task.value
    }

    @Test func aPriceResetsTheBackoff() async {
        let harness = StreamHarness(refusals: [.unavailable])
        await harness.streamer.watch(["SPY"])
        _ = await harness.stream.nextConnection()
        harness.clock.advance(by: await harness.clock.nextSleep())
        let connection = await harness.stream.nextConnection()
        connection.send(.quote(quote("SPY", 500, at: "10:00:05")))
        await connection.drained()
        connection.send(.failure(.unavailable))
        // 5 s again, not 10: the connection worked before it dropped.
        #expect(await harness.clock.nextSleep() == 5)
        harness.task.cancel()
        await harness.task.value
    }

    @Test func aRateLimitWaitsAtLeastAsLongAsTheProviderAsks() async {
        let harness = StreamHarness(refusals: [.rateLimited(retryAfter: 120)])
        await harness.streamer.watch(["SPY"])
        #expect(await harness.clock.nextSleep() == 120)
        harness.task.cancel()
        await harness.task.value
    }

    @Test func theBackoffStopsGrowingAtFiveMinutes() async {
        let harness = StreamHarness(refusals: Array(repeating: .unavailable, count: 8))
        await harness.streamer.watch(["SPY"])
        var waits: [TimeInterval] = []
        for _ in 0..<8 {
            let wait = await harness.clock.nextSleep()
            waits.append(wait)
            harness.clock.advance(by: wait)
        }
        #expect(waits == [5, 10, 20, 40, 80, 160, 300, 300])
        harness.task.cancel()
        await harness.task.value
    }
}
