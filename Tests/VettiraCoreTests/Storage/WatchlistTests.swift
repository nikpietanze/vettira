import Foundation
import Testing
import VettiraCore

private func ticker(_ symbol: String) -> TickerSymbol { try! TickerSymbol(symbol) }

private func watchlist(_ symbols: String...) throws -> Watchlist {
    var list = Watchlist()
    for symbol in symbols { try list.add(ticker(symbol)) }
    return list
}

private func symbols(_ entries: [WatchlistEntry]) -> [String] { entries.map(\.symbol.rawValue) }

@Test func aNewWatchlistIsEmpty() {
    #expect(Watchlist().entries.isEmpty)
    #expect(Watchlist().menuBarSymbol == nil)
}

@Test func addingAppendsEnabledUnpinnedOnTheDefaults() throws {
    let list = try watchlist("SPY", "QQQ")
    #expect(symbols(list.entries) == ["SPY", "QQQ"])
    let entry = try #require(list.entry(for: ticker("QQQ")))
    #expect(entry.isEnabled)
    #expect(!entry.isPinned)
    #expect(entry.thresholds == nil)
}

@Test func theFirstSymbolAddedIsTheMenuBars() throws {
    #expect(try watchlist("SPY", "QQQ").menuBarSymbol == ticker("SPY"))
}

@Test func aSymbolIsOnTheListOnce() throws {
    var list = try watchlist("SPY")
    #expect(throws: WatchlistError.alreadyInList(ticker("SPY"))) { try list.add(ticker("spy")) }
    #expect(symbols(list.entries) == ["SPY"])
}

@Test func removingTakesTheSymbolOff() throws {
    var list = try watchlist("SPY", "QQQ", "DIA")
    try list.remove(ticker("QQQ"))
    #expect(symbols(list.entries) == ["SPY", "DIA"])
    #expect(list.menuBarSymbol == ticker("SPY"))
    #expect(throws: WatchlistError.notInList(ticker("QQQ"))) { try list.remove(ticker("QQQ")) }
}

@Test func removingTheMenuBarSymbolShowsTheFirstLeft() throws {
    var list = try watchlist("SPY", "QQQ", "DIA")
    try list.showInMenuBar(ticker("QQQ"))
    try list.remove(ticker("QQQ"))
    #expect(list.menuBarSymbol == ticker("SPY"))
    try list.remove(ticker("SPY"))
    #expect(list.menuBarSymbol == ticker("DIA"))
    try list.remove(ticker("DIA"))
    #expect(list.menuBarSymbol == nil)
}

@Test func theMenuBarShowsOnlyASymbolOnTheList() throws {
    var list = try watchlist("SPY", "QQQ")
    try list.showInMenuBar(ticker("QQQ"))
    #expect(list.menuBarSymbol == ticker("QQQ"))
    #expect(throws: WatchlistError.notInList(ticker("DIA"))) { try list.showInMenuBar(ticker("DIA")) }
    #expect(list.menuBarSymbol == ticker("QQQ"))
}

// The same moves SwiftUI's onMove reports for a drag in a list of A B C D.
private let drags: [(source: [Int], destination: Int, expected: [String])] = [
    ([0], 3, ["B", "C", "A", "D"]), ([0], 4, ["B", "C", "D", "A"]), ([3], 0, ["D", "A", "B", "C"]),
    ([1], 1, ["A", "B", "C", "D"]), ([1], 2, ["A", "B", "C", "D"]), ([0, 2], 4, ["B", "D", "A", "C"]),
    ([1, 3], 0, ["B", "D", "A", "C"]),
]

@Test(arguments: drags)
func reorderingMovesEntriesWhereTheyWereDropped(source: [Int], destination: Int, expected: [String]) throws {
    var list = try watchlist("A", "B", "C", "D")
    list.move(fromOffsets: IndexSet(source), toOffset: destination)
    #expect(symbols(list.entries) == expected)
}

// A B C D with C pinned lists C A B D: a drag's offsets are into that order.
private let pinnedDrags: [(source: [Int], destination: Int, expected: [String])] = [
    ([3], 1, ["C", "D", "A", "B"]),
    ([2], 1, ["C", "B", "A", "D"]),
    // A pinned symbol dropped among the others stays last of the pinned, and the other way round.
    ([0], 4, ["C", "A", "B", "D"]),
    ([3], 0, ["C", "D", "A", "B"]),
]

