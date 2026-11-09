import Foundation

/// Polls the watchlist's enabled symbols through a `MarketDataProvider`, feeds each quote to the
/// alert engine, and publishes what it knows.
///
/// It's a light client (docs/architecture.md, "Polling"): one poll at a time, each one request per
/// enabled symbol through the provider (which sends them one at a time, at least a second apart);
/// polls start no closer together than the update interval, and the wait after one is at least as
/// long as it took, so a long watchlist still leaves the provider idle half the time; outside regular hours only a slow
/// check; and after an error it backs off, doubling each time, honouring a wait the provider asks
/// for, until a poll succeeds again.
///
/// The app reads it through two streams, each for one consumer, its shared state on the main
/// actor: `snapshots`, the latest state after each poll or settings change, and `alerts`, every
/// alert as it fires. The engine's state is `engineState`, for the app to save and hand back.
public actor QuoteMonitor {
    /// The state after each poll and each settings change, starting with the state before the
    /// first poll. Only the latest is kept: a consumer that falls behind skips to it.
    public nonisolated let snapshots: AsyncStream<MonitorSnapshot>
    /// Every alert, once, as it fires. None is dropped while the stream waits to be read.
    public nonisolated let alerts: AsyncStream<ReversalAlert>
    private let snapshotSink: AsyncStream<MonitorSnapshot>.Continuation
    private let alertSink: AsyncStream<ReversalAlert>.Continuation

    private let provider: any MarketDataProvider
    private let calendar: MarketCalendar
    private let clock: MonitorClock
    private var settings: UserSettings
    private var monitorSettings: MonitorSettings
    private var engine: ReversalAlertEngine
    /// The trading day of each symbol's high, so a high is shown only during its own session.
    private var highDays: [TickerSymbol: TradingDay] = [:]
    private var running = false

    /// The latest state, the same as the last one `snapshots` published.
    public private(set) var snapshot: MonitorSnapshot

    /// A monitor for `settings`' watchlist that hasn't polled yet. `engineState` is the alert
    /// engine's saved state, so alerts it already sent aren't sent again.
    public init(
        provider: any MarketDataProvider,
        settings: UserSettings,
        monitorSettings: MonitorSettings = .standard,
        alertSettings: AlertSettings = .standard,
        engineState: ReversalAlertEngine.State = .init(),
        calendar: MarketCalendar = .usEquities,
        clock: MonitorClock = .system
    ) {
        (snapshots, snapshotSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (alerts, alertSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        self.provider = provider
        self.calendar = calendar
        self.clock = clock
        self.settings = settings
        self.monitorSettings = monitorSettings
        engine = ReversalAlertEngine(settings: alertSettings, state: engineState, calendar: calendar)
        let waiting = settings.watchlist.entries.filter(\.isEnabled).map { ($0.symbol, SymbolSnapshot(symbol: $0.symbol)) }
        snapshot = MonitorSnapshot(
            symbols: Dictionary(uniqueKeysWithValues: waiting), diagnostics: MonitorDiagnostics(source: provider.name))
        snapshotSink.yield(snapshot)
    }

    deinit {
        snapshotSink.finish()
        alertSink.finish()
    }

    /// The alert engine's state: each symbol's high and which thresholds it has sent. Save it, and
    /// pass it to the next monitor's `init`, to keep alerts from repeating after a relaunch.
    public var engineState: ReversalAlertEngine.State { engine.state }

    /// Polls until the task running it is cancelled. Calling it while it's already running does
    /// nothing, so there's never more than one poll at a time.
    public func run() async {
        guard !running else { return }
        running = true
        defer { running = false }
        while !Task.isCancelled {
            guard let delay = await poll() else { return }
            do {
                try await clock.sleep(delay)
            } catch {
                return
            }
        }
    }

    /// A new watchlist or thresholds. A newly enabled symbol is polled from the next poll.
    public func update(settings: UserSettings) {
        self.settings = settings
        refresh(at: clock.now())
        snapshotSink.yield(snapshot)
    }

    /// A new update interval, from the wait after the next poll.
    public func update(monitorSettings: MonitorSettings) {
        self.monitorSettings = monitorSettings
    }

    /// New rearm, cooldown, staleness and spike settings, from the next quote.
    public func update(alertSettings: AlertSettings) {
        engine.settings = alertSettings
        refresh(at: clock.now())
        snapshotSink.yield(snapshot)
    }

    // MARK: Polling

    /// Polls once, publishes the snapshot, and returns how long to wait before the next poll;
    /// `nil` when the task was cancelled during the poll.
    private func poll() async -> TimeInterval? {
        let started = clock.now()
        let symbols = enabledSymbols
        var failure: ProviderError?
        if !symbols.isEmpty {
            do throws(ProviderError) {
                let batch = try await provider.quotes(for: symbols.map(\.rawValue))
                if Task.isCancelled { return nil }
                let received = clock.now()
                apply(batch, at: received)
                snapshot.diagnostics.lastReceived = received
            } catch {
                // A cancelled poll fails without being a provider failure.
                if Task.isCancelled { return nil }
                failure = error
            }
        }

        let now = clock.now()
        if failure == nil {
            snapshot.diagnostics.consecutiveFailures = 0
        } else {
            snapshot.diagnostics.consecutiveFailures += 1
        }
        let delay = delay(afterPollStartedAt: started, now: now, failure: failure)
        snapshot.diagnostics.marketState = calendar.status(at: now)?.state
        snapshot.diagnostics.lastError = failure
        snapshot.diagnostics.lastPoll = now
        snapshot.diagnostics.pollDelay = delay
        snapshot.diagnostics.nextPoll = now.addingTimeInterval(delay)
        refresh(at: now)
        snapshotSink.yield(snapshot)
        return delay
    }

    /// The wait before the next poll. In regular hours, the rest of the update interval since this
    /// poll started, but no less than the poll took; outside them, the slow check, but in the pre-market no later than the open.
    /// After a failure, at least the backoff (the interval doubled for each failure in a row, up to
    /// the longest backoff) and at least what a rate limit asked for.
    private func delay(afterPollStartedAt started: Date, now: Date, failure: ProviderError?) -> TimeInterval {
        let interval = monitorSettings.interval
        let status = calendar.status(at: now)
        var delay = monitorSettings.closedInterval
        if let status, status.state == .regular {
            // At least as long as the poll took, so a long watchlist leaves the provider idle
            // at least half the time instead of polling back to back.
            let elapsed = max(0, now.timeIntervalSince(started))
            delay = max(interval - elapsed, elapsed)
        } else if let status, status.state == .preMarket {
            delay = min(delay, max(0, status.session.open.timeIntervalSince(now)))
        }
        guard let failure else { return delay }
        let failures = snapshot.diagnostics.consecutiveFailures
        let backoff = min(interval * pow(2, Double(min(failures, 30))), monitorSettings.longestBackoff)
        delay = max(delay, backoff)
        if case .rateLimited(let retryAfter?) = failure {
            delay = max(delay, retryAfter)
        }
        return delay
    }

    /// Records the batch's quotes and problems for the symbols still enabled, and runs each quote
    /// through the alert engine at `now`.
    private func apply(_ batch: QuoteBatch, at now: Date) {
        let quotes = Dictionary(batch.quotes.map { ($0.symbol.uppercased(), $0) }) { first, _ in first }
        let unknown = Set(batch.unknownSymbols.map { $0.uppercased() })
        let unusable = Set(batch.unusableSymbols.map { $0.uppercased() })
        for entry in settings.watchlist.entries where entry.isEnabled {
            let symbol = entry.symbol
            var state = snapshot.symbols[symbol] ?? SymbolSnapshot(symbol: symbol)
            if let quote = quotes[symbol.rawValue] {
                state.quote = quote
                state.problem = nil
                let thresholds = settings.thresholds(for: symbol) ?? settings.defaultThresholds
                switch engine.evaluate(quote, thresholds: thresholds, now: now) {
                case .rejected(let reason):
                    state.lastRejection = reason
                case .accepted(let high, let pullback, let alert):
                    state.lastRejection = nil
                    state.high = high
                    state.pullbackPercent = pullback
                    highDays[symbol] = calendar.status(at: quote.timestamp)?.session.day
                    if let alert {
                        state.lastAlert = alert
                        alertSink.yield(alert)
                    }
                }
            } else if unknown.contains(symbol.rawValue) {
                state.problem = .unknownSymbol
            } else if unusable.contains(symbol.rawValue) {
                state.problem = .noUsableQuote
            }
            snapshot.symbols[symbol] = state
        }
    }

    /// Brings the snapshot's symbols in line with the watchlist, and each one's data age,
    /// staleness and high up to `now`.
    private func refresh(at now: Date) {
        let tolerance = engine.settings.staleTolerance
        let today = calendar.status(at: now)?.session.day
        var symbols: [TickerSymbol: SymbolSnapshot] = [:]
        for symbol in enabledSymbols {
            var state = snapshot.symbols[symbol] ?? SymbolSnapshot(symbol: symbol)
            if let quote = state.quote {
                let age = quote.age(at: now)
                state.dataAge = age
                state.isStale = age > tolerance || (quote.providerDelay ?? 0) > tolerance
            } else {
                state.dataAge = nil
                state.isStale = true
            }
            if today == nil || highDays[symbol] != today {
                state.high = nil
                state.pullbackPercent = nil
            }
            symbols[symbol] = state
        }
        snapshot.symbols = symbols
        highDays = highDays.filter { symbols[$0.key] != nil }
    }

    private var enabledSymbols: [TickerSymbol] {
        settings.watchlist.entries.filter(\.isEnabled).map(\.symbol)
    }
}

/// The monitor's time: `now` for data age and the market session, `sleep` to wait between polls.
/// Tests pass a clock that doesn't really wait.
public struct MonitorClock: Sendable {
    public var now: @Sendable () -> Date
    /// Waits, or throws when the task is cancelled.
    public var sleep: @Sendable (TimeInterval) async throws -> Void

    public init(
        now: @escaping @Sendable () -> Date,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// The Mac's clock.
    public static let system = MonitorClock(now: { Date() }, sleep: { try await Task.sleep(for: .seconds($0)) })
}
