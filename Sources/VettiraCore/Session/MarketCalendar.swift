import Foundation

/// A date in New York: the day a US equity session trades on.
public struct TradingDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    public let year: Int
    public let month: Int
    public let day: Int

    public init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    public static func < (lhs: TradingDay, rhs: TradingDay) -> Bool {
        (lhs.year, lhs.month, lhs.day) < (rhs.year, rhs.month, rhs.day)
    }

    /// `2026-11-27`.
    public var description: String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }
}

/// Where an instant falls in a US equity trading day.
public enum SessionState: String, Sendable, Codable {
    /// 04:00 to the 09:30 open, New York time.
    case preMarket
    /// The regular session: 09:30 to the close, 16:00, or 13:00 on an early-close day.
    case regular
    /// The close to 20:00, or to 17:00 on an early-close day.
    case afterHours
    /// Overnight, weekends and full holidays.
    case closed
}

/// One trading day's session. Every instant is an absolute `Date`.
public struct MarketSession: Hashable, Sendable {
    public let day: TradingDay
    /// 04:00 New York time, when pre-market trading starts.
    public let preMarketOpen: Date
    /// 09:30 New York time, the regular session's open.
    public let open: Date
    /// The regular session's close: 16:00 New York time, or 13:00 on an early-close day.
    public let close: Date
    /// When after-hours trading ends: 20:00 New York time, or 17:00 on an early-close day.
    public let afterHoursClose: Date
    /// Whether the exchange closes early, at 13:00, this day.
    public let isEarlyClose: Bool

    func state(at instant: Date) -> SessionState {
        if instant < preMarketOpen { return .closed }
        if instant < open { return .preMarket }
        if instant < close { return .regular }
        if instant < afterHoursClose { return .afterHours }
        return .closed
    }
}

/// What the market is doing at an instant, and the session that instant belongs to.
public struct SessionStatus: Hashable, Sendable {
    public let state: SessionState
    /// The trading day's session this instant belongs to: the latest one whose pre-market had
    /// started by then. A weekend or holiday belongs to the trading day before it; from 04:00 on a
    /// trading day, the instant belongs to that day.
    public let session: MarketSession
}

/// The US equity market's calendar: regular hours 09:30 to 16:00 New York time, with the full
/// holidays and 13:00 early closes NYSE publishes, year by year. It needs no network; a year
/// it doesn't hold, it doesn't guess. docs/alerts.md says how to add a year.
public struct MarketCalendar: Sendable {
    /// One year's published full holidays and early closes, as (month, day).
    struct Year: Sendable {
        let holidays: [(month: Int, day: Int)]
        let earlyCloses: [(month: Int, day: Int)]
    }

    private let holidays: Set<TradingDay>
    private let earlyCloses: Set<TradingDay>

    /// The years whose holidays and early closes the calendar holds, in order.
    public let coveredYears: [Int]

    init(years: [Int: Year]) {
        func days(_ year: Int, _ dates: [(month: Int, day: Int)]) -> [TradingDay] {
            dates.map { TradingDay(year: year, month: $0.month, day: $0.day) }
        }
        holidays = Set(years.flatMap { days($0.key, $0.value.holidays) })
        earlyCloses = Set(years.flatMap { days($0.key, $0.value.earlyCloses) })
        coveredYears = years.keys.sorted()
        for day in holidays.union(earlyCloses) {
            precondition(Self.isWeekday(day), "\(day) in the market calendar isn't a weekday")
        }
        precondition(holidays.isDisjoint(with: earlyCloses), "a day in the market calendar is both a holiday and an early close")
    }

    /// The session state at `instant`, and the trading day's session it belongs to; `nil` when the
    /// calendar doesn't cover the days needed to say.
    public func status(at instant: Date) -> SessionStatus? {
        var day = Self.day(of: instant)
        while true {
            guard let trades = isTradingDay(day) else { return nil }
            if trades {
                let session = session(on: day)
                if instant >= session.preMarketOpen {
                    return SessionStatus(state: session.state(at: instant), session: session)
                }
            }
            day = Self.day(before: day)
        }
    }

