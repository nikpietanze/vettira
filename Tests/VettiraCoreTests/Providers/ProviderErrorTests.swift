import Foundation
import Testing
import VettiraCore

@Suite struct ProviderErrorTests {
    static let everyError: [ProviderError] = [
        .rateLimited(retryAfter: 30),
        .rateLimited(retryAfter: nil),
        .blocked,
        .unknownSymbols(["SPYY"]),
        .noUsableQuote(["HALT"]),
        .malformedResponse(detail: "no price for SPY"),
        .unavailable,
    ]

    @Test(arguments: everyError)
    func everyErrorSaysWhatHappenedAndWhatToDo(error: ProviderError) {
        #expect(!error.message.isEmpty)
        #expect(!error.nextStep.isEmpty)
        #expect(error.message != error.nextStep)
    }

    @Test(arguments: everyError)
    func theAppSeesTheMessageAndNextStepThroughFoundation(error: ProviderError) {
        let shown = error as Error
        #expect(shown.localizedDescription == error.message)
        #expect((shown as NSError).localizedRecoverySuggestion == error.nextStep)
    }

    @Test(arguments: everyError)
    func noErrorGivesAdviceOrPromisesRealTimeData(error: ProviderError) {
        let text = "\(error.message) \(error.nextStep)".lowercased()
        for word in ["sell", "buy", "real-time", "realtime", "guarantee"] {
            #expect(!text.contains(word), "\(error) says \"\(word)\"")
        }
    }

    @Test func eachKindOfFailureReadsDifferently() {
        let messages = Set(Self.everyError.map(\.message))
        #expect(messages.count == Self.everyError.count)
    }

    @Test func rateLimitedSaysHowLongTheProviderAskedToWait() {
        #expect(ProviderError.rateLimited(retryAfter: 30).message.contains("wait 30 seconds"))
        #expect(ProviderError.rateLimited(retryAfter: 1).message.contains("wait 1 second."))
        #expect(ProviderError.rateLimited(retryAfter: 0.2).message.contains("wait 1 second."))
        #expect(ProviderError.rateLimited(retryAfter: 60).message.contains("wait 1 minute."))
        #expect(ProviderError.rateLimited(retryAfter: 61).message.contains("wait 2 minutes"))
    }

    @Test func rateLimitedWithoutARetryAfterNamesNoWait() {
        let message = ProviderError.rateLimited(retryAfter: nil).message
        #expect(!message.contains("wait"))
        #expect(message.contains("limiting requests"))
    }

    @Test func unknownSymbolsNamesEachSymbol() {
        #expect(ProviderError.unknownSymbols(["SPYY"]).message.contains("the symbol SPYY"))
        #expect(ProviderError.unknownSymbols(["SPYY", "QQQQ"]).message.contains("the symbols SPYY, QQQQ"))
    }

    @Test func noUsableQuoteNamesEachSymbol() {
        #expect(ProviderError.noUsableQuote(["HALT", "NEWCO"]).message.contains("for HALT, NEWCO."))
    }

    @Test func malformedResponseSaysWhatWasWrong() {
        #expect(ProviderError.malformedResponse(detail: "no price for SPY").message.contains("no price for SPY"))
    }
}
