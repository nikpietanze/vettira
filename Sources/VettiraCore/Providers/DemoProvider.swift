import Foundation

/// Made-up prices, for trying the app and checking it works without calling a real provider. The
/// app uses it only in Debug builds, when launched with `--demo`. Its name says the prices are
/// made up, and it's shown as every quote's source.
///
/// Each symbol starts at its own base price and, one step per poll, follows `path`: up to a high
/// 0.30% above the base, back down past the default early warning (0.25% below the high) and then
/// past the stronger one (0.40%), then it holds at the last step. Each quote is timestamped at the
/// clock's now, in the regular session, with no session high, so its high is the observed one.
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
        let time = now()
        return QuoteBatch(quotes: symbols.map { symbol in
            let step = steps[symbol, default: 0]
            steps[symbol] = step + 1
            let percent = Self.path[min(step, Self.path.count - 1)]
            return Quote(
                symbol: symbol, price: Self.basePrice(symbol) * (1 + percent / 100), timestamp: time, source: name,
                session: .regular)
        })
    }

    public func testConnection() async throws(ProviderError) {}

    /// A symbol's starting price, from 100 to 499, the same on every run.
    public static func basePrice(_ symbol: String) -> Double {
        Double(100 + symbol.unicodeScalars.reduce(0) { $0 + Int($1.value) } % 400)
    }

    /// How far to move a clock at `now` so it reads regular hours: none when `now` is already in
    /// the regular session (or the calendar doesn't cover it), otherwise to 30 minutes after the
    /// open of the session `now` belongs to. Demo prices then alert at any time of day.
    public static func regularHoursOffset(at now: Date, calendar: MarketCalendar = .usEquities) -> TimeInterval {
        guard let status = calendar.status(at: now), status.state != .regular else { return 0 }
        return status.session.open.addingTimeInterval(30 * 60).timeIntervalSince(now)
    }
}
