import Foundation
import Testing
import VettiraCore

// Expected values come from the spec (docs/spec.md, "Reversal detection") and the issue it was
// built to: `pullbackPct = (high - price) / high * 100`; an early warning at 0.25% and a stronger
// one at 0.40%, each sent once per high-water-mark cycle; rearming on a new high 0.10% above the
// last alerted high, or a new session; regular hours only (09:30 to 16:00 New York time, 13:00 on
// an early-close day); and no alert from a stale (over 60 s), delayed, out-of-order, duplicate,
// extended-hours or spiking quote. The cooldown (5 minutes) and spike limit (10%) are the
// engine's documented defaults (docs/alerts.md).
//
// Quotes are synthetic unless they say they're recorded, and each is evaluated a few seconds after
// its own time unless the test says otherwise. New York is UTC-5 in November 2026.

private let tuesday = "2026-11-10"
private let wednesday = "2026-11-11"
private let dayAfterThanksgiving = "2026-11-27"  // an early close, at 13:00

private func at(_ time: String, on day: String = tuesday) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter.date(from: "\(day)T\(time)-05:00")!
}

private func quote(
    _ price: Double, at time: Date, symbol: String = "SPY", high: Double? = nil,
    session: Quote.Session = .regular, delay: TimeInterval? = nil, bars: [PriceBar] = []
) -> Quote {
    Quote(symbol: symbol, price: price, timestamp: time, source: "Test provider",
          sessionHigh: high, session: session, providerDelay: delay, intraday: bars)
}

/// A 5-minute bar starting at `time`, with its last price and its highest.
private func bar(_ time: String, on day: String = tuesday, close: Double?, high: Double?) -> PriceBar {
    PriceBar(timestamp: at(time, on: day), close: close, high: high)
}

private func close(_ a: Double?, _ b: Double) -> Bool {
    guard let a else { return false }
    return abs(a - b) < 1e-9
}

/// An engine fed quotes the way the poller will, each evaluated `lag` after its own time.
private struct Feed {
    var engine: ReversalAlertEngine
    var thresholds = PullbackThresholds.standard
    var lag: TimeInterval = 5

    init(_ engine: ReversalAlertEngine = ReversalAlertEngine()) {
        self.engine = engine
    }

    @discardableResult
    mutating func send(
        _ price: Double, at time: String, on day: String = tuesday, symbol: String = "SPY",
        high: Double? = nil, session: Quote.Session = .regular, delay: TimeInterval? = nil,
        bars: [PriceBar] = []
    ) -> QuoteEvaluation {
        let when = at(time, on: day)
        let quote = quote(price, at: when, symbol: symbol, high: high, session: session, delay: delay, bars: bars)
        return engine.evaluate(quote, thresholds: thresholds, now: when.addingTimeInterval(lag))
    }
}

extension QuoteEvaluation {
    var alert: ReversalAlert? {
        if case .accepted(_, _, let alert) = self { return alert }
        return nil
    }

    var high: SessionHigh? {
        if case .accepted(let high, _, _) = self { return high }
        return nil
    }

    var pullbackPercent: Double? {
        if case .accepted(_, let pullback, _) = self { return pullback }
        return nil
    }

    var rejection: QuoteRejection? {
        if case .rejected(let reason) = self { return reason }
        return nil
    }

    var isAcceptedWithoutAlert: Bool {
        if case .accepted(_, _, nil) = self { return true }
        return false
    }
}

@Suite struct ReversalAlertEngineTests {
    // MARK: Thresholds and the alert

    @Test func firesTheEarlyWarningWithEverythingTheNotificationShows() throws {
        var feed = Feed()
        #expect(feed.send(100, at: "10:00:00").isAcceptedWithoutAlert)
        let evaluation = feed.send(99.70, at: "10:01:00")

        let alert = try #require(evaluation.alert)
        #expect(alert.symbol == "SPY")
        #expect(alert.price == 99.70)
        #expect(alert.high == SessionHigh(price: 100, kind: .observed))
        #expect(close(alert.pullbackPercent, 0.30))
        #expect(alert.signal == .early)
        #expect(alert.thresholdPercent == 0.25)
        #expect(alert.quoteTimestamp == at("10:01:00"))
        #expect(alert.dataAge == 5)
        #expect(alert.source == "Test provider")
        #expect(evaluation.high == SessionHigh(price: 100, kind: .observed))
        #expect(close(evaluation.pullbackPercent, 0.30))
    }

