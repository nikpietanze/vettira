import Foundation
import Testing
import VettiraCore

/// A provider that answers from what it's given, the way the poller's tests will use one.
private struct CannedProvider: MarketDataProvider {
    let name = "Canned"
    let known: [String: Double]
    let failure: ProviderError?

    func quotes(for symbols: [String]) async throws(ProviderError) -> QuoteBatch {
        if let failure { throw failure }
        let at = Date(timeIntervalSince1970: 1_762_871_400)
        return QuoteBatch(
            quotes: symbols.compactMap { symbol in
                known[symbol].map { Quote(symbol: symbol, price: $0, timestamp: at, source: name) }
            },
            unknownSymbols: symbols.filter { known[$0] == nil })
    }

    /// Not asked for in these tests.
    func history(for symbol: String, timeframe: ChartTimeframe) async throws(ProviderError) -> PriceHistory {
        throw .unavailable
    }
}

@Suite struct MarketDataProviderTests {
    @Test func aBatchReturnsKnownSymbolsAndListsUnknownOnes() async throws {
        let provider: any MarketDataProvider = CannedProvider(known: ["SPY": 671.2, "QQQ": 612.4], failure: nil)
        let batch = try await provider.quotes(for: ["SPY", "SPYY", "QQQ"])
        #expect(batch.quotes.map(\.symbol) == ["SPY", "QQQ"])
        #expect(batch.quotes.allSatisfy { $0.source == "Canned" })
        #expect(batch.unknownSymbols == ["SPYY"])
    }

    @Test func callersGetTheProvidersTypedError() async {
        let provider: any MarketDataProvider = CannedProvider(known: [:], failure: .blocked)
        do {
            _ = try await provider.quotes(for: ["SPY"])
            Issue.record("expected the blocked error")
        } catch {
            #expect(error == .blocked)
            #expect(error.nextStep.contains("consent page"))
        }
        await #expect(throws: ProviderError.blocked) {
            try await provider.testConnection(symbol: "SPY")
        }
    }

    @Test func testConnectionReturnsTheSymbolsQuote() async throws {
        let provider: any MarketDataProvider = CannedProvider(known: ["SPY": 671.2], failure: nil)
        let quote = try await provider.testConnection(symbol: "SPY")
        #expect(quote.symbol == "SPY")
        #expect(quote.price == 671.2)
    }

    @Test func testConnectionSaysTheSymbolIsUnknown() async {
        let provider: any MarketDataProvider = CannedProvider(known: [:], failure: nil)
        await #expect(throws: ProviderError.unknownSymbols(["SPYY"])) {
            try await provider.testConnection(symbol: "SPYY")
        }
    }
}
