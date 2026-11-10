import Foundation
import Testing
import VettiraCore

// A launch whose settings.json can't be used runs on the defaults, whose watchlist is empty. Its
// first poll would then drop every symbol from the saved alert state, so the alert state is kept
// only when the settings loaded: alert-state.json is left as it is for that run, to be used again
// once the settings are fixed. With good settings, a symbol no longer on the watchlist is dropped
// from it as before (docs/alerts.md, "Saved state").

private func at(_ time: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: "2026-11-10T\(time)-05:00")!
}

private func settings(_ symbols: [String]) throws -> UserSettings {
    var settings = UserSettings()
    for symbol in symbols { try settings.watchlist.add(TickerSymbol(symbol)) }
    return settings
}

/// A storage directory with SPY's and QQQ's alert state saved, removed when the test ends.
private func withSavedAlertState(_ body: (SettingsStore, AlertStateStore) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "vettira-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = SettingsStore(directory: directory)
    let alertStateStore = AlertStateStore(directory: directory)
    var engine = ReversalAlertEngine()
    for symbol in ["SPY", "QQQ"] {
        let quote = Quote(symbol: symbol, price: 100, timestamp: at("10:00:00"), source: "Test provider", session: .regular)
        _ = engine.evaluate(quote, thresholds: .standard, now: at("10:00:02"))
    }
    try alertStateStore.save(engine.state)
    try await body(settingsStore, alertStateStore)
}

/// Launches as the app does from `storage`, and runs the monitor for its first poll.
private func launchAndPollOnce(_ storage: LaunchStorage) async throws {
    let engineState = try storage.alertStateStore?.load() ?? .init()
    let store = storage.alertStateStore
    let clock = MonitorTestClock(at: at("10:01:00"))
    let monitor = QuoteMonitor(
        provider: MockProvider(clock: clock), settings: storage.settings, engineState: engineState,
        clock: clock.monitorClock, saveState: { try? store?.save($0) })
    clock.allow(polls: 1)
    await monitor.run()
}

@Test func aCorruptSettingsFileLeavesTheSavedAlertStateAsItIs() async throws {
    try await withSavedAlertState { settingsStore, alertStateStore in
        let saved = try Data(contentsOf: alertStateStore.fileURL)
        try Data("not json".utf8).write(to: settingsStore.fileURL)

        let storage = LaunchStorage(loading: settingsStore)
        #expect(storage.problem == .corrupt(movedTo: settingsStore.corruptFileURL))
        #expect(storage.settings.watchlist.entries.isEmpty)
        try await launchAndPollOnce(storage)

        let after = try alertStateStore.load()
        #expect(after.trackedSymbols == ["SPY", "QQQ"])
        let file = try Data(contentsOf: alertStateStore.fileURL)
        #expect(file == saved)
    }
}

@Test func goodSettingsDropASymbolNoLongerWatchedFromTheSavedAlertState() async throws {
    try await withSavedAlertState { settingsStore, alertStateStore in
        try settingsStore.save(settings(["SPY"]))

        let storage = LaunchStorage(loading: settingsStore)
        #expect(storage.problem == nil)
        try await launchAndPollOnce(storage)

        let after = try alertStateStore.load()
        #expect(after.trackedSymbols == ["SPY"])
    }
}

@Test func withNoSettingsSavedYetTheAlertStateIsKept() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "vettira-tests-\(UUID().uuidString)")
    let storage = LaunchStorage(loading: SettingsStore(directory: directory))
    #expect(storage.problem == nil)
    #expect(storage.settings == .defaults)
    #expect(storage.settingsStore?.directory == directory)
    #expect(storage.alertStateStore?.directory == directory)
}

@Test func aSettingsFileThatCanNotBeReadIsNeitherSavedOverNorUsedForAlertState() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "vettira-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    let settingsStore = SettingsStore(directory: directory)
    // A directory where the file should be.
    try FileManager.default.createDirectory(at: settingsStore.fileURL, withIntermediateDirectories: true)

    let storage = LaunchStorage(loading: settingsStore)
    guard case .unreadable = storage.problem else {
        Issue.record("Expected unreadable, got \(String(describing: storage.problem))")
        return
    }
    #expect(storage.settingsStore == nil)
    #expect(storage.alertStateStore == nil)
}
