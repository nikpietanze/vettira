import Foundation

/// The dashboard's diagnostics: where quotes come from, how often Vettira updates, whether prices
/// stream, when data last came, when the next update is, and the last error, each as a label and a
/// value.
public struct DiagnosticsSummary: Equatable, Sendable {
    public struct Item: Equatable, Sendable, Identifiable {
        public let label: String
        public let value: String
        public var id: String { label }
    }

    public let items: [Item]

    public init(diagnostics: MonitorDiagnostics, settings: UserSettings, now: Date, timeZone: TimeZone = .current) {
        let monitor = settings.monitorSettings
        func time(_ date: Date) -> String { DisplayFormat.time(date, in: timeZone) }
        let next: String
        if let due = diagnostics.nextPoll {
            next = due <= now ? "Now" : "In \(DisplayFormat.duration(due.timeIntervalSince(now))), at \(time(due))"
        } else {
            next = "Starting"
        }
        let streaming = diagnostics.stream.map { status in
            Item(label: "Streaming", value: Self.describe(status, monitor: monitor, now: now, time: time))
        }
        let regular = diagnostics.stream == nil ? "" : " (every \(DisplayFormat.duration(monitor.streamingInterval)) while prices stream)"
        items = [
            Item(label: "Source", value: diagnostics.source),
            Item(label: "Update interval", value: "Every \(DisplayFormat.duration(monitor.interval)) in regular hours\(regular), "
                + "every \(DisplayFormat.duration(monitor.closedInterval)) outside them"),
        ] + [streaming].compactMap { $0 } + [
            Item(label: "Stale after", value: DisplayFormat.duration(settings.alertSettings.staleTolerance)),
            Item(label: "Last received", value: diagnostics.lastReceived.map {
                "\(time($0)), \(DisplayFormat.duration(now.timeIntervalSince($0))) ago"
            } ?? "Nothing yet"),
            Item(label: "Last update", value: diagnostics.lastPoll.map(time) ?? "None yet"),
            Item(label: "Next update", value: next),
            Item(label: "Last error", value: diagnostics.lastError?.message ?? "None"),
            Item(label: "Failed updates in a row", value: "\(diagnostics.consecutiveFailures)"),
        ]
    }

    private static func describe(
        _ status: StreamStatus, monitor: MonitorSettings, now: Date, time: (Date) -> String
    ) -> String {
        switch status {
        case .off:
            "Off: prices stream only in regular hours, for the symbols that are on"
        case .connecting:
            "Connecting"
        case .live(let since):
            "Live since \(time(since)): prices as they change, at most once a second"
        case .reconnecting(let error, let retryAt):
            "Reconnecting \(retryAt <= now ? "now" : "in \(DisplayFormat.duration(retryAt.timeIntervalSince(now)))"), "
                + "updating every \(DisplayFormat.duration(monitor.interval)) meanwhile. \(error.message)"
        }
    }
}
