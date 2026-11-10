import Foundation
import Testing
import VettiraCore

@Suite struct YahooHistoryTests {
    private func provider(
        _ replies: [FakeHTTPClient.Reply], clock: PacingClock = PacingClock()
    ) -> (YahooFinanceProvider, FakeHTTPClient) {
        let http = FakeHTTPClient(replies)
        return (YahooFinanceProvider(http: http, pacing: clock.pacing), http)
    }

    private func query(of request: URLRequest) -> [String: String] {
        let items = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
    }

    /// Each timeframe, the range and interval it asks for (the spec's: 1D at a minute, 5D at 5
    /// minutes, 1M at 30, 6M, YTD and 1Y at a day, 5Y at a week), the bars in SPY's recorded
    /// response, and the close before them.
    struct Case: Sendable {
        let timeframe: ChartTimeframe, range: String, interval: String, bars: Int, previousClose: Double
        var fixture: String { ["1d", "5d", "1mo"].contains(range) ? "\(range)-\(interval)" : range }
    }

    static let timeframes = [
        // A session is 390 minutes, so a minute's bars from 09:30 to 16:00 are 391, as are five
        // sessions of 5-minute bars (5 × 78 + the last close); a month of 30-minute bars, 274.
        Case(timeframe: .oneDay, range: "1d", interval: "1m", bars: 391, previousClose: 735.29),
        Case(timeframe: .fiveDays, range: "5d", interval: "5m", bars: 391, previousClose: 752.1),
        Case(timeframe: .oneMonth, range: "1mo", interval: "30m", bars: 274, previousClose: 778.57),
        Case(timeframe: .sixMonths, range: "6mo", interval: "1d", bars: 127, previousClose: 737.62),
        Case(timeframe: .yearToDate, range: "ytd", interval: "1d", bars: 215, previousClose: 681.92),
        Case(timeframe: .oneYear, range: "1y", interval: "1d", bars: 251, previousClose: 670.97),
        Case(timeframe: .fiveYears, range: "5y", interval: "1wk", bars: 262, previousClose: 467.38),
    ]

