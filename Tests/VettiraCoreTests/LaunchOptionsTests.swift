import Foundation
import Testing
import VettiraCore

// A check run (`--demo`, or a scratch `--settings-dir`) never posts a
// real notification or asks for permission unless it's launched with `--notify`; a plain launch
// uses the system's notifications. A log-only notification keeps its full text, so the wording
// can be checked from the log.

@Test func aPlainLaunchUsesTheSystemsNotifications() {
    let options = LaunchOptions.parse(["Vettira"])
    #expect(options == LaunchOptions())
    #expect(options.notifications == .system)
}

@Test(arguments: [
    ["Vettira", "--demo"],
    ["Vettira", "--settings-dir", "/tmp/check"],
    ["Vettira", "--demo", "--settings-dir", "/tmp/check"],
])
func aCheckRunOnlyLogsItsNotifications(arguments: [String]) {
    #expect(LaunchOptions.parse(arguments).notifications == .log)
}

@Test(arguments: [
    ["Vettira", "--demo"],
    ["Vettira", "--settings-dir", "/tmp/check"],
    ["Vettira", "--demo", "--settings-dir", "/tmp/check", "--notify"],
])
func aCheckRunLeavesTheUsersWindowFramesAlone(arguments: [String]) {
    let options = LaunchOptions.parse(arguments)
    #expect(options.isCheck)
    #expect(!options.remembersWindowFrames)
}

@Test func aPlainLaunchRemembersWhereItsWindowsWere() {
    let options = LaunchOptions.parse(["Vettira"])
    #expect(!options.isCheck)
    #expect(options.remembersWindowFrames)
}

@Test func notifyMakesACheckRunPostRealNotifications() {
    #expect(LaunchOptions.parse(["Vettira", "--demo", "--settings-dir", "/tmp/check", "--notify"]).notifications == .system)
}

@Test func theArgumentsAreRead() {
    let options = LaunchOptions.parse(["Vettira", "-NSDocumentRevisionsDebugMode", "YES", "--settings-dir", "/tmp/check", "--demo"])
    #expect(options.demo)
    #expect(options.settingsDirectory?.path == "/tmp/check")
    #expect(!options.notify)
}

// The verify skill's helper can pass a launch environment but not arguments, so each option has
// a variable too.
@Test func theEnvironmentNamesTheSameOptions() {
    let options = LaunchOptions.parse(
        ["Vettira"], environment: ["VETTIRA_DEMO": "1", "VETTIRA_SETTINGS_DIR": "/tmp/check", "HOME": "/Users/x"])
    #expect(options.demo)
    #expect(options.settingsDirectory?.path == "/tmp/check")
    #expect(options.notifications == .log)
    #expect(LaunchOptions.parse(["Vettira", "--demo"], environment: ["VETTIRA_NOTIFY": "1"]).notifications == .system)
    #expect(LaunchOptions.parse(["Vettira"], environment: ["VETTIRA_DEMO": "0", "VETTIRA_SETTINGS_DIR": ""]) == LaunchOptions())
}

private final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var _lines: [String] = []
    var lines: [String] { lock.withLock { _lines } }
    func append(_ line: String) { lock.withLock { _lines.append(line) } }
}

@Test func theLogNotifierWritesTheWholeNotificationAndNeverAsks() async {
    let written = Lines()
    let delivery = AlertDelivery(center: LogNotificationCenter(write: written.append), timeZone: newYork)
    #expect(await delivery.authorize() == .allowed)
    #expect(await delivery.deliver(earlyWarning(), sound: true) == .delivered)
    #expect(written.lines == [
        "Would notify: SPY: possible reversal, not confirmed | Early warning (0.25% threshold) | "
            + "100.20 is 0.30% below the observed high of 100.50. Quote at 10:00:15 EST, 5 s old, from Test provider. "
            + "(sound on)"
    ])
}

// A check run with a scratch directory reads and writes its files, the alert state among them,
// only there; a demo run without one keeps no alert state, so its made-up highs never reach the
// user's own file.

@Test(arguments: [
    ["Vettira", "--settings-dir", "/tmp/check"],
    ["Vettira", "--demo", "--settings-dir", "/tmp/check"],
])
func aScratchDirectoryHoldsTheAlertStateAndApplicationSupportIsNotUsed(arguments: [String]) {
    let options = LaunchOptions.parse(arguments)
    let directory = options.storageDirectory {
        Issue.record("Application Support was looked up")
        return URL(filePath: "/Users/someone/Library/Application Support/Vettira")
    }
    #expect(directory == URL(filePath: "/tmp/check", directoryHint: .isDirectory))
    #expect(options.keepsAlertState)
    #expect(AlertStateStore(directory: directory).fileURL.path == "/tmp/check/alert-state.json")
}

@Test func aPlainLaunchKeepsItsAlertStateInApplicationSupport() {
    let options = LaunchOptions.parse(["Vettira"])
    let support = URL(filePath: "/Users/someone/Library/Application Support/Vettira", directoryHint: .isDirectory)
    #expect(options.storageDirectory { support } == support)
    #expect(options.keepsAlertState)
}

@Test func aDemoRunWithoutAScratchDirectoryKeepsNoAlertState() {
    #expect(!LaunchOptions.parse(["Vettira", "--demo"]).keepsAlertState)
    #expect(!LaunchOptions.parse(["Vettira"], environment: ["VETTIRA_DEMO": "1"]).keepsAlertState)
}
