import Foundation

/// The update intervals and staleness tolerances Settings offers, and what it says when the two
/// don't fit together.
public enum SettingsChoices {
    public struct Choice: Hashable, Sendable, Identifiable {
        /// In seconds.
        public let seconds: TimeInterval
        /// `15 s`, `1 min`, `1 h`.
        public let label: String
        public var id: TimeInterval { seconds }

        init(_ seconds: TimeInterval) {
            self.seconds = seconds
            label = DisplayFormat.duration(seconds)
        }
    }

    /// From 10 seconds to an hour, `MonitorSettings`' range.
    static let updateIntervals: [TimeInterval] = [10, 15, 30, 60, 120, 300, 600, 900, 1800, 3600]
    static let staleTolerances: [TimeInterval] = [30, 60, 120, 300, 600, 900, 1800, 3600]

    /// The update intervals to choose from, with `current` among them even when it isn't one of
    /// the usual ones (a hand-edited settings file).
    public static func updateIntervals(current: TimeInterval) -> [Choice] {
        choices(updateIntervals, current: current)
    }

    /// The staleness tolerances to choose from, with `current` among them.
    public static func staleTolerances(current: TimeInterval) -> [Choice] {
        choices(staleTolerances, current: current)
    }

    /// A warning when quotes would turn stale between updates: a tolerance shorter than the
    /// update interval.
    public static func toleranceNote(for settings: UserSettings) -> String? {
        let interval = settings.monitorSettings.interval
        let tolerance = settings.alertSettings.staleTolerance
        guard tolerance < interval else { return nil }
        return "Quotes turn stale between updates: they're stale after \(DisplayFormat.duration(tolerance)), "
            + "and updates come every \(DisplayFormat.duration(interval))."
    }

    private static func choices(_ usual: [TimeInterval], current: TimeInterval) -> [Choice] {
        Set(usual + [current]).sorted().map(Choice.init)
    }
}
