import Foundation

/// Whether the user lets Vettira post notifications.
public enum NotificationAuthorization: Equatable, Sendable {
    /// Not asked yet.
    case notDetermined
    case allowed
    /// Turned off, in the prompt or in System Settings. Only the user can turn them back on.
    case denied
}

/// The system's notification center, as alert delivery uses it. The app's wraps
/// `UNUserNotificationCenter`; tests use a fake.
public protocol AlertNotificationCenter: Sendable {
    func authorization() async -> NotificationAuthorization
    /// Asks the user, once; the system answers without asking again after that.
    func requestAuthorization() async -> NotificationAuthorization
    func add(_ notification: AlertNotification, sound: Bool) async throws
}

/// Posts each alert as a notification, asking for permission the first time it's needed.
public struct AlertDelivery: Sendable {
    public enum Outcome: Equatable, Sendable {
        case delivered
        /// Notifications are turned off, so it wasn't posted.
        case denied
        /// The system refused it, with its reason.
        case failed(String)
    }

    private let center: any AlertNotificationCenter
    private let timeZone: TimeZone

    public init(center: any AlertNotificationCenter, timeZone: TimeZone = .current) {
        self.center = center
        self.timeZone = timeZone
    }

    /// Whether notifications are allowed, asking the user when they haven't been asked yet. The
    /// app calls it when it starts monitoring a symbol, the first moment an alert can come.
    public func authorize() async -> NotificationAuthorization {
        let current = await center.authorization()
        return current == .notDetermined ? await center.requestAuthorization() : current
    }

    /// Posts the alert's notification, with a sound if `sound`, asking for permission first if
    /// nobody has asked yet.
    public func deliver(_ alert: ReversalAlert, sound: Bool) async -> Outcome {
        guard await authorize() == .allowed else { return .denied }
        do {
            try await center.add(AlertNotification(alert, timeZone: timeZone), sound: sound)
            return .delivered
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
