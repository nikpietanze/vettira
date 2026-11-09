import Foundation

/// How the menu bar, the popover, the dashboard and notifications write numbers and times, so
/// they read the same everywhere.
public enum DisplayFormat {
    /// A price: two decimals, or four below 1 (`512.30`, `0.4215`).
    public static func price(_ price: Double) -> String {
        String(format: price < 1 ? "%.4f" : "%.2f", price)
    }

    /// How far below the high the price is, as a change: `−0.31%`, or `0.00%` at the high.
    public static func changeFromHigh(_ pullbackPercent: Double) -> String {
        let percent = String(format: "%.2f", max(0, pullbackPercent))
        return percent == "0.00" ? "0.00%" : "\u{2212}\(percent)%"
    }

    /// A percent with two decimals: `0.31%`.
    public static func percent(_ percent: Double) -> String {
        String(format: "%.2f%%", percent)
    }

    /// A pair of thresholds, early then stronger: `0.25% / 0.40%`.
    public static func thresholds(_ thresholds: PullbackThresholds) -> String {
        "\(percent(thresholds.early)) / \(percent(thresholds.strong))"
    }

    /// A data age or a wait: `5 s`, `4 min`, `3 h`, `2 d`, rounded down. A negative one (a quote
    /// time a little ahead of the Mac's clock) is `0 s`.
    public static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.isFinite ? seconds : 0))
        if whole < 60 { return "\(whole) s" }
        if whole < 3600 { return "\(whole / 60) min" }
        if whole < 86_400 { return "\(whole / 3600) h" }
        return "\(whole / 86_400) d"
    }

    /// A quote's time of day with its time zone: `10:31:05 EST`.
    public static func time(_ date: Date, in timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss zzz"
        return formatter.string(from: date)
    }
}

extension SymbolSnapshot {
    /// Whether the data is too old to alert on at `now`: stale when the snapshot was taken, or its
    /// quote has aged past the tolerance since (the monitor publishes only after a poll, and waits
    /// long between polls while it backs off).
    func isStale(at now: Date, tolerance: TimeInterval) -> Bool {
        guard let quote else { return true }
        return isStale || quote.age(at: now) > tolerance
    }

    /// The last alert, when it's from `now`'s trading-day session.
    func alertThisSession(at now: Date, calendar: MarketCalendar) -> ReversalAlert? {
        guard let lastAlert, let today = calendar.status(at: now)?.session.day,
              calendar.status(at: lastAlert.quoteTimestamp)?.session.day == today
        else { return nil }
        return lastAlert
    }
}
