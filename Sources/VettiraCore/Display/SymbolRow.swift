import Foundation

/// One watchlist symbol as the popover and the dashboard list it: its price, its high and which
/// kind it is, its pullback, its data age, what's wrong with its data if anything, and the last
/// warning this session.
public struct SymbolRow: Equatable, Sendable, Identifiable {
    public let symbol: TickerSymbol
    public var id: TickerSymbol { symbol }
    /// Whether the symbol is monitored. A disabled one has no quote.
    public let isEnabled: Bool
    /// Whether it's the symbol the menu bar shows.
    public let isInMenuBar: Bool
    /// The latest price: `512.30`.
    public let price: String?
    /// The change from the high: `−0.31%`.
    public let changeFromHigh: String?
    /// The high and its kind: `513.90 observed high`. Only during the high's own session.
    public let high: String?
    /// How old the quote is: `5 s`.
    public let dataAge: String?
    /// Why the data can't alert, when it can't: `off`, `waiting`, `unknown symbol`,
    /// `market closed`, `stale` and the like.
    public let status: String?
    /// Whether the data is too old to alert on.
    public let isStale: Bool
    /// The last warning this session: `Early warning at 10:31:05 EST`.
    public let lastWarning: String?

    /// A row for each symbol on the watchlist, in its display order (pinned first), at `now`.
    public static func rows(
        watchlist: Watchlist, snapshot: MonitorSnapshot, staleTolerance: TimeInterval, now: Date,
        timeZone: TimeZone = .current, calendar: MarketCalendar = .usEquities
    ) -> [SymbolRow] {
        watchlist.displayOrder.map { entry in
            SymbolRow(
                entry: entry, state: entry.isEnabled ? snapshot.symbols[entry.symbol] : nil,
                isInMenuBar: watchlist.menuBarSymbol == entry.symbol, staleTolerance: staleTolerance, now: now,
                timeZone: timeZone, calendar: calendar)
        }
    }

    private init(
        entry: WatchlistEntry, state: SymbolSnapshot?, isInMenuBar: Bool, staleTolerance: TimeInterval, now: Date,
        timeZone: TimeZone, calendar: MarketCalendar
    ) {
        symbol = entry.symbol
        isEnabled = entry.isEnabled
        self.isInMenuBar = isInMenuBar
        let quote = state?.quote
        price = quote.map { DisplayFormat.price($0.price) }
        dataAge = quote.map { DisplayFormat.duration($0.age(at: now)) }
        if let high = state?.high {
            self.high = "\(DisplayFormat.price(high.price)) \(high.kind.label)"
        } else {
            self.high = nil
        }
        changeFromHigh = state?.pullbackPercent.map(DisplayFormat.changeFromHigh)
        isStale = state?.isStale(at: now, tolerance: staleTolerance) ?? true
        if let alert = state?.alertThisSession(at: now, calendar: calendar) {
            lastWarning = "\(alert.signal.label) at \(DisplayFormat.time(alert.quoteTimestamp, in: timeZone))"
        } else {
            lastWarning = nil
        }
        status = Self.status(entry: entry, state: state, isStale: isStale)
    }

    private static func status(entry: WatchlistEntry, state: SymbolSnapshot?, isStale: Bool) -> String? {
        guard entry.isEnabled, let state else { return "off" }
        if let problem = state.problem { return problem.label }
        guard state.quote != nil else { return "waiting" }
        switch state.lastRejection {
        case .outsideRegularHours, .notInCalendar: return "market closed"
        case .invalidPrice: return "invalid price"
        case .delayed: return "delayed"
        case .aheadOfClock: return "quote time ahead of the Mac's clock"
        case .implausibleJump: return "unconfirmed jump"
        case .stale, .duplicate, .outOfOrder, nil: return isStale ? "stale" : nil
        }
    }
}
