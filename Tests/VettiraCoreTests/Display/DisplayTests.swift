import Foundation
import Testing
import VettiraCore

// Expected values come from the issue and the spec: the menu bar shows the selected ticker with
// its latest price and change from the high, or its alert or stale status; the popover lists each
// symbol's price, high and whether it's observed, pullback, data age and connection health. Data
// age is always visible, a stale quote is said to be stale (older than the 60-second tolerance),
// and a warning is a possible reversal, not a confirmed one (AGENTS.md).


// MARK: Formatting

@Test func pricesHaveTwoDecimalsOrFourBelowOne() {
    #expect(DisplayFormat.price(512.3) == "512.30")
    #expect(DisplayFormat.price(0.42151) == "0.4215")
}

@Test func theChangeFromTheHighIsNegativeOrZero() {
    #expect(DisplayFormat.changeFromHigh(0.3125) == "\u{2212}0.31%")
    #expect(DisplayFormat.changeFromHigh(0) == "0.00%")
    #expect(DisplayFormat.changeFromHigh(0.001) == "0.00%")
}

@Test func agesReadInTheLargestWholeUnit() {
    #expect(DisplayFormat.duration(5.9) == "5 s")
    #expect(DisplayFormat.duration(-2) == "0 s")
    #expect(DisplayFormat.duration(250) == "4 min")
    #expect(DisplayFormat.duration(3 * 3600 + 5) == "3 h")
    #expect(DisplayFormat.duration(2 * 86_400) == "2 d")
}

@Test func quoteTimesShowTheirTimeZone() {
    #expect(DisplayFormat.time(nyTime("10:31:05"), in: newYork) == "10:31:05 EST")
}

// MARK: The menu bar

private func status(
    _ snapshot: MonitorSnapshot, list: Watchlist = displayWatchlist(["SPY"]), now: Date = nyTime("10:00:20")
) -> MenuBarStatus {
    var settings = UserSettings()
    settings.watchlist = list
    return MenuBarStatus(settings: settings, snapshot: snapshot, now: now)
}

@Test func anEmptyWatchlistShowsNoSymbol() {
    let shown = status(displaySnapshot([]), list: Watchlist())
    #expect(shown.symbol == nil)
    #expect(shown.title == "")
    #expect(shown.indicator == .empty)
}

@Test func aDisabledMenuBarSymbolSaysItsOff() {
    let shown = status(displaySnapshot([]), list: displayWatchlist(["SPY"], disabled: ["SPY"]))
    #expect(shown.title == "SPY off")
    #expect(shown.indicator == .notMonitored)
}

@Test func beforeTheFirstQuoteItWaits() {
    let shown = status(displaySnapshot([SymbolSnapshot(symbol: displayTicker("SPY"))], market: nil, polled: nil))
    #expect(shown.title == "SPY \u{2026}")
    #expect(shown.indicator == .waiting)
}

@Test func aProviderErrorBeforeAnyQuoteShowsUnavailable() {
    var failed = displaySnapshot([SymbolSnapshot(symbol: displayTicker("SPY"))])
    failed.diagnostics.lastError = .rateLimited(retryAfter: nil)
    let shown = status(failed)
    #expect(shown.title == "SPY \u{2014}")
    #expect(shown.indicator == .unavailable)
    #expect(shown.detail.contains("limiting requests"))
}

@Test func anUnknownSymbolShowsUnavailable() {
    var state = SymbolSnapshot(symbol: displayTicker("SPY"))
    state.problem = .unknownSymbol
    let shown = status(displaySnapshot([state]))
    #expect(shown.indicator == .unavailable)
    #expect(shown.detail == "The provider doesn't recognize SPY.")
}

@Test func aFreshQuoteShowsThePriceAndChangeFromTheHigh() {
    let shown = status(displaySnapshot([spy(100.3)]))
    #expect(shown.title == "SPY 100.30 \u{2212}0.20%")
    #expect(shown.indicator == .live)
    #expect(shown.detail == "SPY 100.30 is 0.20% below its observed high of 100.50. Quote 5 s old.")
}

@Test func aWarningThePriceIsStillPastShowsAsAPossibleReversal() {
    let alert = earlyWarning()
    let shown = status(displaySnapshot([spy(100.2, alert: alert)]))
    #expect(shown.title == "SPY 100.20 \u{2212}0.30%")
    #expect(shown.indicator == .pullback(.early))
    #expect(shown.detail.hasPrefix("Early warning: possible reversal, not confirmed. "))
}

