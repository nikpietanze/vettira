import Foundation
import Testing
import VettiraCore

// Test Connection asks the provider for one quote and says plainly what came back: the quote with
// its time and age, a stale quote (older than the 60-second tolerance) in regular hours, the last
// session's price when the market is closed, or a distinct message and next step for each kind of
// provider error (the spec: rate limiting or blocking, a response the app can't read, missing
// symbols, stale quotes).

/// Answers Test Connection with what it's given, and counts the requests.
private actor ScriptedProvider: MarketDataProvider {
    nonisolated let name = "Test provider"
    nonisolated let streams = false
    private let reply: Result<QuoteBatch, ProviderError>
    private(set) var requests: [[String]] = []

    init(_ reply: Result<QuoteBatch, ProviderError>) {
        self.reply = reply
    }

    func quotes(for symbols: [String]) async throws(ProviderError) -> QuoteBatch {
        requests.append(symbols)
        return try reply.get()
    }
}

private func report(
    _ reply: Result<QuoteBatch, ProviderError>, at now: Date = nyTime("10:00:20")
) async -> (ConnectionTestReport, [[String]]) {
    let provider = ScriptedProvider(reply)
    let report = await ConnectionTestReport.run(
        on: provider, symbol: displayTicker("SPY"), staleTolerance: 60, now: { now }, timeZone: newYork)
    return (report, await provider.requests)
}

@Test func aFreshQuoteSaysConnectedWithItsTimeAgeAndSource() async {
    let (shown, requests) = await report(.success(QuoteBatch(quotes: [regularQuote(512.3, at: nyTime("10:00:15"))])))
    #expect(requests == [["SPY"]])
    #expect(shown.outcome == .connected)
    #expect(shown.headline == "Connected: SPY 512.30")
    #expect(shown.detail == "Quote at 10:00:15 EST, 5 s old, from Test provider.")
}

@Test func anOldQuoteInRegularHoursIsStale() async {
    let (shown, _) = await report(.success(QuoteBatch(quotes: [regularQuote(512.3, at: nyTime("09:50:00"))])))
    #expect(shown.outcome == .stale)
    #expect(shown.headline == "Connected, but SPY's quote is stale")
    #expect(shown.detail == "Quote at 09:50:00 EST, 10 min old, from Test provider. That's older than the "
        + "1 min staleness tolerance, so it wouldn't alert. The provider's quotes may be delayed: try again in a minute.")
}

@Test func aQuoteTheProviderSaysIsDelayedIsStale() async {
    var quote = regularQuote(512.3, at: nyTime("10:00:15"))
    quote.providerDelay = 900
    let (shown, _) = await report(.success(QuoteBatch(quotes: [quote])))
    #expect(shown.outcome == .stale)
}

@Test func whenTheMarketIsClosedItsTheLastSessionsPrice() async {
    let (shown, _) = await report(
        .success(QuoteBatch(quotes: [regularQuote(512.3, at: nyTime("16:00:00"))])), at: nyTime("18:00:00"))
    #expect(shown.outcome == .connected)
    #expect(shown.headline == "Connected: SPY 512.30, the last session's price")
    #expect(shown.detail == "Quote at 16:00:00 EST, 2 h old, from Test provider. "
        + "The market is closed, so nothing alerts until the next session.")
}

private let failures: [(reply: Result<QuoteBatch, ProviderError>, headline: String)] = [
    (.failure(.rateLimited(retryAfter: 30)), "The provider is limiting requests and asked Vettira to wait 30 seconds."),
    (.failure(.rateLimited(retryAfter: nil)), "The provider is limiting requests: too many were sent in a short time."),
    (.failure(.blocked), "The provider refused the request, or sent a consent page instead of quotes."),
    (.success(QuoteBatch(quotes: [], unknownSymbols: ["SPY"])), "The provider doesn't recognize the symbol SPY."),
    (.success(QuoteBatch(quotes: [], unusableSymbols: ["SPY"])), "The provider returned no usable price or quote time for SPY."),
    (.failure(.malformedResponse(detail: "not the chart JSON Vettira expects")),
     "The provider sent a response Vettira couldn't read: not the chart JSON Vettira expects."),
    (.success(QuoteBatch(quotes: [])), "The provider sent a response Vettira couldn't read: no quote for SPY."),
    (.failure(.unavailable), "Vettira couldn't reach the provider, or the provider had an error."),
]

@Test(arguments: failures.indices)
func eachProviderErrorHasItsOwnMessageAndNextStep(index: Int) async {
    let (shown, requests) = await report(failures[index].reply)
    #expect(requests == [["SPY"]])
    #expect(shown.outcome == .failed)
    #expect(shown.headline == failures[index].headline)
    #expect(!shown.detail.isEmpty)
}

@Test func noTwoErrorsReadTheSame() async {
    var seen: Set<String> = []
    for failure in failures {
        let (shown, _) = await report(failure.reply)
        #expect(seen.insert(shown.headline).inserted)
    }
}

@Test func theNextStepSaysWhatToDo() async {
    let (rateLimited, _) = await report(.failure(.rateLimited(retryAfter: nil)))
    #expect(rateLimited.detail == "Wait before trying again. If it keeps happening, lengthen the update interval.")
    let (unknown, _) = await report(.success(QuoteBatch(quotes: [], unknownSymbols: ["SPY"])))
    #expect(unknown.detail == "Check the spelling, and use the ticker the provider lists for the stock or ETF.")
}

@Test func inTheDemoTestConnectionUsesTheDemoProvider() async {
    let now = nyTime("10:00:20")
    let shown = await ConnectionTestReport.run(
        on: DemoProvider(now: { now }), symbol: displayTicker("SPY"), staleTolerance: 60, now: { now },
        timeZone: newYork)
    #expect(shown.outcome == .connected)
    #expect(shown.detail == "Quote at 10:00:20 EST, 0 s old, from Demo (made-up prices).")
}
