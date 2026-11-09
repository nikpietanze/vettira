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

    let status = MenuBarStatus(
        settings: settings, snapshot: snapshot, staleTolerance: 60, now: clock.now)
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
