import Foundation

/// Which pullback threshold an alert is for.
public enum PullbackSignal: String, Equatable, Comparable, Sendable, Codable, CaseIterable {
    /// The smaller pullback (by default 0.25% below the high).
    case early
    /// The larger pullback (by default 0.40% below the high).
    case strong

    /// "Early warning" or "Stronger warning".
    public var label: String {
        switch self {
        case .early: "Early warning"
        case .strong: "Stronger warning"
        }
    }

    public static func < (lhs: PullbackSignal, rhs: PullbackSignal) -> Bool {
        lhs == .early && rhs == .strong
    }
}

extension PullbackThresholds {
    /// The percent below the high for `signal`.
    func percent(for signal: PullbackSignal) -> Double {
        switch signal {
        case .early: early
        case .strong: strong
        }
    }
}

/// A notification that a price pulled back from its high by a threshold: a possible reversal,
/// not a confirmed one, and never an instruction to sell.
public struct ReversalAlert: Equatable, Sendable, Codable {
    public let symbol: String
    /// The quote's price.
    public let price: Double
    /// The high the pullback is measured from, and whether it's the session or the observed high.
    public let high: SessionHigh
    /// How far the price is below the high, in percent.
    public let pullbackPercent: Double
    public let signal: PullbackSignal
    /// The threshold that fired, in percent below the high, as it was set when the alert fired.
    public let thresholdPercent: Double
    /// The quote's own time, as the provider gave it.
    public let quoteTimestamp: Date
    /// How old the quote was when the engine evaluated it: the data age.
    public let dataAge: TimeInterval
    /// The provider the quote came from.
    public let source: String

    /// One line saying what happened, labelled as a possible reversal, with the threshold and the
    /// data age: "Early warning (0.25% threshold): possible reversal, not confirmed. SPY is 0.31%
    /// below its observed high. Quote 5 s old."
    public var summary: String {
        let threshold = String(format: "%.2f", thresholdPercent)
        let percent = String(format: "%.2f", pullbackPercent)
        let age = max(0, Int(dataAge.rounded()))
        return "\(signal.label) (\(threshold)% threshold): possible reversal, not confirmed. "
            + "\(symbol) is \(percent)% below its \(high.kind.label). Quote \(age) s old."
    }
}

/// Why a quote was kept from updating the high or firing an alert.
public enum QuoteRejection: Equatable, Sendable {
    /// The price isn't a positive number.
    case invalidPrice
    /// The market calendar doesn't cover the quote's date, so its session can't be placed.
    case notInCalendar
    /// The quote is from outside the regular session: pre-market, after-hours, closed, or the
    /// provider says it isn't a regular-session quote.
    case outsideRegularHours
    /// The provider says its data is delayed by more than the tolerance.
    case delayed(TimeInterval)
    /// The quote is older than the tolerance.
    case stale(age: TimeInterval)
    /// The quote's time is ahead of the clock by more than the tolerance.
    case aheadOfClock(TimeInterval)
    /// The quote has the same time as the last accepted one.
    case duplicate
    /// The quote is older than the last accepted one.
    case outOfOrder
    /// The price moved further than the spike limit from the last accepted price, and no later
    /// quote has confirmed the move yet.
    case implausibleJump(fromPrice: Double)
}

/// What the engine made of a quote.
public enum QuoteEvaluation: Equatable, Sendable {
    /// The quote was ignored, for this reason. It changed no high and fired no alert.
    case rejected(QuoteRejection)
    /// The quote was used: the high it's measured against, how far below it the price is, in
    /// percent, and the alert it fired, if any.
    case accepted(high: SessionHigh, pullbackPercent: Double, alert: ReversalAlert?)
}
