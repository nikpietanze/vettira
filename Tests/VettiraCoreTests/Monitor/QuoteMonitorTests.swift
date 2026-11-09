import Foundation
import Testing
import VettiraCore

// Expected values come from the issue and AGENTS.md's light-client rule: one request per enabled
// symbol per poll, one poll at a time, polls no closer than the update interval (15 s by
// default), backoff on errors and rate limits that honours the provider's Retry-After and
// recovers once a poll succeeds, a slow check outside regular hours, and stale data (older than
// the 60-second tolerance) suspending alerts. The backoff's doubling, its 15-minute cap and the
// 10-minute slow check are the monitor's documented defaults (docs/architecture.md, "Polling").
//
// The fake provider spends a second per symbol, as Yahoo's pacing does, and returns quotes 2 s
// old unless a test says otherwise. New York is UTC-5 in November 2026.

private func at(_ time: String, on day: String = "2026-11-10") -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: "\(day)T\(time)-05:00")!
}

private func symbol(_ raw: String) -> TickerSymbol {
    try! TickerSymbol(raw)
}

private func settings(_ symbols: [String], disabled: Set<String> = []) -> UserSettings {
    var settings = UserSettings()
    for raw in symbols {
        try! settings.watchlist.add(symbol(raw))
        if disabled.contains(raw) { try! settings.watchlist.setEnabled(false, for: symbol(raw)) }
    }
    return settings
}

/// A monitor on a test clock and a fake provider, run a poll at a time.
private struct Harness {
    let clock: MonitorTestClock
    let provider: MockProvider
    let monitor: QuoteMonitor

    init(
        _ symbols: [String] = ["SPY"], disabled: Set<String> = [], at start: Date = at("10:00:00"),
        replies: [MockProvider.Reply] = [], secondsPerSymbol: TimeInterval = 1,
        monitorSettings: MonitorSettings = .standard, engineState: ReversalAlertEngine.State = .init()
    ) {
        clock = MonitorTestClock(at: start)
        provider = MockProvider(clock: clock, replies: replies, secondsPerSymbol: secondsPerSymbol)
        monitor = QuoteMonitor(
            provider: provider, settings: settings(symbols, disabled: disabled), monitorSettings: monitorSettings,
            engineState: engineState, clock: clock.monitorClock)
    }

    /// Runs the monitor for `count` polls, ending in the wait after the last.
    func poll(_ count: Int = 1) async {
        clock.allow(polls: count)
        await monitor.run()
    }

    func state(_ raw: String) async -> SymbolSnapshot? {
        await monitor.snapshot.symbols[symbol(raw)]
    }

    var diagnostics: MonitorDiagnostics {
        get async { await monitor.snapshot.diagnostics }
    }
}

/// Every alert the monitor sent, once it's gone and its stream has finished.
private func allAlerts(_ alerts: AsyncStream<ReversalAlert>) async -> [ReversalAlert] {
    var sent: [ReversalAlert] = []
    for await alert in alerts { sent.append(alert) }
    return sent
}

@Suite struct QuoteMonitorTests {
    // MARK: Requests

    @Test func eachPollAsksForEveryEnabledSymbolOnceInWatchlistOrder() async {
        let harness = Harness(["SPY", "AAPL", "QQQ"], disabled: ["AAPL"])
        await harness.poll(2)
        #expect(await harness.provider.requests.map(\.symbols) == [["SPY", "QQQ"], ["SPY", "QQQ"]])
    }

    @Test func pollsStartTheUpdateIntervalApart() async {
        let harness = Harness(["SPY", "AAPL", "QQQ"])
        await harness.poll(3)
        // Each poll spends 3 s on three symbols, so it waits out the other 12 s.
        #expect(harness.clock.sleeps == [12, 12, 12])
        #expect(await harness.provider.requests.map(\.at) == [at("10:00:00"), at("10:00:15"), at("10:00:30")])
    }

    @Test func aPollLongerThanTheIntervalWaitsAsLongAsItTook() async {
        // 20 symbols at a second each: 20 s a poll, longer than the 15 s interval.
        let symbols = (0..<20).map { "S\($0)" }
        let harness = Harness(symbols)
        await harness.poll(3)
        #expect(harness.clock.sleeps == [20, 20, 20])
        let starts = await harness.provider.requests.map(\.at)
        #expect(starts == [at("10:00:00"), at("10:00:40"), at("10:01:20")])
        #expect(await harness.provider.requests.allSatisfy { $0.symbols == symbols })
        #expect(await harness.provider.mostInFlight == 1)
    }