    @Test(arguments: timeframes)
    func eachTimeframeIsOneRequestForItsRangeAndInterval(_ test: Case) async throws {
        let (timeframe, range, interval, bars, previousClose) = (test.timeframe, test.range, test.interval, test.bars, test.previousClose)
        let (yahoo, http) = provider([Yahoo.chart("SPY", try HistoryFixtures.spy(test.fixture))])
        let history = try await yahoo.history(for: "SPY", timeframe: timeframe)

        let requests = await http.requests
        #expect(requests.count == 1)
        #expect(query(of: requests[0]) == ["range": range, "interval": interval, "includePrePost": "false"])
        #expect(requests[0].value(forHTTPHeaderField: "User-Agent") == "Vettira (https://github.com/nikpietanze/vettira)")

        #expect(history.symbol == "SPY")
        #expect(history.timeframe == timeframe)
        #expect(history.name == "State Street SPDR S&P 500 ETF Trust")
        #expect(history.previousClose == previousClose)
        #expect(history.bars.count == bars)
        // Oldest first, each with its open, high, low, close and volume.
        #expect(zip(history.bars, history.bars.dropFirst()).allSatisfy { $0.timestamp < $1.timestamp })
        #expect(history.bars.allSatisfy {
            $0.open != nil && $0.close != nil && $0.volume != nil
                && ($0.high ?? 0) >= max($0.open!, $0.close!) - 0.01 && ($0.low ?? .infinity) <= min($0.open!, $0.close!) + 0.01
        })
        #expect(history.bars.last?.close.map { ($0 * 100).rounded() / 100 } == 752.69)
    }

    @Test func theIntradayRangesRunFromTheOpenToTheClose() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", try HistoryFixtures.spy("1d-1m"))])
        let history = try await yahoo.history(for: "SPY", timeframe: .oneDay)
        #expect(history.bars.first?.timestamp == HistoryFixtures.open)
        #expect(history.bars.last?.timestamp == HistoryFixtures.close)
    }

    @Test func aBarWithoutTradesIsAGap() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", HistoryFixtures.withGap)])
        let history = try await yahoo.history(for: "SPY", timeframe: .fiveDays)
        let open = HistoryFixtures.open
        #expect(history.bars == [
            PriceBar(timestamp: open, close: 752.4, high: 753.1, open: 752.73, low: 752.0, volume: 1_200_000),
            PriceBar(timestamp: open + 900, close: nil, high: nil, open: nil, low: nil, volume: nil),
            PriceBar(timestamp: open + 1800, close: 750.8, high: 751.0, open: 750.2, low: 749.9, volume: 900_000),
        ])
        // No name in the response, so none.
        #expect(history.name == nil)
    }

    @Test func anUnknownSymbolSaysSo() async throws {
        let (yahoo, _) = provider([Yahoo.chart("VETTIRAZZ", YahooFixtures.unknownSymbol, status: 404)])
        await #expect(throws: ProviderError.unknownSymbols(["VETTIRAZZ"])) {
            try await yahoo.history(for: "VETTIRAZZ", timeframe: .oneYear)
        }
    }

    @Test func aRateLimitIsTheProvidersError() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", "", status: 429, headers: ["Retry-After": "120"])])
        await #expect(throws: ProviderError.rateLimited(retryAfter: 120)) {
            try await yahoo.history(for: "SPY", timeframe: .oneYear)
        }
    }

    @Test func aHistoryRequestWaitsItsTurnWithThePollsAndKeepsTheirPace() async throws {
        let clock = PacingClock()
        // The same symbol's URL either way, so whichever goes first gets the first reply; both
        // bodies read as a quote and as a history.
        let (yahoo, http) = provider([
            Yahoo.chart("SPY", try HistoryFixtures.spy("1d")), Yahoo.chart("SPY", try HistoryFixtures.spy("1y")),
            Yahoo.chart("SPY", try HistoryFixtures.spy("5d-5m")),
        ], clock: clock)
        async let poll = yahoo.quotes(for: ["SPY"])
        async let history = yahoo.history(for: "SPY", timeframe: .oneYear)
        async let another = yahoo.history(for: "SPY", timeframe: .fiveDays)
        _ = try await (poll, history, another)

        // Never two requests in flight, and a second between any two.
        #expect(await http.mostInFlight == 1)
        #expect(await http.requests.count == 3)
        #expect(clock.sleeps == [.seconds(1), .seconds(1)])
    }

    @Test func thePollsStayAtFiveMinutesWhileTheChartsDayIsAtAMinute() async throws {
        let (yahoo, http) = provider([
            Yahoo.chart("SPY", try HistoryFixtures.spy("1d")), Yahoo.chart("SPY", try HistoryFixtures.spy("1d-1m")),
        ])
        _ = try await yahoo.quotes(for: ["SPY"])
        _ = try await yahoo.history(for: "SPY", timeframe: .oneDay)
        #expect(await http.requests.map { query(of: $0)["interval"] } == ["5m", "1m"])
    }

    @Test func thePollsQuoteHasTheDaysOpenLowVolumeAndName() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", try HistoryFixtures.spy("1d"))])
        let quote = try #require(try await yahoo.quotes(for: ["SPY"]).quotes.first)
        #expect(quote.name == "State Street SPDR S&P 500 ETF Trust")
        // Yahoo's own count for the day, which is more than its 5-minute bars add up to.
        #expect(quote.dayVolume == 48_888_639)
        #expect(quote.sessionLow == 741.09)
        #expect(quote.intraday.first?.open.map { ($0 * 100).rounded() / 100 } == 741.95)
        #expect(quote.intraday.allSatisfy { $0.low != nil && $0.volume != nil })
    }
}
