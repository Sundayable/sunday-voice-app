import AppKit
import SwiftUI
import XCTest
import DictationEngine
@testable import Sunday_Voice

/// 0.3.23 shipped a first-screen language switch that only redrew itself: the step views kept the old
/// language because SwiftUI skipped them (same model). This renders the real window before and after.
@MainActor
final class LanguageSwitchRenderTests: XCTestCase {
    private var savedLanguage: String?
    private var savedPreferredProvider: (() -> [String])!

    override func setUp() async throws {
        savedLanguage = UserDefaults.standard.string(forKey: UILanguage.key)
        savedPreferredProvider = UILanguage.systemPreferredLanguages
    }
    override func tearDown() async throws {
        UILanguage.systemPreferredLanguages = savedPreferredProvider
        if let savedLanguage { UILanguage.choice = savedLanguage } else { UserDefaults.standard.removeObject(forKey: UILanguage.key) }
    }

    private func pump() {
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }

    /// Pixels of a region (AppKit view coordinates, flipped by the hosting view) as raw bytes.
    private func pixels(_ host: NSView, _ rect: NSRect) -> Data {
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: rect)!
        host.cacheDisplay(in: rect, to: rep)
        return Data(bytes: rep.bitmapData!, count: rep.bytesPerRow * rep.pixelsHigh)
    }

    private func assertRedraws<V: View>(_ view: V, size: NSSize, region: NSRect, file: StaticString = #filePath, line: UInt = #line) {
        UILanguage.choice = "en"; pump()
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        pump()
        let english = pixels(host, region)
        UILanguage.choice = "ko"; pump()
        let korean = pixels(host, region)
        XCTAssertNotEqual(english, korean, "text outside the switch must change language too", file: file, line: line)
        window.contentView = nil
    }

    func testStringsComeFromThePickedLanguageTable() {
        UILanguage.choice = "en"
        XCTAssertEqual(L("ob.welcome.title"), UILanguage.table("en")?["ob.welcome.title"])
        UILanguage.choice = "ko"
        XCTAssertEqual(UILanguage.code, "ko")
        XCTAssertEqual(L("ob.welcome.title"), "말하면, 내 말투로 써 드려요.")
        XCTAssertEqual(L("keys.mouseButton", "5"), "마우스 버튼 5", "format arguments still apply")
        UILanguage.choice = "en"
        XCTAssertEqual(L("keys.mouseButton", "5"), "Mouse button 5")
        XCTAssertEqual(L("no.such.key"), "no.such.key", "missing keys fall back to the key")
    }

    func testOnboardingStepsRedrawWhenTheLanguageChanges() {
        let auth = AuthService(storage: MemoryAuthStorage())
        let model = OnboardingModel(auth: auth, api: APIClient(auth: auth), monitor: PermissionMonitor(), engine: MockDictationEngine())
        model.isPreview = true; model.fnUsage = .nothing
        model.auth.previewSignedIn(nil); model.step = .signIn
        // The step rail on the left: no part of the language switch is drawn there.
        assertRedraws(OnboardingView(model: model), size: NSSize(width: 760, height: 600), region: NSRect(x: 0, y: 0, width: 190, height: 600))
    }

    func testSystemDefaultFollowsMacOSLanguageAndHighlightsToggleWhenUnset() {
        UserDefaults.standard.removeObject(forKey: UILanguage.key)
        XCTAssertEqual(UILanguage.choice, "system")

        UILanguage.systemPreferredLanguages = { ["ko-KR", "en-US"] }
        UILanguageObserver.shared.bump()
        XCTAssertEqual(UILanguage.code, "ko")
        XCTAssertTrue(UILanguage.isKorean)
        XCTAssertEqual(L("ob.welcome.title"), "말하면, 내 말투로 써 드려요.")
        let koHost = NSHostingView(rootView: LanguageSwitch().padding(8))
        koHost.frame = NSRect(x: 0, y: 0, width: 220, height: 50)
        let koWin = NSWindow(contentRect: koHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        koWin.contentView = koHost
        pump()
        let koPixels = pixels(koHost, koHost.bounds)
        koWin.contentView = nil

        UILanguage.systemPreferredLanguages = { ["en-US", "ko-KR"] }
        UILanguageObserver.shared.bump()
        XCTAssertEqual(UILanguage.code, "en")
        XCTAssertFalse(UILanguage.isKorean)
        XCTAssertEqual(L("ob.welcome.title"), UILanguage.table("en")?["ob.welcome.title"])
        let enHost = NSHostingView(rootView: LanguageSwitch().padding(8))
        enHost.frame = NSRect(x: 0, y: 0, width: 220, height: 50)
        let enWin = NSWindow(contentRect: enHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        enWin.contentView = enHost
        pump()
        let enPixels = pixels(enHost, enHost.bounds)
        enWin.contentView = nil

        XCTAssertNotEqual(koPixels, enPixels, "toggle highlight must reflect the active macOS language when uiLanguage is unset")
    }

    func testLockedAndEntitledKeysViewsRenderDifferently() {
        UILanguage.choice = "ko"; pump()
        let freeAuth = AuthService(storage: MemoryAuthStorage())
        let freeModel = OnboardingModel(auth: freeAuth, api: APIClient(auth: freeAuth), monitor: PermissionMonitor(), engine: MockDictationEngine())
        freeModel.isPreview = true; freeModel.fnUsage = .nothing; freeModel.auth.previewSignedIn(nil)
        freeModel.triggers = Prefs.defaultTriggers; freeModel.tidyKeys = [.default]

        let proAuth = AuthService(storage: MemoryAuthStorage())
        let proModel = OnboardingModel(auth: proAuth, api: APIClient(auth: proAuth), monitor: PermissionMonitor(), engine: MockDictationEngine())
        proModel.isPreview = true; proModel.fnUsage = .nothing
        proModel.auth.previewSignedIn(UserProfile(id: "p1", email: "pro@example.com", name: "Pro", picture: nil, guest: true))
        proModel.billing = BillingSummary(plan: "pro", status: "active", entitled: true, pro_required: true, price_usd_monthly: 19, current_period_end: nil, cancel_at_period_end: false, has_customer: true, checkout_available: true)
        proModel.triggers = Prefs.defaultTriggers; proModel.tidyKeys = [.default]

        let size = NSSize(width: 820, height: 600)
        let freeHost = NSHostingView(rootView: SettingsView(model: freeModel, words: VocabularyModel(api: APIClient(auth: freeAuth)), pane: .keys, onSignOut: {}))
        freeHost.frame = NSRect(origin: .zero, size: size)
        let freeWin = NSWindow(contentRect: freeHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        freeWin.contentView = freeHost; pump()
        let freePixels = pixels(freeHost, NSRect(x: 210, y: 0, width: 600, height: 600))
        freeWin.contentView = nil

        let proHost = NSHostingView(rootView: SettingsView(model: proModel, words: VocabularyModel(api: APIClient(auth: proAuth)), pane: .keys, onSignOut: {}))
        proHost.frame = NSRect(origin: .zero, size: size)
        let proWin = NSWindow(contentRect: proHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        proWin.contentView = proHost; pump()
        let proPixels = pixels(proHost, NSRect(x: 210, y: 0, width: 600, height: 600))
        proWin.contentView = nil

        XCTAssertNotEqual(freePixels, proPixels, "Free locked Pro cards and Pro editable cards must render differently")
    }

    func testSettingsPanesRedrawWhenTheLanguageChanges() {
        let auth = AuthService(storage: MemoryAuthStorage())
        let model = OnboardingModel(auth: auth, api: APIClient(auth: auth), monitor: PermissionMonitor(), engine: MockDictationEngine())
        model.isPreview = true; model.fnUsage = .nothing
        let words = VocabularyModel(api: APIClient(auth: auth))
        // The Keys pane body (right of the sidebar).
        assertRedraws(SettingsView(model: model, words: words, pane: .keys, onSignOut: {}),
                      size: NSSize(width: 820, height: 600), region: NSRect(x: 210, y: 0, width: 600, height: 600))
    }
}
