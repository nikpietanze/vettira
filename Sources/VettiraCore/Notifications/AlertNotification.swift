import Foundation

/// The notification for a `ReversalAlert`: worded as a possible reversal, never advice or an
/// instruction, with the ticker, the price, the high and its kind, the drop from the high, the
/// warning and its threshold, and the quote's own time and age.
public struct AlertNotification: Equatable, Sendable {
    /// Unique per alert, so each alert is its own notification.
    public let identifier: String
    /// The symbol, so a symbol's notifications group together.
    public let threadIdentifier: String
    /// `SPY: possible reversal, not confirmed`
    public let title: String
    /// `Early warning (0.25% threshold)`
    public let subtitle: String
    /// `512.30 is 0.31% below the observed high of 513.90. Quote at 10:31:05 EST, 5 s old, from
    /// Yahoo Finance (unofficial).`
    public let body: String

    /// The notification for `alert`, with the quote's time in `timeZone`.
    public init(_ alert: ReversalAlert, timeZone: TimeZone = .current) {
        identifier = "\(alert.symbol)-\(alert.signal.rawValue)-\(Int(alert.quoteTimestamp.timeIntervalSince1970))"
        threadIdentifier = alert.symbol
        title = "\(alert.symbol): possible reversal, not confirmed"
        subtitle = "\(alert.signal.label) (\(DisplayFormat.percent(alert.thresholdPercent)) threshold)"
        body = "\(DisplayFormat.price(alert.price)) is \(DisplayFormat.percent(alert.pullbackPercent)) below the "
            + "\(alert.high.kind.label) of \(DisplayFormat.price(alert.high.price)). "
            + "Quote at \(DisplayFormat.time(alert.quoteTimestamp, in: timeZone)), "
            + "\(DisplayFormat.duration(alert.dataAge)) old, from \(alert.source)."
    }
}