    @Test func theAlertSaysPossibleReversalAndNamesTheKindOfHigh() throws {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        let observed = try #require(feed.send(99.70, at: "10:01:00").alert)
        #expect(observed.summary
            == "Early warning (0.25% threshold): possible reversal, not confirmed. SPY is 0.30% below its observed high. Quote 5 s old.")

        feed.lag = 12.4
        let session = try #require(feed.send(99.40, at: "10:01:00", symbol: "QQQ", high: 100).alert)
        #expect(session.summary
            == "Stronger warning (0.40% threshold): possible reversal, not confirmed. QQQ is 0.60% below its session high. Quote 12 s old.")
        for summary in [observed.summary, session.summary] {
            #expect(!summary.localizedCaseInsensitiveContains("sell"))
            #expect(!summary.localizedCaseInsensitiveContains("confirmed reversal"))
        }
    }

    @Test func belowTheEarlyThresholdNothingFires() {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        let evaluation = feed.send(99.80, at: "10:01:00")
        #expect(evaluation.isAcceptedWithoutAlert)
        #expect(close(evaluation.pullbackPercent, 0.20))
    }

    @Test func eachThresholdFiresOncePerCycle() {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.70, at: "10:01:00").alert?.signal == .early)
        #expect(feed.send(99.65, at: "10:02:00").isAcceptedWithoutAlert)
        #expect(feed.send(99.50, at: "10:03:00").alert?.signal == .strong)
        #expect(feed.send(99.40, at: "10:04:00").isAcceptedWithoutAlert)
        // A recovery and a second dip below the high it already alerted on: no repeat.
        #expect(feed.send(99.95, at: "10:15:00").isAcceptedWithoutAlert)
        #expect(feed.send(99.70, at: "10:16:00").isAcceptedWithoutAlert)
        #expect(feed.send(99.50, at: "10:17:00").isAcceptedWithoutAlert)
    }

    @Test func aDropPastBothThresholdsAtOnceSendsOneStrongerWarning() throws {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        let alert = try #require(feed.send(99.50, at: "10:01:00").alert)
        #expect(alert.signal == .strong)
        #expect(close(alert.pullbackPercent, 0.50))
        // The early warning was covered by it.
        #expect(feed.send(99.70, at: "10:20:00").isAcceptedWithoutAlert)
    }

    @Test func thresholdsArePerSymbol() throws {
        var feed = Feed()
        feed.thresholds = try PullbackThresholds(early: 1.0, strong: 2.0)
        feed.send(100, at: "10:00:00", symbol: "AAPL")
        #expect(feed.send(99.50, at: "10:01:00", symbol: "AAPL").isAcceptedWithoutAlert)
        let aapl = feed.send(98.90, at: "10:02:00", symbol: "AAPL").alert
        #expect(aapl?.signal == .early)
        #expect(aapl?.thresholdPercent == 1.0)

        feed.thresholds = .standard
        feed.send(50, at: "10:00:00", symbol: "SPY")
        #expect(feed.send(49.75, at: "10:01:00", symbol: "SPY").alert?.signal == .strong)  // 0.50%
    }

    @Test func eachSymbolHasItsOwnHighAndCycle() {
        var feed = Feed()
        feed.send(100, at: "10:00:00", symbol: "SPY")
        feed.send(200, at: "10:00:00", symbol: "QQQ")
        #expect(feed.send(99.70, at: "10:01:00", symbol: "SPY").alert?.signal == .early)
        let qqq = feed.send(199.40, at: "10:01:00", symbol: "QQQ")
        #expect(qqq.alert?.signal == .early)
        #expect(qqq.high == SessionHigh(price: 200, kind: .observed))
    }

    // MARK: Session and observed highs

    @Test func theProvidersHighIsTheSessionHighFromTheFirstQuote() throws {
        var feed = Feed()
        let alert = try #require(feed.send(99.70, at: "10:00:00", high: 100).alert)
        #expect(alert.high == SessionHigh(price: 100, kind: .session))
        #expect(alert.signal == .early)
    }

    @Test func aPriceAboveTheProvidersHighIsTheObservedHigh() throws {
        var feed = Feed()
        #expect(feed.send(100.50, at: "10:00:00", high: 100).high == SessionHigh(price: 100.50, kind: .observed))
        let alert = try #require(feed.send(100.10, at: "10:01:00", high: 100).alert)
        #expect(alert.high == SessionHigh(price: 100.50, kind: .observed))
        #expect(alert.signal == .early)
        #expect(close(alert.pullbackPercent, (100.50 - 100.10) / 100.50 * 100))
    }

    // MARK: The day's bars

    @Test func aBarsHighAboveTheQuotesIsTheObservedHigh() throws {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        // Between the polls the price reached 100.40, in the 10:00 bar; 99.80 is 0.20% below the
        // quotes' high of 100, but 0.60% below the bar's.
        let alert = try #require(feed.send(99.80, at: "10:12:10", bars: [
            bar("10:00:00", close: 100.10, high: 100.40),
            bar("10:05:00", close: 99.90, high: 100.00),
            bar("10:10:00", close: 99.80, high: 99.85),
        ]).alert)
        #expect(alert.high == SessionHigh(price: 100.40, kind: .observed))
        #expect(alert.signal == .strong)
        #expect(close(alert.pullbackPercent, (100.40 - 99.80) / 100.40 * 100))
        #expect(alert.summary.hasSuffix("SPY is 0.60% below its observed high. Quote 5 s old."))
    }

    @Test func aBarsHighCountsBeforeTheFirstQuote() throws {
        // Monitoring starts at 10:12: the morning's bars are part of the observed high from the
        // first quote, which is past the stronger warning from the start.
        var feed = Feed()
        let alert = try #require(feed.send(99.80, at: "10:12:10", bars: [
            bar("09:30:00", close: 100.20, high: 100.50),
            bar("09:35:00", close: 100.00, high: 100.25),
            bar("10:10:00", close: 99.80, high: 99.85),
        ]).alert)
        #expect(alert.high == SessionHigh(price: 100.50, kind: .observed))
        #expect(alert.signal == .strong)
    }

    @Test func aBarCountsOnlyOnceItEndedByTheQuotesTime() {
        var feed = Feed()
        let bars = [
            bar("10:00:00", close: 99.85, high: 99.90),
            bar("10:05:00", close: 99.90, high: 100.30),
            bar("10:10:00", close: 99.80, high: 100.40),
        ]
        // At 10:07 the 10:05 bar is still in progress, and the 10:10 bar starts after the quote:
        // only the 10:00 bar ended by then.
        let first = feed.send(99.80, at: "10:07:00", bars: bars)
        #expect(first.high == SessionHigh(price: 99.90, kind: .observed))
        #expect(first.isAcceptedWithoutAlert)
        // At 10:12 the 10:05 bar has ended; the 10:10 bar is in progress.
        let second = feed.send(99.80, at: "10:12:00", bars: bars)
        #expect(second.high == SessionHigh(price: 100.30, kind: .observed))
        #expect(second.alert?.signal == .strong)  // 0.50% below 100.30
    }

    @Test func barsOutsideTheQuotesRegularSessionDoNotCount() {
        var feed = Feed()
        let evaluation = feed.send(100, at: "09:40:00", bars: [
            bar("15:55:00", on: "2026-11-09", close: 104.90, high: 105.00),  // Monday's session
            bar("16:00:00", on: "2026-11-09", close: 104.80, high: 104.95),  // Monday's close
            bar("09:00:00", close: 102.90, high: 103.00),                    // Tuesday's pre-market
            bar("09:25:00", close: 101.90, high: 102.00),
            bar("09:30:00", close: 100.00, high: 100.10),
            bar("09:35:00", close: 100.00, high: 100.05),
        ])
        #expect(evaluation.high == SessionHigh(price: 100.10, kind: .observed))
        #expect(evaluation.isAcceptedWithoutAlert)
    }

    @Test func aRejectedQuoteBringsNoBarsIn() {
        let bars = [bar("10:00:00", close: 100.10, high: 100.40), bar("10:05:00", close: 99.80, high: 99.85)]
        let rejected: [(inout Feed) -> QuoteEvaluation] = [
            { feed in feed.lag = 61; return feed.send(99.80, at: "10:08:00", bars: bars) },
            { feed in feed.send(99.80, at: "10:08:00", delay: 900, bars: bars) },
            { feed in feed.send(99.80, at: "10:08:00", session: .postMarket, bars: bars) },
            { feed in feed.send(99.80, at: "09:59:00", bars: bars) },  // out of order
            { feed in feed.send(99.80, at: "10:00:00", bars: bars) },  // a duplicate
            { feed in feed.send(80, at: "10:08:00", bars: bars) },     // an unconfirmed jump
        ]
        for send in rejected {
            var feed = Feed()
            feed.send(100, at: "10:00:00")
            let evaluation = send(&feed)
            #expect(evaluation.rejection != nil)
            // The next fresh quote, without bars, is measured from the quotes' high alone.
            feed.lag = 5
            let next = feed.send(99.80, at: "10:09:00")
            #expect(next.high == SessionHigh(price: 100, kind: .observed))
            #expect(next.isAcceptedWithoutAlert)
        }
    }

    @Test func aBarsHighThePriceAfterItDoesNotConfirmIsIgnored() throws {
        var feed = Feed()
        // 112 is 10.7% from the next close, 100: past the spike limit, a bad tick. The 10:05
        // bar's 100.10, confirmed by the 10:10 close, counts.
        let alert = try #require(feed.send(99.80, at: "10:12:00", bars: [
            bar("10:00:00", close: 100.00, high: 112.00),
            bar("10:05:00", close: 100.00, high: 100.10),
            bar("10:10:00", close: 99.80, high: 99.85),
        ]).alert)
        #expect(alert.high == SessionHigh(price: 100.10, kind: .observed))
        #expect(alert.signal == .early)
        #expect(close(alert.pullbackPercent, (100.10 - 99.80) / 100.10 * 100))
    }

    @Test func withNoLaterCloseTheQuotesPriceConfirmsABarsHigh() {
        // The 10:05 bar had no trades, so the price after the 10:00 bar's high is the quote's.
        let bars = [bar("10:00:00", close: 100.40, high: 100.50), bar("10:05:00", close: nil, high: nil)]
        var confirmed = Feed()
        let alert = confirmed.send(99.90, at: "10:07:00", bars: bars).alert
        #expect(alert?.high == SessionHigh(price: 100.50, kind: .observed))
        #expect(alert?.signal == .strong)  // 0.597% below
        // 90 is 10.4% from 100.50: past the spike limit, so the bar's high is ignored.
        var unconfirmed = Feed()
        let evaluation = unconfirmed.send(90, at: "10:07:00", bars: bars)
        #expect(evaluation.high == SessionHigh(price: 90, kind: .observed))
        #expect(evaluation.isAcceptedWithoutAlert)
    }

    @Test func aSpikeLimitSetHigherLetsALargerBarHighCount() throws {
        var feed = Feed(ReversalAlertEngine(settings: try AlertSettings(spikePercent: 20)))
        let evaluation = feed.send(99.80, at: "10:12:00", bars: [
            bar("10:00:00", close: 100.00, high: 112.00),
            bar("10:05:00", close: 100.00, high: 100.10),
        ])
        #expect(evaluation.high == SessionHigh(price: 112.00, kind: .observed))
    }

    @Test func aBarsHighMovesTheHighButNeverRearms() throws {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.50, at: "10:01:00").alert?.signal == .strong)
        // The 10:05 bar's 100.50 is 0.50% above the alerted high, 100: the high moves to it, but
        // the cycle doesn't start over, so 100.05, 0.45% below it, sends nothing, though both
        // cooldowns from 10:01 are over.
        let moved = feed.send(100.05, at: "10:12:10", bars: [
            bar("10:05:00", close: 100.40, high: 100.50),
            bar("10:10:00", close: 100.05, high: 100.30),
        ])
        #expect(moved.high == SessionHigh(price: 100.50, kind: .observed))
        #expect(moved.isAcceptedWithoutAlert)
        // A quote 0.10% or more above the alerted high rearms: 100.70, then 0.40% below it.
        #expect(feed.send(100.70, at: "10:20:00").isAcceptedWithoutAlert)
        let early = try #require(feed.send(100.30, at: "10:21:00").alert)
        #expect(early.signal == .early)
        #expect(early.high == SessionHigh(price: 100.70, kind: .observed))
    }

    @Test func withTheProvidersSessionHighTheBarsAddNothing() {
        var feed = Feed()
        // A bar's high a hair above the provider's, as single-precision bars carry it, and one
        // well above it: the high is still the provider's session high.
        let evaluation = feed.send(752.00, at: "10:12:00", high: 752.96, bars: [
            bar("10:00:00", close: 752.50, high: 752.9600219726562),
            bar("10:05:00", close: 752.10, high: 755.00),
            bar("10:10:00", close: 752.00, high: 752.20),
        ])
        #expect(evaluation.high == SessionHigh(price: 752.96, kind: .session))
        #expect(close(evaluation.pullbackPercent, (752.96 - 752.00) / 752.96 * 100))
        // Later quotes without the provider's high keep it, and their bars still add nothing.
        let later = feed.send(752.00, at: "10:16:00", bars: [
            bar("10:10:00", close: 752.00, high: 760.00), bar("10:15:00", close: 752.00, high: 752.10),
        ])
        #expect(later.high == SessionHigh(price: 752.96, kind: .session))
    }

    @Test func aRestoredStateCarriesTheBarsHigh() throws {
        var feed = Feed()
        feed.send(99.80, at: "10:12:00", bars: [
            bar("10:00:00", close: 99.90, high: 100.00), bar("10:05:00", close: 99.85, high: 99.90),
        ])
        try withAlertStateStore { store in
            try store.save(feed.engine.state)
            var relaunched = Feed(ReversalAlertEngine(state: try store.load()))
            // No bars with this quote: the high is still the saved bar's 100, 0.30% above 99.70.
            let alert = relaunched.send(99.70, at: "10:13:00").alert
            #expect(alert?.high == SessionHigh(price: 100, kind: .observed))
            #expect(alert?.signal == .early)
        }
    }

    // MARK: Rearming and the cooldown

    @Test func aHighLessThanTheRearmMarginAboveDoesNotRearm() {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.70, at: "10:01:00").alert?.signal == .early)
        // 100.05 is 0.05% above the alerted high: a new high, but not a meaningful one.
        #expect(feed.send(100.05, at: "10:10:00").high == SessionHigh(price: 100.05, kind: .observed))
        #expect(feed.send(99.75, at: "10:11:00").isAcceptedWithoutAlert)  // 0.30% below 100.05
    }

    @Test func aMeaningfulNewHighRearmsBothThresholds() throws {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        feed.send(99.70, at: "10:01:00")
        #expect(feed.send(99.50, at: "10:02:00").alert?.signal == .strong)
        // 100.20 is 0.20% above the last alerted high: the cycle starts over from it.
        #expect(feed.send(100.20, at: "10:10:00").isAcceptedWithoutAlert)
        let early = try #require(feed.send(99.85, at: "10:11:00").alert)
        #expect(early.signal == .early)
        #expect(early.high == SessionHigh(price: 100.20, kind: .observed))
        #expect(close(early.pullbackPercent, (100.20 - 99.85) / 100.20 * 100))
        // 0.449% below 100.20: the stronger warning's cooldown from 10:02 ended at 10:07.
        #expect(feed.send(99.75, at: "10:12:00").alert?.signal == .strong)
    }

    @Test func theCooldownHoldsARepeatOfTheSameThresholdThenLetsItFire() {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.70, at: "10:01:00").alert?.signal == .early)
        feed.send(100.20, at: "10:02:00")  // rearms
        // 0.30% below 100.20, but the early warning went out at 10:01: held until 10:06.
        #expect(feed.send(99.90, at: "10:03:00").isAcceptedWithoutAlert)
        #expect(feed.send(99.90, at: "10:05:30").isAcceptedWithoutAlert)
        #expect(feed.send(99.90, at: "10:07:00").alert?.signal == .early)
    }

    @Test func theCooldownDoesNotHoldTheStrongerWarningAfterTheEarlyOne() {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.70, at: "10:01:00").alert?.signal == .early)
        #expect(feed.send(99.50, at: "10:01:30").alert?.signal == .strong)
    }

    @Test func theCooldownIsConfigurable() throws {
        var feed = Feed(ReversalAlertEngine(settings: try AlertSettings(cooldown: 0)))
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.70, at: "10:01:00").alert?.signal == .early)
        feed.send(100.20, at: "10:02:00")
        #expect(feed.send(99.90, at: "10:03:00").alert?.signal == .early)
    }

    @Test func theRearmMarginIsConfigurable() throws {
        var feed = Feed(ReversalAlertEngine(settings: try AlertSettings(rearmPercent: 0.5, cooldown: 0)))
        feed.send(100, at: "10:00:00")
        feed.send(99.70, at: "10:01:00")
        feed.send(100.20, at: "10:02:00")  // 0.20% above: under a 0.5% margin
        #expect(feed.send(99.90, at: "10:03:00").isAcceptedWithoutAlert)
        feed.send(100.60, at: "10:04:00")  // 0.60% above
        #expect(feed.send(100.30, at: "10:05:00").alert?.signal == .early)
    }

    // MARK: Saved state

    @Test func aRestoredStateDoesNotAlertAgainForTheSamePullback() throws {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.70, at: "10:01:00").alert?.signal == .early)

        // A relaunch: the state goes through the file into a new engine.
        try withAlertStateStore { store in
            try store.save(feed.engine.state)
            let restored = try store.load()
            var relaunched = Feed(ReversalAlertEngine(state: restored))
            #expect(relaunched.engine.state == feed.engine.state)
            let same = relaunched.send(99.70, at: "10:03:00")
            #expect(same.isAcceptedWithoutAlert)
            #expect(same.high == SessionHigh(price: 100, kind: .observed))
            // The stronger warning, not sent before the relaunch, still comes.
            #expect(relaunched.send(99.50, at: "10:04:00").alert?.signal == .strong)
        }
    }

    @Test func aStateSavedInOneSessionDoesNotCarryIntoTheNext() throws {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.50, at: "10:01:00").alert?.signal == .strong)

        // Relaunched Wednesday, the same high and the same pullback warn again.
        try withAlertStateStore { store in
            try store.save(feed.engine.state)
            let restored = try store.load()
            var wednesdayFeed = Feed(ReversalAlertEngine(state: restored))
            #expect(wednesdayFeed.send(100, at: "10:00:00", on: wednesday).isAcceptedWithoutAlert)
            #expect(wednesdayFeed.send(99.50, at: "10:01:00", on: wednesday).alert?.signal == .strong)
        }
    }

    @Test func removingSymbolsForgetsOnlyThem() {
        var feed = Feed()
        for symbol in ["SPY", "QQQ", "DIA"] { feed.send(100, at: "10:00:00", symbol: symbol) }
        #expect(feed.engine.state.trackedSymbols == ["SPY", "QQQ", "DIA"])
        feed.engine.removeSymbols(notIn: ["spy", "DIA", "AAPL"])
        #expect(feed.engine.state.trackedSymbols == ["SPY", "DIA"])
        // QQQ starts over: its next quote is a new high, not a pullback from the old one.
        #expect(feed.send(99, at: "10:01:00", symbol: "QQQ").high == SessionHigh(price: 99, kind: .observed))
    }

    // MARK: Sessions

    @Test func aNewSessionResetsTheHighAndRearms() throws {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.50, at: "10:01:00").alert?.signal == .strong)
        feed.send(99.40, at: "15:59:00")

        // Wednesday opens below Tuesday's high: the high starts over, and so does the cycle.
        let open = feed.send(99.30, at: "09:30:05", on: wednesday)
        #expect(open.isAcceptedWithoutAlert)
        #expect(open.high == SessionHigh(price: 99.30, kind: .observed))
        let alert = try #require(feed.send(98.90, at: "09:31:00", on: wednesday).alert)
        #expect(alert.signal == .strong)
        #expect(alert.high == SessionHigh(price: 99.30, kind: .observed))
    }

    @Test func onAnEarlyCloseDayAlertsStopAt1300() {
        var feed = Feed()
        feed.send(100, at: "12:00:00", on: dayAfterThanksgiving)
        #expect(feed.send(99.70, at: "12:59:00", on: dayAfterThanksgiving).alert?.signal == .early)
        #expect(feed.send(99.40, at: "13:00:00", on: dayAfterThanksgiving).rejection == .outsideRegularHours)
        #expect(feed.send(99.40, at: "13:30:00", on: dayAfterThanksgiving).rejection == .outsideRegularHours)
    }

    @Test(arguments: [
        ("09:29:59", Quote.Session.regular),   // pre-market by the calendar
        ("16:00:00", .regular),                // the close: after-hours by the calendar
        ("17:00:00", .postMarket),
        ("21:00:00", .closed),
        ("10:00:00", .closed),                 // the provider says it isn't a regular-session quote
        ("10:00:00", .preMarket),
        ("10:00:00", .postMarket),
    ])
    func extendedHoursAndClosedQuotesAreIgnored(time: String, session: Quote.Session) {
        var feed = Feed()
        #expect(feed.send(80, at: time, session: session).rejection == .outsideRegularHours)
    }

    @Test func anExtendedHoursQuoteChangesNothing() {
        var feed = Feed()
        feed.send(100, at: "15:00:00")
        feed.send(150, at: "16:30:00", session: .postMarket)
        // The high is still 100, and 99.70 is 0.30% below it.
        let evaluation = feed.send(99.70, at: "15:01:00")
        #expect(evaluation.high == SessionHigh(price: 100, kind: .observed))
        #expect(evaluation.alert?.signal == .early)
    }

    @Test func aProviderThatDoesNotSayItsSessionIsJudgedByTheCalendar() {
        var feed = Feed()
        feed.send(100, at: "10:00:00", session: .unknown)
        #expect(feed.send(99.70, at: "10:01:00", session: .unknown).alert?.signal == .early)
        #expect(feed.send(99.40, at: "17:00:00", session: .unknown).rejection == .outsideRegularHours)
    }

    @Test func aDateTheCalendarDoesNotCoverIsRejected() {
        var feed = Feed()
        #expect(feed.send(100, at: "10:00:00", on: "2030-03-12").rejection == .notInCalendar)
    }

    // MARK: Bad data

    @Test func outOfOrderAndDuplicateQuotesAreRejected() {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        feed.send(99.90, at: "10:02:00")
        #expect(feed.send(99.50, at: "10:01:00").rejection == .outOfOrder)
        #expect(feed.send(99.50, at: "10:02:00").rejection == .duplicate)
        // Neither touched the cycle: the next fresh quote fires as it would have.
        #expect(feed.send(99.50, at: "10:03:00").alert?.signal == .strong)
    }

    @Test func aStaleQuoteIsRejected() {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        feed.lag = 61
        #expect(feed.send(99.50, at: "10:01:00").rejection == .stale(age: 61))
        feed.lag = 60
        #expect(feed.send(99.50, at: "10:02:00").alert?.signal == .strong)
    }

    @Test func theStalenessToleranceIsConfigurable() throws {
        var feed = Feed(ReversalAlertEngine(settings: try AlertSettings(staleTolerance: 120)))
        feed.lag = 90
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.50, at: "10:01:00").alert?.signal == .strong)
        feed.lag = 121
        #expect(feed.send(99.50, at: "10:02:00").rejection == .stale(age: 121))
    }

    @Test func aQuoteTheProviderSaysIsDelayedIsRejected() {
        var feed = Feed()
        #expect(feed.send(100, at: "10:00:00", delay: 900).rejection == .delayed(900))
        #expect(feed.send(100, at: "10:01:00", delay: 0).isAcceptedWithoutAlert)
    }

    @Test func aQuoteFromAheadOfTheClockIsRejected() {
        var feed = Feed()
        feed.lag = -120
        #expect(feed.send(100, at: "10:00:00").rejection == .aheadOfClock(120))
    }

    @Test func aSpikeIsRejectedAndChangesNothing() {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(50, at: "10:01:00").rejection == .implausibleJump(fromPrice: 100))
        #expect(feed.send(99.95, at: "10:02:00").isAcceptedWithoutAlert)
        #expect(feed.send(150, at: "10:03:00").rejection == .implausibleJump(fromPrice: 99.95))
        // The upward spike didn't become the high.
        let evaluation = feed.send(99.70, at: "10:04:00")
        #expect(evaluation.high == SessionHigh(price: 100, kind: .observed))
        #expect(evaluation.alert?.signal == .early)
    }

    @Test func aJumpALaterQuoteConfirmsIsUsed() throws {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(85, at: "10:01:00").rejection == .implausibleJump(fromPrice: 100))
        let alert = try #require(feed.send(85.50, at: "10:02:00").alert)
        #expect(alert.signal == .strong)
        #expect(close(alert.pullbackPercent, 14.5))
    }

    @Test func aRepeatOfTheSameSpikeDoesNotConfirmIt() {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(85, at: "10:01:00").rejection == .implausibleJump(fromPrice: 100))
        // The provider returning the same quote again is no evidence the move was real.
        #expect(feed.send(85, at: "10:01:00").rejection == .implausibleJump(fromPrice: 100))
    }

    @Test func theSpikeLimitIsConfigurable() throws {
        var feed = Feed(ReversalAlertEngine(settings: try AlertSettings(spikePercent: 20)))
        feed.send(100, at: "10:00:00")
        #expect(feed.send(85, at: "10:01:00").alert?.signal == .strong)
    }

    @Test(arguments: [0.0, -5.0, Double.nan, Double.infinity])
    func aPriceThatIsNotAPositiveNumberIsRejected(price: Double) {
        var feed = Feed()
        #expect(feed.send(price, at: "10:00:00").rejection == .invalidPrice)
    }

    // MARK: Saved state

    @Test func restoredStateDoesNotAlertAgain() throws {
        var feed = Feed()
        feed.send(100, at: "10:00:00")
        #expect(feed.send(99.70, at: "10:01:00").alert?.signal == .early)

        let saved = try JSONEncoder().encode(feed.engine.state)
        let state = try JSONDecoder().decode(ReversalAlertEngine.State.self, from: saved)
        #expect(state == feed.engine.state)

        var relaunched = Feed(ReversalAlertEngine(state: state))
        #expect(relaunched.send(99.70, at: "10:01:00").rejection == .duplicate)
        let next = relaunched.send(99.68, at: "10:02:00")
        #expect(next.isAcceptedWithoutAlert)
        #expect(next.high == SessionHigh(price: 100, kind: .observed))
        #expect(relaunched.send(99.50, at: "10:03:00").alert?.signal == .strong)
    }

    // MARK: Recorded quotes

    @Test func aRecordedDaysBarsMakeTheObservedHighWhenThereIsNoSessionHigh() async throws {
        let http = FakeHTTPClient([Yahoo.chart("SPY", YahooFixtures.spyDay)])
        let recorded = try #require(
            try await YahooFinanceProvider(http: http, pacing: PacingClock().pacing).quotes(for: ["SPY"]).quotes.first)
        // Hand-made quotes during SPY's recorded day of Monday 9 November, each with all 79 of the
        // day's bars, so some start after the quote's time.
        func quote(_ price: Double, at time: String, sessionHigh: Double?) -> Quote {
            var quote = recorded
            quote.price = price
            quote.timestamp = at(time, on: "2026-11-09")
            quote.session = .regular
            quote.sessionHigh = sessionHigh
            return quote
        }
        func evaluate(_ quote: Quote, in engine: inout ReversalAlertEngine) -> QuoteEvaluation {
            engine.evaluate(quote, thresholds: .standard, now: quote.timestamp + 5)
        }

        // Without the session high: at 15:17 the day's highest bar, 15:15's, is still in
        // progress, so the highest that ended is 14:40's.
        var engine = ReversalAlertEngine()
        let before = evaluate(quote(754.00, at: "15:17:00", sessionHigh: nil), in: &engine)
        #expect(before.high == SessionHigh(price: 755.2100219726562, kind: .observed))
        #expect(before.isAcceptedWithoutAlert)
        // At 15:21 it has ended: 753.00 is 0.32% below its high.
        let alert = try #require(evaluate(quote(753.00, at: "15:21:00", sessionHigh: nil), in: &engine).alert)
        #expect(alert.high == SessionHigh(price: 755.4199829101562, kind: .observed))
        #expect(alert.signal == .early)
        #expect(close(alert.pullbackPercent, (755.4199829101562 - 753.00) / 755.4199829101562 * 100))
        #expect(alert.summary.contains("below its observed high"))

        // With Yahoo's session high, as recorded, the bars add nothing.
        var withHigh = ReversalAlertEngine()
        let session = evaluate(quote(753.00, at: "15:21:00", sessionHigh: recorded.sessionHigh), in: &withHigh)
        #expect(recorded.sessionHigh == 755.42)
        #expect(session.high == SessionHigh(price: 755.42, kind: .session))
        #expect(close(session.pullbackPercent, (755.42 - 753.00) / 755.42 * 100))
    }

    @Test func recordedYahooQuotesAreMeasuredFromTheSessionHigh() async throws {
        let http = FakeHTTPClient([Yahoo.chart("SPY", YahooFixtures.spy), Yahoo.chart("AAPL", YahooFixtures.aapl)])
        let batch = try await YahooFinanceProvider(http: http, pacing: PacingClock().pacing).quotes(for: ["SPY", "AAPL"])
        var engine = ReversalAlertEngine()
        let now = YahooFixtures.quoteTime.addingTimeInterval(10)

        // SPY: 752.68 against Yahoo's day high of 752.96, 0.037% below: no alert.
        let spy = engine.evaluate(batch.quotes[0], thresholds: .standard, now: now)
        #expect(spy.isAcceptedWithoutAlert)
        #expect(spy.high == SessionHigh(price: 752.96, kind: .session))
        #expect(close(spy.pullbackPercent, (752.96 - 752.68) / 752.96 * 100))

        // AAPL: 349.35 against 351.42, 0.589% below: past the stronger warning's 0.40%.
        let alert = try #require(engine.evaluate(batch.quotes[1], thresholds: .standard, now: now).alert)
        #expect(alert.symbol == "AAPL")
        #expect(alert.signal == .strong)
        #expect(alert.high == SessionHigh(price: 351.42, kind: .session))
        #expect(close(alert.pullbackPercent, (351.42 - 349.35) / 351.42 * 100))
        #expect(alert.thresholdPercent == 0.40)
        #expect(alert.quoteTimestamp == YahooFixtures.quoteTime)
        #expect(alert.dataAge == 10)
        #expect(alert.source == "Yahoo Finance (unofficial)")
    }
}
