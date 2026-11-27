import AppKit
import Sparkle
import UserNotifications

/// Gentle update reminders for a menu-bar app (Sparkle "gentle reminders"). Right after launch, or
/// when the Mac has been idle, Sparkle shows its update window itself. Otherwise a scheduled update
/// never pops a window over the app the user is dictating into: a notification and an
/// "Update to …" menu item appear instead, and clicking either brings Sparkle's window into focus.
@MainActor
final class UpdateReminder: NSObject, SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate {
    static let notificationID = "sunday-voice-update-available"

    /// Version offered by a scheduled check and not yet attended to (drives the menu item).
    private(set) var availableVersion: String? { didSet { onChange?(availableVersion) } }
    var onChange: ((String?) -> Void)?
    /// Brings Sparkle's update window into focus (`checkForUpdates`).
    var showUpdate: () -> Void = {}
    /// Posts the notification; replaced in tests.
    var notify: (String) -> Void = UpdateReminder.postNotification

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        let version = update.displayVersionString, userInitiated = state.userInitiated
        MainActor.assumeIsolated { self.willShow(version: version, handledBySparkle: handleShowingUpdate, userInitiated: userInitiated) }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { self.clear() }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { self.clear() }
    }

    func willShow(version: String, handledBySparkle: Bool, userInitiated: Bool) {
        guard !userInitiated else { return }
        availableVersion = version
        if !handledBySparkle { notify(version) }
    }

    func clear() {
        availableVersion = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }

    // MARK: notification

    static func postNotification(version: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = L("update.available.title", AppIdentity.name, version)
            content.body = L("update.available.body")
            content.sound = .default
            center.add(UNNotificationRequest(identifier: notificationID, content: content, trigger: nil))
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier == Self.notificationID else { return }
        await MainActor.run { self.showUpdate() }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
