import XCTest
import DictationEngine
import LocalMeetingEngine
@testable import Sunday_Voice

@MainActor
final class BillingAndLanguageTests: XCTestCase {
    func testSpeechLanguageAllowlistMatchesAcrossEngines() {
        XCTAssertEqual(DictationEngine.allowedSpeechLanguages, ["ko", "en"])
        XCTAssertEqual(LocalMeetingEngine.SpeechLanguagePolicy.allowedLanguages, ["ko", "en"])
        XCTAssertEqual(DictationEngine.allowedSpeechLanguages, LocalMeetingEngine.SpeechLanguagePolicy.allowedLanguages)
    }

    func testAccountSummaryDecodesBillingPayload() throws {
        let json = """
        {
          "plan": "pro",
          "billing": {
            "plan": "pro",
            "status": "active",
            "entitled": true,
            "pro_required": true,
            "price_usd_monthly": 19,
            "current_period_end": "2026-12-27T00:00:00.000Z",
            "cancel_at_period_end": false,
            "has_customer": true,
            "checkout_available": true
          }
        }
        """
        let decoded = try JSONDecoder().decode(AccountSummary.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.plan, "pro")
        XCTAssertEqual(decoded.billing?.status, "active")
        XCTAssertEqual(decoded.billing?.entitled, true)
        XCTAssertEqual(decoded.billing?.price_usd_monthly, 19)
        XCTAssertEqual(decoded.billing?.has_customer, true)
    }

    func testSubscriptionRequiredMapsToUpgradeActionAndLocalizedMessage() {
        XCTAssertEqual(AppDelegate.action(.server("subscription_required")), .openAccount)
        XCTAssertEqual(AppDelegate.action(.server("STT_subscription_required")), .openAccount)
        XCTAssertEqual(AppDelegate.action(.server("local_model_missing")), .openLocalModel)
        XCTAssertEqual(ClipboardTidy.action(TidyError.subscriptionRequired), .openAccount)
        let message = AppDelegate.message(.server("subscription_required"))
        XCTAssertFalse(message.isEmpty)
        XCTAssertNotEqual(message, "error.subscriptionRequired")
        let tidyMsg = ClipboardTidy.message(TidyError.subscriptionRequired)
        XCTAssertTrue(tidyMsg.contains("$19"))
    }

    func testBillingStringsExistInBothEnglishAndKorean() throws {
        let requiredKeys = [
            "billing.sectionTitle",
            "billing.upgrade.title",
            "billing.upgrade.body",
            "billing.upgradeButton",
            "billing.manage",
            "billing.updatePayment",
            "billing.pastDue.title",
            "billing.pro.activeTitle",
            "billing.pro.renewsOn",
            "billing.pro.cancelsOn",
            "error.subscriptionRequired",
            "hud.button.upgradePro",
            "hud.button.setupModel",
            "tidy.error.subscriptionRequired",
            "ob.welcome.pro.title",
            "ob.welcome.pro.badge",
            "ob.welcome.pro.body",
            "ob.step.pro",
            "ob.pro.title",
            "ob.pro.body",
            "ob.pro.useLocal",
            "ob.step.localModel",
            "ob.localModel.title",
            "ob.localModel.body",
            "ob.localModel.download",
            "ob.localModel.lowDisk",
            "ob.localModel.failed",
            "ob.keys.proOnly",
            "ob.keys.english.localDetail",
            "ob.keys.tidy.localDetail",
            "ob.try.body.local",
            "consent.title",
            "consent.noTrain",
            "meeting.model.downloading",
            "meeting.model.progress",
            "meeting.model.preparing",
            "meeting.model.ready",
            "meeting.model.failed",
            "meeting.model.lowDisk",
        ]
        let noGmailSlackKeys = [
            "ob.welcome.pro.body",
            "settings.proFeature.voiceBody",
            "settings.proFeature.wordsBody",
            "vocab.empty.guestBody",
        ]
        for language in ["en", "ko"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            for key in requiredKeys {
                let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
                XCTAssertNotEqual(value, "__MISSING__", "Missing \(language) localization for \(key)")
                XCTAssertFalse(value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty \(language) localization for \(key)")
                XCTAssertFalse(value.contains("대표님"), "Unexpected 대표님 in \(language) \(key)")
            }
            for key in noGmailSlackKeys {
                let value = bundle.localizedString(forKey: key, value: "__MISSING__", table: nil)
                XCTAssertFalse(value.localizedCaseInsensitiveContains("Gmail"), "Unexpected Gmail in \(language) \(key): \(value)")
                XCTAssertFalse(value.localizedCaseInsensitiveContains("Slack"), "Unexpected Slack in \(language) \(key): \(value)")
            }
        }
    }
}
