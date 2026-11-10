import Foundation
import Testing
import VettiraCore

// Expected values come from the issue: the menu bar shows `SYMBOL price` only. On each new price
// it compares the price as displayed with the symbol's previous one, character by character from
// the left, and colours everything from the first difference to the end, green when it rose and
// red when it fell; a change in the number of characters colours the whole price. The colour
// stays until the symbol's next change. A stale or closed price is dimmed, never green or red. It
// cycles through the enabled symbols, or with cycling off shows only the menu-bar symbol.

// MARK: Which characters changed

@Test(arguments: [
    // The user's examples.
    (740.43, 741.12, "74", "1.12", PriceChange.Direction.up),
    (740.43, 739.81, "7", "39.81", .down),
    (740.43, 740.41, "740.4", "1", .down),
    (99.98, 100.02, "", "100.02", .up),
    // And the other way.
    (100.02, 99.98, "", "99.98", .down),
])
func theCharactersFromTheFirstDifferenceChanged(
    old: Double, new: Double, unchanged: String, changed: String, direction: PriceChange.Direction
) throws {
    let change = try #require(PriceChange(from: old, to: new))
    #expect(change.unchanged == unchanged)
    #expect(change.changed == changed)
    #expect(change.direction == direction)
    #expect(change.from == DisplayFormat.price(old))
    #expect(change.to == DisplayFormat.price(new))
}

@Test func aPriceThatDisplaysTheSameIsNoChange() {
    #expect(PriceChange(from: 740.43, to: 740.43) == nil)
    #expect(PriceChange(from: 740.431, to: 740.434) == nil)
}

// MARK: Each symbol's last change

private func snapshot(_ prices: [String: Double]) -> MonitorSnapshot {
    displaySnapshot(prices.map { symbol, price in
        var state = SymbolSnapshot(symbol: displayTicker(symbol))
        state.quote = regularQuote(price, at: nyTime("10:00:15"), symbol: symbol)
        state.isStale = false
        return state
    })
}

@Test func theFirstPriceIsNoChange() {
    var changes = PriceChanges()
    changes.record(snapshot(["SPY": 740.43]))
    #expect(changes[displayTicker("SPY")] == nil)
}

@Test func eachSymbolKeepsItsLastChangeUntilItsPriceChangesAgain() {
    var changes = PriceChanges()
    changes.record(snapshot(["SPY": 740.43, "QQQ": 500.00]))
    changes.record(snapshot(["SPY": 741.12, "QQQ": 499.50]))
    // The same prices again, and then a price that displays the same: the colours stay.
    changes.record(snapshot(["SPY": 741.12, "QQQ": 499.50]))
    changes.record(snapshot(["SPY": 741.121]))
    #expect(changes[displayTicker("SPY")] == PriceChange(from: 740.43, to: 741.12))
    #expect(changes[displayTicker("QQQ")] == PriceChange(from: 500, to: 499.5))
    // The next change replaces it, compared with the price before it.
    changes.record(snapshot(["SPY": 740.41]))
    #expect(changes[displayTicker("SPY")] == PriceChange(from: 741.12, to: 740.41))
}

@Test func aSymbolWithoutAQuoteKeepsWhatItHad() {
    var changes = PriceChanges()
    changes.record(snapshot(["SPY": 740.43]))
    changes.record(snapshot(["SPY": 741.12]))
    changes.record(displaySnapshot([SymbolSnapshot(symbol: displayTicker("SPY"))]))
    #expect(changes[displayTicker("SPY")] == PriceChange(from: 740.43, to: 741.12))
}

// MARK: What the menu bar shows

private func status(
    _ snapshot: MonitorSnapshot, changes: PriceChanges, showing symbol: String? = nil,
    now: Date = nyTime("10:00:20")
) -> MenuBarStatus {
    var settings = UserSettings()
    settings.watchlist = displayWatchlist(["SPY", "QQQ"])
    return MenuBarStatus(
        settings: settings, snapshot: snapshot, now: now, showing: symbol.map(displayTicker), changes: changes)
}

/// SPY at 740.43 then at `price`, as the menu bar remembers it.
private func changes(to price: Double) -> PriceChanges {
    var changes = PriceChanges()
    changes.record(snapshot(["SPY": 740.43]))
    changes.record(snapshot(["SPY": price]))
    return changes
}

