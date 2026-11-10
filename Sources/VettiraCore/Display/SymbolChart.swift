import Foundation

/// The symbol chart's maths, for one timeframe: where each price goes, the price range to show,
/// the period's change and its direction, the time labels along the bottom, and what the
/// crosshair says at each point. The app only draws what it gives.
///
/// 1D spreads its bars by time over the whole session, so a day still trading leaves the rest of
/// the session empty. Longer timeframes space their bars evenly, one after another, leaving out
/// nights, weekends and holidays, as trading apps do. Times are the exchange's, in New York (ET).
/// The line ends at the latest quote's price, so it moves with each quote between requests.
public struct SymbolChart: Equatable, Sendable {
    /// One price on the line.
    public struct Point: Equatable, Sendable, Identifiable {
        /// Its bar's place among the history's bars, gaps included.
        public let id: Int
        /// Where it goes across, in `xDomain`.
        public let x: Double
        /// The bar's close.
        public let price: Double
        /// Which unbroken run of the line it's in: a bar with no price breaks the line.
        public let segment: Int
        public let bar: PriceBar
    }

    /// A time label along the bottom.
    public struct Tick: Equatable, Sendable {
        public let x: Double
        public let label: String
    }

    /// What the crosshair shows at a point: `13:24 ET`, `741.86`, `+0.40%`, `Vol 412K`.
    public struct Readout: Equatable, Sendable {
        public let time: String
        public let price: String
        /// The change from the period's start (the previous close, on 1D) to this point.
        public let change: String?
        public let direction: PriceChart.Direction
        public let volume: String?
    }

    public let symbol: String
    public let timeframe: ChartTimeframe
    public let points: [Point]
    /// The span across, with half a bar's room at each end.
    public let xDomain: ClosedRange<Double>
    /// The prices to show, low to high: the line's (and on 1D the previous close), with room
    /// above and below.
    public let priceDomain: ClosedRange<Double>
    /// The previous close's level, drawn as a dotted line on 1D only.
    public let previousCloseLine: Double?
    /// What the period's change is measured from: the close before its first bar (the previous
    /// close, on 1D), or its first price when the provider gave none.
    public let reference: Double
    /// The last price: the latest quote's, when it's newer than the bars.
    public let last: Double
    public let direction: PriceChart.Direction
    /// The change over the period, with when: `+2.22 (+0.30%) today`, `+81.72 (+12.18%) past year`.
    public let change: String
    /// The period's highest and lowest prices.
    public let high: Double
    public let low: Double
    /// The time labels along the bottom, before any thinning.
    public let ticks: [Tick]
    /// The chart in words, for VoiceOver.
    public let description: String

    private static let exchange = TimeZone(identifier: "America/New_York")!

