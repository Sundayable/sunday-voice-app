import AppKit
import OSLog
import Sparkle
import UserNotifications

enum UpdateDeferralError: LocalizedError {
    case busy
    var errorDescription: String? { "Update deferred while recording or transcribing." }
}

/// Non-sensitive local runtime status marker so external install helpers (`scripts/install-mac.sh`)
/// never kill or replace Sunday Voice mid-meeting or mid-transcription.
enum RuntimeActivityMarker {
    struct Status: Codable, Equatable {
        let pid: Int32
        let active: Bool
        let kind: String
        let updatedAt: TimeInterval
    }

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SundayVoice/runtime-activity.json")
    }

    static func update(activeKind: String?, url: URL = defaultURL, pid: Int32 = ProcessInfo.processInfo.processIdentifier) {
        if let kind = activeKind {
            let status = Status(pid: pid, active: true, kind: kind, updatedAt: Date().timeIntervalSince1970)
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let data = try JSONEncoder().encode(status)
                try data.write(to: url, options: [.atomic])
                try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            } catch {}
        } else {
            try? FileManager.default.removeItem(at: url)
        }
    }
}

/// Gentle update reminders + recording/transcription deferral for a menu-bar app (Sparkle).
/// Never checks in the background, pops an update dialog, or relaunches the app while a meeting
/// recording, offline meeting transcription, or dictation is active. Postponed relaunches run once idle.
@MainActor
final class UpdateReminder: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate, UNUserNotificationCenterDelegate {
    static let notificationID = "sunday-voice-update-available"
    private let log = Logger(subsystem: "ca.sundayable.sunday-voice", category: "updates")

    /// Version offered by a scheduled check and not yet attended to (drives the menu item).
    private(set) var availableVersion: String? { didSet { onChange?(availableVersion) } }
    /// Version whose Sparkle relaunch was postponed because a recording or transcription was active.
    private(set) var deferredRelaunchVersion: String?
    private var deferredInstallHandler: (() -> Void)?
    var onChange: ((String?) -> Void)?
    /// True while a meeting recording, meeting transcription, or dictation is in progress.
    var isBusy: () -> Bool = { false }
    /// Brings Sparkle's update window into focus (`checkForUpdates`).
    var showUpdate: () -> Void = {}
    /// Posts the notification; replaced in tests.
    var notify: (String) -> Void = UpdateReminder.postNotification

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // Explicit user-initiated "Check for Updates…" is allowed; scheduled background checks defer while busy.
        guard updateCheck != .updates else { return }
        let busy = MainActor.assumeIsolated { self.isBusy() }
        if busy {
            log.notice("sparkle_check_deferred reason=active_recording_or_transcription")
            throw UpdateDeferralError.busy
        }
    }

    nonisolated func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        return MainActor.assumeIsolated {
            self.shouldPostponeRelaunch(version: version, installHandler: installHandler)
        }
    }

    func shouldPostponeRelaunch(version: String, installHandler: @escaping () -> Void) -> Bool {
        guard isBusy() else { return false }
        deferredRelaunchVersion = version
        deferredInstallHandler = installHandler
        availableVersion = version
        log.notice("sparkle_relaunch_deferred version=\(version, privacy: .public)")
        return true
    }

    /// Invokes a postponed Sparkle install/relaunch as soon as recording and transcription return to idle.
    @discardableResult
    func flushDeferredRelaunchIfIdle() -> Bool {
        guard !isBusy(), let handler = deferredInstallHandler else { return false }
        let version = deferredRelaunchVersion ?? "unknown"
        deferredInstallHandler = nil
        deferredRelaunchVersion = nil
        log.notice("sparkle_relaunch_resumed version=\(version, privacy: .public)")
        handler()
        return true
    }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        let busy = MainActor.assumeIsolated { self.isBusy() }
        return immediateFocus && !busy
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
