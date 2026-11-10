import Foundation
import Testing
import VettiraCore

// The demo provider's prices are made up, and it says so as their source. Its path is documented
// (docs/providers.md): up 0.30%, then back down past the default early warning (0.25% below the
// high) and the stronger one (0.40%), once each. Expected alerts come from the spec's defaults.

@Test func demoQuotesSayTheyreMadeUpAndAreFreshRegularSessionQuotes() async throws {
    let now = nyTime("10:00:00")
    let provider = DemoProvider(now: { now })
    let batch = try await provider.quotes(for: ["SPY", "QQQ"])
    #expect(batch.quotes.map(\.symbol) == ["SPY", "QQQ"])
    #expect(batch.quotes.allSatisfy {
        $0.source == "Demo (made-up prices)" && $0.timestamp == now && $0.session == .regular && $0.sessionHigh == nil
    })
    #expect(batch.quotes[0].price == DemoProvider.basePrice("SPY"))
}

@Test func demoQuotesHaveAMadeUpDayFromTheOpenUpToNow() async throws {
    let now = nyTime("10:02:00")
    let batch = try await DemoProvider(now: { now }).quotes(for: ["SPY", "QQQ"])
    for quote in batch.quotes {
        // 09:30 to 10:00, every 5 minutes: none after now.
        #expect(quote.intraday.map(\.timestamp) == stride(from: 0, through: 1800, by: 300).map { nyTime("09:30:00") + $0 })
        #expect(quote.intraday.allSatisfy { ($0.close ?? 0) > 0 })
        #expect(quote.previousClose == DemoProvider.previousClose(quote.symbol))
        // The day ends near the quote's price, so the line doesn't jump to it.
        let last = try #require(quote.intraday.last?.close)
        #expect(abs(last - quote.price) / quote.price * 100 < 0.05)
    }
    // One symbol's day is up and the other's down, so the demo shows both colours.
    let directions = Set(batch.quotes.compactMap { PriceChart(quote: $0, now: now)?.direction })
    #expect(directions == [.up, .down])
}

@Test func outsideRegularHoursTheDemoHasNoBars() async throws {
    let now = nyTime("08:00:00")
    let quote = try #require(try await DemoProvider(now: { now }).quotes(for: ["SPY"]).quotes.first)
    #expect(quote.intraday.isEmpty)
}

@Test func testingTheConnectionDoesntMoveTheDemoOn() async throws {
    let now = nyTime("10:00:00")
    let provider = DemoProvider(now: { now })
    _ = try await provider.quotes(for: ["SPY"])
    let tested = try await provider.testConnection(symbol: "spy")
    let next = try await provider.quotes(for: ["SPY"])
    let base = DemoProvider.basePrice("SPY")
    #expect(tested.symbol == "SPY")
    #expect(tested.price == base * (1 + DemoProvider.path[1] / 100))
    #expect(next.quotes.first?.price == tested.price)
}

@Test func aDemoRunWarnsOnceEarlyThenOnceStrongerAndNotifiesEachOnce() async {
    let clock = MonitorTestClock(at: nyTime("10:00:00"))
    var settings = UserSettings()
    try! settings.watchlist.add(displayTicker("SPY"))
    var monitor: QuoteMonitor? = QuoteMonitor(
        provider: DemoProvider(now: clock.monitorClock.now), settings: settings, clock: clock.monitorClock)
    clock.allow(polls: DemoProvider.path.count + 4)
    await monitor?.run()
    let alerts = monitor!.alerts
    let snapshot = await monitor!.snapshot
    // Releasing the monitor ends its streams, so reading the alerts stops after the last one.
    monitor = nil

    let center = RecordingCenter()
    let delivery = AlertDelivery(center: center, timeZone: newYork)
    var signals: [PullbackSignal] = []
    for await alert in alerts {
        signals.append(alert.signal)
        #expect(await delivery.deliver(alert, sound: true) == .delivered)
    }
    #expect(signals == [.early, .strong])
    #expect(center.titles == ["SPY: possible reversal, not confirmed", "SPY: possible reversal, not confirmed"])

    let status = MenuBarStatus(settings: settings, snapshot: snapshot, now: clock.now)
    // The path holds 0.40% below the high: past the early threshold, back inside the stronger.
    #expect(status.indicator == .pullback(.early))
    #expect(snapshot.symbols[displayTicker("SPY")]?.lastAlert?.signal == .strong)
    #expect(snapshot.symbols[displayTicker("SPY")]?.high?.kind == .observed)
}

@Test func theDemoPathAlertsExactlyTwice() {
    var engine = ReversalAlertEngine()
    var fired: [PullbackSignal] = []
    var time = nyTime("10:00:00")
    for percent in DemoProvider.path(for: "SPY") + [DemoProvider.path.last!, DemoProvider.path.last!] {
        let quote = regularQuote(DemoProvider.basePrice("SPY") * (1 + percent / 100), at: time)
        if case .accepted(_, _, let alert?) = engine.evaluate(quote, thresholds: .standard, now: time + 1) {
            fired.append(alert.signal)
        }
        time += 15
    }
    #expect(fired == [.early, .strong])
}

