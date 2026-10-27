import Foundation
import UserNotifications

/// Local "pint is ready" notifications.
@MainActor
enum Notifier {
    static func requestIfNeeded(_ user: UserStore) async -> Bool {
        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        case .denied: return false
        default:
            user.data.notificationsAsked = true
            return (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        }
    }

    static func schedule(_ t: FreezeTimer, recipeName: String, usesServings: Bool = false) async {
        let recipeReadyTitle = usesServings ? "Ready to eat" : "Ready to spin"
        let content = UNMutableNotificationContent()
        content.title = recipeReadyTitle
        content.body = usesServings ? "Your \(recipeName) is ready to eat 🍰" : "Your \(recipeName) pint is ready to spin 🍦"
        content.sound = .default
        let interval = max(1, t.readyAt.timeIntervalSinceNow)
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: t.id.uuidString, content: content, trigger: trigger))
    }

    static func cancel(_ t: FreezeTimer) {
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [t.id.uuidString])
    }

    /// Starts a freeze timer for the recipe and schedules its notification.
    static func startTimer(for r: Recipe, user: UserStore) {
        let t = user.startTimer(for: r)
        Task {
            if await requestIfNeeded(user) { await schedule(t, recipeName: r.name, usesServings: r.usesServings) }
        }
    }
}
