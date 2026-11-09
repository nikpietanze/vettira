import Foundation
import Testing
import VettiraCore

// Expected values come from the spec (docs/spec.md, "Reversal detection"): the high is the
// session's running high, `pullbackPct = (sessionHigh - latestPrice) / sessionHigh * 100`, and a high
// the provider didn't supply as the session high is the "observed high".

private let monday = TradingDay(year: 2026, month: 11, day: 9)
private let tuesday = TradingDay(year: 2026, month: 11, day: 10)

@Test func withoutAProviderHighTheHighIsTheHighestPriceObserved() {
    var tracker = SessionHighTracker()
    #expect(tracker.high == nil)
    for price in [100.0, 101.5, 100.8] {
        tracker.record(price: price, providerHigh: nil, on: monday)
    }
    #expect(tracker.high == SessionHigh(price: 101.5, kind: .observed))
    #expect(tracker.day == monday)
}

@Test func theProvidersHighIsTheSessionHigh() {
    var tracker = SessionHighTracker()
    tracker.record(price: 100, providerHigh: 102, on: monday)
    #expect(tracker.high == SessionHigh(price: 102, kind: .session))
}

@Test func aPriceAboveTheProvidersHighMakesTheHighObserved() {
    var tracker = SessionHighTracker()
    tracker.record(price: 100, providerHigh: 102, on: monday)
    tracker.record(price: 102.5, providerHigh: 102, on: monday)
    #expect(tracker.high == SessionHigh(price: 102.5, kind: .observed))
    // Once the provider's high catches up, it's the session high again.
    tracker.record(price: 102.4, providerHigh: 102.6, on: monday)
    #expect(tracker.high == SessionHigh(price: 102.6, kind: .session))
}

@Test func aQuoteWithoutTheProvidersHighKeepsTheOneItSupplied() {
    var tracker = SessionHighTracker()
    tracker.record(price: 100, providerHigh: 102, on: monday)
    tracker.record(price: 100.5, providerHigh: nil, on: monday)
    #expect(tracker.high == SessionHigh(price: 102, kind: .session))
}

@Test func aNewTradingDayStartsTheHighOver() {
    var tracker = SessionHighTracker()
    tracker.record(price: 105, providerHigh: 106, on: monday)
    tracker.record(price: 99, providerHigh: nil, on: tuesday)
    #expect(tracker.high == SessionHigh(price: 99, kind: .observed))
    #expect(tracker.day == tuesday)
}

@Test func thePullbackIsThePercentBelowTheHigh() {
    // Prices whose percentages are exact in binary floating point.
    #expect(SessionHigh(price: 64, kind: .session).pullbackPercent(at: 63) == 1.5625)
    #expect(SessionHigh(price: 50, kind: .observed).pullbackPercent(at: 50) == 0)
    #expect(SessionHigh(price: 64, kind: .observed).pullbackPercent(at: 68) == -6.25)
}

@Test func theHighsAreLabelledSessionAndObserved() {
    #expect(SessionHigh.Kind.session.label == "session high")
    #expect(SessionHigh.Kind.observed.label == "observed high")
}

@Test func theTrackerRoundTripsThroughJSON() throws {
    var tracker = SessionHighTracker()
    tracker.record(price: 100, providerHigh: 101, on: monday)
    tracker.record(price: 101.2, providerHigh: nil, on: monday)
    let decoded = try JSONDecoder().decode(SessionHighTracker.self, from: JSONEncoder().encode(tracker))
    #expect(decoded == tracker)
    #expect(decoded.high == SessionHigh(price: 101.2, kind: .observed))
}
