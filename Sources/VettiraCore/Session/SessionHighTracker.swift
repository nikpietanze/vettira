/// The high a pullback is measured from, and what kind of high it is.
public struct SessionHigh: Equatable, Sendable, Codable {
    /// Where the high came from.
    public enum Kind: String, Equatable, Sendable, Codable {
        /// The regular-session high, as the provider supplied it.
        case session
        /// The highest regular-session price Vettira saw itself this session: its quotes' prices
        /// and, when the provider supplies no session high, the highs of the day's bars. It can be
        /// lower than the day's actual high, so it's never called the session high.
        case observed

        /// How the high is labelled: "session high" or "observed high".
        public var label: String {
            switch self {
            case .session: "session high"
            case .observed: "observed high"
            }
        }
    }

    public let price: Double
    public let kind: Kind

    public init(price: Double, kind: Kind) {
        self.price = price
        self.kind = kind
    }

    /// How far `price` is below this high, in percent: `(high - price) / high * 100`. Negative when
    /// `price` is above it.
    public func pullbackPercent(at price: Double) -> Double {
        (self.price - price) / self.price * 100
    }
}

/// One symbol's high for one trading day's session: the provider's regular-session high when it
/// supplies one, or the highest price observed, in quotes and in the day's bars.
///
/// Feed it regular-session prices only; it doesn't judge whether a quote or a bar is fresh, in
/// regular hours or plausible (`ReversalAlertEngine` does). A price from a new trading day starts
/// the high over.
public struct SessionHighTracker: Equatable, Sendable, Codable {
    /// The trading day whose session the high belongs to; `nil` before the first price.
    public private(set) var day: TradingDay?
    /// The highest regular-session high the provider supplied this session.
    private var providerHigh: Double?
    /// The highest quote price seen this session.
    private var observedHigh: Double?
    /// The highest bar high recorded this session. Optional in the saved state, since state saved
    /// before bars were counted doesn't have it.
    private var barHigh: Double?

    public init() {}

    /// Records a regular-session price from `day`'s session, with the provider's session high when
    /// it supplied one.
    public mutating func record(price: Double, providerHigh: Double?, on day: TradingDay) {
        start(day)
        observedHigh = max(observedHigh ?? price, price)
        if let providerHigh {
            self.providerHigh = max(self.providerHigh ?? providerHigh, providerHigh)
        }
    }

    /// Records the high of one of `day`'s regular-session bars. It counts in the observed high only
    /// while the provider has supplied no session high this session, since the provider's high
    /// already covers the whole session.
    public mutating func record(barHigh: Double, on day: TradingDay) {
        start(day)
        self.barHigh = max(self.barHigh ?? barHigh, barHigh)
    }

    /// The high: the provider's session high, unless a price above it was seen, in which case the
    /// observed high, since that's the higher one Vettira knows of. Without a provider high, the
    /// observed high counts the bars' highs. `nil` before the first price.
    public var high: SessionHigh? {
        guard let observedHigh else { return nil }
        if let providerHigh {
            return providerHigh >= observedHigh
                ? SessionHigh(price: providerHigh, kind: .session) : SessionHigh(price: observedHigh, kind: .observed)
        }
        return SessionHigh(price: max(observedHigh, barHigh ?? observedHigh), kind: .observed)
    }

    /// The high from the quotes alone, their prices and the provider's session high, without the
    /// bars' highs: what a rearm is judged by, since a bar's high can be from before the last
    /// alert. `nil` before the first price.
    public var quotedHigh: Double? {
        guard let observedHigh else { return nil }
        return max(observedHigh, providerHigh ?? observedHigh)
    }

    /// Starts the high over when `day` is a new trading day.
    private mutating func start(_ day: TradingDay) {
        if day != self.day {
            self = SessionHighTracker()
            self.day = day
        }
    }
}
