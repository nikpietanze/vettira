import Foundation

/// The chart's price history, fetched only when the user opens a timeframe and kept in memory.
///
/// It keeps to the light-client rule (docs/providers.md, "History for the chart"):
///
/// - **1D is a minute's bars**, asked for when its chart opens and again once a minute while it's
///   open in regular hours (`ChartTimeframe.refreshes(at:calendar:)`); until they come, or while
///   they're an earlier session's than the polls', the chart shows the polls' 5-minute bars
///   (`oneDay(fetched:polled:)`).
/// - **One request per symbol and timeframe**, through the provider, which sends it in turn with
///   the polls' requests and at the same pace, never alongside one. Asking again for one that's in
///   flight waits for that request rather than sending another.
/// - **Cached** for the timeframe's `cacheLifetime` (just under a minute for 1D to 12 hours for
///   5Y), in memory only; nothing is written to disk.
/// - **Backs off.** After the provider rate-limits, refuses or can't be reached, nothing is asked
///   for a minute, or for as long as it said to wait; after any other failure, that symbol and
///   timeframe aren't asked again for a minute.
/// - **Nothing in the background:** it fetches only when `history(for:timeframe:)` is called,
///   which the app does when the user opens a timeframe, and for 1D each minute it stays open.
public actor ChartHistoryStore {
    private struct Key: Hashable {
        let symbol: String
        let timeframe: ChartTimeframe
    }

    private let provider: any MarketDataProvider
    private let now: @Sendable () -> Date
    private var cache: [Key: (history: PriceHistory, expires: Date)] = [:]
    private var failures: [Key: (error: ProviderError, until: Date)] = [:]
    private var inFlight: [Key: Task<Result<PriceHistory, ProviderError>, Never>] = [:]
    /// No request before this, after the provider rate-limited, refused or couldn't be reached.
    private var pause: (error: ProviderError, until: Date)?

    /// How long it waits after a failure, at least.
    public static let failureWait: TimeInterval = 60

    /// `provider` is the monitor's own, so history requests take their turn with the polls'.
    public init(provider: any MarketDataProvider, now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.now = now
    }

    /// `symbol`'s history over `timeframe`: the cached history while it's fresh, or one request.
    /// Throws the provider's error, or the last one again while backing off.
    public func history(for symbol: TickerSymbol, timeframe: ChartTimeframe) async throws(ProviderError) -> PriceHistory {
        let key = Key(symbol: symbol.rawValue, timeframe: timeframe)
        let time = now()
        if let cached = cache[key], time < cached.expires { return cached.history }
        if let pause, time < pause.until { throw pause.error }
        if let failure = failures[key], time < failure.until { throw failure.error }

        let task = inFlight[key] ?? Task { [provider] in
            do throws(ProviderError) {
                return .success(try await provider.history(for: symbol.rawValue, timeframe: timeframe))
            } catch {
                return .failure(error)
            }
        }
        if inFlight[key] == nil {
            inFlight[key] = task
            let result = await task.value
            inFlight[key] = nil
            record(result, for: key)
            return try result.get()
        }
        return try await task.value.get()
    }

    /// 1D from a polled quote: its day's 5-minute bars and previous close, when it has bars. The
    /// chart shows it straight away, until the minute's bars come or when they can't.
    public nonisolated static func polledDay(_ quote: Quote?) -> PriceHistory? {
        guard let quote, !quote.intraday.isEmpty else { return nil }
        return PriceHistory(
            symbol: quote.symbol, timeframe: .oneDay, bars: quote.intraday, previousClose: quote.previousClose,
            name: quote.name)
    }

    /// What 1D shows: the fetched minute bars, unless the polls' bars (`polledDay(_:)`) are a
    /// later session's, as they are once the market opens on a chart asked for before it.
    public nonisolated static func oneDay(fetched: PriceHistory?, polled: PriceHistory?) -> PriceHistory? {
        guard let fetched, fetched.timeframe == .oneDay, let fetchedStart = fetched.bars.first?.timestamp else { return polled }
        guard let polledStart = polled?.bars.first?.timestamp,
              MarketCalendar.day(of: polledStart) > MarketCalendar.day(of: fetchedStart)
        else { return fetched }
        return polled
    }

    /// The fresh cached history, without asking the provider: what the chart can show at once.
    public func cached(for symbol: TickerSymbol, timeframe: ChartTimeframe) -> PriceHistory? {
        let key = Key(symbol: symbol.rawValue, timeframe: timeframe)
        guard let cached = cache[key], now() < cached.expires else { return nil }
        return cached.history
    }

    private func record(_ result: Result<PriceHistory, ProviderError>, for key: Key) {
        let time = now()
        cache = cache.filter { time < $0.value.expires }
        failures = failures.filter { time < $0.value.until }
        switch result {
        case .success(let history):
            cache[key] = (history, time + key.timeframe.cacheLifetime)
            failures[key] = nil
        case .failure(let error):
            var wait = Self.failureWait
            if case .rateLimited(let retryAfter?) = error { wait = max(wait, retryAfter) }
            switch error {
            case .rateLimited, .blocked, .unavailable: pause = (error, time + wait)
            case .unknownSymbols, .noUsableQuote, .malformedResponse: break
            }
            failures[key] = (error, time + wait)
        }
    }
}
