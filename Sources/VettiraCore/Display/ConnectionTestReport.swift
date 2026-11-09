import Foundation

/// What Settings' Test Connection found: a quote for the symbol and how fresh it is, or why the
/// provider gave none, with what to do about it.
public struct ConnectionTestReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// A quote came: fresh, or the last session's while the market is closed.
        case connected
        /// A quote came, but in regular hours it's too old to alert on.
        case stale
        /// No quote: the provider's error says why.
        case failed
    }

    public let outcome: Outcome
    /// What happened, in a line.
    public let headline: String
    /// The quote's time, age and source, or for an error what to do.
    public let detail: String

    /// Asks `provider` for one quote for `symbol` (`MarketDataProvider.testConnection(symbol:)`),
    /// then reports on it at `now()`. A quote older than `staleTolerance` is stale.
    public static func run(
        on provider: any MarketDataProvider, symbol: TickerSymbol, staleTolerance: TimeInterval,
        now: @Sendable () -> Date, timeZone: TimeZone = .current, calendar: MarketCalendar = .usEquities
    ) async -> ConnectionTestReport {
        let result: Result<Quote, ProviderError>
        do {
            result = .success(try await provider.testConnection(symbol: symbol.rawValue))
        } catch {
            result = .failure(error)
        }
        return ConnectionTestReport(
            symbol: symbol, result: result, staleTolerance: staleTolerance, now: now(), timeZone: timeZone,
            calendar: calendar)
    }

    public init(
        symbol: TickerSymbol, result: Result<Quote, ProviderError>, staleTolerance: TimeInterval, now: Date,
        timeZone: TimeZone = .current, calendar: MarketCalendar = .usEquities
    ) {
        let quote: Quote
        switch result {
        case .failure(let error):
            outcome = .failed
            headline = error.message
            detail = error.nextStep
            return
        case .success(let received):
            quote = received
        }
        let price = DisplayFormat.price(quote.price)
        let age = quote.age(at: now)
        let when = "Quote at \(DisplayFormat.time(quote.timestamp, in: timeZone)), \(DisplayFormat.duration(age)) old, from \(quote.source)."
        guard calendar.status(at: now)?.state == .regular else {
            outcome = .connected
            headline = "Connected: \(symbol) \(price), the last session's price"
            detail = "\(when) The market is closed, so nothing alerts until the next session."
            return
        }
        if age > staleTolerance || (quote.providerDelay ?? 0) > staleTolerance {
            outcome = .stale
            headline = "Connected, but \(symbol)'s quote is stale"
            detail = "\(when) That's older than the \(DisplayFormat.duration(staleTolerance)) staleness tolerance, "
                + "so it wouldn't alert. The provider's quotes may be delayed: try again in a minute."
            return
        }
        outcome = .connected
        headline = "Connected: \(symbol) \(price)"
        detail = when
    }
}
