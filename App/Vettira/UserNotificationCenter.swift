import UserNotifications
import VettiraCore

/// Alert delivery's notification center: the system's `UNUserNotificationCenter`.
struct UserNotificationCenter: AlertNotificationCenter {
    func authorization() async -> NotificationAuthorization {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .authorized, .provisional: .allowed
        case .notDetermined: .notDetermined
        case .denied: .denied
        @unknown default: .denied
        }
    }

    func requestAuthorization() async -> NotificationAuthorization {
        // A refusal throws nothing; an error means the system couldn't ask, and the status says
        // where that leaves it.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
        return await authorization()
    }

    func add(_ notification: AlertNotification, sound: Bool) async throws {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.subtitle = notification.subtitle
        content.body = notification.body
        content.threadIdentifier = notification.threadIdentifier
        content.sound = sound ? .default : nil
        try await UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil))
    }
}

/// Shows alerts as banners even while Vettira is the active app, as it is while its popover or
/// dashboard is open; the system hides them then otherwise.
final class NotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