// A stronger warning fired, and the price came back up to between the two thresholds.
@Test func aPriceBackInsideTheStrongerThresholdShowsTheEarlyWarning() {
    let alert = strongerWarning()
    #expect(status(displaySnapshot([spy(100.2, alert: alert)])).indicator == .pullback(.early))
    #expect(status(displaySnapshot([spy(100.0, alert: alert)])).indicator == .pullback(.strong))
}

@Test func aPriceBackAboveTheWarningsThresholdIsLiveAgain() {
    let shown = status(displaySnapshot([spy(100.4, alert: earlyWarning())]))
    #expect(shown.indicator == .live)
}

@Test func yesterdaysWarningIsntShownToday() {
    let today = nyTime("10:00:15", on: "2026-11-11")
    let shown = status(displaySnapshot([spy(100.2, at: today, alert: earlyWarning())]), now: today + 5)
    #expect(shown.indicator == .live)
}

@Test func aStaleQuoteSaysSo() {
    let shown = status(displaySnapshot([spy(100.3, stale: true)]), now: nyTime("10:05:15"))
    #expect(shown.title == "SPY 100.30 \u{00B7} stale")
    #expect(shown.indicator == .stale)
    #expect(shown.detail == "SPY 100.30: the quote is 5 min old, too old to alert on.")
}

// The monitor only publishes after a poll, and waits up to 15 minutes while it backs off: a quote
// that ages past the tolerance in between is stale all the same.
@Test func aQuoteThatAgedSinceTheLastSnapshotIsStale() {
    let shown = status(displaySnapshot([spy(100.3)]), now: nyTime("10:01:16"))
    #expect(shown.indicator == .stale)
}

@Test func outsideRegularHoursItSaysClosed() {
    let shown = status(displaySnapshot([spy(100.3, stale: true)], market: .afterHours), now: nyTime("17:00:00"))
    #expect(shown.title == "SPY 100.30 \u{00B7} closed")
    #expect(shown.indicator == .closed)
}

// MARK: The day's chart

/// SPY at `price` at 10:00:15 with bars from 09:30 and a previous close of 100.
private func spyWithDay(_ price: Double = 100.3, stale: Bool = false) -> SymbolSnapshot {
    var state = spy(price, stale: stale)
    state.quote?.previousClose = 100
    state.quote?.intraday = [
        PriceBar(timestamp: nyTime("09:30:00"), close: 99.8), PriceBar(timestamp: nyTime("09:55:00"), close: 100.6),
    ]
    return state
}

@Test func theMenuBarShowsTheDaysChartAndSaysItInWords() throws {
    let shown = status(displaySnapshot([spyWithDay()]))
    let chart = try #require(shown.chart)
    #expect(chart.direction == .up)
    // The text keeps its sign; the chart adds its words to what the item says.
    #expect(shown.title == "SPY 100.30 \u{2212}0.20%")
    #expect(shown.accessibilityValue == "SPY 100.30 is 0.20% below its observed high of 100.50. Quote 5 s old. "
        + "Chart of today's price for SPY, updated with each quote: up 0.30% from the previous close of 100.00.")
}

@Test func aStaleOrClosedQuoteStillShowsItsChartWithTheStatusInTheText() {
    let stale = status(displaySnapshot([spyWithDay(stale: true)]), now: nyTime("10:05:15"))
    #expect(stale.title == "SPY 100.30 \u{00B7} stale")
    #expect(stale.chart != nil)
    let closed = status(displaySnapshot([spyWithDay(stale: true)], market: .afterHours), now: nyTime("17:00:00"))
    #expect(closed.title == "SPY 100.30 \u{00B7} closed")
    #expect(closed.chart != nil)
}

@Test func withTheChartTurnedOffTheMenuBarHasNone() {
    var settings = UserSettings()
    settings.watchlist = displayWatchlist(["SPY"])
    settings.showsChartInMenuBar = false
    let shown = MenuBarStatus(settings: settings, snapshot: displaySnapshot([spyWithDay()]), now: nyTime("10:00:20"))
    #expect(shown.chart == nil)
    #expect(shown.accessibilityValue == shown.detail)
}

