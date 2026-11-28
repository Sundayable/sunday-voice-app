import XCTest
@testable import Sunday_Voice

/// Scheduled update found while the user works: remind (menu item + notification), never pop a
/// window; right after launch/idle Sparkle shows its own window and we only add the menu item.
@MainActor
final class UpdateReminderTests: XCTestCase {
    func testBackgroundUpdateGetsNotificationAndMenuItem() {
        let reminder = UpdateReminder()
        var notified: [String] = [], seen: [String?] = []
        reminder.notify = { notified.append($0) }
        reminder.onChange = { seen.append($0) }
        reminder.willShow(version: "0.2.12", handledBySparkle: false, userInitiated: false)
        XCTAssertEqual(reminder.availableVersion, "0.2.12")
        XCTAssertEqual(notified, ["0.2.12"])
        reminder.clear()
        XCTAssertNil(reminder.availableVersion)
        XCTAssertEqual(seen, ["0.2.12", nil])
    }

    func testSparkleShownOrUserInitiatedChecksDoNotNotify() {
        let reminder = UpdateReminder()
        var notified: [String] = []
        reminder.notify = { notified.append($0) }
        reminder.willShow(version: "0.2.12", handledBySparkle: true, userInitiated: false)
        XCTAssertEqual(reminder.availableVersion, "0.2.12", "menu item still offered")
        reminder.clear()
        reminder.willShow(version: "0.2.12", handledBySparkle: true, userInitiated: true)
        XCTAssertNil(reminder.availableVersion)
        XCTAssertTrue(notified.isEmpty)
        XCTAssertTrue(reminder.supportsGentleScheduledUpdateReminders)
    }

    func testReminderStringsAreLocalizedWithVersion() {
        XCTAssertTrue(L("menu.updateAvailable", "0.2.12").contains("0.2.12"))
        let title = L("update.available.title", AppIdentity.name, "0.2.12")
        XCTAssertTrue(title.hasPrefix(AppIdentity.name) && title.contains("0.2.12"))
    }

    func testHourlyScheduledChecks() {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUScheduledCheckInterval") as? Int, 3600)
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "SUEnableAutomaticChecks") as? Bool, true)
    }

    func testSparkleRelaunchDefersWhileBusyAndResumesOnceIdle() {
        let reminder = UpdateReminder()
        var busy = true
        reminder.isBusy = { busy }
        var installed = false

        let postponed = reminder.shouldPostponeRelaunch(version: "0.3.31") { installed = true }
        XCTAssertTrue(postponed, "Relaunch must postpone while recording or transcribing")
        XCTAssertEqual(reminder.deferredRelaunchVersion, "0.3.31")
        XCTAssertEqual(reminder.availableVersion, "0.3.31")
        XCTAssertFalse(installed)
        XCTAssertFalse(reminder.flushDeferredRelaunchIfIdle(), "Still busy: must not relaunch")
        XCTAssertFalse(installed)

        busy = false
        XCTAssertTrue(reminder.flushDeferredRelaunchIfIdle(), "Once idle: postponed relaunch runs")
        XCTAssertTrue(installed)
        XCTAssertNil(reminder.deferredRelaunchVersion)
        XCTAssertFalse(reminder.flushDeferredRelaunchIfIdle(), "Deferred handler runs once only")
    }

    func testRuntimeActivityMarkerWritesAndClearsCleanly() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("sv-activity-\(UUID().uuidString)/runtime-activity.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        RuntimeActivityMarker.update(activeKind: "meeting_recording", url: url, pid: 12345)
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(RuntimeActivityMarker.Status.self, from: data)
        XCTAssertEqual(decoded.pid, 12345)
        XCTAssertTrue(decoded.active)
        XCTAssertEqual(decoded.kind, "meeting_recording")

        RuntimeActivityMarker.update(activeKind: nil, url: url)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
