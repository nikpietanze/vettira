import Foundation

/// A small line chart of a symbol's day, for the menu bar and the popover: the day's bars and the
/// latest price, the previous close as a faint line, and whether the price is up or down on the
/// day. It's the price as of the latest quote, polled or streamed.
///
/// The maths is here, so it's tested without a UI; the app only strokes the lines it gives and
/// picks the colour its direction names: green for up on the day, red for down, never buy or sell.
public struct PriceChart: Equatable, Sendable {
    /// The latest price against the previous close, to two decimals of a percent.
    public enum Direction: Equatable, Sendable {
        case up, down
        /// Within 0.005% of the previous close, so it reads as 0.00%.
        case flat
        /// The provider didn't supply a previous close.
        case unknown
    }

    /// A point on the chart, `x` and `y` each from 0 to 1, `y` up.
    public struct Point: Equatable, Sendable {
        public var x: Double
        public var y: Double

        public init(x: Double, y: Double) {
            self.x = x
            self.y = y
        }
    }

    /// The line's unbroken runs, oldest first: `x` from the first price (0) to the last (1) by
    /// time, `y` from the lowest price (0) to the highest (1), the previous close counted among
    /// them so its line is always on the chart. A bar with no price breaks the line.
    public let segments: [[Point]]
    /// Where the previous close's line goes, from 0 to 1; `nil` without a previous close.
    public let previousCloseLevel: Double?
    public let direction: Direction
    /// The chart in words, for VoiceOver and the tooltip: `Chart of today's price for SPY, updated
    /// with each quote: up 0.42% from the previous close of 510.10.`
    public let description: String

    /// The chart of `quote`'s bars, ending at its price when that's newer than the last bar, at
    /// `now`. `nil` when there are fewer than two prices to draw a line through.
    public init?(quote: Quote, now: Date, calendar: MarketCalendar = .usEquities) {
        var prices: [(time: Date, price: Double?)] = quote.intraday.map { ($0.timestamp, $0.close) }
        guard let lastBar = quote.intraday.last else { return nil }
        let day = calendar.status(at: lastBar.timestamp)?.session.day
        if quote.timestamp > lastBar.timestamp, calendar.status(at: quote.timestamp)?.session.day == day {
            prices.append((time: quote.timestamp, price: quote.price))
        }
        // From the first price to the last: a gap at either end isn't part of the line.
        guard let first = prices.firstIndex(where: { $0.price != nil }),
              let last = prices.lastIndex(where: { $0.price != nil }), first < last
        else { return nil }
        prices = Array(prices[first...last])

        let start = prices[0].time
        let span = prices[prices.count - 1].time.timeIntervalSince(start)
        let levels = prices.compactMap { $0.price } + [quote.previousClose].compactMap { $0 }
        let low = levels.min()!
        let range = levels.max()! - low
        func level(_ price: Double) -> Double { range > 0 ? (price - low) / range : 0.5 }

        var segments: [[Point]] = []
        var run: [Point] = []
        for (time, price) in prices {
            guard let price else {
                segments.append(run)
                run = []
                continue
            }
            run.append(Point(x: span > 0 ? time.timeIntervalSince(start) / span : 0, y: level(price)))
        }
        segments.append(run)
        self.segments = segments.filter { !$0.isEmpty }
        previousCloseLevel = quote.previousClose.map(level)

        // Today's when the bars are from the session of the date it is in New York.
        let what = day != nil && day == MarketCalendar.day(of: now)
            ? "today's price for \(quote.symbol), updated with each quote" : "the last session's price for \(quote.symbol)"
        guard let previousClose = quote.previousClose else {
            direction = .unknown
            description = "Chart of \(what)."
            return
        }
        let change = (quote.price - previousClose) / previousClose * 100
        let close = DisplayFormat.price(previousClose)
        if (change * 100).rounded() == 0 {
            direction = .flat
            description = "Chart of \(what): unchanged from the previous close of \(close)."
        } else {
            direction = change > 0 ? .up : .down
            description = "Chart of \(what): \(change > 0 ? "up" : "down") \(DisplayFormat.percent(abs(change))) "
                + "from the previous close of \(close)."
        }
    }

    /// `segments` in a box `width` by `height` points, `inset` in from each edge, `y` up.
    public func lines(width: Double, height: Double, inset: Double) -> [[Point]] {
        segments.map { $0.map { Point(x: inset + $0.x * (width - 2 * inset), y: inset + $0.y * (height - 2 * inset)) } }
    }

    /// `previousCloseLevel` in a box `height` points high, `inset` in from each edge, `y` up.
    public func previousCloseY(height: Double, inset: Double) -> Double? {
        previousCloseLevel.map { inset + $0 * (height - 2 * inset) }
    }
}
