import Foundation

/// Decides, quote by quote, whether a symbol's price has pulled back from its high far enough to
/// alert: each threshold once per high-water-mark cycle, only on fresh regular-session quotes.
///
/// docs/alerts.md explains the rules. The engine has no clock of its own: each quote is evaluated
/// at the `now` it's given. Its `state` is `Codable`, so the app can save it and, after a relaunch,
/// carry on without alerting again for a pullback it already alerted.
public struct ReversalAlertEngine: Sendable {
    /// Everything the engine remembers, for every symbol it has seen. Save it to keep alerts
    /// de-duplicated across relaunches.
    public struct State: Equatable, Sendable, Codable {
        var symbols: [String: SymbolState] = [:]

        public init() {}
    }

    public var settings: AlertSettings
    public private(set) var state: State
    private let calendar: MarketCalendar

    public init(settings: AlertSettings = .standard, state: State = State(), calendar: MarketCalendar = .usEquities) {
        self.settings = settings
        self.state = state
        self.calendar = calendar
    }

    /// Evaluates `quote` at `now` against its symbol's `thresholds`: rejects it with the reason, or
    /// uses it to update the high and returns the alert it fires, if any.
    public mutating func evaluate(_ quote: Quote, thresholds: PullbackThresholds, now: Date) -> QuoteEvaluation {
        var symbol = state.symbols[quote.symbol] ?? SymbolState()
        let evaluation = symbol.evaluate(quote, thresholds: thresholds, now: now, settings: settings, calendar: calendar)
        state.symbols[quote.symbol] = symbol
        return evaluation
    }
}

/// One symbol's high, its last accepted quote and its alert cycle.
struct SymbolState: Equatable, Sendable, Codable {
    /// A quote that jumped past the spike limit, kept to see whether the next one confirms it.
    struct Jump: Equatable, Sendable, Codable {
        let price: Double
        let timestamp: Date
    }

    var tracker = SessionHighTracker()
    /// The last accepted quote's time, which a quote must be later than.
    var lastTimestamp: Date?
    /// The last accepted price this session, for the spike limit.
    var lastPrice: Double?
    var pendingJump: Jump?
    /// The high at the last alert this cycle; `nil` while nothing has fired.
    var alertedHigh: Double?
    /// The thresholds already sent (or covered by a stronger one) this cycle.
    var fired: Set<PullbackSignal> = []
    /// When each threshold was last sent, by quote time, for the cooldown.
    var lastFired: [PullbackSignal: Date] = [:]

    mutating func evaluate(
        _ quote: Quote, thresholds: PullbackThresholds, now: Date,
        settings: AlertSettings, calendar: MarketCalendar
    ) -> QuoteEvaluation {
        let price = quote.price
        guard price.isFinite, price > 0 else { return .rejected(.invalidPrice) }
        guard let status = calendar.status(at: quote.timestamp) else { return .rejected(.notInCalendar) }
        guard status.state == .regular, quote.session == .regular || quote.session == .unknown else {
            return .rejected(.outsideRegularHours)
        }
        if let delay = quote.providerDelay, delay > settings.staleTolerance { return .rejected(.delayed(delay)) }
        let age = quote.age(at: now)
        if age > settings.staleTolerance { return .rejected(.stale(age: age)) }
        if -age > settings.staleTolerance { return .rejected(.aheadOfClock(-age)) }
        if let lastTimestamp {
            if quote.timestamp == lastTimestamp { return .rejected(.duplicate) }
            if quote.timestamp < lastTimestamp { return .rejected(.outOfOrder) }
        }

        let day = status.session.day
        if day != tracker.day {
            // A new session: a new high, a new cycle, and no last price to measure a spike from.
            lastPrice = nil
            pendingJump = nil
            alertedHigh = nil
            fired = []
        }
        if let lastPrice, Self.move(from: lastPrice, to: price) > settings.spikePercent {
            let confirmed = pendingJump.map {
                quote.timestamp > $0.timestamp && Self.move(from: $0.price, to: price) <= settings.spikePercent
            } ?? false
            if !confirmed {
                pendingJump = Jump(price: price, timestamp: quote.timestamp)
                return .rejected(.implausibleJump(fromPrice: lastPrice))
            }
        }

        pendingJump = nil
        lastTimestamp = quote.timestamp
        lastPrice = price
        tracker.record(price: price, providerHigh: quote.sessionHigh, on: day)
        let high = tracker.high!
        if let alertedHigh, high.price >= alertedHigh * (1 + settings.rearmPercent / 100) {
            self.alertedHigh = nil
            fired = []
        }

        let pullback = high.pullbackPercent(at: price)
        let crossed = PullbackSignal.allCases.filter { pullback >= thresholds.percent(for: $0) }
        let ready = crossed.filter { signal in
            !fired.contains(signal)
                && lastFired[signal].map { quote.timestamp.timeIntervalSince($0) >= settings.cooldown } ?? true
        }
        guard let signal = ready.max() else {
            return .accepted(high: high, pullbackPercent: pullback, alert: nil)
        }
        // The stronger warning covers the early one, so one quote sends one alert.
        for covered in crossed where covered <= signal && !fired.contains(covered) {
            fired.insert(covered)
            lastFired[covered] = quote.timestamp
        }
        alertedHigh = high.price
        let alert = ReversalAlert(
            symbol: quote.symbol, price: price, high: high, pullbackPercent: pullback,
            signal: signal, thresholdPercent: thresholds.percent(for: signal), quoteTimestamp: quote.timestamp,
            dataAge: quote.age(at: now), source: quote.source)
        return .accepted(high: high, pullbackPercent: pullback, alert: alert)
    }

    /// How far `to` is from `from`, in percent of `from`, either way.
    private static func move(from: Double, to: Double) -> Double {
        abs(to - from) / from * 100
    }
}
