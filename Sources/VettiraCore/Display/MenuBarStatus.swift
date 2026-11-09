import Foundation

/// What the menu-bar item shows: the watchlist's menu-bar symbol with its latest price and its
/// change from the high, or why it can't (no quote yet, the market closed, stale data, a provider
/// error), and whether a warning fired that the price is still past.
public struct MenuBarStatus: Equatable, Sendable {
    public enum Indicator: Equatable, Sendable {
        /// The watchlist is empty, so there's no symbol to show.
        case empty
        /// The symbol is turned off, so it isn't monitored.
        case notMonitored
        /// No quote for it yet.
        case waiting
        /// A fresh regular-session quote.
        case live
        /// A warning fired this session and the price is still past a threshold: the larger one
        /// it's past, up to the warning that fired. A possible reversal, not a confirmed one.
        case pullback(PullbackSignal)
        /// Outside the regular session, so the price is the last session's and nothing alerts.
        case closed
        /// The quote is too old to alert on.
        case stale
        /// The provider has no quote for the symbol, or the last update failed before one came.
        case unavailable
    }

    /// The symbol shown, or `nil` when the watchlist is empty.
    public let symbol: TickerSymbol?
    /// The menu bar's text: `SPY 512.30 −0.31%`, `SPY 512.30 · stale`; empty when there's no symbol.
    public let title: String
    public let indicator: Indicator
    /// A sentence saying the same in full, for the tooltip and VoiceOver.
    public let detail: String

    /// The status at `now`. `staleTolerance` is the alert engine's: a quote older than it is
    /// stale.
    public init(
        settings: UserSettings, snapshot: MonitorSnapshot, staleTolerance: TimeInterval, now: Date,
        calendar: MarketCalendar = .usEquities
    ) {
        guard let symbol = settings.watchlist.menuBarSymbol else {
            self.init(nil, "", .empty, "The watchlist is empty, so there's no symbol to show.")
            return
        }
        guard let state = snapshot.symbols[symbol] else {
            self.init(symbol, "\(symbol) off", .notMonitored, "\(symbol) is turned off, so it isn't monitored.")
            return
        }
        guard let quote = state.quote else {
            if let problem = state.problem {
                self.init(symbol, "\(symbol) \u{2014}", .unavailable, problem.sentence(for: symbol))
            } else if let error = snapshot.diagnostics.lastError {
                self.init(symbol, "\(symbol) \u{2014}", .unavailable, "No quote for \(symbol): \(error.message)")
            } else {
                self.init(symbol, "\(symbol) \u{2026}", .waiting, "Waiting for the first quote for \(symbol).")
            }
            return
        }
        let price = DisplayFormat.price(quote.price)
        let age = DisplayFormat.duration(quote.age(at: now))
        if snapshot.diagnostics.marketState != .regular {
            self.init(
                symbol, "\(symbol) \(price) \u{00B7} closed", .closed,
                "\(symbol) \(price), the last regular-session price. The market is closed, so nothing alerts.")
        } else if state.isStale(at: now, tolerance: staleTolerance) {
            self.init(
                symbol, "\(symbol) \(price) \u{00B7} stale", .stale,
                "\(symbol) \(price): the quote is \(age) old, too old to alert on.")
        } else if let high = state.high, let pullback = state.pullbackPercent {
            let title = "\(symbol) \(price) \(DisplayFormat.changeFromHigh(pullback))"
            let position = "\(symbol) \(price) is \(DisplayFormat.percent(pullback)) below its \(high.kind.label) of "
                + "\(DisplayFormat.price(high.price)). Quote \(age) old."
            let thresholds = settings.thresholds(for: symbol) ?? settings.defaultThresholds
            let past: PullbackSignal? = pullback >= thresholds.strong ? .strong : pullback >= thresholds.early ? .early : nil
            if let alert = state.alertThisSession(at: now, calendar: calendar), let past {
                let signal = min(past, alert.signal)
                self.init(
                    symbol, title, .pullback(signal), "\(signal.label): possible reversal, not confirmed. " + position)
            } else {
                self.init(symbol, title, .live, position)
            }
        } else {
            self.init(symbol, "\(symbol) \(price)", .live, "\(symbol) \(price). Quote \(age) old.")
        }
    }

    private init(_ symbol: TickerSymbol?, _ title: String, _ indicator: Indicator, _ detail: String) {
        self.symbol = symbol
        self.title = title
        self.indicator = indicator
        self.detail = detail
    }
}

extension SymbolProblem {
    /// A short label: "unknown symbol" or "no usable quote".
    public var label: String {
        switch self {
        case .unknownSymbol: "unknown symbol"
        case .noUsableQuote: "no usable quote"
        }
    }

    func sentence(for symbol: TickerSymbol) -> String {
        switch self {
        case .unknownSymbol: "The provider doesn't recognize \(symbol)."
        case .noUsableQuote: "The provider returned no usable price for \(symbol); it may be halted."
        }
    }
}