    /// Whether the market trades on `day`; `nil` for a weekday in a year the calendar doesn't hold.
    private func isTradingDay(_ day: TradingDay) -> Bool? {
        guard Self.isWeekday(day) else { return false }
        guard coveredYears.contains(day.year) else { return nil }
        return !holidays.contains(day)
    }

    private func session(on day: TradingDay) -> MarketSession {
        let early = earlyCloses.contains(day)
        return MarketSession(
            day: day,
            preMarketOpen: Self.instant(day, hour: 4, minute: 0),
            open: Self.instant(day, hour: 9, minute: 30),
            close: Self.instant(day, hour: early ? 13 : 16, minute: 0),
            afterHoursClose: Self.instant(day, hour: early ? 17 : 20, minute: 0),
            isEarlyClose: early
        )
    }

    private static let newYork: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }()

    private static func instant(_ day: TradingDay, hour: Int, minute: Int) -> Date {
        let components = DateComponents(year: day.year, month: day.month, day: day.day, hour: hour, minute: minute)
        return newYork.date(from: components)!
    }

    /// The New York date of `instant`, as a day, whether or not the market trades on it.
    static func day(of instant: Date) -> TradingDay {
        let components = newYork.dateComponents([.year, .month, .day], from: instant)
        return TradingDay(year: components.year!, month: components.month!, day: components.day!)
    }

    private static func day(before day: TradingDay) -> TradingDay {
        Self.day(of: newYork.date(byAdding: .day, value: -1, to: instant(day, hour: 12, minute: 0))!)
    }

    private static func isWeekday(_ day: TradingDay) -> Bool {
        !newYork.isDateInWeekend(instant(day, hour: 12, minute: 0))
    }
}

extension MarketCalendar {
    /// NYSE's full holidays and 13:00 early closes, from https://www.nyse.com/markets/hours-calendars
    /// (read 2026-11-09). Add each year as NYSE publishes it (docs/alerts.md).
    public static let usEquities = MarketCalendar(years: [
        2026: Year(
            holidays: [
                (1, 1),    // New Year's Day
                (1, 19),   // Martin Luther King, Jr. Day
                (2, 16),   // Washington's Birthday
                (4, 3),    // Good Friday
                (5, 25),   // Memorial Day
                (6, 19),   // Juneteenth National Independence Day
                (7, 3),    // Independence Day, observed
                (9, 7),    // Labor Day
                (11, 26),  // Thanksgiving Day
                (12, 25),  // Christmas Day
            ],
            earlyCloses: [
                (11, 27),  // the day after Thanksgiving
                (12, 24),  // Christmas Eve
            ]
        ),
        2027: Year(
            holidays: [
                (1, 1),    // New Year's Day
                (1, 18),   // Martin Luther King, Jr. Day
                (2, 15),   // Washington's Birthday
                (3, 26),   // Good Friday
                (5, 31),   // Memorial Day
                (6, 18),   // Juneteenth National Independence Day, observed
                (7, 5),    // Independence Day, observed
                (9, 6),    // Labor Day
                (11, 25),  // Thanksgiving Day
                (12, 24),  // Christmas Day, observed
            ],
            earlyCloses: [
                (11, 26),  // the day after Thanksgiving
            ]
        ),
        2028: Year(
            holidays: [
                // No New Year's Day holiday: January 1, 2028 is a Saturday, and NYSE observes none.
                (1, 17),   // Martin Luther King, Jr. Day
                (2, 21),   // Washington's Birthday
                (4, 14),   // Good Friday
                (5, 29),   // Memorial Day
                (6, 19),   // Juneteenth National Independence Day
                (7, 4),    // Independence Day
                (9, 4),    // Labor Day
                (11, 23),  // Thanksgiving Day
                (12, 25),  // Christmas Day
            ],
            earlyCloses: [
                (7, 3),    // the day before Independence Day
                (11, 24),  // the day after Thanksgiving
            ]
        ),
    ])
}
