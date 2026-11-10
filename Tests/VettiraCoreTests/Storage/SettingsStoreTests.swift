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
    settings.menuBarCycle = 10
    settings.monitorSettings = try MonitorSettings(interval: 60)
    try settings.setStaleTolerance(120)
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
        #expect(loaded.monitorSettings.interval == 60)
        #expect(loaded.alertSettings.staleTolerance == 120)
    }
}

/// Each edit the dashboard and Settings make, on a watchlist of SPY, QQQ and DIA.
private let edits: [(name: String, edit: @Sendable (inout UserSettings) throws -> Void)] = [
    ("add", { try $0.watchlist.add(ticker("brk.b")) }),
    ("remove", { try $0.watchlist.remove(ticker("QQQ")) }),
    ("drag", { $0.watchlist.move(fromOffsets: [2], toOffset: 0) }),
    ("move up", { try $0.watchlist.move(ticker("DIA"), by: -1) }),
    ("pin", { try $0.watchlist.setPinned(true, for: ticker("DIA")) }),
    ("disable", { try $0.watchlist.setEnabled(false, for: ticker("SPY")) }),
    ("own thresholds", { try $0.watchlist.setThresholds(PullbackThresholds(early: 1, strong: 2), for: ticker("QQQ")) }),
    ("menu-bar symbol", { try $0.watchlist.showInMenuBar(ticker("DIA")) }),
    ("default thresholds", { $0.defaultThresholds = try PullbackThresholds(early: 0.5, strong: 1.5) }),
    ("update interval", { $0.monitorSettings = try MonitorSettings(interval: 300) }),
    ("staleness tolerance", { try $0.setStaleTolerance(900) }),
    ("alert sound", { $0.notificationSound = false }),
    ("menu-bar cycle", { $0.menuBarCycle = 3 }),
    ("menu-bar cycle off", { $0.menuBarCycle = nil }),
]

@Test(arguments: edits.map(\.name))
func eachEditIsThereAfterARelaunch(name: String) throws {
    try withStore { store in
        var settings = UserSettings()
        for symbol in ["SPY", "QQQ", "DIA"] { try settings.watchlist.add(ticker(symbol)) }
        try store.save(settings)
        let before = settings

        try edits.first { $0.name == name }!.edit(&settings)
        #expect(settings != before)
        try store.save(settings)

        // A relaunch: a new store on the same directory.
        #expect(try SettingsStore(directory: store.directory).load() == settings)
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
        #expect(settings.menuBarCycle == 5)
        #expect(settings.watchlist.entries.map(\.symbol.rawValue) == ["SPY", "QQQ"])
        #expect(settings.watchlist.menuBarSymbol == ticker("SPY"))
        #expect(settings.watchlist.entry(for: ticker("SPY"))?.isEnabled == true)
        #expect(settings.watchlist.entry(for: ticker("QQQ"))?.isPinned == true)
        #expect(settings.monitorSettings == .standard)
        #expect(settings.alertSettings == .standard)
    }
}

@Test(arguments: [
    "not json",
    #"{"watchlist": {"entries": [{"symbol": "S P Y"}]}}"#,
    #"{"watchlist": {"entries": [{"symbol": "SPY"}, {"symbol": "spy"}]}}"#,
    #"{"watchlist": {"entries": [{"symbol": "SPY"}], "menuBarSymbol": "QQQ"}}"#,
    #"{"defaultThresholds": {"early": 0.4, "strong": 0.25}}"#,
    #"{"updateInterval": 5}"#,
    #"{"staleTolerance": 0}"#,
    #"{"menuBarCycle": 0.5}"#,
    #"{"menuBarCycle": 120}"#,
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

// The file format: the update interval and the staleness tolerance in seconds, and none of the
// alert engine's other settings, which aren't the user's.
@Test func theFileHoldsTheIntervalAndToleranceInSeconds() throws {
    try withStore { store in
        var settings = UserSettings()
        settings.monitorSettings = try MonitorSettings(interval: 30)
        try settings.setStaleTolerance(90)
        try store.save(settings)

        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(json["updateInterval"] as? Double == 30)
        #expect(json["staleTolerance"] as? Double == 90)
        #expect(Set(json.keys) == [
            "watchlist", "defaultThresholds", "notificationSound", "updateInterval", "staleTolerance",
            "menuBarCycle",
        ])
        #expect(json["menuBarCycle"] as? Double == 5)
    }
}

// The file holds the menu bar's cycle in seconds, 0 for off.
@Test func cyclingOffIsSavedAsZero() throws {
    try withStore { store in
        var settings = UserSettings()
        settings.menuBarCycle = nil
        try store.save(settings)
        let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        #expect(json["menuBarCycle"] as? Double == 0)
        #expect(try store.load().menuBarCycle == nil)
    }
}

// The menu bar no longer has a chart: a file from before still loads, cycling at the default.
@Test func aFileWithTheOldChartSettingStillLoads() throws {
    try withStore { store in
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(#"{"watchlist": {"entries": [{"symbol": "SPY"}]}, "showChartInMenuBar": false}"#.utf8)
            .write(to: store.fileURL)
        let settings = try store.load()
        #expect(settings.watchlist.entries.map(\.symbol.rawValue) == ["SPY"])
        #expect(settings.menuBarCycle == 5)
    }
}
