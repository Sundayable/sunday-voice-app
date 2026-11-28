import XCTest
import AVFoundation
import DictationEngine
@testable import Sunday_Voice

@MainActor
final class AppTests: XCTestCase {
    func testPKCEMatchesRFC7636() {
        XCTAssertEqual(AuthService.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"), "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        let v = AuthService.randomVerifier()
        XCTAssertEqual(v.count, 43)
        XCTAssertNil(v.rangeOfCharacter(from: CharacterSet(charactersIn: "+/=")))
    }

    func testDeepLinksPerMacOSVersion() {
        XCTAssertEqual(SettingsLink.url(.accessibility, majorVersion: 15).absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        XCTAssertEqual(SettingsLink.url(.microphone, majorVersion: 14).absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        XCTAssertEqual(SettingsLink.url(.inputMonitoring, majorVersion: 15).absoluteString, "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
        XCTAssertEqual(SettingsLink.url(.accessibility, majorVersion: 26).absoluteString, "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility")
    }

    func testPermissionRetryOpensSettingsWithoutRequestingAnotherPrompt() {
        var opened: [Permission] = []
        let monitor = PermissionMonitor(settingsOpener: { opened.append($0) })
        monitor.openSettings(.microphone)
        monitor.openSettings(.accessibility)
        XCTAssertEqual(opened, [.microphone, .accessibility])
        XCTAssertNotNil(monitor.waitingSince[.microphone])
        XCTAssertFalse(monitor.showRetry(.microphone))
    }

    func testOnlyMicAndAccessibilityAreRequiredByDefault() {
        var s = PermissionState(microphone: .notDetermined, accessibility: false)
        XCTAssertEqual(s.required, [.microphone, .accessibility])
        XCTAssertEqual(s.nextMissing, .microphone)
        s.microphone = .authorized
        XCTAssertEqual(s.nextMissing, .accessibility)
        s.accessibility = true
        XCTAssertTrue(s.allGranted)
        s.inputMonitoringNeeded = true
        XCTAssertFalse(s.allGranted)
        XCTAssertEqual(s.nextMissing, .inputMonitoring)
    }

    func testFlowGates() {
        let granted = PermissionState(microphone: .authorized, accessibility: true)
        var f = OnboardingFlow.Facts(signedIn: false, permissions: PermissionState(), micHeard: false, hasTrigger: true)
        // Signed-out users start in Free Local Mode without a login gate.
        XCTAssertTrue(OnboardingFlow.canContinue(.signIn, f))
        XCTAssertEqual(OnboardingFlow.resumeStep(f, completed: false), .signIn)
        XCTAssertEqual(OnboardingFlow.resumeStep(f, completed: true), .permissions)
        // Active consent requirement still blocks until accepted.
        f.needsConsent = true
        XCTAssertFalse(OnboardingFlow.canContinue(.signIn, f))
        XCTAssertEqual(OnboardingFlow.resumeStep(f, completed: true), .signIn)
        f.needsConsent = false
        f.signedIn = true
        XCTAssertEqual(OnboardingFlow.resumeStep(f, completed: true), .permissions)
        XCTAssertFalse(OnboardingFlow.canContinue(.permissions, f))
        f.permissions = granted
        XCTAssertTrue(OnboardingFlow.canContinue(.permissions, f))
        XCTAssertNil(OnboardingFlow.resumeStep(f, completed: true))
        XCTAssertEqual(OnboardingFlow.resumeStep(f, completed: false), .mic)
        XCTAssertFalse(OnboardingFlow.canContinue(.mic, f))
        f.micHeard = true
        XCTAssertTrue(OnboardingFlow.canContinue(.mic, f))
        XCTAssertTrue(OnboardingFlow.canContinue(.connect, f)) // optional steps never block
        f.hasTrigger = false
        XCTAssertFalse(OnboardingFlow.canContinue(.keys, f))
    }

    func testSignedOutStartsInFreeLocalModeAndSkipsCloudSteps() {
        let savedLocal = UserDefaults.standard.object(forKey: "localDictationEnabled")
        defer {
            if let savedLocal { UserDefaults.standard.set(savedLocal, forKey: "localDictationEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "localDictationEnabled") }
        }
        UserDefaults.standard.removeObject(forKey: "localDictationEnabled")

        let auth = AuthService(storage: MemoryAuthStorage())
        let model = OnboardingModel(auth: auth, api: APIClient(auth: auth), monitor: PermissionMonitor(), engine: MockDictationEngine())
        XCTAssertTrue(model.isLocalOnly)
        XCTAssertTrue(model.effectiveLocalDictation)
        XCTAssertTrue(model.hidesCloudSteps)
        XCTAssertTrue(model.canContinue)

        // Signed-out onboarding includes Local Speech Model step and skips cloud-only Connect and Voice steps.
        model.step = .keys
        model.next()
        XCTAssertEqual(model.step, .localModel)
        model.next()
        XCTAssertEqual(model.step, .tryIt)
        model.back()
        XCTAssertEqual(model.step, .localModel)
        model.back()
        XCTAssertEqual(model.step, .keys)

        // Signed-in Pro user defaults to Cloud mode and sees full onboarding steps.
        auth.previewSignedIn(UserProfile(id: "pro", email: "pro@sundayable.com", name: "Pro", picture: nil))
        XCTAssertFalse(model.isLocalOnly)
        XCTAssertFalse(model.effectiveLocalDictation)
        XCTAssertFalse(model.hidesCloudSteps)
        model.step = .keys
        model.next()
        XCTAssertEqual(model.step, .connect)
    }

    func testExternalNonProSignInLandsOnProUpgradeAndCanSwitchToLocalMode() {
        let savedLocal = UserDefaults.standard.object(forKey: "localDictationEnabled")
        defer {
            if let savedLocal { UserDefaults.standard.set(savedLocal, forKey: "localDictationEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "localDictationEnabled") }
        }
        UserDefaults.standard.removeObject(forKey: "localDictationEnabled")

        let auth = AuthService(storage: MemoryAuthStorage())
        auth.previewSignedIn(UserProfile(id: "ext", email: "ext@gmail.com", name: "Ext", picture: nil, guest: true))
        let model = OnboardingModel(auth: auth, api: APIClient(auth: auth), monitor: PermissionMonitor(), engine: MockDictationEngine())
        model.step = .signIn
        XCTAssertTrue(model.showProUpgradeStep)
        XCTAssertTrue(model.effectiveLocalDictation, "non-Pro account stays usable in Free Local Mode immediately")
        model.didSignIn()
        XCTAssertEqual(model.step, .proUpgrade)
        XCTAssertTrue(model.canContinue, "Pro upgrade step never traps a non-Pro user in a dead state")

        // Switching to Free Local Mode advances to permissions + localModel.
        model.switchToFreeLocalMode()
        XCTAssertTrue(model.effectiveLocalDictation)
        XCTAssertFalse(model.needsProUpgrade)
        XCTAssertEqual(model.step, .permissions)
        XCTAssertTrue(model.visibleSteps.contains(.localModel))
    }

    func testLocalModelDownloadChecksDiskSpaceBeforeStarting() {
        let auth = AuthService(storage: MemoryAuthStorage())
        let model = OnboardingModel(auth: auth, api: APIClient(auth: auth), monitor: PermissionMonitor(), engine: MockDictationEngine())
        model.diskSpaceProvider = { 500_000_000 } // 0.5 GB < 1.5 GB required
        model.downloadLocalModel()
        XCTAssertFalse(model.localModelDownloading)
        XCTAssertNotNil(model.localModelError)
        XCTAssertTrue(model.localModelError?.contains("0.5") == true)
    }

    func testTriggerIdentityTracksPhysicalInputAcrossModes() {
        let english = TriggerKind.key(keyCode: 79, modifiers: 0, mode: .english)
        XCTAssertEqual(english.inputKey, english.with(mode: .bilingual).inputKey)
        XCTAssertNotEqual(english.inputKey, TriggerKind.key(keyCode: 80, modifiers: 0, mode: .english).inputKey)
        XCTAssertEqual(OnboardingModel.describe(.mouseButton(number: 4, mode: .bilingual)), L("keyname.mouseSide2"))
        XCTAssertEqual(OnboardingModel.describe(.mouseButton(number: 5, mode: .bilingual)), L("keys.mouseButton", "6"))
        XCTAssertEqual(OnboardingModel.describe(english), "F18")
        XCTAssertNotNil(OnboardingModel.problem(with: .key(keyCode: 0, modifiers: 0, mode: .english)))
        XCTAssertNil(OnboardingModel.problem(with: english))
    }

    func testFreshInstallUsesFnDefaultsEvenWithLegacyConfigPresent() {
        let saved = UserDefaults.standard.object(forKey: "triggers")
        defer {
            if let saved { UserDefaults.standard.set(saved, forKey: "triggers") }
            else { UserDefaults.standard.removeObject(forKey: "triggers") }
        }
        UserDefaults.standard.removeObject(forKey: "triggers")
        XCTAssertEqual(Prefs.triggers, Prefs.defaultTriggers)
        XCTAssertEqual(Prefs.triggers.count, 2)
        XCTAssertEqual(Prefs.triggers.map(\.inputKey), ["mod:fn", "mod:fn+shift"])
    }

    func testSignInAdvancesOnceAndConnectionTimeoutAllowsRetry() {
        let auth = AuthService(storage: MemoryAuthStorage())
        auth.previewSignedIn(UserProfile(id: "qa", email: "qa@example.com", name: nil, picture: nil))
        let model = OnboardingModel(auth: auth, api: APIClient(auth: auth), monitor: PermissionMonitor(), engine: MockDictationEngine())
        model.step = .signIn
        model.didSignIn()
        XCTAssertEqual(model.step, .permissions)
        model.didSignIn()
        XCTAssertEqual(model.step, .permissions)
        model.connections = ["gmail": "pending", "slack": "active"]
        model.expirePendingConnections()
        XCTAssertEqual(model.connections["gmail"], "error")
        XCTAssertEqual(model.connections["slack"], "active")
        XCTAssertNotNil(model.connectionError)
    }

    func testQuietMicSpeechPassesButSingleClickAndSilenceDoNot() {
        let start = Date(timeIntervalSince1970: 0)
        var quiet = MicCheckDetector()
        var heard = false
        for i in 0...8 { heard = heard || quiet.receive(0.0035, at: start.addingTimeInterval(Double(i) * 0.05)) }
        XCTAssertTrue(heard)
        var click = MicCheckDetector()
        XCTAssertFalse(click.receive(0.3, at: start))
        for i in 1...20 { XCTAssertFalse(click.receive(0.0001, at: start.addingTimeInterval(Double(i) * 0.05))) }
    }

    func testPartialVoiceFailureIsDecoded() throws {
        let data = Data(#"{"cards":{},"stats":{"gmail_messages":0,"slack_messages":2,"en_samples":2,"ko_samples":0,"sources_failed":1},"failed":["gmail"]}"#.utf8)
        let result = try JSONDecoder().decode(VoiceRefresh.self, from: data)
        XCTAssertEqual(result.failed, ["gmail"])
        XCTAssertEqual(result.stats.sources_failed, 1)
    }

    func testRetryHintAfterTenSeconds() {
        let monitor = PermissionMonitor()
        XCTAssertFalse(monitor.showRetry(.accessibility))
    }

    func testIdentityComesFromBundle() {
        XCTAssertFalse(AppIdentity.name.isEmpty)
        XCTAssertEqual(AppIdentity.urlScheme, Bundle.main.object(forInfoDictionaryKey: "SVURLScheme") as? String ?? AppIdentity.bundleID)
    }

    func testHUDPrepareStaysHiddenAndShowsListeningImmediately() {
        let hud = HUD()
        hud.prepare()
        XCTAssertEqual(hud.state, .hidden, "Pre-warming the HUD panel must keep it hidden until dictation starts")
        hud.show(.listening(mode: "bilingual", meter: true))
        XCTAssertEqual(hud.state, .listening(mode: "bilingual", meter: true))
        hud.show(.hidden)
        XCTAssertEqual(hud.state, .hidden)
    }
}
