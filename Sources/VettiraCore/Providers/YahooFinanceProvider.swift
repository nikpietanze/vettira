import Foundation

/// Quotes from Yahoo Finance's unofficial chart endpoint, one of those the yfinance project uses.
///
/// It's undocumented and not licensed or endorsed by Yahoo; it can change or be blocked without
/// notice, and Yahoo's terms govern its use (docs/providers.md). No key, no account, no cookie: one
/// request per symbol, sent one at a time and at most one a second, with a User-Agent that names
/// Vettira. Each request asks for the day's 5-minute bars, so the same request that brings the
/// quote brings the day's chart. A longer chart's history is one more request, for one symbol and
/// timeframe, only when the user opens it (`history(for:timeframe:)`). It reads the regular
/// session's fields and bars only, never an extended-hours price, and never scrapes a page.
public actor YahooFinanceProvider: MarketDataProvider {
    public nonisolated let name = "Yahoo Finance (unofficial)"

    /// Says plainly what's asking; never a browser's.
    static let userAgent = "Vettira (https://github.com/nikpietanze/vettira)"
    static let chartURL = "https://query1.finance.yahoo.com/v8/finance/chart/"

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

    /// `symbol`'s bars over `timeframe`: one request for the timeframe's range and interval
    /// (`parameters(for:)`), regular session only, sent in turn with the polls' requests and at
    /// the same pace.
    public func history(for symbol: String, timeframe: ChartTimeframe) async throws(ProviderError) -> PriceHistory {
        let (range, interval) = Self.parameters(for: timeframe)
        switch try await chart(for: symbol, range: range, interval: interval) {
        case .unknown: throw .unknownSymbols([symbol])
        case .unusable: throw .noUsableQuote([symbol])
        case .result(let result, let meta):
            return PriceHistory(
                symbol: meta.symbol ?? symbol.trimmingCharacters(in: .whitespaces), timeframe: timeframe,
                bars: Self.bars(result), previousClose: Self.positive(meta.chartPreviousClose), name: meta.name)
        }
    }

    /// The chart endpoint's `range` and `interval` for a timeframe.
    static func parameters(for timeframe: ChartTimeframe) -> (range: String, interval: String) {
        switch timeframe {
        case .oneDay: ("1d", "5m")
        case .fiveDays: ("5d", "15m")
        case .oneMonth: ("1mo", "60m")
        case .sixMonths: ("6mo", "1d")
        case .yearToDate: ("ytd", "1d")
        case .oneYear: ("1y", "1d")
        case .fiveYears: ("5y", "1wk")
        }
    }

    // MARK: One symbol

    private enum Outcome {
        case quote(Quote)
        case unknown
        case unusable
    }

    /// The symbol's quote, from the day's chart: the same request brings the day's bars.
    private func quote(for symbol: String) async throws(ProviderError) -> Outcome {
        let (range, interval) = Self.parameters(for: .oneDay)
        let fetched = try await chart(for: symbol, range: range, interval: interval)
        guard case .result(let result, let meta) = fetched else {
            if case .unknown = fetched { return .unknown }
            return .unusable
        }
        guard let price = meta.regularMarketPrice, price > 0,
              let time = meta.regularMarketTime, time > 0
        else { return .unusable }
        return .quote(Quote(
            symbol: meta.symbol ?? symbol.trimmingCharacters(in: .whitespaces),
            price: price,
            timestamp: Date(timeIntervalSince1970: time),
            source: name,
            sessionHigh: meta.regularMarketDayHigh.flatMap { $0 > 0 ? $0 : nil },
            session: Self.session(at: time, regular: meta.currentTradingPeriod?.regular),
            providerDelay: nil,
            previousClose: Self.positive(meta.chartPreviousClose),
            intraday: Self.bars(result),
            name: meta.name,
            dayVolume: Self.volume(meta.regularMarketVolume),
            sessionLow: Self.positive(meta.regularMarketDayLow)))
    }

    private enum Fetched {
        case result(ChartResponse.Result, ChartResponse.Meta)
        /// Yahoo doesn't know the symbol.
        case unknown
        /// Yahoo answered without a result for it.
        case unusable
    }

    /// One request to the chart endpoint for `symbol` over `range` at `interval`, regular session
    /// only, and its result; or the error that stops it.
    private func chart(for symbol: String, range: String, interval: String) async throws(ProviderError) -> Fetched {
        let trimmed = symbol.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let path = trimmed.addingPercentEncoding(withAllowedCharacters: Self.symbolAllowed),
              var components = URLComponents(string: Self.chartURL + path)
        else { return .unknown }
        components.queryItems = [
            URLQueryItem(name: "range", value: range), URLQueryItem(name: "interval", value: interval),
            URLQueryItem(name: "includePrePost", value: "false"),
        ]

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
        guard let result = chart.result?.first, let meta = result.meta else {
            return chart.error != nil ? .unknown : .unusable
        }
        return .result(result, meta)
    }

    /// The result's bars, oldest first. A missing, zero or negative close is a gap (Yahoo sends
    /// `null` for a bar with no trades), and a bar whose time isn't after the one before is dropped.
    /// Open, low and volume are read when they're there; without them a bar still has its close.
    private static func bars(_ result: ChartResponse.Result) -> [PriceBar] {
        guard let times = result.timestamp else { return [] }
        let prices = result.indicators?.quote?.first
        var bars: [PriceBar] = []
        for (index, time) in times.enumerated() {
            guard let time, time > 0, bars.last.map({ time > $0.timestamp.timeIntervalSince1970 }) ?? true else {
                continue
            }
            bars.append(PriceBar(
                timestamp: Date(timeIntervalSince1970: time),
                close: positive(prices?.close?[safe: index] ?? nil),
                high: positive(prices?.high?[safe: index] ?? nil),
                open: positive(prices?.open?[safe: index] ?? nil),
                low: positive(prices?.low?[safe: index] ?? nil),
                volume: volume(prices?.volume?[safe: index] ?? nil)))
        }
        return bars
    }

    /// A whole, non-negative number of shares.
    private static func volume(_ value: Double?) -> Int? {
        value.flatMap { $0.isFinite && $0 >= 0 && $0 < 1e15 ? Int($0) : nil }
    }

    /// The value when it's a finite price above 0.
    private static func positive(_ value: Double?) -> Double? {
        value.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
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
            let timestamp: [Double?]?
            let indicators: Indicators?

            private enum CodingKeys: String, CodingKey { case meta, timestamp, indicators }

            // Bars that can't be read leave the quote without a chart, never without a quote.
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                meta = try container.decodeIfPresent(Meta.self, forKey: .meta)
                timestamp = try? container.decodeIfPresent([Double?].self, forKey: .timestamp)
                indicators = try? container.decodeIfPresent(Indicators.self, forKey: .indicators)
            }
        }
        struct Meta: Decodable {
            let symbol: String?
            let regularMarketPrice: Double?
            let regularMarketTime: Double?
            let regularMarketDayHigh: Double?
            let chartPreviousClose: Double?
            let currentTradingPeriod: TradingPeriods?
            let longName: String?
            let shortName: String?
            let regularMarketVolume: Double?
            let regularMarketDayLow: Double?

            /// The security's name: its long name, or its short one, trimmed; `nil` without either.
            var name: String? {
                [longName, shortName].lazy.compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .first { !$0.isEmpty }
            }
        }
        struct Indicators: Decodable {
            let quote: [Bars]?
        }
        struct Bars: Decodable {
            let close: [Double?]?
            let high: [Double?]?
            let open: [Double?]?
            let low: [Double?]?
            let volume: [Double?]?

            private enum CodingKeys: String, CodingKey { case close, high, open, low, volume }

            // Close and high as before; an open, low or volume that can't be read is left out.
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                close = try container.decodeIfPresent([Double?].self, forKey: .close)
                high = try container.decodeIfPresent([Double?].self, forKey: .high)
                open = try? container.decodeIfPresent([Double?].self, forKey: .open)
                low = try? container.decodeIfPresent([Double?].self, forKey: .low)
                volume = try? container.decodeIfPresent([Double?].self, forKey: .volume)
            }
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

extension Array {
    /// The element at `index`, or `nil` past the end.
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
