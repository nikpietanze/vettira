import Foundation

/// A notification center that writes each notification's full text to a log instead of posting
/// it, for checking a run without anything reaching the screen. It never asks for permission: it
/// has nothing to ask.
public struct LogNotificationCenter: AlertNotificationCenter {
    private let write: @Sendable (String) -> Void

    /// `write` gets one line per notification.
    public init(write: @escaping @Sendable (String) -> Void) {
        self.write = write
    }

    public func authorization() async -> NotificationAuthorization { .allowed }

    public func requestAuthorization() async -> NotificationAuthorization { .allowed }

    public func add(_ notification: AlertNotification, sound: Bool) async throws {
        write("Would notify: \(notification.title) | \(notification.subtitle) | \(notification.body) "
            + "(sound \(sound ? "on" : "off"))")
    }
}
