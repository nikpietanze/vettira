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
/// With a `QuoteStreamer` (docs/architecture.md, "Streaming"), prices also stream in between polls
/// in regular hours: `streamSymbols` says what to stream, and `receive(_:)` takes each streamed
/// batch, at most once a second, through the same alert engine. While the stream is live, polls
/// only refresh the day's bars, previous close and session high, so they slow to the streaming
/// interval; when it drops, polling takes over at the update interval straight away.
///
/// The app reads it through two streams, each for one consumer, its shared state on the main
/// actor: `snapshots`, the latest state after each poll, streamed batch or settings change, and
/// `alerts`, every alert as it fires. The engine's state is `engineState`; the monitor hands it to
/// `saveState` each time it changes, for the app to save and hand back.
public actor QuoteMonitor {
    /// The state after each poll and each settings change, starting with the state before the
    /// first poll. Only the latest is kept: a consumer that falls behind skips to it.
    public nonisolated let snapshots: AsyncStream<MonitorSnapshot>
    /// Every alert, once, as it fires. None is dropped while the stream waits to be read.
    public nonisolated let alerts: AsyncStream<ReversalAlert>
    /// The symbols to stream, each time they change: the enabled symbols in regular hours, and none
    /// outside them. Only the latest is kept.
    public nonisolated let streamSymbols: AsyncStream<[String]>
    private let snapshotSink: AsyncStream<MonitorSnapshot>.Continuation
    private let alertSink: AsyncStream<ReversalAlert>.Continuation
    private let streamSymbolsSink: AsyncStream<[String]>.Continuation
    /// What `streamSymbols` last said.
    private var streaming: [String] = []

    private let provider: any MarketDataProvider
    private let calendar: MarketCalendar
    private let clock: MonitorClock
    private var settings: UserSettings
    private var engine: ReversalAlertEngine
    private let saveState: @Sendable (ReversalAlertEngine.State) -> Void
    /// The engine's state as `saveState` last had it.
    private var savedState: ReversalAlertEngine.State
    /// The trading day of each symbol's high, so a high is shown only during its own session.
    private var highDays: [TickerSymbol: TradingDay] = [:]
    private var running = false
    /// When the last poll started, and the wait after it, which a stream that drops cuts short.
    private var pollStarted: Date?
    private var pollWait: Task<Void, any Error>?
    /// When the next poll is due, once a dropped stream brought it forward.
    private var pollDue: Date?

    /// The latest state, the same as the last one `snapshots` published.
    public private(set) var snapshot: MonitorSnapshot

    /// A monitor for `settings`' watchlist, at its update interval and with its alert settings,
    /// that hasn't polled yet. `engineState` is the alert engine's saved state, so alerts it
    /// already sent aren't sent again; what it holds for a symbol no longer on the watchlist is
    /// dropped. `saveState` gets the engine's state after each poll or settings change that
    /// changed it, to save for the next launch.
    public init(
        provider: any MarketDataProvider,
        settings: UserSettings,
        engineState: ReversalAlertEngine.State = .init(),
        calendar: MarketCalendar = .usEquities,
        clock: MonitorClock = .system,
        saveState: @escaping @Sendable (ReversalAlertEngine.State) -> Void = { _ in }
    ) {
        (snapshots, snapshotSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        (alerts, alertSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
        (streamSymbols, streamSymbolsSink) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1))
        self.provider = provider
        self.calendar = calendar
        self.clock = clock
        self.settings = settings
        var engine = ReversalAlertEngine(settings: settings.alertSettings, state: engineState, calendar: calendar)
        engine.removeSymbols(notIn: Self.watched(settings))
        self.engine = engine
        self.saveState = saveState
        savedState = engineState
        let waiting = settings.watchlist.entries.filter(\.isEnabled).map { ($0.symbol, SymbolSnapshot(symbol: $0.symbol)) }
        snapshot = MonitorSnapshot(
            symbols: Dictionary(uniqueKeysWithValues: waiting), diagnostics: MonitorDiagnostics(source: provider.name))
        snapshotSink.yield(snapshot)
    }

    deinit {
        snapshotSink.finish()
        alertSink.finish()
        streamSymbolsSink.finish()
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
            guard var delay = await poll() else { return }
            // The wait for the next poll, cut short when a dropped stream brings the poll forward.
            while true {
                let wait = Task { [clock, delay] in try await clock.sleep(delay) }
                pollWait = wait
                let result = await withTaskCancellationHandler { await wait.result } onCancel: { wait.cancel() }
                pollWait = nil
                if case .success = result { break }
                guard let due = pollDue, !Task.isCancelled else { return }
                pollDue = nil
                delay = max(0, due.timeIntervalSince(clock.now()))
            }
        }
    }

    /// Takes an update from the `QuoteStreamer`: each streamed quote newer than the symbol's
    /// latest goes through the alert engine as a poll's would, with the day's bars, previous close
    /// and session high of the symbol's last quote from the same session; and the stream's status,
    /// for the diagnostics and the polls' pace.
    public func receive(_ update: QuoteStreamer.Update) {
        let now = clock.now()
        switch update {
        case .quotes(let quotes):
            applyStreamed(quotes, at: now)
            snapshot.diagnostics.lastReceived = now
        case .status(let status):
            let wasLive = snapshot.diagnostics.stream?.isLive ?? false
            snapshot.diagnostics.stream = status
            if wasLive, !status.isLive { bringPollForward(at: now) }
        }
        refresh(at: now)
        saveIfChanged()
        snapshotSink.yield(snapshot)
    }

    /// New settings: a newly enabled symbol is polled from the next poll, new thresholds and a
    /// new staleness tolerance apply from the next quote (and the tolerance to this snapshot), and
    /// a new update interval from the wait after the next poll. A symbol taken off the watchlist
    /// is dropped from the engine's state, and the state saved; a disabled one keeps its state.
    public func update(settings: UserSettings) {
        self.settings = settings
        engine.settings = settings.alertSettings
        engine.removeSymbols(notIn: Self.watched(settings))
        saveIfChanged()
        refresh(at: clock.now())
        publishStreamSymbols()
        snapshotSink.yield(snapshot)
    }

    // MARK: Polling

    /// Polls once, publishes the snapshot, and returns how long to wait before the next poll;
    /// `nil` when the task was cancelled during the poll.
    private func poll() async -> TimeInterval? {
        let started = clock.now()
        pollStarted = started
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
        saveIfChanged()
        publishStreamSymbols()
        snapshotSink.yield(snapshot)
        return delay
    }

    /// Tells the streamer the symbols to stream, when they changed: the enabled ones in regular
    /// hours, none outside them.
    private func publishStreamSymbols() {
        let symbols = snapshot.diagnostics.marketState == .regular ? enabledSymbols.map(\.rawValue) : []
        guard symbols != streaming else { return }
        streaming = symbols
        streamSymbolsSink.yield(symbols)
    }

    /// The stream dropped: the next poll is due an update interval after the last one started,
    /// rather than the streaming interval, in regular hours and when it isn't backing off.
    private func bringPollForward(at now: Date) {
        guard let started = pollStarted, let wait = pollWait, let next = snapshot.diagnostics.nextPoll,
              snapshot.diagnostics.lastError == nil, calendar.status(at: now)?.state == .regular
        else { return }
        let due = max(now, started.addingTimeInterval(settings.monitorSettings.interval))
        guard due < next else { return }
        pollDue = due
        snapshot.diagnostics.nextPoll = due
        snapshot.diagnostics.pollDelay = due.timeIntervalSince(started)
        wait.cancel()
    }

    /// Hands the engine's state to `saveState` if it changed since it last did.
    private func saveIfChanged() {
        guard engine.state != savedState else { return }
        savedState = engine.state
        saveState(engine.state)
    }

    /// The wait before the next poll. In regular hours, the rest of the update interval (the
    /// streaming interval while the stream is live) since this poll started, but no less than the
    /// poll took; outside them, the slow check, but in the pre-market no later than the open.
    /// After a failure, at least the backoff (the interval doubled for each failure in a row, up to
    /// the longest backoff) and at least what a rate limit asked for.
    private func delay(afterPollStartedAt started: Date, now: Date, failure: ProviderError?) -> TimeInterval {
        let interval = settings.monitorSettings.interval
        let status = calendar.status(at: now)
        var delay = settings.monitorSettings.closedInterval
        if let status, status.state == .regular {
            // At least as long as the poll took, so a long watchlist leaves the provider idle
            // at least half the time instead of polling back to back.
            let elapsed = max(0, now.timeIntervalSince(started))
            let pace = snapshot.diagnostics.stream?.isLive == true ? settings.monitorSettings.streamingInterval : interval
            delay = max(pace - elapsed, elapsed)
        } else if let status, status.state == .preMarket {
            delay = min(delay, max(0, status.session.open.timeIntervalSince(now)))
        }
        guard let failure else { return delay }
        let failures = snapshot.diagnostics.consecutiveFailures
        let backoff = min(interval * pow(2, Double(min(failures, 30))), settings.monitorSettings.longestBackoff)
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
                state.problem = nil
                if let latest = state.quote, latest.timestamp > quote.timestamp {
                    // A streamed price is newer: keep it, with the poll's bars, close and high.
                    state.quote = merge(latest, into: quote)
                } else {
                    evaluate(quote, into: &state, at: now)
                }
            } else if unknown.contains(symbol.rawValue) {
                state.problem = .unknownSymbol
            } else if unusable.contains(symbol.rawValue) {
                state.problem = .noUsableQuote
            }
            snapshot.symbols[symbol] = state
        }
    }

    /// Runs each streamed quote for an enabled symbol through the alert engine at `now`, when it's
    /// newer than the symbol's latest quote.
    private func applyStreamed(_ quotes: [Quote], at now: Date) {
        let quotes = Dictionary(quotes.map { ($0.symbol.uppercased(), $0) }) { first, _ in first }
        for symbol in enabledSymbols {
            guard let quote = quotes[symbol.rawValue] else { continue }
            var state = snapshot.symbols[symbol] ?? SymbolSnapshot(symbol: symbol)
            if let latest = state.quote, latest.timestamp >= quote.timestamp { continue }
            evaluate(state.quote.map { merge(quote, into: $0) } ?? quote, into: &state, at: now)
            snapshot.symbols[symbol] = state
        }
    }

    /// `price`'s price, time, source and session, with `base`'s day's bars, previous close and
    /// session high when both are from the same session, and none of them when they aren't: a
    /// streamed price brings no day of its own.
    private func merge(_ price: Quote, into base: Quote) -> Quote {
        var merged = price
        let day = calendar.status(at: price.timestamp)?.session.day
        let sameSession = day != nil && day == calendar.status(at: base.timestamp)?.session.day
        merged.symbol = base.symbol
        merged.name = merged.name ?? base.name
        merged.sessionHigh = sameSession ? base.sessionHigh : nil
        merged.previousClose = sameSession ? base.previousClose : nil
        merged.intraday = sameSession ? base.intraday : []
        merged.dayVolume = sameSession ? base.dayVolume : nil
        merged.sessionLow = sameSession ? base.sessionLow : nil
        return merged
    }

    /// Records `quote` as the symbol's latest, and runs it through the alert engine at `now`.
    private func evaluate(_ quote: Quote, into state: inout SymbolSnapshot, at now: Date) {
        let symbol = state.symbol
        state.quote = quote
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

    /// Every symbol on the settings' watchlist, enabled or not.
    private static func watched(_ settings: UserSettings) -> Set<String> {
        Set(settings.watchlist.entries.map(\.symbol.rawValue))
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
