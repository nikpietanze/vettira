import Foundation
import Testing
import VettiraCore

@Suite struct QuoteTests {
    let quoteTime = Date(timeIntervalSince1970: 1_762_871_400)

    @Test func aQuoteWithoutAProviderHighHasNoSessionHigh() {
        let quote = Quote(symbol: "SPY", price: 671.2, timestamp: quoteTime, source: "Example")
        #expect(quote.sessionHigh == nil)
        #expect(quote.session == .unknown)
        #expect(quote.providerDelay == nil)
    }

    @Test func aQuoteKeepsWhatTheProviderSupplied() {
        let quote = Quote(
            symbol: "SPY", price: 671.2, timestamp: quoteTime, source: "Example",
            sessionHigh: 673.5, session: .regular, providerDelay: 0)
        #expect(quote.symbol == "SPY")
        #expect(quote.price == 671.2)
        #expect(quote.timestamp == quoteTime)
        #expect(quote.source == "Example")
        #expect(quote.sessionHigh == 673.5)
        #expect(quote.session == .regular)
        #expect(quote.providerDelay == 0)
    }

    @Test func ageIsTheTimeSinceTheQuotesOwnTimestamp() {
        let quote = Quote(symbol: "SPY", price: 671.2, timestamp: quoteTime, source: "Example")
        #expect(quote.age(at: quoteTime.addingTimeInterval(45)) == 45)
        #expect(quote.age(at: quoteTime) == 0)
    }

    @Test func aQuoteFromAheadOfTheClockHasNegativeAge() {
        let quote = Quote(symbol: "SPY", price: 671.2, timestamp: quoteTime, source: "Example")
        #expect(quote.age(at: quoteTime.addingTimeInterval(-3)) == -3)
    }
}