@Test func theDemosBarsNeverRaiseItsHigh() async throws {
    // The demo's quotes, with their made-up day's bars, polled every 15 s from 10:00: for a
    // symbol up on the day (SPY) and one down (QQQ), the high is the path's 0.30% above the base,
    // and the warnings come on the sixth and seventh poll, or a poll earlier for every other
    // symbol (QQQ), as docs/providers.md says.
    let clock = DemoClock(nyTime("10:00:00"))
    let provider = DemoProvider(now: { clock.now })
    var engine = ReversalAlertEngine()
    var fired: [String: [Int: PullbackSignal]] = [:]
    var highs: [String: SessionHigh] = [:]
    for poll in 1...(DemoProvider.path.count + 2) {
        for quote in try await provider.quotes(for: ["SPY", "QQQ"]).quotes {
            #expect(!quote.intraday.isEmpty)
            guard case .accepted(let high, _, let alert) = engine.evaluate(
                quote, thresholds: .standard, now: clock.now + 1) else {
                Issue.record("The demo's \(quote.symbol) quote was rejected")
                continue
            }
            highs[quote.symbol] = high
            if let alert { fired[quote.symbol, default: [:]][poll] = alert.signal }
        }
        clock.now += 15
    }
    for symbol in ["SPY", "QQQ"] {
        #expect(highs[symbol] == SessionHigh(price: DemoProvider.basePrice(symbol) * (1 + DemoProvider.path[3] / 100), kind: .observed))
    }
    #expect(fired["SPY"] == [6: .early, 7: .strong])
    #expect(fired["QQQ"] == [5: .early, 6: .strong])
}

// When the last symbol falls to its stronger warning (when a snapshot is taken), another is
// rising again, so the menu bar shows both colours.
@Test func atTheSeventhPollOneDemoSymbolFallsAndAnotherRises() async throws {
    let now = nyTime("10:00:00")
    let provider = DemoProvider(now: { now })
    var changes = PriceChanges()
    for _ in 1...7 {
        let batch = try await provider.quotes(for: ["SPY", "QQQ", "DIA"])
        changes.record(MonitorSnapshot(
            symbols: Dictionary(uniqueKeysWithValues: batch.quotes.map { quote in
                var state = SymbolSnapshot(symbol: displayTicker(quote.symbol))
                state.quote = quote
                return (state.symbol, state)
            }),
            diagnostics: MonitorDiagnostics(source: provider.name)))
    }
    #expect(changes[displayTicker("SPY")]?.direction == .down)
    #expect(changes[displayTicker("DIA")]?.direction == .down)
    #expect(changes[displayTicker("QQQ")]?.direction == .up)
}

private final class DemoClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ now: Date) { _now = now }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}

@Test(arguments: [
    // After-hours, Tuesday: to 14:00 that day.
    ("19:00:00", "2026-11-10", "14:00:00", "2026-11-10"),
    // Pre-market, Tuesday: to 14:00 the same day.
    ("05:00:00", "2026-11-10", "14:00:00", "2026-11-10"),
    // Saturday belongs to Friday's session.
    ("12:00:00", "2026-11-14", "14:00:00", "2026-11-13"),
    // The day after Thanksgiving closes at 13:00: to 12:00.
    ("20:00:00", "2026-11-27", "12:00:00", "2026-11-27"),
])
func theDemoClockMovesIntoRegularHours(time: String, day: String, expected: String, expectedDay: String) {
    let now = nyTime(time, on: day)
    #expect(now + DemoProvider.regularHoursOffset(at: now) == nyTime(expected, on: expectedDay))
}

@Test func inRegularHoursTheDemoClockIsntMoved() {
    #expect(DemoProvider.regularHoursOffset(at: nyTime("11:00:00")) == 0)
}

private final class RecordingCenter: AlertNotificationCenter, @unchecked Sendable {
    private let lock = NSLock()
    private var _titles: [String] = []
    var titles: [String] { lock.withLock { _titles } }
    func authorization() async -> NotificationAuthorization { .allowed }
    func requestAuthorization() async -> NotificationAuthorization { .allowed }
    func add(_ notification: AlertNotification, sound: Bool) async throws {
        lock.withLock { _titles.append(notification.title) }
    }
}

// MARK: History

