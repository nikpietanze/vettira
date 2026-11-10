import Foundation
import Testing
import VettiraCore

// Expected values come from the issue: a small line chart of the day, its line green when the
// price is above the previous close and red when below, with a faint previous-close line; gaps in
// the provider's bars are gaps; the chart's words say "today's price, updated with each quote", never
// live, and say up or down on the day, never buy or sell. Tuesday 10 November 2026 is a trading day.

private func bar(_ time: String, _ close: Double?) -> PriceBar {
    PriceBar(timestamp: nyTime(time), close: close, high: close.map { $0 + 0.05 })
}

/// SPY's day: 100 at 09:30, 101 at 09:35, nothing at 09:40, 102 at 09:45, and the quote at 101
/// at 09:50, with the previous close at 99.
private func day(
    price: Double = 101, at time: String = "09:50:00", previousClose: Double? = 99,
    bars: [PriceBar] = [bar("09:30:00", 100), bar("09:35:00", 101), bar("09:40:00", nil), bar("09:45:00", 102)]
) -> Quote {
    Quote(symbol: "SPY", price: price, timestamp: nyTime(time), source: "Test provider", session: .regular,
          previousClose: previousClose, intraday: bars)
}

private func chart(_ quote: Quote, now: Date = nyTime("09:50:05")) -> PriceChart? {
    PriceChart(quote: quote, now: now)
}

@Test func theLineRunsThroughEachBarAndTheLatestPriceAndBreaksAtAGap() throws {
    let chart = try #require(chart(day()))
    // From the previous close, 99 (the lowest), to 102 (the highest); 09:30 to 09:50.
    #expect(chart.segments == [
        [PriceChart.Point(x: 0, y: 1.0 / 3), PriceChart.Point(x: 0.25, y: 2.0 / 3)],
        [PriceChart.Point(x: 0.75, y: 1), PriceChart.Point(x: 1, y: 2.0 / 3)],
    ])
    #expect(chart.previousCloseLevel == 0)
}

@Test func thePreviousCloseIsAlwaysOnTheChart() throws {
    let above = try #require(chart(day(previousClose: 105)))
    #expect(above.previousCloseLevel == 1)
    #expect(above.segments.flatMap { $0 }.allSatisfy { (0...1).contains($0.y) })
}

@Test func upOnTheDayIsUpAndSaysSoWithTodaysPriceUpdatedWithEachQuote() throws {
    let chart = try #require(chart(day()))
    #expect(chart.direction == .up)
    #expect(chart.description
        == "Chart of today's price for SPY, updated with each quote: up 2.02% from the previous close of 99.00.")
}

@Test func downOnTheDayIsDown() throws {
    let chart = try #require(chart(day(price: 98)))
    #expect(chart.direction == .down)
    #expect(chart.description
        == "Chart of today's price for SPY, updated with each quote: down 1.01% from the previous close of 99.00.")
}

@Test func withinHalfAHundredthOfAPercentIsUnchanged() throws {
    let chart = try #require(chart(day(price: 99.004)))
    #expect(chart.direction == .flat)
    #expect(chart.description
        == "Chart of today's price for SPY, updated with each quote: unchanged from the previous close of 99.00.")
}

@Test func withoutAPreviousCloseThereIsNoDirectionOrLine() throws {
    let chart = try #require(chart(day(previousClose: nil)))
    #expect(chart.direction == .unknown)
    #expect(chart.previousCloseLevel == nil)
    #expect(chart.description == "Chart of today's price for SPY, updated with each quote.")
}

@Test(arguments: [
    // Wednesday's pre-market, and the Saturday after.
    nyTime("07:00:00", on: "2026-11-11"),
    nyTime("12:00:00", on: "2026-11-14"),
])
func onALaterDayItsTheLastSessions(now: Date) throws {
    let chart = try #require(chart(day(), now: now))
    #expect(chart.description == "Chart of the last session's price for SPY: up 2.02% from the previous close of 99.00.")
}

@Test func afterTheCloseTheSameDayItsStillToday() throws {
    let chart = try #require(chart(day(), now: nyTime("18:00:00")))
    #expect(chart.description.hasPrefix("Chart of today's price for SPY, updated with each quote"))
}

@Test func aQuoteNoNewerThanTheLastBarIsntAddedToTheLine() throws {
    let chart = try #require(chart(day(price: 50, at: "09:45:00")))
    // Without 50 the lowest price is the previous close, 99, and the line ends at 09:45's bar.
    #expect(chart.segments.last?.last == PriceChart.Point(x: 1, y: 1))
}

@Test func gapsAtEitherEndArentPartOfTheLine() throws {
    let chart = try #require(chart(day(
        price: 101, at: "09:40:00", previousClose: nil,
        bars: [bar("09:30:00", nil), bar("09:35:00", 100), bar("09:40:00", 102), bar("09:45:00", nil)])))
    #expect(chart.segments == [[PriceChart.Point(x: 0, y: 0), PriceChart.Point(x: 1, y: 1)]])
}

@Test func fewerThanTwoPricesIsNoChart() {
    #expect(chart(day(bars: [])) == nil)
    #expect(chart(day(at: "09:30:00", bars: [bar("09:30:00", 100)])) == nil)
    #expect(chart(day(at: "09:30:00", bars: [bar("09:30:00", nil), bar("09:35:00", nil)])) == nil)
}

@Test func aFlatDayIsALevelLineAcrossTheMiddle() throws {
    let chart = try #require(chart(day(
        price: 100, previousClose: 100, bars: [bar("09:30:00", 100), bar("09:35:00", 100)])))
    #expect(chart.segments == [[PriceChart.Point(x: 0, y: 0.5), PriceChart.Point(x: 0.25, y: 0.5),
                                 PriceChart.Point(x: 1, y: 0.5)]])
    #expect(chart.previousCloseLevel == 0.5)
}

@Test func linesScaleIntoTheBoxInsideTheInset() throws {
    let chart = try #require(chart(day()))
    let lines = chart.lines(width: 40, height: 16, inset: 1.5)
    let first = try #require(lines.first?.first)
    let last = try #require(lines.last?.last)
    #expect(abs(first.x - 1.5) < 1e-9 && abs(first.y - (1.5 + 13.0 / 3)) < 1e-9)
    #expect(abs(last.x - 38.5) < 1e-9 && abs(last.y - (1.5 + 26.0 / 3)) < 1e-9)
    #expect(chart.previousCloseY(height: 16, inset: 1.5) == 1.5)
}