@Test func withoutBarsThereIsNoChart() {
    let shown = status(displaySnapshot([spy(100.3)]))
    #expect(shown.chart == nil)
    #expect(shown.accessibilityValue == shown.detail)
}

@Test func eachRowHasItsDaysChartWhateverTheMenuBarSetting() {
    var settings = rowSettings(displayWatchlist(["SPY", "QQQ"], disabled: ["QQQ"]))
    settings.showsChartInMenuBar = false
    let rows = SymbolRow.rows(
        settings: settings, snapshot: displaySnapshot([spyWithDay()]), now: nyTime("10:00:20"), timeZone: newYork)
    #expect(rows[0].chart?.direction == .up)
    #expect(rows[1].chart == nil)
}

// MARK: The popover's and the dashboard's rows

private func rowSettings(_ list: Watchlist) -> UserSettings {
    var settings = UserSettings()
    settings.watchlist = list
    return settings
}

@Test func rowsListPinnedSymbolsFirstAndMarkTheMenuBars() {
    let list = displayWatchlist(["SPY", "QQQ", "DIA"], disabled: ["DIA"], pinned: ["QQQ"])
    let rows = SymbolRow.rows(
        settings: rowSettings(list), snapshot: displaySnapshot([spy(100.3)]), now: nyTime("10:00:20"),
        timeZone: newYork)
    #expect(rows.map(\.symbol.rawValue) == ["QQQ", "SPY", "DIA"])
    #expect(rows.map(\.isInMenuBar) == [false, true, false])
    #expect(rows[2].status == "off")
    #expect(rows[2].isEnabled == false)
}

@Test func aRowShowsThePriceTheHighItsKindThePullbackAndTheDataAge() {
    let row = SymbolRow.rows(
        settings: rowSettings(displayWatchlist(["SPY"])), snapshot: displaySnapshot([spy(100.2, alert: earlyWarning())]), now: nyTime("10:00:20"), timeZone: newYork)[0]
    #expect(row.price == "100.20")
    #expect(row.high == "100.50 observed high")
    #expect(row.changeFromHigh == "\u{2212}0.30%")
    #expect(row.dataAge == "5 s")
    #expect(row.status == nil)
    #expect(row.isStale == false)
    #expect(row.lastWarning == "Early warning at 10:00:15 EST")
}

@Test func aSessionHighIsLabelledAsOne() {
    let row = SymbolRow.rows(
        settings: rowSettings(displayWatchlist(["SPY"])),
        snapshot: displaySnapshot([spy(100.2, high: SessionHigh(price: 101, kind: .session))]), now: nyTime("10:00:20"), timeZone: newYork)[0]
    #expect(row.high == "101.00 session high")
}

@Test(arguments: [
    (QuoteRejection.outsideRegularHours, false, "market closed"),
    (.implausibleJump(fromPrice: 90), false, "unconfirmed jump"),
    (.duplicate, false, nil),
    (.duplicate, true, "stale"),
    (.stale(age: 90), true, "stale"),
] as [(QuoteRejection, Bool, String?)])
func aRowSaysWhyItsDataCantAlert(rejection: QuoteRejection, stale: Bool, expected: String?) {
    var state = spy(100.2, stale: stale)
    state.lastRejection = rejection
    let row = SymbolRow.rows(
        settings: rowSettings(displayWatchlist(["SPY"])), snapshot: displaySnapshot([state]),
        now: nyTime("10:00:20"), timeZone: newYork)[0]
    #expect(row.status == expected)
}

@Test func aSymbolWithNoQuoteYetIsWaitingOrSaysWhy() {
    var unknown = SymbolSnapshot(symbol: displayTicker("QQQ"))
    unknown.problem = .unknownSymbol
    let rows = SymbolRow.rows(
        settings: rowSettings(displayWatchlist(["SPY", "QQQ"])),
        snapshot: displaySnapshot([SymbolSnapshot(symbol: displayTicker("SPY")), unknown]),
        now: nyTime("10:00:20"), timeZone: newYork)
    #expect(rows.map(\.status) == ["waiting", "unknown symbol"])
    #expect(rows.allSatisfy { $0.price == nil && $0.dataAge == nil && $0.isStale })
}

