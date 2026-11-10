import Foundation

/// A span of a symbol's price history the chart shows, and the bars it's drawn from: 1D at a
/// minute, 5D at 5 minutes, 1M at 30 minutes, 6M, YTD and 1Y at a day, and 5Y at a week. Each
/// provider turns it into its own request.
public enum ChartTimeframe: String, CaseIterable, Sendable, Hashable, Identifiable {
    case oneDay = "1D"
    case fiveDays = "5D"
    case oneMonth = "1M"
    case sixMonths = "6M"
    case yearToDate = "YTD"
    case oneYear = "1Y"
    case fiveYears = "5Y"

    public var id: String { rawValue }

    /// How long each bar lasts.
    public enum BarLength: Sendable, Equatable {
        case minutes(Int)
        case day
        case week
    }

    public var barLength: BarLength {
        switch self {
        case .oneDay: .minutes(1)
        case .fiveDays: .minutes(5)
        case .oneMonth: .minutes(30)
        case .sixMonths, .yearToDate, .oneYear: .day
        case .fiveYears: .week
        }
    }

    /// Whether its bars are parts of a session (minutes or hours), rather than whole days or weeks.
    public var isIntraday: Bool {
        if case .minutes = barLength { return true }
        return false
    }

    /// How long a fetched history stays fresh enough to show again without asking: about a bar,
    /// so a new request brings at most a bar or two more. 1D's is just under a minute, so its
    /// once-a-minute refresh (`refreshes(at:calendar:)`) asks again each time.
    public var cacheLifetime: TimeInterval {
        switch self {
        case .oneDay: 55
        case .fiveDays: 5 * 60
        case .oneMonth: 30 * 60
        case .sixMonths, .yearToDate, .oneYear: 4 * 3600
        case .fiveYears: 12 * 3600
        }
    }

    /// How often an open 1D chart wakes to ask for its history again, when `refreshes(at:)`.
    public static let refreshInterval: TimeInterval = 60

    /// Whether an open chart of this timeframe asks for its history again at `now`: 1D in regular
    /// hours, so each new minute's bar joins the line. Between refreshes the chart ends at the
    /// latest quote's price.
    public func refreshes(at now: Date, calendar: MarketCalendar = .usEquities) -> Bool {
        self == .oneDay && calendar.status(at: now)?.state == .regular
    }

    /// The period in words, for the chart's heading: `Past 5 days`.
    public var period: String {
        switch self {
        case .oneDay: "Today"
        case .fiveDays: "Past 5 days"
        case .oneMonth: "Past month"
        case .sixMonths: "Past 6 months"
        case .yearToDate: "Year to date"
        case .oneYear: "Past year"
        case .fiveYears: "Past 5 years"
        }
    }
}

/// A symbol's prices over one timeframe, as the provider returned them.
public struct PriceHistory: Sendable, Equatable {
    /// The ticker, as the provider returned it.
    public var symbol: String
    public var timeframe: ChartTimeframe
    /// The bars, oldest first, regular session only. A bar with no close is a gap.
    public var bars: [PriceBar]
    /// The close before the first bar, when the provider supplies it: what the period's change is
    /// measured from. For 1D, the previous session's close.
    public var previousClose: Double?
    /// The security's name, when the provider supplies it.
    public var name: String?

    public init(
        symbol: String, timeframe: ChartTimeframe, bars: [PriceBar], previousClose: Double? = nil, name: String? = nil
    ) {
        self.symbol = symbol
        self.timeframe = timeframe
        self.bars = bars
        self.previousClose = previousClose
        self.name = name
    }
}
