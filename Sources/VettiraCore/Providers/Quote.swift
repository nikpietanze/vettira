import Foundation

/// One symbol's latest quote, in the same shape whichever provider it came from.
///
/// A provider turns its own response into these at its boundary; nothing past the provider reads
/// the provider's format. Fields a provider doesn't supply stay `nil` rather than being guessed.
public struct Quote: Sendable, Equatable {
    /// Where a quote falls in the trading day, as the provider reports it.
    public enum Session: Sendable, Equatable {
        /// Before the regular session opens (extended hours).
        case preMarket
        /// The regular session (US: 09:30 to 16:00 America/New_York).
        case regular
        /// After the regular session closes (extended hours).
        case postMarket
        /// The market is closed.
        case closed
        /// The provider didn't say.
        case unknown
    }

    /// The ticker, as the provider returned it (`SPY`, `AAPL`).
    public var symbol: String
    /// The last price.
    public var price: Double
    /// When the provider says the price was set: the quote's own time, not when Vettira received it.
    public var timestamp: Date
    /// The name of the provider the quote came from, to show with it.
    public var source: String
    /// The regular-session high, only when the provider supplies it as that. `nil` means the
    /// provider gave none, so the only high Vettira has is the one it observed itself, and it
    /// must be labeled "observed high".
    public var sessionHigh: Double?
    /// Which part of the trading day the quote is from.
    public var session: Session
    /// How far behind the exchange the provider says its data is (`0` when it says it isn't
    /// delayed), or `nil` when it doesn't say.
    public var providerDelay: TimeInterval?
    /// The previous regular session's close, when the provider supplies it: what the day's change,
    /// up or down, is measured from.
    public var previousClose: Double?
    /// The day's regular-session bars, oldest first, as the provider returned them with the quote:
    /// today's, or the last session's while the market is closed. Empty when it returned none.
    public var intraday: [PriceBar]

    public init(
        symbol: String,
        price: Double,
        timestamp: Date,
        source: String,
        sessionHigh: Double? = nil,
        session: Session = .unknown,
        providerDelay: TimeInterval? = nil,
        previousClose: Double? = nil,
        intraday: [PriceBar] = []
    ) {
        self.symbol = symbol
        self.price = price
        self.timestamp = timestamp
        self.source = source
        self.sessionHigh = sessionHigh
        self.session = session
        self.providerDelay = providerDelay
        self.previousClose = previousClose
        self.intraday = intraday
    }

    /// How old the quote is at `now`: the time since its timestamp. Negative when the quote's
    /// timestamp is ahead of `now`, which a clock difference can cause.
    public func age(at now: Date) -> TimeInterval {
        now.timeIntervalSince(timestamp)
    }
}

/// One bar of the day's prices: the price at the end of a few minutes of trading, and the highest
/// price in them.
public struct PriceBar: Sendable, Equatable {
    /// When the bar starts.
    public var timestamp: Date
    /// The last price in the bar; `nil` when the provider has none for it, a gap in the day.
    public var close: Double?
    /// The highest price in the bar, when the provider has one.
    public var high: Double?

    public init(timestamp: Date, close: Double?, high: Double? = nil) {
        self.timestamp = timestamp
        self.close = close
        self.high = high
    }
}
