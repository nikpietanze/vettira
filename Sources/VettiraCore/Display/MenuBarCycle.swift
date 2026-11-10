import Foundation

/// Which symbol the menu bar shows, as it takes turns through the watchlist: every enabled symbol
/// in the watchlist's order, moving on every `UserSettings.menuBarCycle` seconds, or with cycling
/// off only the menu-bar symbol. Turning the cycle only changes what's shown: it never asks the
/// provider for anything.
public enum MenuBarCycle {
    /// The intervals Settings offers, in seconds, `nil` for off.
    public static let intervals: [TimeInterval?] = [nil, 3, 5, 10]
    /// The interval a fresh install cycles at.
    public static let standardInterval: TimeInterval = 5
    /// The range a settings file can hold, in seconds.
    public static let allowedIntervals: ClosedRange<TimeInterval> = 1...60

    /// The intervals to choose from, with `current` among them even when it isn't one of the
    /// usual ones (a hand-edited settings file): off first, then the shortest.
    public static func intervals(current: TimeInterval?) -> [TimeInterval?] {
        guard let current, !intervals.contains(current) else { return intervals }
        return [nil] + (intervals.compactMap { $0 } + [current]).sorted()
    }

    /// The symbols the menu bar takes turns showing: each enabled one in the watchlist's order
    /// while it cycles, or with cycling off, or none enabled, only the menu-bar symbol. Empty for
    /// an empty watchlist.
    public static func symbols(_ settings: UserSettings) -> [TickerSymbol] {
        let enabled = settings.watchlist.displayOrder.filter(\.isEnabled).map(\.symbol)
        if settings.menuBarCycle != nil, !enabled.isEmpty { return enabled }
        return [settings.watchlist.menuBarSymbol].compactMap { $0 }
    }

    /// The symbol to show, given the one shown last: that one while it's still in the cycle, or
    /// while it's the menu-bar symbol (one the user just picked, even turned off, shows until the
    /// next turn); otherwise the menu-bar symbol when it's in the cycle, otherwise the first.
    public static func current(_ shown: TickerSymbol?, settings: UserSettings) -> TickerSymbol? {
        let symbols = symbols(settings)
        if let shown, symbols.contains(shown) || shown == settings.watchlist.menuBarSymbol { return shown }
        if let selected = settings.watchlist.menuBarSymbol, symbols.contains(selected) { return selected }
        return symbols.first
    }

    /// The symbol to show at the next turn: the one after `current(shown)`, back to the first
    /// after the last, or the first when the current one isn't in the cycle.
    public static func next(after shown: TickerSymbol?, settings: UserSettings) -> TickerSymbol? {
        let symbols = symbols(settings)
        guard let current = current(shown, settings: settings) else { return nil }
        guard let index = symbols.firstIndex(of: current) else { return symbols.first }
        return symbols[(index + 1) % symbols.count]
    }

    /// How long until the next turn, for a symbol shown `elapsed` seconds ago: 0 or less when
    /// it's due, so a symbol the user picks gets a whole turn. `nil` with cycling off.
    public static func untilNextTurn(shownFor elapsed: TimeInterval, settings: UserSettings) -> TimeInterval? {
        settings.menuBarCycle.map { $0 - elapsed }
    }
}
