import Foundation
import Testing
import VettiraCore

// Expected values come from the issue and AGENTS.md: streamed prices go through the same alert
// engine as polled ones, so a stale, out-of-order or extended-hours one never alerts; the poll
// still brings the day's bars, previous close and session high; while the stream is live polls
// slow to a minute, and when it drops, polling takes over at the update interval (15 s by
// default); and only the enabled symbols stream, only in regular hours. The default early warning
// is 0.25%. New York is UTC-5 in November 2026.

private func at(_ time: String, on day: String = "2026-11-10") -> Date {
    ISO8601DateFormatter().date(from: "\(day)T\(time)-05:00")!
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

private func streamed(_ symbol: String, _ price: Double, at time: Date, session: Quote.Session = .regular) -> Quote {
    Quote(symbol: symbol, price: price, timestamp: time, source: "Test stream", session: session)
}

/// A poll's quote at 100, 2 s old, with the day's bars, a previous close and a session high 0.20%
/// above it, short of the early warning.
private let polledDay: MockProvider.Reply = { symbols, now in
    .success(QuoteBatch(quotes: symbols.map {
        Quote(symbol: $0, price: 100, timestamp: now - 2, source: "Test provider", sessionHigh: 100.2,
              session: .regular, previousClose: 99, intraday: [PriceBar(timestamp: now - 300, close: 99.5, high: 100)])
    }))
}

private struct Harness {
    let clock: MonitorTestClock
    let provider: MockProvider
    let monitor: QuoteMonitor

    init(_ symbols: [String] = ["SPY"], disabled: Set<String> = [], at start: Date = at("10:00:00"),
         replies: [MockProvider.Reply] = [polledDay], suspending: Bool = false) {
        clock = MonitorTestClock(at: start, suspending: suspending)
        provider = MockProvider(clock: clock, replies: replies)
        monitor = QuoteMonitor(provider: provider, settings: settings(symbols, disabled: disabled), clock: clock.monitorClock)
    }

    func poll(_ count: Int = 1) async {
        clock.allow(polls: count)
        await monitor.run()
    }

    func state(_ raw: String) async -> SymbolSnapshot? {
        await monitor.snapshot.symbols[symbol(raw)]
    }
}

private func allAlerts(_ alerts: AsyncStream<ReversalAlert>) async -> [ReversalAlert] {
    var sent: [ReversalAlert] = []
    for await alert in alerts { sent.append(alert) }
    return sent
}

// A broken test fails within a minute instead of hanging the run.
@Suite(.timeLimit(.minutes(1))) struct QuoteMonitorStreamingTests {
    // MARK: Streamed prices

    @Test func aStreamedPriceKeepsThePollsDayCloseAndHigh() async {
        let harness = Harness()
        await harness.poll()
        let time = harness.clock.now + 1
        await harness.monitor.receive(.quotes([streamed("SPY", 100.4, at: time)]))
        let quote = await harness.state("SPY")?.quote
        #expect(quote?.price == 100.4)
        #expect(quote?.timestamp == time)
        #expect(quote?.source == "Test stream")
        #expect(quote?.previousClose == 99)
        #expect(quote?.sessionHigh == 100.2)
        #expect(quote?.intraday.map(\.close) == [99.5])
        #expect(await harness.monitor.snapshot.diagnostics.lastReceived == harness.clock.now)
    }

    @Test func aStreamedPullbackAlertsAsAPolledOneWould() async {
        var harness: Harness? = Harness()
        let alerts = harness!.monitor.alerts
        await harness!.poll()
        // 0.30% below the poll's session high of 100.2.
        await harness!.monitor.receive(.quotes([streamed("SPY", 99.9, at: harness!.clock.now)]))
        let state = await harness!.state("SPY")
        #expect(state?.high == SessionHigh(price: 100.2, kind: .session))
        #expect(state?.lastAlert?.signal == .early)
        harness = nil
        let sent = await allAlerts(alerts)
        #expect(sent.map(\.signal) == [.early])
        #expect(sent.first?.source == "Test stream")
    }

    @Test func aStreamedPriceNoNewerThanTheLatestIsIgnored() async {
        let harness = Harness()
        await harness.poll()
        let polled = await harness.state("SPY")?.quote
        await harness.monitor.receive(.quotes([streamed("SPY", 90, at: polled!.timestamp - 1)]))
        await harness.monitor.receive(.quotes([streamed("SPY", 90, at: polled!.timestamp)]))
        #expect(await harness.state("SPY")?.quote == polled)
        #expect(await harness.state("SPY")?.lastAlert == nil)
    }

    @Test func aStaleStreamedPriceNeverAlerts() async {
        let stale: MockProvider.Reply = { symbols, now in
            .success(QuoteBatch(quotes: symbols.map {
                Quote(symbol: $0, price: 100, timestamp: now - 300, source: "Test provider", sessionHigh: 101, session: .regular)
            }))
        }
        let harness = Harness(replies: [stale])
        await harness.poll()
        // Newer than the poll's, but 2 minutes old: past the 60-second tolerance.
        await harness.monitor.receive(.quotes([streamed("SPY", 99, at: harness.clock.now - 120)]))
        let state = await harness.state("SPY")
        #expect(state?.quote?.price == 99)
        #expect(state?.lastRejection == .stale(age: 120))
        #expect(state?.lastAlert == nil)
    }

    @Test func anExtendedHoursStreamedPriceNeverAlerts() async {
        let harness = Harness()
        await harness.poll()
        await harness.monitor.receive(.quotes([streamed("SPY", 99, at: harness.clock.now, session: .postMarket)]))
        #expect(await harness.state("SPY")?.lastRejection == .outsideRegularHours)
        #expect(await harness.state("SPY")?.lastAlert == nil)
    }

    @Test func aStreamedPriceForASymbolThatIsntOnIsIgnored() async {
        let harness = Harness(["SPY", "QQQ"], disabled: ["QQQ"])
        await harness.poll()
        await harness.monitor.receive(.quotes([streamed("QQQ", 400, at: harness.clock.now), streamed("AAPL", 200, at: harness.clock.now)]))
        #expect(await harness.monitor.snapshot.symbols.keys.sorted() == [symbol("SPY")])
    }

    @Test func aStreamedPriceFromALaterSessionBringsNoOldDay() async {
        // Yesterday's last poll; today's first price comes from the stream before today's poll.
        let harness = Harness(at: at("15:59:00", on: "2026-11-09"))
        await harness.poll()
        let morning = at("09:30:05")
        harness.clock.set(morning)
        await harness.monitor.receive(.quotes([streamed("SPY", 100.2, at: morning)]))
        let quote = await harness.state("SPY")?.quote
        #expect(quote?.price == 100.2)
        #expect(quote?.sessionHigh == nil)
        #expect(quote?.previousClose == nil)
        #expect(quote?.intraday == [])
        #expect(await harness.state("SPY")?.high == SessionHigh(price: 100.2, kind: .observed))
    }

    @Test func anOlderPollKeepsTheStreamedPriceAndTakesItsDay() async {
        let harness = Harness(replies: [polledDay, polledDay])
        await harness.poll()
        let time = harness.clock.now + 10
        harness.clock.set(time)
        await harness.monitor.receive(.quotes([streamed("SPY", 100.3, at: time)]))
        // The next poll's quote is 2 s older than the streamed price.
        await harness.poll()
        let quote = await harness.state("SPY")?.quote
        #expect(quote?.price == 100.3)
        #expect(quote?.timestamp == time)
        #expect(quote?.intraday.count == 1)
        #expect(quote?.previousClose == 99)
    }

    // MARK: What streams

    @Test func theEnabledSymbolsStreamInRegularHoursOnly() async {
        let harness = Harness(["SPY", "AAPL", "QQQ"], disabled: ["AAPL"])
        var symbols = harness.monitor.streamSymbols.makeAsyncIterator()
        await harness.poll()
        #expect(await symbols.next() == ["SPY", "QQQ"])
        await harness.monitor.update(settings: settings(["SPY", "AAPL"]))
        #expect(await symbols.next() == ["SPY", "AAPL"])
        harness.clock.set(at("16:00:30"))
        await harness.poll()
        #expect(await symbols.next() == [])
    }

    @Test func nothingStreamsOutsideRegularHours() async {
        let harness = Harness(at: at("08:00:00"))
        var symbols = harness.monitor.streamSymbols.makeAsyncIterator()
        await harness.poll()
        harness.clock.set(at("09:30:00"))
        await harness.poll()
        // Only the open's poll says to stream: before it there was nothing to change.
        #expect(await symbols.next() == ["SPY"])
    }

    // MARK: The polls' pace

    @Test func whileTheStreamIsLivePollsAreAMinuteApart() async {
        let harness = Harness(replies: [polledDay, polledDay, polledDay])
        await harness.monitor.receive(.status(.live(since: at("10:00:00"))))
        await harness.poll(2)
        #expect(harness.clock.sleeps == [59, 59])
        await harness.monitor.receive(.status(.reconnecting(.unavailable, retryAt: at("10:03:00"))))
        await harness.poll()
        #expect(harness.clock.sleeps.last == 14)
    }

    @Test func aDroppedStreamBringsTheNextPollForward() async {
        let harness = Harness(replies: [polledDay, polledDay], suspending: true)
        await harness.monitor.receive(.status(.live(since: at("10:00:00"))))
        let run = Task { await harness.monitor.run() }
        #expect(await harness.clock.nextSleep() == 59)
        #expect(await harness.monitor.snapshot.diagnostics.nextPoll == at("10:01:00"))

        harness.clock.advance(by: 4)
        await harness.monitor.receive(.status(.reconnecting(.unavailable, retryAt: at("10:00:10"))))
        // An update interval after the last poll started, at 10:00:00.
        #expect(await harness.monitor.snapshot.diagnostics.nextPoll == at("10:00:15"))
        #expect(await harness.clock.nextSleep() == 10)
        harness.clock.advance(by: 10)
        #expect(await harness.clock.nextSleep() == 14)
        #expect(await harness.provider.requests.map(\.at) == [at("10:00:00"), at("10:00:15")])
        run.cancel()
        await run.value
    }

    @Test func aStreamThatWasntLiveChangesNoPoll() async {
        let harness = Harness(suspending: true)
        let run = Task { await harness.monitor.run() }
        #expect(await harness.clock.nextSleep() == 14)
        await harness.monitor.receive(.status(.reconnecting(.unavailable, retryAt: at("10:00:10"))))
        #expect(await harness.monitor.snapshot.diagnostics.nextPoll == at("10:00:15"))
        harness.clock.advance(by: 14)
        #expect(await harness.clock.nextSleep() == 14)
        #expect(await harness.provider.requests.count == 2)
        run.cancel()
        await run.value
    }

    @Test func theStreamsStatusIsInTheDiagnostics() async {
        let harness = Harness()
        #expect(await harness.monitor.snapshot.diagnostics.stream == nil)
        await harness.monitor.receive(.status(.connecting))
        #expect(await harness.monitor.snapshot.diagnostics.stream == .connecting)
    }
}
