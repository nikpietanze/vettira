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
            #expect(query(of: request) == ["range": "1d", "interval": "1d"])
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

    @Test func testConnectionAsksForSPYAndPassesWhenItComes() async throws {
        let (yahoo, http) = provider([Yahoo.chart("SPY", YahooFixtures.spy)])
        try await yahoo.testConnection()
        #expect(await http.requests.count == 1)
    }

    @Test func testConnectionFailsWithTheProvidersError() async {
        let (yahoo, _) = provider([Yahoo.chart("SPY", "Forbidden", status: 403)])
        await #expect(throws: ProviderError.blocked) { try await yahoo.testConnection() }
    }

    @Test func testConnectionFailsWhenTheQuoteHasNoUsableData() async {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.spy(without: "regularMarketPrice"))])
        await #expect(throws: ProviderError.noUsableQuote(["SPY"])) { try await yahoo.testConnection() }
    }

    @Test func testConnectionFailsWhenSPYIsUnknown() async {
        let (yahoo, _) = provider([Yahoo.chart("SPY", YahooFixtures.unknownSymbol, status: 404)])
        await #expect(throws: ProviderError.malformedResponse(detail: "no quote for SPY")) { try await yahoo.testConnection() }
    }

    // MARK: What it is

    @Test func itPollsAndSaysItsUnofficial() {
        let yahoo = YahooFinanceProvider(http: FakeHTTPClient([]))
        #expect(yahoo.streams == false)
        #expect(yahoo.name == "Yahoo Finance (unofficial)")
    }
}
