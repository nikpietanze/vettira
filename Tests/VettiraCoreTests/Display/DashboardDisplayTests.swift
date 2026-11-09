import Foundation
import Testing
import VettiraCore

// The dashboard's diagnostics (the spec: polling cadence, last received time, errors, source),
// Settings' choices, and when Vettira shows in the Dock: while one of its windows is open.

// MARK: Diagnostics

private func values(_ summary: DiagnosticsSummary) -> [String: String] {
    Dictionary(uniqueKeysWithValues: summary.items.map { ($0.label, $0.value) })
}

@Test func diagnosticsBeforeTheFirstUpdate() {
    let summary = DiagnosticsSummary(
        diagnostics: MonitorDiagnostics(source: "Test provider"), settings: UserSettings(), now: nyTime("10:00:00"),
        timeZone: newYork)
    #expect(summary.items.map(\.label) == [
        "Source", "Update interval", "Stale after", "Last received", "Last update", "Next update", "Last error",
        "Failed updates in a row",
    ])
    #expect(values(summary) == [
        "Source": "Test provider",
        "Update interval": "Every 15 s in regular hours, every 10 min outside them",
        "Stale after": "1 min",
        "Last received": "Nothing yet",
        "Last update": "None yet",
        "Next update": "Starting",
        "Last error": "None",
        "Failed updates in a row": "0",
    ])
}

@Test func diagnosticsWhileFailing() throws {
    var diagnostics = displaySnapshot([]).diagnostics  // polled and received at 10:00:20
    diagnostics.lastPoll = nyTime("10:01:00")
    diagnostics.lastError = .rateLimited(retryAfter: nil)
    diagnostics.consecutiveFailures = 2
    diagnostics.nextPoll = nyTime("10:02:00")
    var settings = UserSettings()
    settings.monitorSettings = try MonitorSettings(interval: 30)
    try settings.setStaleTolerance(120)
    let shown = values(DiagnosticsSummary(diagnostics: diagnostics, settings: settings, now: nyTime("10:01:30"), timeZone: newYork))
    #expect(shown["Update interval"] == "Every 30 s in regular hours, every 10 min outside them")
    #expect(shown["Stale after"] == "2 min")
    #expect(shown["Last received"] == "10:00:20 EST, 1 min ago")
    #expect(shown["Last update"] == "10:01:00 EST")
    #expect(shown["Next update"] == "In 30 s, at 10:02:00 EST")
    #expect(shown["Last error"] == ProviderError.rateLimited(retryAfter: nil).message)
    #expect(shown["Failed updates in a row"] == "2")
}

@Test func anUpdateDueIsNow() {
    var diagnostics = displaySnapshot([]).diagnostics
    diagnostics.nextPoll = nyTime("10:00:30")
    let shown = values(DiagnosticsSummary(diagnostics: diagnostics, settings: UserSettings(), now: nyTime("10:00:30")))
    #expect(shown["Next update"] == "Now")
}

// MARK: Settings' choices

@Test func theUpdateIntervalsRunFromTenSecondsToAnHour() {
    let choices = SettingsChoices.updateIntervals(current: 15)
    #expect(choices.map(\.label) == ["10 s", "15 s", "30 s", "1 min", "2 min", "5 min", "10 min", "15 min", "30 min", "1 h"])
    #expect(choices.allSatisfy { (try? MonitorSettings(interval: $0.seconds)) != nil })
}

@Test func aSavedValueOffTheListIsStillOffered() {
    #expect(SettingsChoices.updateIntervals(current: 45).map(\.seconds).contains(45))
    #expect(SettingsChoices.staleTolerances(current: 90).map(\.seconds) == [30, 60, 90, 120, 300, 600, 900, 1800, 3600])
}

@Test func aToleranceShorterThanTheIntervalIsCalledOut() throws {
    var settings = UserSettings()
    #expect(SettingsChoices.toleranceNote(for: settings) == nil)
    settings.monitorSettings = try MonitorSettings(interval: 300)
    #expect(SettingsChoices.toleranceNote(for: settings)
        == "Quotes turn stale between updates: they're stale after 1 min, and updates come every 5 min.")
}

// MARK: The Dock

@Test func vettiraShowsInTheDockWhileAWindowIsOpen() {
    var dock = DockPresence()
    #expect(!dock.showsInDock)
    let openedDashboard = dock.opened("dashboard")
    #expect(openedDashboard && dock.showsInDock)
    let openedSettings = dock.opened("settings")
    #expect(!openedSettings)
    let closedDashboard = dock.closed("dashboard")
    #expect(!closedDashboard && dock.showsInDock)
    let closedSettings = dock.closed("settings")
    #expect(closedSettings && !dock.showsInDock)
}

@Test func openingOrClosingAWindowTwiceChangesNothing() {
    var dock = DockPresence()
    dock.opened("dashboard")
    let openedAgain = dock.opened("dashboard")
    #expect(!openedAgain)
    dock.closed("dashboard")
    let closedAgain = dock.closed("dashboard")
    #expect(!closedAgain && !dock.showsInDock)
}