@Test func theMenuBarShowsTheSymbolAndPriceOnlyWithItsChangeColoured() {
    let up = status(snapshot(["SPY": 741.12]), changes: changes(to: 741.12))
    #expect(up.title == "SPY 741.12")
    #expect(up.segments == [.init("SPY 74", .normal), .init("1.12", .up)])
    #expect(up.accessibilityValue == "SPY 741.12. Quote 5 s old. Last change: up from 740.43.")

    let down = status(snapshot(["SPY": 739.81]), changes: changes(to: 739.81))
    #expect(down.segments == [.init("SPY 7", .normal), .init("39.81", .down)])
    #expect(down.accessibilityValue == "SPY 739.81. Quote 5 s old. Last change: down from 740.43.")

    let last = status(snapshot(["SPY": 740.41]), changes: changes(to: 740.41))
    #expect(last.segments == [.init("SPY 740.4", .normal), .init("1", .down)])
}

@Test func aWholeNewNumberIsAllColoured() {
    var changes = PriceChanges()
    changes.record(snapshot(["SPY": 99.98]))
    changes.record(snapshot(["SPY": 100.02]))
    let shown = status(snapshot(["SPY": 100.02]), changes: changes)
    #expect(shown.segments == [.init("SPY ", .normal), .init("100.02", .up)])
}

@Test func beforeItsFirstChangeAPriceIsInTheMenuBarsOwnColour() {
    let shown = status(snapshot(["SPY": 740.43]), changes: PriceChanges())
    #expect(shown.segments == [.init("SPY 740.43", .normal)])
    #expect(shown.accessibilityValue == "SPY 740.43. Quote 5 s old.")
}

@Test func eachSymbolShowsItsOwnLastChangeWhenItsTurnComes() {
    var changes = PriceChanges()
    changes.record(snapshot(["SPY": 740.43, "QQQ": 480.25]))
    changes.record(snapshot(["SPY": 741.12, "QQQ": 479.80]))
    let now = snapshot(["SPY": 741.12, "QQQ": 479.80])
    #expect(status(now, changes: changes, showing: "SPY").segments == [.init("SPY 74", .normal), .init("1.12", .up)])
    #expect(status(now, changes: changes, showing: "QQQ").segments == [.init("QQQ 4", .normal), .init("79.80", .down)])
}

@Test func aStaleOrClosedPriceIsDimmedNeverGreenOrRed() {
    var stale = snapshot(["SPY": 741.12])
    stale.symbols[displayTicker("SPY")]?.isStale = true
    let staleShown = status(stale, changes: changes(to: 741.12), now: nyTime("10:05:15"))
    #expect(staleShown.segments == [.init("SPY 741.12", .dimmed)])
    #expect(staleShown.indicator == .stale)
    #expect(staleShown.accessibilityValue == "SPY 741.12: the quote is 5 min old, too old to alert on.")

    var closed = snapshot(["SPY": 741.12])
    closed.diagnostics.marketState = .afterHours
    let closedShown = status(closed, changes: changes(to: 741.12), now: nyTime("17:00:00"))
    #expect(closedShown.segments == [.init("SPY 741.12", .dimmed)])
    #expect(closedShown.accessibilityValue == "SPY 741.12, the last regular-session price. The market is closed, "
        + "so nothing alerts. Quote 6 h old.")
}

// The user picked "slightly dimmed": the menu bar's own text colour at about 75% opacity, softer
// than a live price but still easy to read, and never green or red.
@Test func aDimmedPriceIsTheMenuBarsTextColourSlightlySoftened() {
    #expect(MenuBarStatus.Tone.dimmed.ink == .label(opacity: 0.75))
    #expect(MenuBarStatus.Tone.normal.ink == .label(opacity: 1))
    #expect(MenuBarStatus.Tone.up.ink == .green)
    #expect(MenuBarStatus.Tone.down.ink == .red)
}

// A colouring kept from another price isn't put on this one.
@Test func aChangeToAnotherPriceIsntShown() {
    let shown = status(snapshot(["SPY": 745.00]), changes: changes(to: 741.12))
    #expect(shown.segments == [.init("SPY 745.00", .normal)])
}

// MARK: Cycling

private func cycleSettings(
    _ symbols: [String], disabled: Set<String> = [], pinned: Set<String> = [], menuBar: String? = nil,
    every interval: TimeInterval? = 5
) -> UserSettings {
    var settings = UserSettings()
    settings.watchlist = displayWatchlist(symbols, disabled: disabled, pinned: pinned)
    if let menuBar { try! settings.watchlist.showInMenuBar(displayTicker(menuBar)) }
    settings.menuBarCycle = interval
    return settings
}

