import Foundation

/// How the connection to the quote provider is doing, in a line or two: waiting for the first
/// update, connected, outside regular hours, or failing with what to do about it.
public struct ConnectionHealth: Equatable, Sendable {
    public enum Level: Equatable, Sendable {
        /// No update has finished yet.
        case waiting
        /// The last update worked, in regular hours.
        case connected
        /// The last update worked, outside regular hours, so nothing alerts and checks are slow.
        case closed
        /// The last update failed.
        case failing
    }

    public let level: Level
    /// What's happening: `Connected`, `Market closed`, or the error.
    public let headline: String
    /// When data last came and when the next update is, and for an error what to do.
    public let detail: String?

    public init(diagnostics: MonitorDiagnostics, now: Date) {
        guard diagnostics.lastPoll != nil else {
            level = .waiting
            headline = "Waiting for the first update"
            detail = nil
            return
        }
        let received = diagnostics.lastReceived.map {
            "Last received \(DisplayFormat.duration(now.timeIntervalSince($0))) ago."
        } ?? "Nothing received yet."
        let next = diagnostics.nextPoll.map { due in
            due <= now ? "Updating now." : "Next update in \(DisplayFormat.duration(due.timeIntervalSince(now)))."
        } ?? ""
        if let error = diagnostics.lastError {
            level = .failing
            headline = error.message
            detail = "\(error.nextStep) \(received) \(next)".trimmingCharacters(in: .whitespaces)
            return
        }
        switch diagnostics.marketState {
        case .regular:
            level = .connected
            headline = "Connected"
        case .preMarket:
            level = .closed
            headline = "Pre-market: alerts start at the open"
        case .afterHours, .closed:
            level = .closed
            headline = "Market closed: no alerts until the next session"
        case nil:
            level = .closed
            headline = "No market session in the calendar for today: no alerts"
        }
        detail = "\(received) \(next)".trimmingCharacters(in: .whitespaces)
    }
}
