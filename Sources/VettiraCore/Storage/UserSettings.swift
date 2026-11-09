import Foundation

/// Everything Vettira keeps about the user's setup on disk: the watchlist, the global defaults,
/// how often to update and how old a quote can be.
public struct UserSettings: Equatable, Sendable {
    /// A fresh install: an empty watchlist, the standard thresholds, a 15-second update interval
    /// and a 60-second staleness tolerance.
    public static let defaults = UserSettings()

    public var watchlist = Watchlist()
    /// The thresholds for every symbol that doesn't set its own.
    public var defaultThresholds = PullbackThresholds.standard
    /// Whether an alert's notification plays a sound. On by default.
    public var notificationSound = true
    /// How often the quote monitor updates in regular hours.
    public var monitorSettings = MonitorSettings.standard
    /// How the alert engine judges quotes. Only the staleness tolerance is the user's
    /// (`setStaleTolerance`), and only it is saved; the rest are the standard settings.
    public private(set) var alertSettings = AlertSettings.standard

    public init() {}

    /// The thresholds that apply to the symbol: its own, or the defaults. Nil if it isn't on the
    /// watchlist.
    public func thresholds(for symbol: TickerSymbol) -> PullbackThresholds? {
        watchlist.entry(for: symbol).map { $0.thresholds ?? defaultThresholds }
    }

    /// How old a quote can be, in seconds, before it's stale and never alerts: more than 0.
    public mutating func setStaleTolerance(_ seconds: TimeInterval) throws(AlertSettingsError) {
        alertSettings = try AlertSettings(staleTolerance: seconds)
    }
}

extension UserSettings: Codable {
    private enum CodingKeys: String, CodingKey {
        case watchlist, defaultThresholds, notificationSound, updateInterval, staleTolerance
    }

    // A field an older file doesn't have gets its default. Add new fields the same way. A value
    // out of range fails the decoding, so the file is treated as corrupt.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watchlist = try container.decodeIfPresent(Watchlist.self, forKey: .watchlist) ?? Watchlist()
        defaultThresholds = try container.decodeIfPresent(PullbackThresholds.self, forKey: .defaultThresholds)
            ?? .standard
        notificationSound = try container.decodeIfPresent(Bool.self, forKey: .notificationSound) ?? true
        do {
            if let interval = try container.decodeIfPresent(TimeInterval.self, forKey: .updateInterval) {
                monitorSettings = try MonitorSettings(interval: interval)
            }
        } catch let error as MonitorSettingsError {
            throw DecodingError.dataCorruptedError(
                forKey: .updateInterval, in: container, debugDescription: error.errorDescription ?? "")
        }
        do {
            if let tolerance = try container.decodeIfPresent(TimeInterval.self, forKey: .staleTolerance) {
                try setStaleTolerance(tolerance)
            }
        } catch let error as AlertSettingsError {
            throw DecodingError.dataCorruptedError(
                forKey: .staleTolerance, in: container, debugDescription: error.errorDescription ?? "")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(watchlist, forKey: .watchlist)
        try container.encode(defaultThresholds, forKey: .defaultThresholds)
        try container.encode(notificationSound, forKey: .notificationSound)
        try container.encode(monitorSettings.interval, forKey: .updateInterval)
        try container.encode(alertSettings.staleTolerance, forKey: .staleTolerance)
    }
}
