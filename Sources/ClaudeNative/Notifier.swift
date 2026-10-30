import AppKit
import UserNotifications

/// Tells the user a reply finished or Claude is waiting on them while the
/// app is in the background, where VoiceOver announcements don't reach.
@MainActor
enum Notifier {
    private static var asked = false
    /// The last request to Notification Center. Each waits for the one
    /// before, so a withdrawal can't overtake the notification it takes
    /// back, and nothing is posted before authorization is asked.
    private static var last: Task<Void, Never>?

    /// Whether Notification Center can be used: UserNotifications raises an
    /// Objective-C exception outside an app bundle (for example swift run
    /// or a hosted model test).
    private static var isAvailable: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    /// Posts a notification while the app is in the background. One with
    /// the same `id` as an earlier one replaces it.
    static func notify(id: String, title: String, body: String) {
        guard NSApp?.isActive != true, isAvailable else { return }
        enqueue { center in
            if !asked {
                asked = true
                _ = try? await center.requestAuthorization(options: [.alert, .sound])
            }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try? await center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
    }

    /// Takes notifications off the screen and out of Notification Center
    /// once they no longer apply, such as a permission already answered.
    static func withdraw(_ ids: [String]) {
        guard isAvailable, !ids.isEmpty else { return }
        enqueue { center in
            center.removeDeliveredNotifications(withIdentifiers: ids)
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private static func enqueue(_ work: @escaping @MainActor (UNUserNotificationCenter) async -> Void) {
        let previous = last
        last = Task {
            await previous?.value
            await work(UNUserNotificationCenter.current())
        }
    }
}