@Test(arguments: pinnedDrags)
func aDragWithPinnedSymbolsMovesThemAsListed(source: [Int], destination: Int, expected: [String]) throws {
    var list = try watchlist("A", "B", "C", "D")
    try list.setPinned(true, for: ticker("C"))
    list.move(fromOffsets: IndexSet(source), toOffset: destination)
    #expect(symbols(list.displayOrder) == expected)
    #expect(list.entry(for: ticker("C"))?.isPinned == true)
}

@Test func moveUpAndDownGoOnePlaceAsListed() throws {
    var list = try watchlist("A", "B", "C", "D")
    try list.move(ticker("C"), by: -1)
    #expect(symbols(list.displayOrder) == ["A", "C", "B", "D"])
    try list.move(ticker("A"), by: 1)
    #expect(symbols(list.displayOrder) == ["C", "A", "B", "D"])
    try list.move(ticker("D"), by: -3)
    #expect(symbols(list.displayOrder) == ["D", "C", "A", "B"])
}

@Test func movingPastEitherEndOfItsGroupStopsThere() throws {
    var list = try watchlist("A", "B", "C", "D")
    try list.setPinned(true, for: ticker("C"))
    try list.setPinned(true, for: ticker("D"))
    // Listed C D A B: C and D move only between themselves, A and B only between themselves.
    try list.move(ticker("C"), by: -1)
    try list.move(ticker("D"), by: 1)
    try list.move(ticker("A"), by: -1)
    try list.move(ticker("B"), by: 5)
    #expect(symbols(list.displayOrder) == ["C", "D", "A", "B"])
    try list.move(ticker("A"), by: 1)
    #expect(symbols(list.displayOrder) == ["C", "D", "B", "A"])
    #expect(throws: WatchlistError.notInList(ticker("QQQ"))) { try list.move(ticker("QQQ"), by: 1) }
}

@Test func pinnedSymbolsListFirstInTheirOrder() throws {
    var list = try watchlist("A", "B", "C", "D")
    try list.setPinned(true, for: ticker("D"))
    try list.setPinned(true, for: ticker("B"))
    #expect(symbols(list.displayOrder) == ["B", "D", "A", "C"])
    try list.setPinned(false, for: ticker("B"))
    #expect(symbols(list.displayOrder) == ["D", "A", "B", "C"])
    #expect(symbols(list.entries) == ["A", "B", "C", "D"])
}

@Test func aSymbolCanBeDisabledAndEnabled() throws {
    var list = try watchlist("SPY")
    try list.setEnabled(false, for: ticker("SPY"))
    #expect(list.entry(for: ticker("SPY"))?.isEnabled == false)
    try list.setEnabled(true, for: ticker("SPY"))
    #expect(list.entry(for: ticker("SPY"))?.isEnabled == true)
    #expect(throws: WatchlistError.notInList(ticker("QQQ"))) { try list.setEnabled(false, for: ticker("QQQ")) }
}

@Test func aSymbolUsesItsOwnThresholdsOrTheDefaults() throws {
    var settings = UserSettings()
    settings.watchlist = try watchlist("SPY", "QQQ")
    let own = try PullbackThresholds(early: 0.5, strong: 1)
    try settings.watchlist.setThresholds(own, for: ticker("QQQ"))
    #expect(settings.thresholds(for: ticker("QQQ")) == own)
    #expect(settings.thresholds(for: ticker("SPY")) == .standard)

    settings.defaultThresholds = try PullbackThresholds(early: 0.2, strong: 0.3)
    #expect(settings.thresholds(for: ticker("SPY")) == settings.defaultThresholds)
    #expect(settings.thresholds(for: ticker("QQQ")) == own)
    #expect(settings.thresholds(for: ticker("DIA")) == nil)

    try settings.watchlist.setThresholds(nil, for: ticker("QQQ"))
    #expect(settings.thresholds(for: ticker("QQQ")) == settings.defaultThresholds)
}
