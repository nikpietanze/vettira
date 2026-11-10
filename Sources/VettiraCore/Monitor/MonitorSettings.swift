import Foundation

/// How often `QuoteMonitor` polls, and how far it slows down outside regular hours and after
/// errors. Only the update interval is the user's; the rest keep Vettira a light client.
public struct MonitorSettings: Equatable, Sendable {
    /// The defaults: a 15-second update interval.
    public static let standard = MonitorSettings(checkedInterval: 15)

    /// The shortest update interval the user can set, in seconds.
    public static let shortestInterval: TimeInterval = 10
    /// The longest update interval the user can set, in seconds.
    public static let longestInterval: TimeInterval = 3600

    /// The time between the starts of two polls in regular hours, in seconds.
    public let interval: TimeInterval

    /// The time between two polls outside regular hours, in seconds: 10 minutes, or the update
    /// interval when that's longer. A poll in the pre-market waits no later than the open.
    public var closedInterval: TimeInterval { max(interval, 600) }

    /// The time between two polls in regular hours while prices stream, in seconds: a minute, or
    /// the update interval when that's longer. Streamed prices come between them; the polls bring
    /// the day's bars, the previous close and the session high.
    public var streamingInterval: TimeInterval { max(interval, 60) }

    /// The longest backoff after errors, in seconds: 15 minutes, or the update interval when that's
    /// longer. A wait the provider asks for (`Retry-After`) is honoured even when it's longer.
    public var longestBackoff: TimeInterval { max(interval, 900) }

    /// `interval` is from 10 seconds to an hour.
    public init(interval: TimeInterval) throws(MonitorSettingsError) {
        guard interval.isFinite, interval >= Self.shortestInterval, interval <= Self.longestInterval else {
            throw .intervalOutOfRange
        }
        self.init(checkedInterval: interval)
    }

    private init(checkedInterval interval: TimeInterval) {
        self.interval = interval
    }
}

public enum MonitorSettingsError: Error, Equatable, LocalizedError {
    case intervalOutOfRange

    public var errorDescription: String? {
        switch self {
        case .intervalOutOfRange: "The update interval is from 10 seconds to 1 hour."
        }
    }
}
