import Foundation
import Testing
import VettiraCore

// The saved alert state is a cache: a missing file is an empty state, and a file that can't be
// used (not JSON, not the engine's state, or another format version) throws, for the app to log
// and start afresh, and the next save replaces it.

/// A store in a new temporary directory, removed when the test ends.
func withAlertStateStore(_ body: (AlertStateStore) throws -> Void) throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "vettira-tests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(AlertStateStore(directory: directory.appending(path: "Vettira")))
}

private func at(_ time: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.date(from: "2026-11-10T\(time)-05:00")!
}

/// An engine's state after SPY's early warning, with quote times to the millisecond.
private func stateAfterAnAlert() -> ReversalAlertEngine.State {
    var engine = ReversalAlertEngine()
    for (price, time) in [(100.0, "10:00:00.125"), (99.7, "10:00:15.250")] {
        let quote = Quote(symbol: "SPY", price: price, timestamp: at(time), source: "Test provider", session: .regular)
        _ = engine.evaluate(quote, thresholds: .standard, now: at(time) + 2)
    }
    return engine.state
}

@Test func withNothingSavedTheStateIsEmpty() throws {
    try withAlertStateStore { store in
        let loaded1 = try store.load()
        #expect(loaded1 == ReversalAlertEngine.State())
    }
}

@Test func aSavedStateLoadsTheSame() throws {
    try withAlertStateStore { store in
        let state = stateAfterAnAlert()
        #expect(state.trackedSymbols == ["SPY"])
        try store.save(state)
        #expect(FileManager.default.fileExists(atPath: store.directory.appending(path: "alert-state.json").path))
        let loaded2 = try store.load()
        #expect(loaded2 == state)
    }
}

@Test(arguments: ["", "not json", "{\"version\": 1}", "{\"version\": 1, \"state\": {\"symbols\": 3}}", "[]"])
func aFileThatIsNotValidStateThrowsAndTheNextSaveReplacesIt(contents: String) throws {
    try withAlertStateStore { store in
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: store.fileURL)
        #expect(throws: AlertStateStoreError.corrupt(store.fileURL)) { try store.load() }

        let state = stateAfterAnAlert()
        try store.save(state)
        let loaded3 = try store.load()
        #expect(loaded3 == state)
    }
}

@Test func aFileSavedBeforeBarsCountedStillLoads() throws {
    // A state whose high came from a bar, saved without the bars' high, as a file from before
    // bars counted is: it's still version 1, and loads with the quotes' high.
    var engine = ReversalAlertEngine()
    let bars = [PriceBar(timestamp: at("10:00:00.000"), close: 99.9, high: 100.5),
                PriceBar(timestamp: at("10:05:00.000"), close: 99.9, high: 99.95)]
    let quote = Quote(symbol: "SPY", price: 100, timestamp: at("10:07:00.000"), source: "Test provider",
                      session: .regular, intraday: bars)
    _ = engine.evaluate(quote, thresholds: .standard, now: at("10:07:02.000"))
    try withAlertStateStore { store in
        try store.save(engine.state)
        let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL))
        let old = removingKey("barHigh", from: saved)
        #expect(String(decoding: try JSONSerialization.data(withJSONObject: saved), as: UTF8.self).contains("\"barHigh\""))
        try JSONSerialization.data(withJSONObject: old).write(to: store.fileURL)

        var relaunched = ReversalAlertEngine(state: try store.load())
        let next = Quote(symbol: "SPY", price: 99.8, timestamp: at("10:07:30.000"), source: "Test provider",
                         session: .regular)
        guard case .accepted(let high, _, let alert) = relaunched.evaluate(
            next, thresholds: .standard, now: at("10:07:32.000")) else {
            Issue.record("The quote after loading was rejected")
            return
        }
        #expect(high == SessionHigh(price: 100, kind: .observed))
        #expect(alert == nil)
    }
}

/// `json` without `key` in any object, at any depth.
private func removingKey(_ key: String, from json: Any) -> Any {
    if let object = json as? [String: Any] {
        return object.filter { $0.key != key }.mapValues { removingKey(key, from: $0) }
    }
    if let array = json as? [Any] {
        return array.map { removingKey(key, from: $0) }
    }
    return json
}

@Test func aFileOfAnotherVersionThrows() throws {
    try withAlertStateStore { store in
        try store.save(stateAfterAnAlert())
        var json = try String(contentsOf: store.fileURL, encoding: .utf8)
        json = json.replacingOccurrences(of: "\"version\" : 1", with: "\"version\" : 2")
        try Data(json.utf8).write(to: store.fileURL)
        #expect(throws: AlertStateStoreError.unsupportedVersion(2, store.fileURL)) { try store.load() }
    }
}

@Test func aFileThatCanNotBeReadThrows() throws {
    try withAlertStateStore { store in
        // A directory where the file should be.
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        do throws(AlertStateStoreError) {
            _ = try store.load()
            Issue.record("A file that can't be read loaded")
        } catch {
            guard case .unreadable(let url, _) = error else {
                Issue.record("Expected unreadable, got \(error)")
                return
            }
            #expect(url == store.fileURL)
        }
    }
}
