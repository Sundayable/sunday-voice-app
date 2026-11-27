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
}
