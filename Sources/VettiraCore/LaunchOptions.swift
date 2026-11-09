import Foundation

/// How a Debug run was launched, from its arguments or its environment, whichever names an
/// option. The app reads them only in Debug builds, so a release build always uses Yahoo Finance,
/// the user's own settings and the system's notifications.
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

    public init() {}

    /// The options in `arguments` (the process's, program name first) and `environment`.
    /// Anything else is ignored; a flag variable counts when it's `1`.
    public static func parse(_ arguments: [String], environment: [String: String] = [:]) -> LaunchOptions {
        var options = LaunchOptions()
        options.demo = environment["VETTIRA_DEMO"] == "1"
        options.notify = environment["VETTIRA_NOTIFY"] == "1"
        if let path = environment["VETTIRA_SETTINGS_DIR"], !path.isEmpty {
            options.settingsDirectory = URL(filePath: path, directoryHint: .isDirectory)
        }
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
            default:
                break
            }
        }
        return options
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
