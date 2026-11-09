import Foundation
import Testing
import VettiraCore

/// A clock that moves only when the monitor sleeps, or a fake provider spends time answering. Each
/// sleep is kept, and the sleep that reaches `stopAfter` sleeps throws, as a cancelled task's
/// would, so `run()` returns there. No test waits on the wall clock.
final class MonitorTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    private var _sleeps: [TimeInterval] = []
    private var stopAfter = 0

    init(at now: Date) {
        _now = now
    }

    var now: Date { lock.withLock { _now } }
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }

    func advance(by seconds: TimeInterval) {
        lock.withLock { _now += seconds }
    }

    func set(_ now: Date) {
        lock.withLock { _now = now }
    }

    /// Lets the monitor poll `polls` more times: its run ends in the wait after the last.
    func allow(polls: Int) {
        lock.withLock { stopAfter = _sleeps.count + polls }
    }

    var monitorClock: MonitorClock {
        MonitorClock(
            now: { [self] in now },
            sleep: { [self] seconds in
                let stop = lock.withLock {
                    _sleeps.append(seconds)
                    _now += seconds
                    return _sleeps.count >= stopAfter
                }
                if stop { throw CancellationError() }
            })
    }
}

/// A provider that answers each poll with the next scripted reply, spending a second per symbol
/// on the clock as Yahoo's pacing does, and keeps every request. Once the script runs out, every
/// symbol gets a fresh regular-session quote at 100.
actor MockProvider: MarketDataProvider {
    typealias Reply = @Sendable (_ symbols: [String], _ now: Date) -> Result<QuoteBatch, ProviderError>

    nonisolated let name = "Test provider"
    nonisolated let streams = false

    struct Request: Equatable {
        let symbols: [String]
        let at: Date
    }

    private let clock: MonitorTestClock
    private var replies: [Reply]
    private let secondsPerSymbol: TimeInterval
    private(set) var requests: [Request] = []
    private var inFlight = 0
    /// The most polls that were ever in flight at once.
    private(set) var mostInFlight = 0

    init(clock: MonitorTestClock, replies: [Reply] = [], secondsPerSymbol: TimeInterval = 1) {
        self.clock = clock
        self.replies = replies
        self.secondsPerSymbol = secondsPerSymbol
    }

    func script(_ more: [Reply]) {
        replies += more
    }

    func quotes(for symbols: [String]) async throws(ProviderError) -> QuoteBatch {
        requests.append(Request(symbols: symbols, at: clock.now))
        inFlight += 1
        mostInFlight = max(mostInFlight, inFlight)
        defer { inFlight -= 1 }
        // Gives a concurrent caller the chance to poll while this one is in flight.
        for _ in 0..<5 { await Task.yield() }
        clock.advance(by: secondsPerSymbol * Double(symbols.count))
        let reply = replies.isEmpty ? Self.prices([:]) : replies.removeFirst()
        return try reply(symbols, clock.now).get()
    }

    /// A quote for every symbol asked for, `age` seconds old: at `prices[symbol]`, or 100.
    static func prices(
        _ prices: [String: Double], age: TimeInterval = 2, high: Double? = nil, session: Quote.Session = .regular
    ) -> Reply {
        { symbols, now in
            .success(QuoteBatch(quotes: symbols.map {
                Quote(symbol: $0, price: prices[$0] ?? 100, timestamp: now - age, source: "Test provider",
                      sessionHigh: high, session: session)
            }))
        }
    }

    static func failure(_ error: ProviderError) -> Reply {
        { _, _ in .failure(error) }
    }

    static func batch(_ batch: QuoteBatch) -> Reply {
        { _, _ in .success(batch) }
    }
}
