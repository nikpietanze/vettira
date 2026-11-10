import Foundation

/// Made-up prices, for trying the app and checking it works without calling a real provider. The
/// app uses it only in Debug builds, when launched with `--demo`. Its name says the prices are
/// made up, and it's shown as every quote's source.
///
/// Each symbol starts at its own base price and, one step per poll, follows `path`: up to a high
/// 0.30% above the base, back down past the default early warning (0.25% below the high) and then
/// past the stronger one (0.40%), then it holds at the last step. Each quote is timestamped at the
/// clock's now, in the regular session, with no session high, so its high is the observed one.
///
/// Each quote also has a made-up day for the chart: a previous close 0.60% below or above the
/// base price (the symbol decides which, so a watchlist shows days both up and down), and a
/// 5-minute bar from the open up to now, wandering from near that close to the quote's price.
public actor DemoProvider: MarketDataProvider {
    public nonisolated let name = "Demo (made-up prices)"
    public nonisolated let streams = false

    /// Percent above each symbol's base price, one step per poll.
    public static let path: [Double] = [0, 0.10, 0.20, 0.30, 0.15, 0.00, -0.15, -0.10]

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

    private func quote(for symbol: String) -> Quote {
        let step = steps[symbol, default: 0]
        let percent = Self.path[min(step, Self.path.count - 1)]
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

    /// A 5-minute bar from the open of `now`'s session to `now`: a wave that starts halfway
    /// between the previous close and the base price and settles, by `now`, on the price `percent`
    /// above the base, the quote's. None outside the regular session or the calendar.
    static func bars(
        _ symbol: String, until now: Date, endingAt percent: Double, calendar: MarketCalendar = .usEquities
    ) -> [PriceBar] {
        guard let status = calendar.status(at: now), status.state == .regular else { return [] }
        let base = basePrice(symbol)
        let gap = (previousClose(symbol) - base) / base * 100 / 2
        let span = now.timeIntervalSince(status.session.open)
        let phase = Double(seed(symbol) % 7)
        return stride(from: 0, to: span, by: 300).map { elapsed in
            let left = 1 - elapsed / span
            let close = base * (1 + ((gap + 0.25 * sin(elapsed / 1500 + phase)) * left + percent * (1 - left)) / 100)
            return PriceBar(timestamp: status.session.open + elapsed, close: close, high: close * 1.0002)
        }
    }

    private static func seed(_ symbol: String) -> Int {
        symbol.unicodeScalars.reduce(0) { $0 + Int($1.value) }
    }

    /// A symbol's starting price, from 100 to 499, the same on every run.
    public static func basePrice(_ symbol: String) -> Double {
        Double(100 + seed(symbol) % 400)
    }

    /// How far to move a clock at `now` so it reads regular hours: none when `now` is already in
    /// the regular session (or the calendar doesn't cover it), otherwise to 30 minutes after the
    /// open of the session `now` belongs to. Demo prices then alert at any time of day.
    public static func regularHoursOffset(at now: Date, calendar: MarketCalendar = .usEquities) -> TimeInterval {
        guard let status = calendar.status(at: now), status.state != .regular else { return 0 }
        return status.session.open.addingTimeInterval(30 * 60).timeIntervalSince(now)
    }
}
