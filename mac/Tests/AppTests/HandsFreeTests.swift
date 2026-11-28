import XCTest
import DictationEngine
@testable import Sunday_Voice

@MainActor
final class HandsFreeTests: XCTestCase {
    func testHandsFreeAvailabilityRequiresMacOS15AndAppleSilicon() {
        XCTAssertFalse(HandsFreeSupport.isAvailable(majorVersion: 14, isAppleSilicon: true), "macOS 14 must hide Hands-free")
        XCTAssertFalse(HandsFreeSupport.isAvailable(majorVersion: 14, isAppleSilicon: false), "macOS 14 Intel must hide Hands-free")
        XCTAssertFalse(HandsFreeSupport.isAvailable(majorVersion: 15, isAppleSilicon: false), "Intel macOS 15 must hide Hands-free")
        XCTAssertTrue(HandsFreeSupport.isAvailable(majorVersion: 15, isAppleSilicon: true), "macOS 15 Apple Silicon shows Hands-free")
        XCTAssertTrue(HandsFreeSupport.isAvailable(majorVersion: 26, isAppleSilicon: true), "macOS 26+ Apple Silicon shows Hands-free")
    }

    func testSettingsSidebarHidesHandsFreeOnMacOS14AndShowsOnMacOS15AppleSilicon() {
        let hidden = SettingsView.Pane.visibleCases(handsFreeAvailable: false)
        XCTAssertFalse(hidden.contains(.handsFree))
        XCTAssertTrue(hidden.contains(.keys))

        let shown = SettingsView.Pane.visibleCases(handsFreeAvailable: true)
        XCTAssertTrue(shown.contains(.handsFree))
        if let keysIdx = shown.firstIndex(of: .keys), let hfIdx = shown.firstIndex(of: .handsFree) {
            XCTAssertEqual(hfIdx, keysIdx + 1)
        } else {
            XCTFail("Expected both .keys and .handsFree in visibleCases")
        }
    }

    func testCursorWakeURLMatchesPublicActionOnly() throws {
        let cursor = HandsFreeSupport.cursorWakeURL
        XCTAssertEqual(cursor.host, "wake")
        XCTAssertEqual(cursor.lastPathComponent, "cursor")
        XCTAssertTrue(HandsFreeSupport.isCursorWakeURL(cursor))
        XCTAssertTrue(HandsFreeSupport.isCursorWakeURL(try XCTUnwrap(URL(string: "sundayvoice://wake/CURSOR"))))
        XCTAssertFalse(HandsFreeSupport.isCursorWakeURL(try XCTUnwrap(URL(string: "sundayvoice://wake/other"))))
        XCTAssertFalse(HandsFreeSupport.isCursorWakeURL(try XCTUnwrap(URL(string: "sundayvoice://auth/cursor"))))
    }

    func testVocalShortcutsDeepLinkAndSuggestedPhrases() {
        XCTAssertEqual(
            SettingsLink.vocalShortcuts(majorVersion: 15).absoluteString,
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?AdaptiveVoiceShortcuts"
        )
        XCTAssertEqual(HandsFreeSupport.suggestedPhrases, ["Hey Sunday", "헤이 선데이"])
    }

    func testHandsFreeBridgeRecordsTriggersAndTestTranscript() {
        let bridge = HandsFreeCursorBridge()
        var sources: [String] = []
        bridge.onTrigger = { sources.append($0) }

        bridge.trigger(source: "app_intent")
        XCTAssertEqual(sources, ["app_intent"])
        XCTAssertEqual(bridge.lastTriggerSource, "app_intent")
        XCTAssertNotNil(bridge.lastTriggeredAt)

        bridge.receiveTestText("안녕하세요")
        bridge.receiveTestText("테스트입니다")
        XCTAssertEqual(bridge.testTranscript, "안녕하세요 테스트입니다")

        bridge.resetTest()
        XCTAssertTrue(bridge.testTranscript.isEmpty)
        XCTAssertNil(bridge.lastTriggeredAt)
        XCTAssertNil(bridge.lastTriggerSource)
    }

    func testAnonymousStatsFirstLaunchRespectsOptInGateAndSendsOnce() async throws {
        let stats = AnonymousStats()
        var enabled = false
        var sentFirstLaunch = false
        var requests: [URLRequest] = []
        stats.baseURL = { URL(string: "https://voice.sundayable.com") }
        stats.isEnabled = { enabled }
        stats.installID = { "00000000-0000-4000-8000-000000000001" }
        stats.hasSentFirstLaunch = { sentFirstLaunch }
        stats.markFirstLaunchSent = { sentFirstLaunch = true }
        stats.sendRequest = { req in
            await MainActor.run { requests.append(req) }
        }

        // Disabled by default: zero network traffic.
        stats.recordFirstLaunchIfNeeded(localMode: true)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(requests.isEmpty)
        XCTAssertFalse(sentFirstLaunch)

        // Opt-in enabled: sends first_launch=true exactly once.
        enabled = true
        stats.recordFirstLaunchIfNeeded(localMode: true)
        stats.recordFirstLaunchIfNeeded(localMode: true)
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertEqual(requests.count, 1)
        let body = try XCTUnwrap(requests.first?.httpBody)
        let decoded = try JSONDecoder().decode(AnonymousStatsPayload.self, from: body)
        XCTAssertEqual(decoded.first_launch, true)
        XCTAssertEqual(decoded.mode, "local")
        XCTAssertNil(decoded.dictation_count)
    }

    func testHandsFreeLocalizationsExistInEnglishAndKorean() {
        let original = UILanguage.choice
        defer { UILanguage.choice = original }
        let keys = [
            "settings.handsFree",
            "handsfree.title",
            "handsfree.openSettings",
            "handsfree.test.button",
            "handsfree.onboarding.title",
        ]
        for lang in ["en", "ko"] {
            UILanguage.choice = lang
            for key in keys {
                let value = L(key)
                XCTAssertNotEqual(value, key, "Missing localization for \(key) in \(lang)")
                XCTAssertFalse(value.isEmpty)
            }
        }
    }
}