    @Test func aPollJustOverHalfTheIntervalWaitsAsLongAsItTook() async {
        let harness = Harness(["SPY", "AAPL"], secondsPerSymbol: 4)
        await harness.poll(2)
        // 8 s a poll: the rest of the interval would be 7 s, so it waits the 8 s it took.
        #expect(harness.clock.sleeps == [8, 8])
    }

    @Test func theUpdateIntervalIsTheUsers() async throws {
        let harness = Harness(monitorSettings: try MonitorSettings(interval: 60))
        await harness.poll()
        #expect(harness.clock.sleeps == [59])

        await harness.monitor.update(monitorSettings: try MonitorSettings(interval: 30))
        await harness.poll()
        #expect(harness.clock.sleeps.last == 29)
    }

    @Test func runningTwiceAtOnceStillPollsOneAtATime() async {
        let harness = Harness(["SPY", "AAPL"])
        harness.clock.allow(polls: 3)
        async let first: Void = harness.monitor.run()
        async let second: Void = harness.monitor.run()
        _ = await (first, second)
        #expect(await harness.provider.mostInFlight == 1)
        #expect(await harness.provider.requests.count == 3)
    }

    @Test func anEmptyWatchlistSendsNoRequests() async {
        let harness = Harness([], at: at("10:00:00"))
        await harness.poll(2)
        #expect(await harness.provider.requests.isEmpty)
        #expect(harness.clock.sleeps == [15, 15])
    }

    @Test func aChangedWatchlistIsPolledFromTheNextPoll() async {
        let harness = Harness(["SPY"])
        await harness.poll()
        await harness.monitor.update(settings: settings(["SPY", "QQQ"]))
        #expect(await harness.state("QQQ") == SymbolSnapshot(symbol: symbol("QQQ")))

        await harness.poll()
        await harness.monitor.update(settings: settings(["QQQ"]))
        #expect(await harness.state("SPY") == nil)
        await harness.poll()

        #expect(await harness.provider.requests.map(\.symbols) == [["SPY"], ["SPY", "QQQ"], ["QQQ"]])
    }

    // MARK: Backoff and recovery

    @Test func failuresBackOffDoublingUpToFifteenMinutesThenRecover() async {
        let errors: [ProviderError] = [.unavailable, .blocked, .malformedResponse(detail: "x"), .unavailable,
                                       .unavailable, .unavailable, .unavailable]
        let harness = Harness(replies: errors.map(MockProvider.failure))
        await harness.poll(errors.count)
        #expect(harness.clock.sleeps == [30, 60, 120, 240, 480, 900, 900])
        #expect(await harness.diagnostics.lastError == .unavailable)
        #expect(await harness.diagnostics.consecutiveFailures == 7)

        await harness.poll()
        #expect(harness.clock.sleeps.last == 14)
        #expect(await harness.diagnostics.lastError == nil)
        #expect(await harness.diagnostics.consecutiveFailures == 0)
        #expect(await harness.state("SPY")?.quote?.price == 100)
        #expect(await harness.state("SPY")?.isStale == false)
    }

    @Test func aRateLimitWaitsAtLeastAsLongAsTheProviderAsks() async {
        let harness = Harness(replies: [
            MockProvider.failure(.rateLimited(retryAfter: 120)),  // longer than the 30 s backoff
            MockProvider.failure(.rateLimited(retryAfter: 5)),    // shorter than the 60 s backoff
            MockProvider.failure(.rateLimited(retryAfter: nil)),
            MockProvider.failure(.rateLimited(retryAfter: 3600)), // past the 15-minute cap
        ])
        await harness.poll(4)
        #expect(harness.clock.sleeps == [120, 60, 120, 3600])
        #expect(await harness.diagnostics.lastError == .rateLimited(retryAfter: 3600))
        #expect(await harness.diagnostics.pollDelay == 3600)
    }

    @Test func diagnosticsSayWhenDataCameAndWhenTheNextPollIs() async {
        let harness = Harness(replies: [MockProvider.prices([:]), MockProvider.failure(.unavailable)])
        #expect(await harness.diagnostics.source == "Test provider")
        await harness.poll()
        var diagnostics = await harness.diagnostics
        #expect(diagnostics.lastReceived == at("10:00:01"))
        #expect(diagnostics.lastPoll == at("10:00:01"))
        #expect(diagnostics.pollDelay == 14)
        #expect(diagnostics.nextPoll == at("10:00:15"))
        #expect(diagnostics.marketState == .regular)

        await harness.poll()
        diagnostics = await harness.diagnostics
        #expect(diagnostics.lastReceived == at("10:00:01"))
        #expect(diagnostics.lastPoll == at("10:00:16"))
        #expect(diagnostics.nextPoll == at("10:00:46"))
    }

