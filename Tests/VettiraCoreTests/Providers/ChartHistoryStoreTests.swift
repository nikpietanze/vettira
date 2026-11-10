import Foundation
import Testing
import VettiraCore

/// Answers history requests with what each symbol and timeframe is scripted to, counts them, and
/// holds each in flight for a few turns so concurrent callers overlap.
private actor HistoryProvider: MarketDataProvider {
    nonisolated let name = "Test provider"
    private var replies: [ChartTimeframe: [Result<PriceHistory, ProviderError>]] = [:]
    private(set) var requests: [ChartTimeframe] = []

    func script(_ timeframe: ChartTimeframe, _ replies: [Result<PriceHistory, ProviderError>]) {
        self.replies[timeframe, default: []] += replies
    }

    func quotes(for symbols: [String]) async throws(ProviderError) -> QuoteBatch {
        Issue.record("the store never polls")
        throw .unavailable
    }

    func history(for symbol: String, timeframe: ChartTimeframe) async throws(ProviderError) -> PriceHistory {
        requests.append(timeframe)
        for _ in 0..<5 { await Task.yield() }
        guard var queue = replies[timeframe], !queue.isEmpty else {
            Issue.record("unscripted \(timeframe.rawValue) request")
            throw .unavailable
        }
        let reply = queue.removeFirst()
        replies[timeframe] = queue
        return try reply.get()
    }
}

/// A clock the tests move by hand.
private final class StoreClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now = Date(timeIntervalSince1970: 1_794_258_000)
    var now: Date { lock.withLock { _now } }
    func advance(_ seconds: TimeInterval) { lock.withLock { _now += seconds } }
}

@Suite struct ChartHistoryStoreTests {
    private let spy = try! TickerSymbol("SPY")

    private func history(_ timeframe: ChartTimeframe, close: Double = 752.69) -> PriceHistory {
        PriceHistory(
            symbol: "SPY", timeframe: timeframe,
            bars: [PriceBar(timestamp: Date(timeIntervalSince1970: 1_794_234_600), close: close)], previousClose: 750)
    }

    private func store() -> (ChartHistoryStore, HistoryProvider, StoreClock) {
        let provider = HistoryProvider()
        let clock = StoreClock()
        return (ChartHistoryStore(provider: provider, now: { clock.now }), provider, clock)
    }

    @Test func oneDayIsThePolledQuotesBarsWithNoRequest() async throws {
        let (store, provider, _) = store()
        let bars = [PriceBar(timestamp: Date(timeIntervalSince1970: 1_794_234_600), close: 751, high: 752, open: 750, low: 749, volume: 10)]
        let quote = Quote(
            symbol: "SPY", price: 752, timestamp: Date(timeIntervalSince1970: 1_794_235_000), source: "Test",
            previousClose: 748, intraday: bars, name: "SPDR")
        let day = try await store.history(for: spy, timeframe: .oneDay, latest: quote)
        #expect(day == PriceHistory(symbol: "SPY", timeframe: .oneDay, bars: bars, previousClose: 748, name: "SPDR"))
        #expect(await provider.requests.isEmpty)
    }

    @Test func oneDayWithoutAPolledQuoteAsksOnce() async throws {
        let (store, provider, _) = store()
        await provider.script(.oneDay, [.success(history(.oneDay))])
        #expect(try await store.history(for: spy, timeframe: .oneDay, latest: nil) == history(.oneDay))
        #expect(try await store.history(for: spy, timeframe: .oneDay, latest: nil) == history(.oneDay))
        #expect(await provider.requests == [.oneDay])
    }

    @Test func aTimeframeIsKeptForItsLifetimeThenAskedForAgain() async throws {
        let (store, provider, clock) = store()
        await provider.script(.oneYear, [.success(history(.oneYear, close: 1)), .success(history(.oneYear, close: 2))])
        #expect(try await store.history(for: spy, timeframe: .oneYear, latest: nil).bars[0].close == 1)
        // Daily bars keep for hours.
        clock.advance(4 * 3600 - 1)
        #expect(try await store.history(for: spy, timeframe: .oneYear, latest: nil).bars[0].close == 1)
        #expect(await store.cached(for: spy, timeframe: .oneYear)?.bars[0].close == 1)
        #expect(await provider.requests == [.oneYear])
        clock.advance(1)
        #expect(await store.cached(for: spy, timeframe: .oneYear) == nil)
        #expect(try await store.history(for: spy, timeframe: .oneYear, latest: nil).bars[0].close == 2)
        #expect(await provider.requests == [.oneYear, .oneYear])
    }

