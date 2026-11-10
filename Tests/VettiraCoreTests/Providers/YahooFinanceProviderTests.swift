import Foundation
import Testing
import VettiraCore

@Suite struct YahooFinanceProviderTests {
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

    private let source = "Yahoo Finance (unofficial)"

    // MARK: Quotes

    @Test func readsEachFieldOfARegularSessionQuote() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spy), Yahoo.chart("AAPL", YahooFixtures.aapl)])
        let batch = try await yahoo.quotes(for: ["SPY", "AAPL"])

        #expect(batch.quotes == [
            Quote(symbol: "SPY", price: 752.68, timestamp: YahooFixtures.quoteTime, source: source,
                  sessionHigh: 752.96, session: .regular, providerDelay: nil),
            Quote(symbol: "AAPL", price: 349.35, timestamp: YahooFixtures.quoteTime, source: source,
                  sessionHigh: 351.42, session: .regular, providerDelay: nil),
        ])
        #expect(batch.unknownSymbols.isEmpty)
        #expect(batch.unusableSymbols.isEmpty)
    }

    @Test(arguments: [
        (YahooFixtures.regularStart, Quote.Session.regular),
        (YahooFixtures.regularEnd, .regular),
        (YahooFixtures.regularStart - 1, .closed),
        (YahooFixtures.regularEnd + 1, .closed),
        (YahooFixtures.regularEnd - 86_400, .closed),
    ])
    func theSessionIsWhetherTheQuoteTimeFallsInTheRegularPeriod(time: TimeInterval, session: Quote.Session) async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spy(at: time))])
        let batch = try await yahoo.quotes(for: ["SPY"])
        #expect(batch.quotes.first?.session == session)
    }

    @Test func withoutTheTradingPeriodTheSessionIsUnknown() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spy(without: "currentTradingPeriod"))])
        let batch = try await yahoo.quotes(for: ["SPY"])
        #expect(batch.quotes.first?.session == .unknown)
    }

    @Test func withoutADayHighThereIsNoSessionHigh() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spy(without: "regularMarketDayHigh"))])
        let batch = try await yahoo.quotes(for: ["SPY"])
        #expect(batch.quotes.count == 1)
        #expect(batch.quotes.first?.sessionHigh == nil)
    }

    @Test func anUnknownSymbolIsListedAndTheRestStillCome() async throws {
        let (yahoo, _) = provider([
            Yahoo.chart("SPY", YahooFixtures.spy),
            Yahoo.chart("VETTIRAZZ", YahooFixtures.unknownSymbol, status: 404),
            Yahoo.chart("AAPL", YahooFixtures.aapl),
        ])
        let batch = try await yahoo.quotes(for: ["SPY", "VETTIRAZZ", "AAPL"])
        #expect(batch.quotes.map(\.symbol) == ["SPY", "AAPL"])
        #expect(batch.unknownSymbols == ["VETTIRAZZ"])
        #expect(batch.unusableSymbols.isEmpty)
    }

    @Test func aSymbolWithoutUsableDataIsListedAndTheRestStillCome() async throws {
        let (yahoo, _) = provider([
            Yahoo.chart("HALT", YahooFixtures.spy(without: "regularMarketPrice")),
            Yahoo.chart("NEWCO", YahooFixtures.spy(without: "regularMarketTime")),
            Yahoo.chart("ZERO", YahooFixtures.spyWithZeroPrice),
            Yahoo.chart("EMPTY", YahooFixtures.noResult),
            Yahoo.chart("AAPL", YahooFixtures.aapl),
        ])
        let batch = try await yahoo.quotes(for: ["HALT", "NEWCO", "ZERO", "EMPTY", "AAPL"])
        #expect(batch.quotes.map(\.symbol) == ["AAPL"])
        #expect(batch.unusableSymbols == ["HALT", "NEWCO", "ZERO", "EMPTY"])
        #expect(batch.unknownSymbols.isEmpty)
    }

    // MARK: The day's bars

    @Test func readsTheDaysBarsAndThePreviousClose() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spyWithBars)])
        let quote = try #require(try await yahoo.quotes(for: ["SPY"]).quotes.first)
        let open = YahooFixtures.regularStart
        #expect(quote.previousClose == YahooFixtures.previousClose)
        #expect(quote.intraday == [
            PriceBar(timestamp: Date(timeIntervalSince1970: open), close: 751.2, high: 751.5),
            PriceBar(timestamp: Date(timeIntervalSince1970: open + 300), close: 751.9, high: 752.1),
            PriceBar(timestamp: Date(timeIntervalSince1970: open + 600), close: nil, high: nil),
            PriceBar(timestamp: Date(timeIntervalSince1970: open + 900), close: 752.4, high: 752.6),
        ])
        // The quote's own fields are the meta's, as before.
        #expect(quote.price == 752.68)
        #expect(quote.timestamp == YahooFixtures.quoteTime)
        #expect(quote.sessionHigh == 752.96)
    }

    @Test func readsARealDaysBarsFromTheOpenToTheClose() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spyDay)])
        let quote = try #require(try await yahoo.quotes(for: ["SPY"]).quotes.first)
        #expect(quote.price == 752.69)
        #expect(quote.previousClose == 735.29)
        #expect(quote.session == .regular)
        // 09:30 to 16:00, every 5 minutes, each with a price and a high.
        #expect(quote.intraday.map(\.timestamp)
            == stride(from: YahooFixtures.regularStart, through: YahooFixtures.regularEnd, by: 300).map {
                Date(timeIntervalSince1970: $0)
            })
        #expect(quote.intraday.allSatisfy { $0.close != nil && $0.high != nil })
        #expect(quote.intraday.last?.close.map { ($0 * 100).rounded() / 100 } == 752.69)
        // The bars' highest high is the day's high Yahoo reports.
        let highest = try #require(quote.intraday.compactMap(\.high).max())
        #expect((highest * 100).rounded() / 100 == quote.sessionHigh)
    }

    @Test func aRealDaysChartIsUpOnTheDay() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spyDay)])
        let quote = try #require(try await yahoo.quotes(for: ["SPY"]).quotes.first)
        // The next morning, before the open.
        let chart = try #require(PriceChart(quote: quote, now: YahooFixtures.quoteTime + 14 * 3600))
        #expect(chart.direction == .up)
        #expect(chart.description == "Chart of the last session's price for SPY: up 2.37% from the previous close of 735.29.")
        #expect(chart.segments.count == 1)
        #expect(chart.segments[0].count == 79)
    }

    @Test func barsThatCantBeReadLeaveTheQuoteWithoutAChart() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spyWithUnreadableBars)])
        let batch = try await yahoo.quotes(for: ["SPY"])
        let quote = try #require(batch.quotes.first)
        #expect(quote.price == 752.68)
        #expect(quote.intraday.isEmpty)
        #expect(quote.previousClose == nil)
    }

    @Test func withoutBarsTheQuoteHasNone() async throws {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spy)])
        let quote = try #require(try await yahoo.quotes(for: ["SPY"]).quotes.first)
        #expect(quote.intraday.isEmpty)
    }

    @Test func noSymbolsSendsNoRequest() async throws {
        let (yahoo, http) = provider([])
        #expect(try await yahoo.quotes(for: []) == QuoteBatch(quotes: []))
        #expect(await http.requests.isEmpty)
    }

    @Test func aBlankSymbolIsUnknownWithoutARequest() async throws {
        let (yahoo, http) = provider([])
        let batch = try await yahoo.quotes(for: ["  "])
        #expect(batch.unknownSymbols == ["  "])
        #expect(await http.requests.isEmpty)
    }

    // MARK: The requests

    @Test func asksForEachSymbolOnceInOrderWithAnHonestUserAgent() async throws {
        let (yahoo, http) = provider([Yahoo.chart("SPY", YahooFixtures.spy), Yahoo.chart("AAPL", YahooFixtures.aapl)])
        _ = try await yahoo.quotes(for: ["SPY", "AAPL", "spy"])
        let requests = await http.requests
        #expect(requests.count == 2)
        for request in requests {
            #expect(query(of: request) == ["range": "1d", "interval": "5m", "includePrePost": "false"])
            let agent = try #require(request.value(forHTTPHeaderField: "User-Agent"))
            #expect(agent == "Vettira (https://github.com/nikpietanze/vettira)")
            #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        }
    }

    @Test func escapesSymbolsInThePath() async throws {
        let (yahoo, _) = provider([
            Yahoo.chart("%5EGSPC", YahooFixtures.noResult),
            Yahoo.chart("BRK-B", YahooFixtures.noResult),
            Yahoo.chart("EURUSD=X", YahooFixtures.noResult),
            Yahoo.chart("A%2FB", YahooFixtures.noResult),
        ])
        // The fake checks each request's URL against the escaped symbol.
        _ = try await yahoo.quotes(for: ["^GSPC", "BRK-B", "EURUSD=X", "A/B"])
    }

    @Test func waitsASecondBetweenRequests() async throws {
        let clock = PacingClock()
        let (yahoo, _) = provider(
            [Yahoo.chart("SPY", YahooFixtures.spy), Yahoo.chart("AAPL", YahooFixtures.aapl),
             Yahoo.chart("QQQ", YahooFixtures.noResult), Yahoo.chart("SPY", YahooFixtures.spy),
             Yahoo.chart("SPY", YahooFixtures.spy)],
            clock: clock)
        _ = try await yahoo.quotes(for: ["SPY", "AAPL", "QQQ"])
        #expect(clock.sleeps == [.seconds(1), .seconds(1)])

        clock.advance(by: .milliseconds(400))
        _ = try await yahoo.quotes(for: ["SPY"])
        #expect(clock.sleeps.last == .milliseconds(600))

        clock.advance(by: .seconds(2))
        _ = try await yahoo.quotes(for: ["SPY"])
        #expect(clock.sleeps.count == 3)
    }

    @Test func concurrentPollsStillSendOneRequestAtATime() async throws {
        let (yahoo, http) = provider((0..<6).map { _ in Yahoo.chart("SPY", YahooFixtures.spy) })
        async let first = yahoo.quotes(for: ["SPY"])
        async let second = yahoo.quotes(for: ["SPY"])
        async let third = yahoo.quotes(for: ["SPY"])
        _ = try await (first, second, third)
        #expect(await http.requests.count == 3)
        #expect(await http.mostInFlight == 1)
    }

    // MARK: Errors that stop the poll

    @Test func rateLimitedStopsThePollWithTheRetryAfter() async {
        let (yahoo, http) = provider([
            Yahoo.chart("SPY", YahooFixtures.spy),
            Yahoo.chart("AAPL", YahooFixtures.tooManyRequests, status: 429, headers: ["Retry-After": "30"]),
        ])
        await #expect(throws: ProviderError.rateLimited(retryAfter: 30)) {
            try await yahoo.quotes(for: ["SPY", "AAPL", "QQQ"])
        }
        #expect(await http.requests.count == 2)
    }

    @Test func rateLimitedWithoutARetryAfter() async {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.tooManyRequests, status: 429)])
        await #expect(throws: ProviderError.rateLimited(retryAfter: nil)) { try await yahoo.quotes(for: ["SPY"]) }
    }

    @Test(arguments: [
        ("inf", nil),
        ("nan", nil),
        ("-30", nil),
        ("1e20", nil),
        ("2.5", nil),
        ("Wed, 11 Nov 2026 15:00:00 GMT", nil),
        (" 45 ", 45),
        ("99999999", 86_400),
    ] as [(String, TimeInterval?)])
    func aRetryAfterIsKeptOnlyAsWholeSecondsUpToADay(header: String, retryAfter: TimeInterval?) async {
        let (yahoo, _) = provider([
            Yahoo.chart("SPY", YahooFixtures.tooManyRequests, status: 429, headers: ["Retry-After": header]),
        ])
        do {
            _ = try await yahoo.quotes(for: ["SPY"])
            Issue.record("expected a rate limit")
        } catch {
            #expect(error == .rateLimited(retryAfter: retryAfter))
            if error == .rateLimited(retryAfter: retryAfter) {
                #expect(!error.message.isEmpty) // shown without trapping
            }
        }
    }

    @Test func forbiddenStopsThePollAsBlocked() async {
        let (yahoo, http) = provider([Yahoo.chart("SPY", "Forbidden", status: 403)])
        await #expect(throws: ProviderError.blocked) { try await yahoo.quotes(for: ["SPY", "AAPL"]) }
        #expect(await http.requests.count == 1)
    }

    @Test func aConsentRedirectIsBlocked() async {
        var reply = Yahoo.chart("SPY", YahooFixtures.consentPage, headers: ["Content-Type": "text/html"])
        reply.finalURL = "https://consent.yahoo.com/v2/collectConsent?sessionId=hand-made"
        let (yahoo, _) = provider([reply])
        await #expect(throws: ProviderError.blocked) { try await yahoo.quotes(for: ["SPY"]) }
    }

    @Test func aResponseThatIsntChartJSONIsMalformed() async {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.consentPage)])
        await #expect(throws: ProviderError.malformedResponse(detail: "not the chart JSON Vettira expects")) {
            try await yahoo.quotes(for: ["SPY"])
        }
    }

    @Test func aNotFoundThatIsntAChartErrorIsMalformed() async {
        let (yahoo, _) = provider([Yahoo.chart("SPY", "Not Found", status: 404)])
        await #expect(throws: ProviderError.malformedResponse(detail: "unexpected HTTP status 404")) {
            try await yahoo.quotes(for: ["SPY"])
        }
    }

    @Test func anUnexpectedStatusIsMalformed() async {
        let (yahoo, _) = provider([Yahoo.chart("SPY", "Unauthorized", status: 401)])
        await #expect(throws: ProviderError.malformedResponse(detail: "unexpected HTTP status 401")) {
            try await yahoo.quotes(for: ["SPY"])
        }
    }

    @Test func aServerErrorIsUnavailable() async {
        let (yahoo, _) = provider([Yahoo.chart("SPY", "Service Unavailable", status: 503)])
        await #expect(throws: ProviderError.unavailable) { try await yahoo.quotes(for: ["SPY"]) }
    }

    @Test func noNetworkIsUnavailable() async {
        var reply = Yahoo.chart("SPY", "")
        reply.networkError = .notConnectedToInternet
        let (yahoo, _) = provider([reply])
        await #expect(throws: ProviderError.unavailable) { try await yahoo.quotes(for: ["SPY"]) }
    }

    // MARK: Test Connection

    @Test func testConnectionAsksForTheSymbolOnceAndReturnsItsQuote() async throws {
        let (yahoo, http) = provider([Yahoo.chart("QQQ", YahooFixtures.spy)])
        let quote = try await yahoo.testConnection(symbol: "QQQ")
        #expect(quote.price == 752.68)
        #expect(quote.timestamp == YahooFixtures.quoteTime)
        #expect(await http.requests.count == 1)
    }

    @Test func testConnectionFailsWithTheProvidersError() async {
        let (yahoo, _) = provider([Yahoo.chart("SPY", "Forbidden", status: 403)])
        await #expect(throws: ProviderError.blocked) { try await yahoo.testConnection(symbol: "SPY") }
    }

    @Test func testConnectionFailsWhenTheQuoteHasNoUsableData() async {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spy(without: "regularMarketPrice"))])
        await #expect(throws: ProviderError.noUsableQuote(["SPY"])) { try await yahoo.testConnection(symbol: "SPY") }
    }

    @Test func testConnectionFailsWhenTheSymbolIsUnknown() async {
        let (yahoo, _) = provider([Yahoo.chart("VETTIRAZZ", YahooFixtures.unknownSymbol, status: 404)])
        await #expect(throws: ProviderError.unknownSymbols(["VETTIRAZZ"])) {
            try await yahoo.testConnection(symbol: "VETTIRAZZ")
        }
    }

    @Test func testConnectionDuringAPollWaitsItsTurnAndThePacing() async throws {
        // The same symbol throughout, since which request goes first is up to the scheduler.
        let clock = PacingClock()
        let (yahoo, http) = provider((0..<3).map { _ in Yahoo.chart("SPY", YahooFixtures.spy) }, clock: clock)
        async let poll = yahoo.quotes(for: ["SPY"])
        async let test = yahoo.testConnection(symbol: "SPY")
        async let nextPoll = yahoo.quotes(for: ["SPY"])
        _ = try await (poll, test, nextPoll)
        #expect(await http.mostInFlight == 1)
        #expect(await http.requests.count == 3)
        // Each request a second after the last.
        #expect(clock.sleeps == [.seconds(1), .seconds(1)])
    }

    // MARK: What it is

    @Test func itPollsAndSaysItsUnofficial() {
        let yahoo = YahooFinanceProvider(http: FakeHTTPClient([]))
        #expect(yahoo.streams == false)
        #expect(yahoo.name == "Yahoo Finance (unofficial)")
    }
}
