import Foundation

/// How a Debug run was launched, from its arguments or its environment, whichever names an
/// option. The app reads them only in Debug builds (`launch(_:environment:debugBuild:)`), so a
/// release build always uses Yahoo Finance, the user's own settings and the system's notifications.
///
///     open Vettira.app --args --demo --settings-dir ~/.cache/vettira/check
///     VETTIRA_DEMO=1 VETTIRA_SETTINGS_DIR=~/.cache/vettira/check Vettira.app/Contents/MacOS/Vettira
public struct LaunchOptions: Equatable, Sendable {
    /// `--demo` or `VETTIRA_DEMO=1`: made-up prices from `DemoProvider` instead of Yahoo, on a clock moved into regular
    /// hours, so a run alerts at any time of day and calls no provider.
    public var demo = false
    /// `--settings-dir <path>` or `VETTIRA_SETTINGS_DIR=<path>`: read and write `settings.json` and
    /// `alert-state.json` there, not in `~/Library/Application Support/Vettira/`.
    public var settingsDirectory: URL?
    /// `--notify` or `VETTIRA_NOTIFY=1`: post a demo or scratch run's alerts as real notifications after all.
    public var notify = false
    /// `--snapshot <dir>` or `VETTIRA_SNAPSHOT_DIR=<dir>`: render the app's own views to PNG files in
    /// that directory, offscreen, then quit (`Snapshot`). A snapshot run is always a demo run.
    public var snapshot: Snapshot?

    /// A run that renders its views to PNG files and quits, instead of showing them.
    public struct Snapshot: Equatable, Sendable {
        /// Where the PNG files go.
        public var directory: URL
        /// `--snapshot-after <seconds>` or `VETTIRA_SNAPSHOT_AFTER=<seconds>`: render this long after
        /// launch. Without it, render once every symbol has had its stronger warning, or after
        /// `longestWait`, whichever comes first.
        public var after: TimeInterval?

        /// How long a run waits for the warnings before rendering what it has: the demo's come
        /// about a minute after launch at a 10-second update interval.
        public static let longestWait: TimeInterval = 180

        public init(directory: URL, after: TimeInterval? = nil) {
            self.directory = directory
            self.after = after
        }

        /// Whether it's time to render, `elapsed` seconds after launch, with the monitor's latest
        /// `snapshot`.
        public func isDue(_ snapshot: MonitorSnapshot, elapsed: TimeInterval) -> Bool {
            if let after { return elapsed >= after }
            return elapsed >= Self.longestWait
                || snapshot.symbols.values.allSatisfy { $0.lastAlert?.signal == .strong }
        }
    }

    public init() {}

    /// The options a build uses: those in `arguments` and `environment` in a Debug build
    /// (`debugBuild`), and none in a release build, whatever it was launched with.
    public static func launch(
        _ arguments: [String], environment: [String: String], debugBuild: Bool
    ) -> LaunchOptions {
        debugBuild ? parse(arguments, environment: environment) : LaunchOptions()
    }

    /// The options in `arguments` (the process's, program name first) and `environment`.
    /// Anything else is ignored; a flag variable counts when it's `1`.
    public static func parse(_ arguments: [String], environment: [String: String] = [:]) -> LaunchOptions {
        var options = LaunchOptions()
        options.demo = environment["VETTIRA_DEMO"] == "1"
        options.notify = environment["VETTIRA_NOTIFY"] == "1"
        if let path = environment["VETTIRA_SETTINGS_DIR"], !path.isEmpty {
            options.settingsDirectory = URL(filePath: path, directoryHint: .isDirectory)
        }
        var snapshotPath = environment["VETTIRA_SNAPSHOT_DIR"].flatMap { $0.isEmpty ? nil : $0 }
        var snapshotAfter = environment["VETTIRA_SNAPSHOT_AFTER"].flatMap(seconds)
        var rest = arguments.dropFirst()
        while let argument = rest.popFirst() {
            switch argument {
            case "--demo":
                options.demo = true
            case "--notify":
                options.notify = true
            case "--settings-dir":
                if let path = rest.popFirst() {
                    options.settingsDirectory = URL(filePath: path, directoryHint: .isDirectory)
                }
            case "--snapshot":
                if let path = rest.popFirst() { snapshotPath = path }
            case "--snapshot-after":
                if let value = rest.popFirst() { snapshotAfter = seconds(value) }
            default:
                break
            }
        }
        if let snapshotPath {
            options.snapshot = Snapshot(
                directory: URL(filePath: snapshotPath, directoryHint: .isDirectory), after: snapshotAfter)
            // Its pictures are of made-up prices: a snapshot never calls a provider.
            options.demo = true
        }
        return options
    }

    /// A number of seconds, zero or more, or nil.
    private static func seconds(_ text: String) -> TimeInterval? {
        guard let value = TimeInterval(text), value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// The directory the app reads and writes its files in: the scratch one `--settings-dir`
    /// names, or else `applicationSupport()`, which it then calls.
    public func storageDirectory(applicationSupport: () throws -> URL) rethrows -> URL {
        try settingsDirectory ?? applicationSupport()
    }

    /// Whether the alert engine's state is saved and read back at launch. Not for a demo run
    /// without a scratch directory: its made-up highs would land in the user's own file and hold
    /// back their real alerts.
    public var keepsAlertState: Bool { !demo || settingsDirectory != nil }

    /// Whether the run is a check: a demo or scratch run, which leaves the user's own setup alone.
    public var isCheck: Bool { demo || settingsDirectory != nil }

    /// Where alerts go. A check only logs them, never reaching the screen or asking for
    /// permission, unless it was launched with `--notify`.
    public var notifications: NotificationOutput {
        isCheck && !notify ? .log : .system
    }

    /// Whether windows open where they were last left and save where they're left. A check
    /// neither reads nor saves them, since the frames live in the app's defaults, which the
    /// user's own Vettira shares; its windows open at their first size each launch.
    public var remembersWindowFrames: Bool { !isCheck }
}

/// Where alert notifications go.
public enum NotificationOutput: Equatable, Sendable {
    /// The system's notification center: banners, with permission asked for.
    case system
    /// Only the app's log, as `LogNotificationCenter` writes them.
    case log
}
