import Foundation
import UserNotifications

enum NotificationSender {
    static func requestPermission() {
        Task {
            _ = try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])
        }
    }

    /// On launch, nudge the user to install the helper if it isn't installed —
    /// otherwise the "Install Helper" prompt only shows if they happen to open
    /// the menu. Requests notification permission first (idempotent), then checks
    /// the on-disk install state (no DaemonManager instance needed).
    static func remindToInstallIfNeeded() {
        Task {
            let granted = (try? await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert])) ?? false
            guard granted, !DaemonManager.isHelperInstalled() else { return }
            send(
                title: "Lunation isn’t set up yet",
                body: "Click the moon in the menu bar and choose “Install Helper” to start keeping your Mac awake with the lid closed."
            )
        }
    }

    /// Posts a notification immediately. Using the title as the identifier means
    /// rapid repeat transitions replace the pending notification rather than stacking.
    static func send(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body  = body
        let request = UNNotificationRequest(
            identifier: title,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
