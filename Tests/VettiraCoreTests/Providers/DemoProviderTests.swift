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
    for percent in DemoProvider.path + [DemoProvider.path.last!, DemoProvider.path.last!] {
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
    // and the warnings come on the sixth and seventh poll, as docs/providers.md says.
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
        #expect(fired[symbol] == [6: .early, 7: .strong])
    }
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
    // After-hours, Tuesday: to 10:00 that morning.
    ("19:00:00", "2026-11-10", "10:00:00", "2026-11-10"),
    // Pre-market, Tuesday: to 10:00 the same morning.
    ("05:00:00", "2026-11-10", "10:00:00", "2026-11-10"),
    // Saturday belongs to Friday's session.
    ("12:00:00", "2026-11-14", "10:00:00", "2026-11-13"),
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