    // MARK: Market hours

    @Test(arguments: [
        ("17:00:00", "2026-11-10", SessionState.afterHours),  // after the close
        ("21:00:00", "2026-11-10", .closed),                   // overnight
        ("12:00:00", "2026-11-14", .closed),                   // a Saturday
        ("12:00:00", "2026-11-26", .closed),                   // Thanksgiving
    ])
    func outsideRegularHoursOnlyASlowCheck(time: String, day: String, state: SessionState) async {
        let harness = Harness(at: at(time, on: day))
        await harness.poll(2)
        #expect(harness.clock.sleeps == [600, 600])
        #expect(await harness.provider.requests.count == 2)
        #expect(await harness.diagnostics.marketState == state)
    }

    @Test func thePreMarketCheckWaitsNoLaterThanTheOpen() async {
        let harness = Harness(at: at("09:15:00"))
        await harness.poll(3)
        // 09:15:01 -> 09:25:01 (the slow check), 09:25:02 -> 09:30:00 (the open), then every 15 s.
        #expect(harness.clock.sleeps == [600, 298, 14])
        #expect(await harness.provider.requests.map(\.at) == [at("09:15:00"), at("09:25:01"), at("09:30:00")])
    }

    @Test func aLongIntervalIsAlsoTheSlowCheck() async throws {
        let harness = Harness(at: at("21:00:00"), monitorSettings: try MonitorSettings(interval: 1800))
        await harness.poll()
        #expect(harness.clock.sleeps == [1800])
    }

    // MARK: Staleness

    @Test func dataTooOldToAlertOnIsStaleAndFiresNothing() async {
        // 90 s old and 2% below its high: past both thresholds, but too old to use.
        let harness = Harness(replies: [MockProvider.prices(["SPY": 98], age: 90, high: 100)])
        await harness.poll()
        let spy = await harness.state("SPY")
        #expect(spy?.isStale == true)
        #expect(spy?.dataAge == 90)
        #expect(spy?.lastRejection == .stale(age: 90))
        #expect(spy?.lastAlert == nil)
        #expect(spy?.high == nil)
    }

    @Test func quotesGoStaleWhenTheProviderStopsAnswering() async {
        let harness = Harness(replies: [MockProvider.prices([:])] + Array(repeating: MockProvider.failure(.unavailable), count: 2))
        await harness.poll()
        #expect(await harness.state("SPY")?.isStale == false)
        #expect(await harness.state("SPY")?.dataAge == 2)

        await harness.poll()  // 10:00:16, the quote is 17 s old
        #expect(await harness.state("SPY")?.isStale == false)

        await harness.poll()  // 10:00:47, 48 s old; then 60 s of backoff
        harness.clock.set(at("10:01:50"))
        await harness.monitor.update(settings: settings(["SPY"]))  // republishes at 10:01:50
        let spy = await harness.state("SPY")
        #expect(spy?.isStale == true)
        #expect(spy?.dataAge == 111)
        #expect(spy?.quote?.price == 100)
    }

    @Test func aSymbolWithNoQuoteYetIsStale() async {
        let harness = Harness()
        let spy = await harness.state("SPY")
        #expect(spy?.quote == nil)
        #expect(spy?.isStale == true)
        #expect(spy?.dataAge == nil)
    }

    @Test func theStalenessToleranceIsTheAlertSettings() async throws {
        let harness = Harness(replies: [MockProvider.prices([:], age: 90)])
        await harness.poll()
        #expect(await harness.state("SPY")?.isStale == true)
        await harness.monitor.update(alertSettings: try AlertSettings(staleTolerance: 120))
        #expect(await harness.state("SPY")?.isStale == false)
    }

    // MARK: Quotes, highs and alerts

    @Test(.timeLimit(.minutes(1))) func aPullbackPastAThresholdAlertsOnce() async {
        var alerts: AsyncStream<ReversalAlert>
        do {
            let harness = Harness(replies: [
                MockProvider.prices(["SPY": 100]),
                MockProvider.prices(["SPY": 99.7]),  // 0.30% below the observed high: early warning
                MockProvider.prices(["SPY": 99.7]),  // the same pullback: nothing new
            ])
            alerts = harness.monitor.alerts
            await harness.poll(3)
            let spy = await harness.state("SPY")
            #expect(spy?.high == SessionHigh(price: 100, kind: .observed))
            #expect(abs((spy?.pullbackPercent ?? 0) - 0.3) < 1e-9)
            #expect(spy?.lastAlert?.signal == .early)
            #expect(spy?.lastAlert?.high == SessionHigh(price: 100, kind: .observed))
            #expect(spy?.lastAlert?.quoteTimestamp == at("10:00:14"))
            #expect(spy?.lastRejection == nil)
        }
        let sent = await allAlerts(alerts)
        #expect(sent.map(\.symbol) == ["SPY"])
        #expect(sent.map(\.signal) == [.early])
    }

