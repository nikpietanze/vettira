import Foundation
import Testing
import VettiraCore

/// A clock that moves only when the monitor sleeps, or a fake provider spends time answering. Each
/// sleep is kept, and the sleep that reaches `stopAfter` sleeps throws, as a cancelled task's
/// would, so `run()` returns there. No test waits on the wall clock.
///
/// A `suspending` clock instead holds each sleep until `advance(by:)` moves the clock past its end,
/// for tests where something else happens while the monitor or the streamer waits: `nextSleep()`
/// waits for the next sleep to start.
final class MonitorTestClock: @unchecked Sendable {
    private struct Sleeper {
        let id: Int
        let due: Date
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var _now: Date
    private var _sleeps: [TimeInterval] = []
    private var stopAfter = 0
    private let suspending: Bool
    private var sleepers: [Sleeper] = []
    private var cancelled: Set<Int> = []
    private var nextID = 0
    /// Sleeps started that `nextSleep()` hasn't returned yet, and the callers waiting for one.
    private var unseen: [TimeInterval] = []
    private var watchers: [CheckedContinuation<TimeInterval, Never>] = []

    init(at now: Date, suspending: Bool = false) {
        _now = now
        self.suspending = suspending
    }

    var now: Date { lock.withLock { _now } }
    var sleeps: [TimeInterval] { lock.withLock { _sleeps } }

    /// Moves the clock on, and wakes each sleep that has ended, earliest first.
    func advance(by seconds: TimeInterval) {
        let woken = lock.withLock {
            _now += seconds
            let woken = sleepers.filter { $0.due <= _now }.sorted { $0.due < $1.due }
            sleepers.removeAll { $0.due <= _now }
            return woken
        }
        woken.forEach { $0.continuation.resume() }
    }

    func set(_ now: Date) {
        lock.withLock { _now = now }
    }

    /// Lets the monitor poll `polls` more times: its run ends in the wait after the last.
    func allow(polls: Int) {
        lock.withLock { stopAfter = _sleeps.count + polls }
    }

    /// Waits for the next sleep to start on a suspending clock, and returns how long it is.
    func nextSleep() async -> TimeInterval {
        await withCheckedContinuation { continuation in
            lock.withLock {
                if unseen.isEmpty { watchers.append(continuation) } else { continuation.resume(returning: unseen.removeFirst()) }
            }
        }
    }

    var monitorClock: MonitorClock {
        MonitorClock(
            now: { [self] in now },
            sleep: { [self] seconds in
                if suspending { return try await suspend(seconds) }
                let stop = lock.withLock {
                    _sleeps.append(seconds)
                    _now += seconds
                    return _sleeps.count >= stopAfter
                }
                if stop { throw CancellationError() }
            })
    }

    private func suspend(_ seconds: TimeInterval) async throws {
        let id = lock.withLock {
            nextID += 1
            return nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let watcher: CheckedContinuation<TimeInterval, Never>? = lock.withLock {
                    _sleeps.append(seconds)
                    if cancelled.contains(id) {
                        continuation.resume(throwing: CancellationError())
                        return nil
                    }
                    sleepers.append(Sleeper(id: id, due: _now + seconds, continuation: continuation))
                    if watchers.isEmpty {
                        unseen.append(seconds)
                        return nil
                    }
                    return watchers.removeFirst()
                }
                watcher?.resume(returning: seconds)
            }
        } onCancel: {
            let sleeper = lock.withLock {
                cancelled.insert(id)
                let sleeper = sleepers.first { $0.id == id }
                sleepers.removeAll { $0.id == id }
                return sleeper
            }
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }
}

/// A provider that answers each poll with the next scripted reply, spending a second per symbol
/// on the clock as Yahoo's pacing does, and keeps every request. Once the script runs out, every
/// symbol gets a fresh regular-session quote at 100.
actor MockProvider: MarketDataProvider {
    typealias Reply = @Sendable (_ symbols: [String], _ now: Date) -> Result<QuoteBatch, ProviderError>

    nonisolated let name = "Test provider"

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