    /// The chart of `history`, ending at `latest`'s price when that's newer than the last bar and
    /// from the same symbol, at `now`. `nil` when no bar has a price.
    public init?(history: PriceHistory, latest: Quote?, now: Date, calendar: MarketCalendar = .usEquities) {
        var bars = history.bars
        let timeframe = history.timeframe
        if let latest, latest.symbol.uppercased() == history.symbol.uppercased() {
            Self.splice(latest, into: &bars, timeframe: timeframe, calendar: calendar)
        }
        guard let first = bars.firstIndex(where: { $0.close != nil }),
              let lastIndex = bars.lastIndex(where: { $0.close != nil })
        else { return nil }
        bars = Array(bars[first...lastIndex])

        // Across: 1D by time over the session; longer timeframes one bar after another.
        let x: (Int, PriceBar) -> Double
        let halfBar: Double
        let session = timeframe == .oneDay ? calendar.status(at: bars[0].timestamp)?.session : nil
        if timeframe == .oneDay {
            let open = session?.open ?? bars[0].timestamp
            let close = session?.close ?? max(bars[bars.count - 1].timestamp, open + 300)
            let length = close.timeIntervalSince(open)
            x = { _, bar in bar.timestamp.timeIntervalSince(open) / length }
            halfBar = 150 / length
            xDomain = -halfBar...(1 + halfBar)
        } else {
            x = { index, _ in Double(index) }
            halfBar = 0.5
            xDomain = -halfBar...(Double(bars.count - 1) + halfBar)
        }

        var points: [Point] = []
        var segment = 0
        for (index, bar) in bars.enumerated() {
            guard let price = bar.close else {
                if points.last?.segment == segment { segment += 1 }
                continue
            }
            points.append(Point(id: index, x: x(index, bar), price: price, segment: segment, bar: bar))
        }
        self.points = points
        symbol = history.symbol
        self.timeframe = timeframe

        let prices = points.map(\.price)
        high = bars.compactMap { $0.high ?? $0.close }.max() ?? prices.max()!
        low = bars.compactMap { $0.low ?? $0.close }.min() ?? prices.min()!
        last = prices[prices.count - 1]
        let firstPrice = bars[0].open ?? prices[0]
        reference = history.previousClose ?? (timeframe == .oneDay ? latest?.previousClose : nil) ?? firstPrice
        previousCloseLine = timeframe == .oneDay ? history.previousClose ?? latest?.previousClose : nil

        // The line's prices, the dotted line's too, with a tenth of the range above and below.
        let levels = prices + [previousCloseLine].compactMap { $0 }
        let lowest = levels.min()!, highest = levels.max()!
        let room = max((highest - lowest) * 0.1, highest * 0.001)
        priceDomain = (lowest - room)...(highest + room)

        let difference = last - reference
        let percent = reference != 0 ? difference / reference * 100 : 0
        direction = (percent * 100).rounded() == 0 ? .flat : difference > 0 ? .up : .down
        let when: String
        if timeframe == .oneDay {
            let day = MarketCalendar.day(of: bars[0].timestamp)
            when = day == MarketCalendar.day(of: now) ? "today" : "on \(Self.format(bars[0].timestamp, "EEE d MMM"))"
        } else {
            when = timeframe.period.lowercased()
        }
        change = "\(DisplayFormat.change(difference, from: reference)) \(when)"
        ticks = Self.ticks(timeframe, bars: bars, x: x, session: session)

        let movement = switch direction {
        case .up: "up \(DisplayFormat.percent(abs(percent)))"
        case .down: "down \(DisplayFormat.percent(abs(percent)))"
        case .flat, .unknown: "unchanged"
        }
        description = "Chart of \(history.symbol), \(timeframe == .oneDay ? when : timeframe.period.lowercased()): "
            + "\(movement) from \(DisplayFormat.price(reference)) to \(DisplayFormat.price(last)). "
            + "High \(DisplayFormat.price(high)), low \(DisplayFormat.price(low))."
    }

    /// The point nearest `x` across, for the crosshair; `nil` without points.
    public func nearest(toX x: Double) -> Point? {
        points.min { abs($0.x - x) < abs($1.x - x) }
    }

    /// What the crosshair says at `point`.
    public func readout(_ point: Point) -> Readout {
        let difference = point.price - reference
        let percent = reference != 0 ? difference / reference * 100 : 0
        let direction: PriceChart.Direction = (percent * 100).rounded() == 0 ? .flat : difference > 0 ? .up : .down
        return Readout(
            time: Self.time(of: point.bar.timestamp, timeframe),
            price: DisplayFormat.price(point.price),
            change: DisplayFormat.signedPercent(percent),
            direction: direction,
            volume: point.bar.volume.map { "Vol \(DisplayFormat.volume($0))" })
    }

    /// At most `count` of the ticks, evenly picked, the first kept.
    public func ticks(atMost count: Int) -> [Tick] {
        guard count > 0, ticks.count > count else { return ticks }
        let step = Int((Double(ticks.count) / Double(count)).rounded(.up))
        return ticks.enumerated().filter { $0.offset % step == 0 }.map(\.element)
    }

    // MARK: Building it

