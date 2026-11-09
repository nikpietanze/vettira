import Foundation

/// Everything Vettira keeps about the user's setup on disk: the watchlist and the global
/// defaults.
public struct UserSettings: Equatable, Sendable {
    /// A fresh install: an empty watchlist and the standard thresholds.
    public static let defaults = UserSettings()

    public var watchlist = Watchlist()
    /// The thresholds for every symbol that doesn't set its own.
    public var defaultThresholds = PullbackThresholds.standard
    /// Whether an alert's notification plays a sound. On by default.
    public var notificationSound = true

    public init() {}

    /// The thresholds that apply to the symbol: its own, or the defaults. Nil if it isn't on the
    /// watchlist.
    public func thresholds(for symbol: TickerSymbol) -> PullbackThresholds? {
        watchlist.entry(for: symbol).map { $0.thresholds ?? defaultThresholds }
    }
}

extension UserSettings: Codable {
    private enum CodingKeys: String, CodingKey { case watchlist, defaultThresholds, notificationSound }

    // A field an older file doesn't have gets its default. Add new fields the same way.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        watchlist = try container.decodeIfPresent(Watchlist.self, forKey: .watchlist) ?? Watchlist()
        defaultThresholds = try container.decodeIfPresent(PullbackThresholds.self, forKey: .defaultThresholds)
            ?? .standard
        notificationSound = try container.decodeIfPresent(Bool.self, forKey: .notificationSound) ?? true
    }
}
