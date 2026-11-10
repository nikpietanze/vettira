import Foundation
import Testing
import VettiraCore

/// SPY's recorded history for `timeframe`, read by the Yahoo provider from its fixture.
func recordedHistory(_ timeframe: ChartTimeframe) async throws -> PriceHistory {
    let fixture = ["1D": "1d-1m", "5D": "5d-5m", "1M": "1mo-30m", "6M": "6mo", "YTD": "ytd", "1Y": "1y", "5Y": "5y"][timeframe.rawValue]!
    let http = FakeHTTPClient([Yahoo.chart("SPY", try HistoryFixtures.spy(fixture))])
    return try await YahooFinanceProvider(http: http, pacing: PacingClock().pacing).history(for: "SPY", timeframe: timeframe)
}

@Suite struct SymbolChartTests {
    /// The morning after the recorded day, before the open.
    private let nextMorning = HistoryFixtures.close + 15 * 3600
    private let open = HistoryFixtures.open

    // MARK: 1D

    @Test func oneDaySpreadsTheBarsOverTheSession() async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(.oneDay), latest: nil, now: nextMorning))
        // Every minute's bar from 09:30 to 16:00.
        #expect(chart.points.count == 391)
        #expect(chart.points.first?.x == 0)
        #expect(chart.points.last?.x == 1)
        // A minute's bar is 1/390 of the session; half of one at each end.
        #expect(abs(chart.xDomain.lowerBound + 1.0 / 780) < 1e-9)
        #expect(abs(chart.xDomain.upperBound - (1 + 1.0 / 780)) < 1e-9)
        #expect(chart.points.map(\.segment).allSatisfy { $0 == 0 })
    }

    @Test func oneDayIsMeasuredFromThePreviousCloseWhichItDraws() async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(.oneDay), latest: nil, now: nextMorning))
        #expect(chart.reference == 735.29)
        #expect(chart.previousCloseLine == 735.29)
        #expect(chart.direction == .up)
        // 752.69 − 735.29 = 17.40, 2.37% of 735.29. The next morning, it's the last session's.
        #expect(chart.change == "+17.40 (+2.37%) on Mon 9 Nov")
        #expect(chart.priceDomain.contains(735.29))
        #expect(chart.points.allSatisfy { chart.priceDomain.contains($0.price) })
        #expect(chart.description == "Chart of SPY, on Mon 9 Nov: up 2.37% from 735.29 to 752.69. High 755.42, low 741.03.")
    }

    @Test func oneDayDuringItsOwnSessionIsToday() async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(.oneDay), latest: nil, now: HistoryFixtures.close))
        #expect(chart.change == "+17.40 (+2.37%) today")
    }

    @Test func oneDayIsLabelledOnTheHourInET() async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(.oneDay), latest: nil, now: nextMorning))
        #expect(chart.ticks.map(\.label) == ["10:00", "11:00", "12:00", "13:00", "14:00", "15:00"])
        // 10:00 is 30 minutes into the 390-minute session.
        #expect(abs(chart.ticks[0].x - 30.0 / 390) < 1e-9)
    }

    @Test func theCrosshairSaysTheTimePriceChangeAndVolume() async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(.oneDay), latest: nil, now: nextMorning))
        // 13:24:20 is nearest the 13:24 bar: the crosshair snaps to it, at its own place and close.
        let minutes: Double = 13 * 60 + 24 + 1.0 / 3 - (9 * 60 + 30)
        let point = try #require(chart.nearest(toX: minutes / 390))
        #expect(point.bar.timestamp == open + 234 * 60)
        #expect(abs(point.x - 234.0 / 390) < 1e-12)
        #expect(point.price == point.bar.close)
        let readout = chart.readout(point)
        #expect(readout.time == "13:24 ET")
        #expect(readout.price == DisplayFormat.price(point.price))
        #expect(readout.change == DisplayFormat.signedPercent((point.price - 735.29) / 735.29 * 100))
        #expect(readout.direction == .up)
        #expect(readout.volume == "Vol \(DisplayFormat.volume(point.bar.volume!))")
    }

    // MARK: Longer timeframes

    @Test func aYearIsOneBarAfterAnotherMeasuredFromTheCloseBeforeIt() async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(.oneYear), latest: nil, now: nextMorning))
        #expect(chart.points.map(\.x) == (0..<251).map(Double.init))
        #expect(chart.xDomain == -0.5...250.5)
        #expect(chart.previousCloseLine == nil)
        #expect(chart.reference == 670.97)
        // 752.69 − 670.97 = 81.72, 12.18%.
        #expect(chart.change == "+81.72 (+12.18%) past year")
        #expect(chart.high.rounded() == 782)
        #expect(chart.low.rounded() == 629)
        let last = chart.readout(try #require(chart.points.last))
        #expect(last.time == "Mon 9 Nov 2026")
        #expect(last.volume == "Vol 50.1M")
        #expect(last.change == "+12.18%")
    }

    @Test func aYearIsLabelledByMonthWithTheYearForJanuary() async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(.oneYear), latest: nil, now: nextMorning))
        #expect(chart.ticks.map(\.label) == ["Dec", "2026", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov"])
        #expect(chart.ticks(atMost: 6).map(\.label) == ["Dec", "Feb", "Apr", "Jun", "Aug", "Oct"])
    }

    @Test func fiveDaysIsLabelledByDay() async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(.fiveDays), latest: nil, now: nextMorning))
        #expect(chart.ticks.map(\.label) == ["Tue 3", "Wed 4", "Thu 5", "Fri 6", "Mon 9"])
        #expect(chart.ticks.first?.x == 0)
        #expect(chart.readout(try #require(chart.points.first)).time == "Tue 3 Nov, 09:30 ET")
        #expect(chart.change.hasSuffix("past 5 days"))
    }

    @Test func aMonthIsLabelledByWeek() async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(.oneMonth), latest: nil, now: nextMorning))
        #expect(chart.ticks.map(\.label) == ["12 Oct", "19 Oct", "26 Oct", "2 Nov", "9 Nov"])
        #expect(chart.direction == .down)
        #expect(chart.change.hasPrefix("\u{2212}"))
    }

    @Test func fiveYearsIsLabelledByYearWithWeeklyReadouts() async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(.fiveYears), latest: nil, now: nextMorning))
        #expect(chart.ticks.map(\.label) == ["2022", "2023", "2024", "2025", "2026"])
        #expect(chart.readout(try #require(chart.points.last)).time == "Week of 9 Nov 2026")
        #expect(chart.change.hasSuffix("past 5 years"))
    }

    @Test(arguments: ChartTimeframe.allCases)
    func everyRecordedTimeframeMakesAChart(timeframe: ChartTimeframe) async throws {
        let chart = try #require(SymbolChart(history: try await recordedHistory(timeframe), latest: nil, now: nextMorning))
        #expect(chart.last.rounded() == 753)
        #expect(chart.points.allSatisfy { chart.xDomain.contains($0.x) && chart.priceDomain.contains($0.price) })
        #expect(!chart.ticks.isEmpty)
    }

    // MARK: The latest price

    private func quote(_ price: Double, at time: Date, symbol: String = "SPY") -> Quote {
        Quote(symbol: symbol, price: price, timestamp: time, source: "Test", session: .regular, previousClose: 100)
    }

    private func bars(_ closes: [Double?], every seconds: TimeInterval = 300) -> [PriceBar] {
        closes.enumerated().map { PriceBar(timestamp: open + Double($0.offset) * seconds, close: $0.element, high: $0.element, open: $0.element, low: $0.element) }
    }

    @Test func aQuoteWithinTheLastBarMovesItsClose() throws {
        let history = PriceHistory(symbol: "SPY", timeframe: .oneYear, bars: bars([100, 101], every: 86_400), previousClose: 99)
        let chart = try #require(SymbolChart(history: history, latest: quote(103, at: open + 86_400 + 3600), now: open + 86_400 + 3600))
        #expect(chart.points.map(\.price) == [100, 103])
        #expect(chart.points.last?.bar.high == 103)
        #expect(chart.last == 103)
    }

    @Test func aQuoteAfterTheLastBarOfTheSameSessionEndsTheLine() throws {
        let history = PriceHistory(symbol: "SPY", timeframe: .oneDay, bars: bars([100, 101]), previousClose: 99)
        let chart = try #require(SymbolChart(history: history, latest: quote(102, at: open + 1200), now: open + 1200))
        #expect(chart.points.map(\.price) == [100, 101, 102])
        #expect(abs(chart.points.last!.x - 1200 / 23_400) < 1e-9)
    }

    @Test func aQuoteFromAnotherSessionOrSymbolIsLeftOut() throws {
        let history = PriceHistory(symbol: "SPY", timeframe: .oneDay, bars: bars([100, 101]), previousClose: 99)
        let tomorrow = open + 86_400 + 600
        #expect(SymbolChart(history: history, latest: quote(110, at: tomorrow), now: tomorrow)?.points.count == 2)
        #expect(SymbolChart(history: history, latest: quote(110, at: open + 1200, symbol: "QQQ"), now: open)?.points.count == 2)
    }

    @Test func aBarWithoutAPriceBreaksTheLine() throws {
        let history = PriceHistory(symbol: "SPY", timeframe: .fiveDays, bars: bars([nil, 100, 101, nil, 102, nil], every: 900), previousClose: 99)
        let chart = try #require(SymbolChart(history: history, latest: nil, now: open))
        // The gaps at either end aren't part of it.
        #expect(chart.points.map(\.segment) == [0, 0, 1])
        #expect(chart.points.map(\.x) == [0, 1, 3])
        #expect(chart.xDomain == -0.5...3.5)
    }

    @Test func withoutACloseBeforeThePeriodItsMeasuredFromTheFirstOpen() throws {
        var history = PriceHistory(symbol: "SPY", timeframe: .sixMonths, bars: bars([100, 98], every: 86_400))
        history.bars[0].open = 104
        let chart = try #require(SymbolChart(history: history, latest: nil, now: open))
        #expect(chart.reference == 104)
        #expect(chart.direction == .down)
        #expect(chart.change == "\u{2212}6.00 (\u{2212}5.77%) past 6 months")
    }

    @Test func noPricesNoChart() {
        let history = PriceHistory(symbol: "SPY", timeframe: .oneYear, bars: bars([nil, nil]))
        #expect(SymbolChart(history: history, latest: nil, now: open) == nil)
        #expect(SymbolChart(history: PriceHistory(symbol: "SPY", timeframe: .oneYear, bars: []), latest: nil, now: open) == nil)
    }
}

