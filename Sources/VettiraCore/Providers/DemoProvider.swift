import Foundation

/// Made-up prices, for trying the app and checking it works without calling a real provider. The
/// app uses it only in Debug builds, when launched with `--demo`. Its name says the prices are
/// made up, and it's shown as every quote's source.
///
/// Each symbol starts at its own base price and, one step per poll, follows `path`: up to a high
/// 0.30% above the base, back down past the default early warning (0.25% below the high) and then
/// past the stronger one (0.40%), then it holds at the last step. Every other symbol follows it a
/// step quicker (`path(for:)`), so when the others fall to their stronger warning it's rising
/// again, and the menu bar shows prices both rising and falling. Each quote is timestamped at the
/// clock's now, in the regular session, with no session high, so its high is the observed one.
///
/// Each quote also has a made-up day for the chart: a previous close 0.60% below or above the
/// base price (the symbol decides which, so a watchlist shows days both up and down), and a
/// 5-minute bar from the open up to now, wandering from below the base price to the quote's
/// price. No bar's high is above the prices the quotes reach, so the high stays the quotes' and
/// the warnings come when the path says.
///
/// Its history, for the chart's longer timeframes, is made up too: a random walk the same on every
/// run for each symbol and timeframe, on the market's trading days in regular hours, that ends at
/// the quote's price, with opens, highs, lows and volumes.
public actor DemoProvider: MarketDataProvider {
    public nonisolated let name = "Demo (made-up prices)"

    /// Percent above each symbol's base price, one step per poll.
    public static let path: [Double] = [0, 0.10, 0.20, 0.30, 0.15, 0.00, -0.15, -0.10]

    /// The symbol's path, the same on every run: `path`, or for every other symbol `path` without
    /// its 0.15 step, so it warns a poll earlier and its seventh step is up, not down.
    public static func path(for symbol: String) -> [Double] {
        seed(symbol) % 2 == 0 ? path : path.filter { $0 != 0.15 }
    }

    private let now: @Sendable () -> Date
    private var steps: [String: Int] = [:]

    /// `now` is the monitor's clock, so quotes are as fresh as the monitor expects.
    public init(now: @escaping @Sendable () -> Date) {
        self.now = now
    }

    public func quotes(for symbols: [String]) async throws(ProviderError) -> QuoteBatch {
        QuoteBatch(quotes: symbols.map { symbol in
            defer { steps[symbol, default: 0] += 1 }
            return quote(for: symbol)
        })
    }

    /// The symbol's quote at its current step, without moving it on, so testing the connection
    /// doesn't change when the demo's warnings come.
    public func testConnection(symbol: String) async throws(ProviderError) -> Quote {
        quote(for: symbol.uppercased())
    }

    /// The symbol's made-up bars over `timeframe`, ending at its quote's price at its current step.
    /// 1D is the quote's own day.
    public func history(for symbol: String, timeframe: ChartTimeframe) async throws(ProviderError) -> PriceHistory {
        let symbol = symbol.uppercased()
        let quote = quote(for: symbol)
        guard timeframe != .oneDay else {
            return PriceHistory(symbol: symbol, timeframe: timeframe, bars: quote.intraday, previousClose: quote.previousClose)
        }
        return Self.history(symbol, timeframe, endingAt: quote.price, now: quote.timestamp)
    }

    private func quote(for symbol: String) -> Quote {
        let step = steps[symbol, default: 0]
        let path = Self.path(for: symbol)
        let percent = path[min(step, path.count - 1)]
        let time = now()
        return Quote(
            symbol: symbol, price: Self.basePrice(symbol) * (1 + percent / 100), timestamp: time, source: name,
            session: .regular, previousClose: Self.previousClose(symbol),
            intraday: Self.bars(symbol, until: time, endingAt: percent))
    }

    /// A symbol's previous close: 0.60% below its base price or above it, the same on every run.
    public static func previousClose(_ symbol: String) -> Double {
        basePrice(symbol) * (1 + (seed(symbol) % 2 == 0 ? -0.6 : 0.6) / 100)
    }

    /// A 5-minute bar from the open of `now`'s session to `now`: a wave that starts 0.30% below the
    /// base price and settles, by `now`, on the price `percent` above the base, the quote's. A
    /// bar's high is the higher of its close and the one before, so no bar's high is above the
    /// base price or the quote's price, whichever is higher. None outside the regular session or
    /// the calendar.
    static func bars(
        _ symbol: String, until now: Date, endingAt percent: Double, calendar: MarketCalendar = .usEquities
    ) -> [PriceBar] {
        guard let status = calendar.status(at: now), status.state == .regular else { return [] }
        let base = basePrice(symbol)
        let span = now.timeIntervalSince(status.session.open)
        let phase = Double(seed(symbol) % 7)
        var previous: Double?
        return stride(from: 0, to: span, by: 300).map { elapsed in
            let left = 1 - elapsed / span
            // The wave runs from 0.55% to 0.05% below the base.
            let close = base * (1 + ((-0.30 + 0.25 * sin(elapsed / 1500 + phase)) * left + percent * (1 - left)) / 100)
            defer { previous = close }
            let open = previous ?? close
            // More shares change hands near the open and the close than at midday.
            let shape = 1 + 1.5 * pow(2 * elapsed / span - 1, 2)
            return PriceBar(
                timestamp: status.session.open + elapsed, close: close, high: max(close, open), open: open,
                low: min(close, open), volume: Int(Double(volumeBase(symbol)) / 78 * shape))
        }
    }

    // MARK: History

    /// `symbol`'s made-up bars over `timeframe` (not 1D) up to `now`, the last closing at `price`.
    static func history(
        _ symbol: String, _ timeframe: ChartTimeframe, endingAt price: Double, now: Date,
        calendar: MarketCalendar = .usEquities
    ) -> PriceHistory {
        let times = barTimes(timeframe, until: now, calendar: calendar)
        var random = SeededRandom(seed: UInt64(seed(symbol)) &* 31 &+ UInt64(timeframe.hashSeed))
        // A trend each symbol keeps: from 10% down to 30% up a year.
        let yearly = -0.10 + 0.40 * Double(seed(symbol) % 97) / 96
        let (barsPerYear, volatility): (Double, Double) = switch timeframe.barLength {
        case .minutes(let minutes): (252 * 390 / Double(minutes), minutes <= 15 ? 0.0015 : 0.004)
        case .day: (252, 0.011)
        case .week: (52, 0.024)
        }
        // Log prices from the close before the first bar, then scaled so the last is `price`.
        var level = 0.0
        var closes = [level]
        for _ in times {
            level += yearly / barsPerYear + volatility * random.normal()
            closes.append(level)
        }
        let shift = log(price) - level
        let prices = closes.map { exp($0 + shift) }
        let dailyVolume = Double(volumeBase(symbol))
        let barVolume = switch timeframe.barLength {
        case .minutes(let minutes): dailyVolume * Double(minutes) / 390
        case .day: dailyVolume
        case .week: dailyVolume * 5
        }
        let bars = times.enumerated().map { index, time in
            let open = prices[index] * (1 + volatility * 0.2 * random.normal())
            let close = prices[index + 1]
            return PriceBar(
                timestamp: time, close: close,
                high: max(open, close) * (1 + volatility * 0.5 * abs(random.normal())), open: open,
                low: min(open, close) * (1 - volatility * 0.5 * abs(random.normal())),
                volume: Int(barVolume * (0.6 + 0.8 * random.unit())))
        }
        return PriceHistory(symbol: symbol, timeframe: timeframe, bars: bars, previousClose: prices[0])
    }

    /// When each of the timeframe's bars starts, up to `now`: in the regular session of each
    /// trading day for minutes and hours, at each trading day's open for days, and at midnight in
    /// New York on each week's Monday for weeks.
    static func barTimes(_ timeframe: ChartTimeframe, until now: Date, calendar: MarketCalendar) -> [Date] {
        let newYork = Self.newYork
        func back(_ component: Calendar.Component, _ value: Int) -> Date {
            newYork.date(byAdding: component, value: -value, to: now)!
        }
        switch timeframe {
        case .oneDay, .fiveDays, .oneMonth:
            guard case .minutes(let minutes) = timeframe.barLength else { return [] }
            let sessions = timeframe == .oneMonth
                ? sessions(from: back(.month, 1), until: now, calendar: calendar)
                : Array(sessions(from: back(.day, 10), until: now, calendar: calendar).suffix(timeframe == .oneDay ? 1 : 5))
            return sessions.flatMap { session in
                stride(from: session.open, to: min(session.close, now + 1), by: TimeInterval(minutes * 60)).map { $0 }
            }
        case .sixMonths, .yearToDate, .oneYear:
            let start = switch timeframe {
            case .sixMonths: back(.month, 6)
            case .yearToDate: newYork.date(from: newYork.dateComponents([.year], from: now))!
            default: back(.year, 1)
            }
            return sessions(from: start, until: now, calendar: calendar).map(\.open)
        case .fiveYears:
            let monday = newYork.date(from: newYork.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now))!
            return stride(from: 260, through: 0, by: -1).map { newYork.date(byAdding: .weekOfYear, value: -$0, to: monday)! }
        }
    }

    /// Each trading day's open and close from `start` to `now`, the last one only once it has
    /// opened. A day the calendar doesn't cover trades when it's a weekday.
    private static func sessions(from start: Date, until now: Date, calendar: MarketCalendar) -> [(open: Date, close: Date)] {
        let newYork = Self.newYork
        var day = newYork.startOfDay(for: start)
        var sessions: [(open: Date, close: Date)] = []
        while day <= now {
            let noon = day + 12 * 3600
            let open = newYork.date(bySettingHour: 9, minute: 30, second: 0, of: day)!
            if let status = calendar.status(at: noon) {
                if status.session.day == MarketCalendar.day(of: noon) {
                    sessions.append((status.session.open, status.session.close))
                }
            } else if !newYork.isDateInWeekend(noon) {
                sessions.append((open, newYork.date(bySettingHour: 16, minute: 0, second: 0, of: day)!))
            }
            day = newYork.date(byAdding: .day, value: 1, to: day)!
        }
        return sessions.filter { $0.open <= now }
    }

    private static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 2
        return calendar
    }()

    /// A symbol's made-up shares traded in a day: 2 to 80 million.
    private static func volumeBase(_ symbol: String) -> Int {
        2_000_000 + seed(symbol) * 7_919 % 78_000_000
    }

    private static func seed(_ symbol: String) -> Int {
        symbol.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    }

    /// A symbol's starting price, from 100 to 499, the same on every run.
    public static func basePrice(_ symbol: String) -> Double {
        Double(100 + seed(symbol) % 400)
    }

    /// How far to move a clock at `now` so it reads regular hours: none when `now` is already in
    /// the regular session (or the calendar doesn't cover it), otherwise to 14:00 in New York in
    /// the session `now` belongs to, or an hour before an early close. Demo prices then alert at
    /// any time of day, and the day's chart has most of a session to show.
    public static func regularHoursOffset(at now: Date, calendar: MarketCalendar = .usEquities) -> TimeInterval {
        guard let status = calendar.status(at: now), status.state != .regular else { return 0 }
        let session = status.session
        return min(session.open.addingTimeInterval(4.5 * 3600), session.close.addingTimeInterval(-3600)).timeIntervalSince(now)
    }
}

extension ChartTimeframe {
    /// A number for each timeframe, so each has its own made-up walk.
    fileprivate var hashSeed: Int { Self.allCases.firstIndex(of: self)! + 1 }
}

/// SplitMix64: the same numbers for the same seed on every run and every Mac.
struct SeededRandom {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// From 0 up to 1.
    mutating func unit() -> Double {
        Double(next() >> 11) / Double(1 << 53)
    }

    /// Roughly normal, mean 0 and standard deviation 1: the sum of twelve uniform numbers, less 6.
    mutating func normal() -> Double {
        (0..<12).reduce(0) { sum, _ in sum + unit() } - 6
    }
}