@Test func aRowShowsItsQuoteTimeAndThresholdsForTheDashboard() throws {
    var list = displayWatchlist(["SPY", "QQQ"], pinned: ["QQQ"])
    try list.setThresholds(PullbackThresholds(early: 0.5, strong: 1), for: displayTicker("QQQ"))
    var settings = rowSettings(list)
    settings.defaultThresholds = try PullbackThresholds(early: 0.3, strong: 0.6)
    let rows = SymbolRow.rows(
        settings: settings, snapshot: displaySnapshot([spy(100.2)]), now: nyTime("10:00:20"), timeZone: newYork)
    #expect(rows.map(\.symbol.rawValue) == ["QQQ", "SPY"])
    #expect(rows.map(\.isPinned) == [true, false])
    #expect(rows.map(\.thresholds) == ["0.50% / 1.00%", "0.30% / 0.60%"])
    #expect(rows.map(\.hasOwnThresholds) == [true, false])
    #expect(rows.map(\.quoteTime) == [nil, "10:00:15 EST"])
}

@Test func aRowIsStalePastTheSettingsTolerance() throws {
    // The quote is 5 s old.
    var settings = rowSettings(displayWatchlist(["SPY"]))
    let fresh = SymbolRow.rows(settings: settings, snapshot: displaySnapshot([spy(100.2)]), now: nyTime("10:00:20"))
    #expect(fresh[0].isStale == false)
    try settings.setStaleTolerance(4)
    let stale = SymbolRow.rows(settings: settings, snapshot: displaySnapshot([spy(100.2)]), now: nyTime("10:00:20"))
    #expect(stale[0].isStale)
    #expect(stale[0].status == "stale")
}

@Test(arguments: [("", true), ("sp", true), (" Y ", true), ("SPY", true), ("QQQ", false), ("SPYY", false)])
func aSearchFindsRowsWhoseTickerHasIt(query: String, found: Bool) {
    let row = SymbolRow.rows(settings: rowSettings(displayWatchlist(["SPY"])), snapshot: displaySnapshot([]),
                             now: nyTime("10:00:20"))[0]
    #expect(row.matches(query) == found)
}

@Test func thresholdsReadEarlyThenStronger() {
    #expect(DisplayFormat.thresholds(.standard) == "0.25% / 0.40%")
}

// MARK: Connection health

@Test func beforeTheFirstPollTheConnectionIsWaiting() {
    let health = ConnectionHealth(diagnostics: MonitorDiagnostics(source: "Test provider"), now: nyTime("10:00:00"))
    #expect(health.level == .waiting)
}

@Test func aWorkingConnectionSaysWhenDataCameAndWhenItsNext() {
    var diagnostics = displaySnapshot([]).diagnostics
    diagnostics.nextPoll = nyTime("10:00:35")
    let health = ConnectionHealth(diagnostics: diagnostics, now: nyTime("10:00:25"))
    #expect(health.level == .connected)
    #expect(health.headline == "Connected")
    #expect(health.detail == "Last received 5 s ago. Next update in 10 s.")
}

@Test func aLiveStreamSaysPricesAreStreaming() {
    var diagnostics = displaySnapshot([]).diagnostics
    diagnostics.stream = .live(since: nyTime("10:00:00"))
    #expect(ConnectionHealth(diagnostics: diagnostics, now: nyTime("10:00:25")).headline == "Connected, prices streaming")
    diagnostics.stream = .reconnecting(.unavailable, retryAt: nyTime("10:00:30"))
    #expect(ConnectionHealth(diagnostics: diagnostics, now: nyTime("10:00:25")).headline == "Connected")
}

@Test func aFailingConnectionSaysWhatHappenedAndWhatToDo() {
    var diagnostics = displaySnapshot([]).diagnostics
    diagnostics.lastError = .blocked
    diagnostics.nextPoll = nyTime("10:01:20")
    let health = ConnectionHealth(diagnostics: diagnostics, now: nyTime("10:00:20"))
    #expect(health.level == .failing)
    #expect(health.headline == ProviderError.blocked.message)
    #expect(health.detail == "\(ProviderError.blocked.nextStep) Last received 0 s ago. Next update in 1 min.")
}

@Test func outsideRegularHoursTheConnectionSaysNoAlerts() {
    let health = ConnectionHealth(diagnostics: displaySnapshot([], market: .closed).diagnostics, now: nyTime("10:00:20"))
    #expect(health.level == .closed)
    #expect(health.headline == "Market closed: no alerts until the next session")
}