@Suite struct SymbolStatsTests {
    private let thresholds = try! PullbackThresholds(early: 0.25, strong: 0.40)

    @Test func theDaysFiguresComeFromTheQuoteAndItsBars() async throws {
        let http = FakeHTTPClient([Yahoo.chart("SPY", try HistoryFixtures.spy("1d"))])
        let quote = try #require(try await YahooFinanceProvider(http: http, pacing: PacingClock().pacing).quotes(for: ["SPY"]).quotes.first)
        var state = SymbolSnapshot(symbol: try TickerSymbol("SPY"))
        state.quote = quote
        state.high = SessionHigh(price: 755.42, kind: .session)
        state.pullbackPercent = 0.36
        let stats = SymbolStats(state: state, thresholds: thresholds)
        #expect(stats.items.map(\.label) == [
            "Open", "High", "Low", "Prev close", "Volume", "Session high", "From high", "Thresholds",
        ])
        // High and low are Yahoo's own for the session (regularMarketDayHigh and DayLow), and the
        // volume its count for the day.
        #expect(stats.items.map(\.value) == [
            "741.95", "755.42", "741.09", "735.29", "48.9M", "755.42", "\u{2212}0.36%", "0.25% / 0.40%",
        ])
        #expect(stats.items.first { $0.label == "From high" }?.tone == .down)
    }

    @Test func aHighVettiraWorkedOutIsOnlyTheObservedHigh() throws {
        var state = SymbolSnapshot(symbol: try TickerSymbol("SPY"))
        let time = Date(timeIntervalSince1970: 1_794_240_000)
        state.quote = Quote(
            symbol: "SPY", price: 100, timestamp: time, source: "Test",
            intraday: [PriceBar(timestamp: time - 300, close: 100.5, high: 101, open: 100.2, low: 99.5)])
        state.high = SessionHigh(price: 102, kind: .observed)
        state.pullbackPercent = 0
        let stats = SymbolStats(state: state, thresholds: thresholds)
        // Without the provider's high and low, the day's are dashes, never the bars' or the quotes'.
        #expect(stats.items[1].value == "\u{2014}")
        #expect(stats.items[2].value == "\u{2014}")
        #expect(stats.items[5].label == "Observed high")
        #expect(stats.items[5].value == "102.00")
        #expect(stats.items[6].value == "0.00%")
        #expect(stats.items[6].tone == .plain)
        #expect(stats.items[0].value == "100.20")
        // No volume from the provider: the bars' sum, and these have none.
        #expect(stats.items[4].value == "\u{2014}")
    }

    @Test func withoutAQuoteOnlyTheThresholds() {
        let stats = SymbolStats(state: nil, thresholds: thresholds)
        #expect(stats.items.dropLast().allSatisfy { $0.value == "\u{2014}" })
        #expect(stats.items[5].label == "Observed high")
        #expect(stats.items.last?.value == "0.25% / 0.40%")
    }
}

@Suite struct ChartFormatTests {
    @Test(arguments: [
        (0, "0"), (950, "950"), (999, "999"), (1_000, "1.0K"), (41_230, "41.2K"), (412_000, "412K"),
        (999_999, "1.0M"), (61_200_000, "61.2M"), (120_000_000, "120M"), (1_300_000_000, "1.3B"),
    ])
    func volumesAreShort(shares: Int, text: String) {
        #expect(DisplayFormat.volume(shares) == text)
    }

    @Test func changesHaveTheirSignAndPercent() {
        #expect(DisplayFormat.change(2.22, from: 738.9) == "+2.22 (+0.30%)")
        #expect(DisplayFormat.change(-1.05, from: 738.9) == "\u{2212}1.05 (\u{2212}0.14%)")
        #expect(DisplayFormat.change(0.001, from: 738.9) == "0.00 (0.00%)")
        #expect(DisplayFormat.signedPercent(0.4) == "+0.40%")
        #expect(DisplayFormat.signedPercent(-0.004) == "0.00%")
    }
}