@Test func aFreshInstallCyclesEveryFiveSeconds() {
    #expect(UserSettings.defaults.menuBarCycle == 5)
    #expect(MenuBarCycle.intervals == [nil, 3, 5, 10])
    #expect(MenuBarCycle.intervals(current: 5) == [nil, 3, 5, 10])
    #expect(MenuBarCycle.intervals(current: nil) == [nil, 3, 5, 10])
    // A hand-edited file's interval is among the choices.
    #expect(MenuBarCycle.intervals(current: 7) == [nil, 3, 5, 7, 10])
}

@Test func itCyclesThroughTheEnabledSymbolsInTheWatchlistsOrder() {
    let settings = cycleSettings(["SPY", "QQQ", "DIA", "IWM"], disabled: ["DIA"], pinned: ["IWM"], menuBar: "QQQ")
    #expect(MenuBarCycle.symbols(settings).map(\.rawValue) == ["IWM", "SPY", "QQQ"])
    // It starts at the menu-bar symbol, and goes round.
    let first = MenuBarCycle.current(nil, settings: settings)
    #expect(first == displayTicker("QQQ"))
    let second = MenuBarCycle.next(after: first, settings: settings)
    #expect(second == displayTicker("IWM"))
    #expect(MenuBarCycle.next(after: second, settings: settings) == displayTicker("SPY"))
}

@Test func aSymbolThatLeftTheCycleIsReplacedByTheMenuBarSymbol() {
    let settings = cycleSettings(["SPY", "QQQ", "DIA"], disabled: ["DIA"], menuBar: "QQQ")
    #expect(MenuBarCycle.current(displayTicker("DIA"), settings: settings) == displayTicker("QQQ"))
    #expect(MenuBarCycle.next(after: displayTicker("DIA"), settings: settings) == displayTicker("SPY"))
}

// Picking a turned-off symbol in the popover or the dashboard shows it (`QQQ off`) until the
// next turn, which goes on to the first enabled symbol.
@Test func aPickedSymbolThatsOffShowsUntilTheNextTurn() {
    let settings = cycleSettings(["SPY", "QQQ", "DIA"], disabled: ["QQQ"], menuBar: "QQQ")
    #expect(MenuBarCycle.current(displayTicker("QQQ"), settings: settings) == displayTicker("QQQ"))
    #expect(MenuBarCycle.next(after: displayTicker("QQQ"), settings: settings) == displayTicker("SPY"))
}

// Each turn lasts the interval from when it started, a picked symbol's too.
@Test func aTurnLastsTheIntervalFromWhenItStarted() {
    let settings = cycleSettings(["SPY", "QQQ"])
    #expect(MenuBarCycle.untilNextTurn(shownFor: 0, settings: settings) == 5)
    #expect(MenuBarCycle.untilNextTurn(shownFor: 4.9, settings: settings)! > 0)
    #expect(MenuBarCycle.untilNextTurn(shownFor: 5, settings: settings)! <= 0)
    #expect(MenuBarCycle.untilNextTurn(shownFor: 5, settings: cycleSettings(["SPY"], every: nil)) == nil)
}

@Test func withCyclingOffOnlyTheMenuBarSymbolShows() {
    let settings = cycleSettings(["SPY", "QQQ"], menuBar: "QQQ", every: nil)
    #expect(MenuBarCycle.symbols(settings) == [displayTicker("QQQ")])
    #expect(MenuBarCycle.current(displayTicker("SPY"), settings: settings) == displayTicker("QQQ"))
    #expect(MenuBarCycle.next(after: displayTicker("QQQ"), settings: settings) == displayTicker("QQQ"))
}

@Test func withNothingEnabledTheMenuBarSymbolShowsThatItsOff() {
    let settings = cycleSettings(["SPY"], disabled: ["SPY"])
    #expect(MenuBarCycle.symbols(settings) == [displayTicker("SPY")])
}

@Test func anEmptyWatchlistHasNothingToCycle() {
    let settings = cycleSettings([])
    #expect(MenuBarCycle.symbols(settings).isEmpty)
    #expect(MenuBarCycle.current(nil, settings: settings) == nil)
    #expect(MenuBarCycle.next(after: nil, settings: settings) == nil)
}
