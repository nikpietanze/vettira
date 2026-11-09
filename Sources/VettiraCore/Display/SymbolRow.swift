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
    /// Whether it's pinned, so it lists first.
    public let isPinned: Bool
    /// The latest price: `512.30`.
    public let price: String?
    /// The change from the high: `−0.31%`.
    public let changeFromHigh: String?
    /// The high and its kind: `513.90 observed high`. Only during the high's own session.
    public let high: String?
    /// The quote's own time: `10:31:05 EST`.
    public let quoteTime: String?
    /// How old the quote is: `5 s`.
    public let dataAge: String?
    /// The thresholds that apply to it, early then stronger: `0.25% / 0.40%`.
    public let thresholds: String
    /// Whether those are its own thresholds rather than the defaults.
    public let hasOwnThresholds: Bool
    /// Why the data can't alert, when it can't: `off`, `waiting`, `unknown symbol`,
    /// `market closed`, `stale` and the like.
    public let status: String?
    /// Whether the data is too old to alert on.
    public let isStale: Bool
    /// The last warning this session: `Early warning at 10:31:05 EST`.
    public let lastWarning: String?

    /// A row for each symbol on the watchlist, in its display order (pinned first), at `now`. A
    /// quote older than the settings' staleness tolerance is stale.
    public static func rows(
        settings: UserSettings, snapshot: MonitorSnapshot, now: Date,
        timeZone: TimeZone = .current, calendar: MarketCalendar = .usEquities
    ) -> [SymbolRow] {
        let watchlist = settings.watchlist
        return watchlist.displayOrder.map { entry in
            SymbolRow(
                entry: entry, state: entry.isEnabled ? snapshot.symbols[entry.symbol] : nil,
                isInMenuBar: watchlist.menuBarSymbol == entry.symbol,
                thresholds: entry.thresholds ?? settings.defaultThresholds,
                staleTolerance: settings.alertSettings.staleTolerance, now: now, timeZone: timeZone, calendar: calendar)
        }
    }

    /// Whether the row is one a search for `query` finds: its ticker contains the query, ignoring
    /// case and surrounding spaces. An empty query finds every row.
    public func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return query.isEmpty || symbol.rawValue.contains(query)
    }

    private init(
        entry: WatchlistEntry, state: SymbolSnapshot?, isInMenuBar: Bool, thresholds: PullbackThresholds,
        staleTolerance: TimeInterval, now: Date, timeZone: TimeZone, calendar: MarketCalendar
    ) {
        symbol = entry.symbol
        isEnabled = entry.isEnabled
        self.isInMenuBar = isInMenuBar
        isPinned = entry.isPinned
        self.thresholds = DisplayFormat.thresholds(thresholds)
        hasOwnThresholds = entry.thresholds != nil
        let quote = state?.quote
        price = quote.map { DisplayFormat.price($0.price) }
        quoteTime = quote.map { DisplayFormat.time($0.timestamp, in: timeZone) }
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
