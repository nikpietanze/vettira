import Foundation
import Testing
import VettiraCore

/// A store in a new temporary directory, removed when the test ends.
private func withStore(_ body: (SettingsStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "vettira-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(SettingsStore(directory: directory.appending(path: "Vettira")))
}

private func ticker(_ symbol: String) -> TickerSymbol { try! TickerSymbol(symbol) }

private func edited() throws -> UserSettings {
    var settings = UserSettings()
    for symbol in ["SPY", "QQQ", "BRK.B", "DIA"] { try settings.watchlist.add(ticker(symbol)) }
    settings.watchlist.move(fromOffsets: [3], toOffset: 1)
    try settings.watchlist.setPinned(true, for: ticker("QQQ"))
    try settings.watchlist.setEnabled(false, for: ticker("BRK.B"))
    try settings.watchlist.setThresholds(PullbackThresholds(early: 0.5, strong: 0.75), for: ticker("SPY"))
    try settings.watchlist.showInMenuBar(ticker("DIA"))
    settings.defaultThresholds = try PullbackThresholds(early: 0.3, strong: 0.6)
    settings.notificationSound = false
    return settings
}

@Test func withNothingSavedTheDefaultsLoad() throws {
    try withStore { store in
        let settings = try store.load()
        #expect(settings == .defaults)
        #expect(settings.watchlist.entries.isEmpty)
        #expect(settings.defaultThresholds == .standard)
    }
}

@Test func savedSettingsLoadTheSame() throws {
    try withStore { store in
        let settings = try edited()
        try store.save(settings)
        let loaded = try store.load()
        #expect(loaded == settings)
        #expect(loaded.watchlist.entries.map(\.symbol.rawValue) == ["SPY", "DIA", "QQQ", "BRK.B"])
        #expect(loaded.watchlist.menuBarSymbol == ticker("DIA"))
    }
}

@Test func savingAgainReplacesTheFile() throws {
    try withStore { store in
        var settings = try edited()
        try store.save(settings)
        try settings.watchlist.remove(ticker("QQQ"))
        try store.save(settings)
        try store.save(settings)
        #expect(try store.load() == settings)
    }
}

@Test func theFileIsInTheStoresDirectory() throws {
    try withStore { store in
        try store.save(.defaults)
        #expect(FileManager.default.fileExists(atPath: store.directory.appending(path: "settings.json").path))
    }
}

@Test func theAppsStoreIsInApplicationSupport() throws {
    let store = try SettingsStore.applicationSupport()
    #expect(store.fileURL.path.hasSuffix("/Library/Application Support/Vettira/settings.json"))
}

// The file format: a file written this way loads, and a field it doesn't have gets its default.
@Test func aFileMissingFieldsLoadsWithTheirDefaults() throws {
    try withStore { store in
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"watchlist": {"entries": [{"symbol": "spy"}, {"symbol": "QQQ", "isPinned": true}]}}"#.utf8)
            .write(to: store.fileURL)
        let settings = try store.load()
        #expect(settings.defaultThresholds == .standard)
        #expect(settings.notificationSound)
        #expect(settings.watchlist.entries.map(\.symbol.rawValue) == ["SPY", "QQQ"])
        #expect(settings.watchlist.menuBarSymbol == ticker("SPY"))
        #expect(settings.watchlist.entry(for: ticker("SPY"))?.isEnabled == true)
        #expect(settings.watchlist.entry(for: ticker("QQQ"))?.isPinned == true)
    }
}

@Test(arguments: [
    "not json",
    #"{"watchlist": {"entries": [{"symbol": "S P Y"}]}}"#,
    #"{"watchlist": {"entries": [{"symbol": "SPY"}, {"symbol": "spy"}]}}"#,
    #"{"watchlist": {"entries": [{"symbol": "SPY"}], "menuBarSymbol": "QQQ"}}"#,
    #"{"defaultThresholds": {"early": 0.4, "strong": 0.25}}"#,
])
func aCorruptFileIsMovedAsideAndTheDefaultsLoad(contents: String) throws {
    try withStore { store in
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("an older corrupt file".utf8).write(to: store.corruptFileURL)
        try Data(contents.utf8).write(to: store.fileURL)

        #expect(throws: SettingsStoreError.corrupt(movedTo: store.corruptFileURL)) { try store.load() }
        #expect(try String(contentsOf: store.corruptFileURL, encoding: .utf8) == contents)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(try store.load() == .defaults)
    }
}

@Test func theFirstCorruptFileIsMovedAsideToo() throws {
    try withStore { store in
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: store.fileURL)

        #expect(throws: SettingsStoreError.corrupt(movedTo: store.corruptFileURL)) { try store.load() }
        #expect(try String(contentsOf: store.corruptFileURL, encoding: .utf8) == "not json")
        #expect(try store.load() == .defaults)
    }
}