    @Test func eachTimeframeKeepsForAboutABar() {
        #expect(ChartTimeframe.oneDay.cacheLifetime == 5 * 60)
        #expect(ChartTimeframe.fiveDays.cacheLifetime == 15 * 60)
        #expect(ChartTimeframe.oneMonth.cacheLifetime == 3600)
        #expect([ChartTimeframe.sixMonths, .yearToDate, .oneYear].allSatisfy { $0.cacheLifetime == 4 * 3600 })
        #expect(ChartTimeframe.fiveYears.cacheLifetime == 12 * 3600)
    }

    @Test func askingAgainWhileARequestIsInFlightSendsNoOther() async throws {
        let (store, provider, _) = store()
        await provider.script(.fiveYears, [.success(history(.fiveYears))])
        async let first = store.history(for: spy, timeframe: .fiveYears, latest: nil)
        async let second = store.history(for: spy, timeframe: .fiveYears, latest: nil)
        let (a, b) = try await (first, second)
        #expect(a == history(.fiveYears))
        #expect(b == history(.fiveYears))
        #expect(await provider.requests == [.fiveYears])
    }

    @Test func afterARateLimitNothingIsAskedForAsLongAsItSaid() async throws {
        let (store, provider, clock) = store()
        await provider.script(.oneYear, [.failure(.rateLimited(retryAfter: 120)), .success(history(.oneYear))])
        await provider.script(.oneMonth, [.success(history(.oneMonth))])
        await #expect(throws: ProviderError.rateLimited(retryAfter: 120)) {
            try await store.history(for: spy, timeframe: .oneYear, latest: nil)
        }
        clock.advance(119)
        // Neither the same timeframe nor another.
        await #expect(throws: ProviderError.rateLimited(retryAfter: 120)) {
            try await store.history(for: spy, timeframe: .oneYear, latest: nil)
        }
        await #expect(throws: ProviderError.rateLimited(retryAfter: 120)) {
            try await store.history(for: spy, timeframe: .oneMonth, latest: nil)
        }
        #expect(await provider.requests == [.oneYear])
        clock.advance(1)
        #expect(try await store.history(for: spy, timeframe: .oneYear, latest: nil) == history(.oneYear))
        #expect(await provider.requests == [.oneYear, .oneYear])
    }

    @Test func afterAnOutageItWaitsAMinute() async throws {
        let (store, provider, clock) = store()
        await provider.script(.sixMonths, [.failure(.unavailable), .success(history(.sixMonths))])
        await #expect(throws: ProviderError.unavailable) {
            try await store.history(for: spy, timeframe: .sixMonths, latest: nil)
        }
        clock.advance(59)
        await #expect(throws: ProviderError.unavailable) {
            try await store.history(for: spy, timeframe: .sixMonths, latest: nil)
        }
        clock.advance(1)
        #expect(try await store.history(for: spy, timeframe: .sixMonths, latest: nil) == history(.sixMonths))
        #expect(await provider.requests == [.sixMonths, .sixMonths])
    }

    @Test func anUnknownSymbolWaitsOnlyForThatTimeframe() async throws {
        let (store, provider, _) = store()
        await provider.script(.oneYear, [.failure(.unknownSymbols(["SPY"]))])
        await provider.script(.fiveDays, [.success(history(.fiveDays))])
        await #expect(throws: ProviderError.unknownSymbols(["SPY"])) {
            try await store.history(for: spy, timeframe: .oneYear, latest: nil)
        }
        await #expect(throws: ProviderError.unknownSymbols(["SPY"])) {
            try await store.history(for: spy, timeframe: .oneYear, latest: nil)
        }
        #expect(try await store.history(for: spy, timeframe: .fiveDays, latest: nil) == history(.fiveDays))
        #expect(await provider.requests == [.oneYear, .fiveDays])
    }

    @Test func nothingIsAskedForUntilATimeframeIsOpened() async throws {
        let (store, provider, _) = store()
        #expect(await store.cached(for: spy, timeframe: .oneYear) == nil)
        #expect(await provider.requests.isEmpty)
    }
}
