import Foundation

/// Quotes from Yahoo Finance's unofficial chart endpoint, one of those the yfinance project uses.
///
/// It's undocumented and not licensed or endorsed by Yahoo; it can change or be blocked without
/// notice, and Yahoo's terms govern its use (docs/providers.md). No key, no account, no cookie: one
/// request per symbol, sent one at a time and at most one a second, with a User-Agent that names
/// Vettira. It reads the regular session's fields only, never an extended-hours price, and never
/// scrapes a page.
public actor YahooFinanceProvider: MarketDataProvider {
    public nonisolated let name = "Yahoo Finance (unofficial)"
    public nonisolated let streams = false

    /// Says plainly what's asking; never a browser's.
    static let userAgent = "Vettira (https://github.com/nikpietanze/vettira)"
    static let chartURL = "https://query1.finance.yahoo.com/v8/finance/chart/"
    /// The symbol Test Connection asks for.
    static let connectionTestSymbol = "SPY"

    private let http: any HTTPClient
    private let pacing: RequestPacing
    private var lastRequest: ContinuousClock.Instant?
    /// Whether a request is in flight, and the requests queued behind it, so concurrent callers
    /// still send one at a time.
    private var sending = false
    private var queued: [CheckedContinuation<Void, Never>] = []

    public init(http: any HTTPClient = URLSessionHTTPClient(), pacing: RequestPacing = .oncePerSecond) {
        self.http = http
        self.pacing = pacing
    }

    /// One request per symbol, in order. A symbol Yahoo doesn't know, or returns without a usable
    /// price or time, is listed in the batch and the rest carry on; a refusal, rate limit or
    /// outage stops the poll and throws, since the remaining symbols would fail the same way.
    public func quotes(for symbols: [String]) async throws(ProviderError) -> QuoteBatch {
        var batch = QuoteBatch(quotes: [])
        var seen = Set<String>()
        for symbol in symbols where seen.insert(symbol.uppercased()).inserted {
            switch try await quote(for: symbol) {
            case .quote(let quote): batch.quotes.append(quote)
            case .unknown: batch.unknownSymbols.append(symbol)
            case .unusable: batch.unusableSymbols.append(symbol)
            }
        }
        return batch
    }

    public func testConnection() async throws(ProviderError) {
        let batch = try await quotes(for: [Self.connectionTestSymbol])
        guard batch.quotes.isEmpty else { return }
        if !batch.unusableSymbols.isEmpty { throw .noUsableQuote(batch.unusableSymbols) }
        throw .malformedResponse(detail: "no quote for \(Self.connectionTestSymbol)")
    }

    // MARK: One symbol

    private enum Outcome {
        case quote(Quote)
        case unknown
        case unusable
    }

    private func quote(for symbol: String) async throws(ProviderError) -> Outcome {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let path = trimmed.addingPercentEncoding(withAllowedCharacters: Self.symbolAllowed),
              var components = URLComponents(string: Self.chartURL + path)
        else { return .unknown }
        components.queryItems = [URLQueryItem(name: "range", value: "1d"), URLQueryItem(name: "interval", value: "1d")]

        let (data, response) = try await send(URLRequest(url: components.url!))
        if let host = response.url?.host?.lowercased(),
           host.hasSuffix("consent.yahoo.com") || host.hasSuffix("guce.yahoo.com") {
            throw .blocked
        }
        switch response.statusCode {
        case 200: break
        case 404:
            // Yahoo's "No data found, symbol may be delisted", as a chart error.
            guard (try? JSONDecoder().decode(ChartResponse.self, from: data))?.chart.error != nil else {
                throw .malformedResponse(detail: "unexpected HTTP status 404")
            }
            return .unknown
        case 403: throw .blocked
        case 429: throw .rateLimited(retryAfter: Self.retryAfter(response.value(forHTTPHeaderField: "Retry-After")))
        case 500...599: throw .unavailable
        default: throw .malformedResponse(detail: "unexpected HTTP status \(response.statusCode)")
        }

        let chart: ChartResponse.Chart
        do {
            chart = try JSONDecoder().decode(ChartResponse.self, from: data).chart
        } catch {
            throw .malformedResponse(detail: "not the chart JSON Vettira expects")
        }
        guard let meta = chart.result?.first?.meta else { return chart.error != nil ? .unknown : .unusable }
        guard let price = meta.regularMarketPrice, price > 0,
              let time = meta.regularMarketTime, time > 0
        else { return .unusable }
        return .quote(Quote(
            symbol: meta.symbol ?? trimmed,
            price: price,
            timestamp: Date(timeIntervalSince1970: time),
            source: name,
            sessionHigh: meta.regularMarketDayHigh.flatMap { $0 > 0 ? $0 : nil },
            session: Self.session(at: time, regular: meta.currentTradingPeriod?.regular),
            providerDelay: nil))
    }

    /// `.regular` when the quote's time falls in the regular period Yahoo reports for the day, its
    /// close included, and `.closed` otherwise: the price is always the regular session's, so a
    /// time outside it is from a session that has ended. `.unknown` without the period.
    private static func session(at time: TimeInterval, regular: ChartResponse.Period?) -> Quote.Session {
        guard let regular, regular.start <= regular.end else { return .unknown }
        return (regular.start...regular.end).contains(time) ? .regular : .closed
    }

    /// A Retry-After header's wait: whole seconds only (its delay-seconds form), at most a day.
    /// Anything else, an HTTP date included, is no wait given.
    private static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let header, let seconds = Int(header.trimmingCharacters(in: .whitespaces)), seconds >= 0 else {
            return nil
        }
        return TimeInterval(min(seconds, 86_400))
    }

    private struct ChartResponse: Decodable {
        struct Chart: Decodable {
            let result: [Result]?
            let error: ChartError?
        }
        struct ChartError: Decodable {
            let code: String?
        }
        struct Result: Decodable {
            let meta: Meta?
        }
        struct Meta: Decodable {
            let symbol: String?
            let regularMarketPrice: Double?
            let regularMarketTime: Double?
            let regularMarketDayHigh: Double?
            let currentTradingPeriod: TradingPeriods?
        }
        struct TradingPeriods: Decodable {
            let regular: Period?
        }
        struct Period: Decodable {
            let start: TimeInterval
            let end: TimeInterval
        }
        let chart: Chart
    }

    // MARK: HTTP

    /// Waits for any request in flight, then out the pacing interval since the last one, then
    /// sends this one.
    private func send(_ request: URLRequest) async throws(ProviderError) -> (Data, HTTPURLResponse) {
        if sending {
            await withCheckedContinuation { queued.append($0) }
        } else {
            sending = true
        }
        defer {
            if queued.isEmpty { sending = false } else { queued.removeFirst().resume() }
        }
        if let lastRequest {
            let wait = pacing.interval - lastRequest.duration(to: pacing.now())
            if wait > .zero { await pacing.sleep(wait) }
        }
        // A cancelled poll sends nothing more; its caller has stopped listening for the result.
        if Task.isCancelled { throw .unavailable }
        var request = request
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        lastRequest = pacing.now()
        do {
            return try await http.data(for: request)
        } catch {
            throw .unavailable
        }
    }

    /// What a symbol may hold unescaped in the path: letters, digits and the `.`, `-` and `=` of
    /// class shares and currencies. Anything else, an index's `^` included, is percent-encoded.
    private static let symbolAllowed: CharacterSet = {
        var allowed = CharacterSet.alphanumerics.intersection(CharacterSet(charactersIn: "\u{0}"..."\u{7F}"))
        allowed.insert(charactersIn: ".-=")
        return allowed
    }()
}

/// How a provider spaces its requests: at least `interval` apart, measured with `now` and waited
/// with `sleep`. Tests pass a clock that doesn't really wait.
public struct RequestPacing: Sendable {
    public var interval: Duration
    public var now: @Sendable () -> ContinuousClock.Instant
    public var sleep: @Sendable (Duration) async -> Void

    public init(
        interval: Duration,
        now: @escaping @Sendable () -> ContinuousClock.Instant,
        sleep: @escaping @Sendable (Duration) async -> Void
    ) {
        self.interval = interval
        self.now = now
        self.sleep = sleep
    }

    /// At most one request a second, on the real clock.
    public static let oncePerSecond = RequestPacing(
        interval: .seconds(1), now: { .now }, sleep: { try? await Task.sleep(for: $0) })
}