    /// Puts `latest`'s price on the line: into the last bar while the quote is within it, or as a
    /// bar of its own after it (on 1D only within the same session).
    private static func splice(_ latest: Quote, into bars: inout [PriceBar], timeframe: ChartTimeframe, calendar: MarketCalendar) {
        guard let lastBar = bars.last, latest.timestamp > lastBar.timestamp, latest.price > 0 else { return }
        let price = latest.price
        if latest.timestamp < end(of: lastBar.timestamp, timeframe) {
            var bar = lastBar
            bar.close = price
            bar.open = bar.open ?? price
            bar.high = max(bar.high ?? price, price)
            bar.low = min(bar.low ?? price, price)
            bars[bars.count - 1] = bar
            return
        }
        if timeframe == .oneDay {
            let day = calendar.status(at: lastBar.timestamp)?.session.day
            guard day != nil, calendar.status(at: latest.timestamp)?.session.day == day else { return }
        }
        let open = bars.last(where: { $0.close != nil })?.close ?? price
        bars.append(PriceBar(
            timestamp: latest.timestamp, close: price, high: max(open, price), open: open, low: min(open, price)))
    }

    /// When the bar that starts at `start` ends.
    private static func end(of start: Date, _ timeframe: ChartTimeframe) -> Date {
        switch timeframe.barLength {
        case .minutes(let minutes): start + TimeInterval(minutes * 60)
        case .day: start + 86_400
        case .week: start + 7 * 86_400
        }
    }

    /// 1D: each whole hour inside the session (`10:00` to `15:00`). 5D: each day's first bar
    /// (`Tue 3`). 1M: each week's first bar (`12 Oct`). 6M, YTD, 1Y: each month's first bar
    /// (`Jun`, or the year for January). 5Y: each year's first bar (`2023`).
    private static func ticks(
        _ timeframe: ChartTimeframe, bars: [PriceBar], x: (Int, PriceBar) -> Double, session: MarketSession?
    ) -> [Tick] {
        let calendar = newYork
        if timeframe == .oneDay {
            guard let session else { return [] }
            var hour = calendar.nextDate(
                after: session.open, matching: DateComponents(minute: 0), matchingPolicy: .nextTime)!
            var ticks: [Tick] = []
            let length = session.close.timeIntervalSince(session.open)
            while hour < session.close {
                ticks.append(Tick(x: hour.timeIntervalSince(session.open) / length, label: format(hour, "HH:mm")))
                hour += 3600
            }
            return ticks
        }
        func key(_ date: Date) -> Int {
            let parts = calendar.dateComponents([.year, .month, .day, .yearForWeekOfYear, .weekOfYear], from: date)
            return switch timeframe {
            case .fiveDays: parts.year! * 10_000 + parts.month! * 100 + parts.day!
            case .oneMonth: parts.yearForWeekOfYear! * 100 + parts.weekOfYear!
            case .fiveYears: parts.year!
            default: parts.year! * 100 + parts.month!
            }
        }
        func label(_ date: Date) -> String {
            switch timeframe {
            case .fiveDays: format(date, "EEE d")
            case .oneMonth: format(date, "d MMM")
            case .fiveYears: format(date, "yyyy")
            default: calendar.component(.month, from: date) == 1 ? format(date, "yyyy") : format(date, "MMM")
            }
        }
        var ticks: [Tick] = []
        var previous: Int?
        for (index, bar) in bars.enumerated() {
            let current = key(bar.timestamp)
            // The first bar starts a period only for 5D and 1M, which start at a session's open.
            if current != previous, previous != nil || timeframe == .fiveDays || timeframe == .oneMonth {
                ticks.append(Tick(x: x(index, bar), label: label(bar.timestamp)))
            }
            previous = current
        }
        return ticks
    }

    /// A bar's time for the crosshair, in ET: `13:24 ET`; `Tue 3 Nov, 13:30 ET`; `Tue 3 Nov 2026`;
    /// `Week of 2 Nov 2026`.
    private static func time(of date: Date, _ timeframe: ChartTimeframe) -> String {
        switch timeframe.barLength {
        case .minutes: timeframe == .oneDay ? "\(format(date, "HH:mm")) ET" : "\(format(date, "EEE d MMM, HH:mm")) ET"
        case .day: format(date, "EEE d MMM yyyy")
        case .week: "Week of \(format(date, "d MMM yyyy"))"
        }
    }

    private static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = exchange
        calendar.firstWeekday = 2
        return calendar
    }()

    private static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = exchange
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}