@Test func demoHistoryForOneDayIsTheQuotesOwnDayAtAMinute() async throws {
    let now = nyTime("11:02:00")
    let provider = DemoProvider(now: { now })
    let quote = try await provider.testConnection(symbol: "SPY")
    let day = try await provider.history(for: "SPY", timeframe: .oneDay)
    #expect(day.timeframe == .oneDay)
    #expect(day.previousClose == quote.previousClose)
    // A bar each minute from 09:30 up to now: 92, to 11:01.
    #expect(day.bars.map(\.timestamp) == stride(from: 0, through: 91 * 60, by: 60).map { nyTime("09:30:00") + $0 })
    // Each bar opens where the one before closed, with a made-up volume.
    #expect(zip(day.bars, day.bars.dropFirst()).allSatisfy { $1.open == $0.close })
    #expect(day.bars.allSatisfy {
        ($0.volume ?? 0) > 0 && $0.low! <= min($0.open!, $0.close!) && $0.high! >= max($0.open!, $0.close!)
    })
    // The polls' 5-minute bars are the same day, five of its minutes each.
    #expect(quote.intraday.count == 19)
    for (index, bar) in quote.intraday.enumerated() {
        try #require(index * 5 < day.bars.count)
        let minutes = day.bars[(index * 5)..<min(index * 5 + 5, day.bars.count)]
        #expect(bar.timestamp == minutes.first?.timestamp)
        #expect(bar.open == minutes.first?.open)
        #expect(bar.close == minutes.last?.close)
        #expect(bar.high == minutes.compactMap(\.high).max())
        #expect(bar.low == minutes.compactMap(\.low).min())
        #expect(bar.volume == minutes.compactMap(\.volume).reduce(0, +))
    }
}

@Test func aDemoDayIsAJaggedWalkNotACurve() async throws {
    let now = nyTime("15:00:00")
    let day = try await DemoProvider(now: { now }).history(for: "SPY", timeframe: .oneDay)
    let again = try await DemoProvider(now: { now }).history(for: "SPY", timeframe: .oneDay)
    #expect(day == again)
    // A random walk turns about every other minute; a smooth curve turns a handful of times a day.
    let moves = zip(day.bars, day.bars.dropFirst()).map { $1.close! - $0.close! }
    let turns = zip(moves, moves.dropFirst()).filter { $0 * $1 < 0 }.count
    #expect(Double(turns) > Double(moves.count) * 0.3)
}

@Test(arguments: [ChartTimeframe.fiveDays, .oneMonth, .sixMonths, .yearToDate, .oneYear, .fiveYears])
func demoHistoryEndsAtTheQuotesPriceAndIsTheSameEachRun(timeframe: ChartTimeframe) async throws {
    let now = nyTime("11:02:00")
    let quote = try await DemoProvider(now: { now }).testConnection(symbol: "QQQ")
    let history = try await DemoProvider(now: { now }).history(for: "QQQ", timeframe: timeframe)
    let again = try await DemoProvider(now: { now }).history(for: "QQQ", timeframe: timeframe)
    #expect(history == again)
    #expect(history.symbol == "QQQ")
    #expect(history.timeframe == timeframe)
    #expect(history.previousClose != nil)
    let last = try #require(history.bars.last?.close)
    #expect(abs(last - quote.price) < 1e-9)
    #expect(zip(history.bars, history.bars.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
    #expect(history.bars.allSatisfy { bar in
        guard let open = bar.open, let close = bar.close, let high = bar.high, let low = bar.low else { return false }
        return high >= max(open, close) && low <= min(open, close) && low > 0 && (bar.volume ?? 0) > 0
    })
    #expect(history.bars.allSatisfy { $0.timestamp <= now })
}

@Test func demoHistoryIsOnTradingDaysInRegularHours() async throws {
    let now = nyTime("11:02:00")
    let provider = DemoProvider(now: { now })
    let calendar = MarketCalendar.usEquities
    // 5 sessions of 5-minute bars: four whole days of 78 and today's to 11:00, 19.
    let fiveDays = try await provider.history(for: "SPY", timeframe: .fiveDays)
    #expect(fiveDays.bars.count == 4 * 78 + 19)
    #expect(fiveDays.bars.allSatisfy { calendar.status(at: $0.timestamp)?.state == .regular })
    #expect(fiveDays.bars.first?.timestamp == nyTime("09:30:00", on: "2026-11-04"))
    // A year of trading days, each at its open: none on a weekend or a holiday the calendar has.
    var newYork = Calendar(identifier: .gregorian)
    newYork.timeZone = TimeZone(identifier: "America/New_York")!
    let year = try await provider.history(for: "SPY", timeframe: .oneYear)
    #expect((248...256).contains(year.bars.count))
    #expect(year.bars.allSatisfy {
        !newYork.isDateInWeekend($0.timestamp) && newYork.dateComponents([.hour, .minute], from: $0.timestamp) == DateComponents(hour: 9, minute: 30)
    })
    func open(_ month: Int, _ day: Int) -> Date {
        newYork.date(from: DateComponents(year: 2026, month: month, day: day, hour: 9, minute: 30))!
    }
    #expect(!year.bars.contains { $0.timestamp == open(7, 3) })
    #expect(year.bars.contains { $0.timestamp == open(7, 2) })
    // Five years of weeks.
    #expect(try await provider.history(for: "SPY", timeframe: .fiveYears).bars.count == 261)
}