    @Test func theProvidersSessionHighIsUsedWhenItGivesOne() async {
        let harness = Harness(replies: [MockProvider.prices(["SPY": 99.8], high: 100)])
        await harness.poll()
        let spy = await harness.state("SPY")
        #expect(spy?.high == SessionHigh(price: 100, kind: .session))
        #expect(abs((spy?.pullbackPercent ?? 0) - 0.2) < 1e-9)
    }

    @Test func eachSymbolUsesItsOwnThresholds() async throws {
        var watch = settings(["SPY", "QQQ"])
        try watch.watchlist.setThresholds(try PullbackThresholds(early: 0.1, strong: 0.2), for: symbol("QQQ"))
        let harness = Harness(["SPY", "QQQ"], replies: [
            MockProvider.prices(["SPY": 100, "QQQ": 100]),
            MockProvider.prices(["SPY": 99.85, "QQQ": 99.85]),  // 0.15%: past QQQ's 0.1%, not SPY's 0.25%
        ])
        await harness.monitor.update(settings: watch)
        await harness.poll(2)
        #expect(await harness.state("SPY")?.lastAlert == nil)
        #expect(await harness.state("QQQ")?.lastAlert?.thresholdPercent == 0.1)
    }

    @Test func savedEngineStateKeepsAnAlertFromRepeating() async {
        let first = Harness(replies: [MockProvider.prices(["SPY": 100]), MockProvider.prices(["SPY": 99.7])])
        await first.poll(2)
        #expect(await first.state("SPY")?.lastAlert != nil)

        // A relaunch a minute later, with the saved state, sees the same pullback.
        let second = Harness(at: at("10:01:30"), replies: [MockProvider.prices(["SPY": 99.7])],
                             engineState: await first.monitor.engineState)
        await second.poll()
        #expect(await second.state("SPY")?.lastAlert == nil)
        #expect(await second.state("SPY")?.high == SessionHigh(price: 100, kind: .observed))
    }

    @Test func aHighFromAnEarlierSessionIsNotShown() async {
        let harness = Harness(replies: [MockProvider.prices(["SPY": 100])])
        await harness.poll()
        #expect(await harness.state("SPY")?.high != nil)

        harness.clock.set(at("05:00:00", on: "2026-11-11"))  // Wednesday's pre-market
        await harness.poll()
        #expect(await harness.state("SPY")?.high == nil)
        #expect(await harness.state("SPY")?.pullbackPercent == nil)
    }

    @Test func symbolsTheProviderCantQuoteSaySoAndTheRestUpdate() async {
        let harness = Harness(["SPY", "XYZQ", "HALT"])
        await harness.provider.script([{ _, now in
            .success(QuoteBatch(
                quotes: [Quote(symbol: "SPY", price: 101, timestamp: now - 2, source: "Test provider", session: .regular)],
                unknownSymbols: ["XYZQ"], unusableSymbols: ["HALT"]))
        }])
        await harness.poll()
        #expect(await harness.state("SPY")?.quote?.price == 101)
        #expect(await harness.state("SPY")?.problem == nil)
        #expect(await harness.state("XYZQ")?.problem == .unknownSymbol)
        #expect(await harness.state("HALT")?.problem == .noUsableQuote)
        #expect(await harness.diagnostics.lastError == nil)
    }

    // MARK: Publishing

    @Test func theSnapshotStreamHasTheLatestState() async {
        let harness = Harness()
        var snapshots = harness.monitor.snapshots.makeAsyncIterator()
        #expect(await snapshots.next()?.symbols[symbol("SPY")]?.quote == nil)

        await harness.poll(2)
        let latest = await snapshots.next()
        let current = await harness.monitor.snapshot
        #expect(latest == current)
        #expect(latest?.diagnostics.lastPoll == at("10:00:16"))
    }

    // MARK: Settings

    @Test(arguments: [10.0, 15, 3600])
    func anIntervalFromTenSecondsToAnHourIsAllowed(interval: TimeInterval) throws {
        #expect(try MonitorSettings(interval: interval).interval == interval)
    }

    @Test(arguments: [9.9, 0, -15, 3601, .infinity, .nan])
    func anyOtherIntervalIsRejected(interval: TimeInterval) {
        #expect(throws: MonitorSettingsError.intervalOutOfRange) { try MonitorSettings(interval: interval) }
    }
}
