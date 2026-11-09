/// The high a pullback is measured from, and what kind of high it is.
public struct SessionHigh: Equatable, Sendable, Codable {
    /// Where the high came from.
    public enum Kind: String, Equatable, Sendable, Codable {
        /// The regular-session high, as the provider supplied it.
        case session
        /// The highest regular-session price Vettira saw itself since it started watching this
        /// session. It can be lower than the day's actual high, so it's never called the session high.
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
/// supplies one, or the highest price observed since monitoring began.
///
/// Feed it regular-session prices only; it doesn't judge whether a quote is fresh or in regular
/// hours (`ReversalAlertEngine` does). A price from a new trading day starts the high over.
public struct SessionHighTracker: Equatable, Sendable, Codable {
    /// The trading day whose session the high belongs to; `nil` before the first price.
    public private(set) var day: TradingDay?
    /// The highest regular-session high the provider supplied this session.
    private var providerHigh: Double?
    /// The highest price seen this session.
    private var observedHigh: Double?

    public init() {}

    /// Records a regular-session price from `day`'s session, with the provider's session high when
    /// it supplied one.
    public mutating func record(price: Double, providerHigh: Double?, on day: TradingDay) {
        if day != self.day {
            self = SessionHighTracker()
            self.day = day
        }
        observedHigh = max(observedHigh ?? price, price)
        if let providerHigh {
            self.providerHigh = max(self.providerHigh ?? providerHigh, providerHigh)
        }
    }

    /// The high: the provider's session high, unless a price above it was seen, in which case the
    /// observed high, since that's the higher one Vettira knows of. `nil` before the first price.
    public var high: SessionHigh? {
        guard let observedHigh else { return nil }
        if let providerHigh, providerHigh >= observedHigh {
            return SessionHigh(price: providerHigh, kind: .session)
        }
        return SessionHigh(price: observedHigh, kind: .observed)
    }
}
