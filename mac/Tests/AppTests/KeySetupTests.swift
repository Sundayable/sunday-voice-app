import XCTest
import DictationEngine
@testable import Sunday_Voice

/// 0.3.23 key setup: one key per action, guarded moves between actions, the live key check,
/// the 🌐 Fn conflict detection and the no-🌐 fallback.
@MainActor
final class KeySetupTests: XCTestCase {
    private let fn = TriggerKind.modifierHold(keys: [.fn], mode: .bilingual, holdMilliseconds: 180)
    private let fnShift = TriggerKind.modifierHold(keys: [.fn, .shift], mode: .english, holdMilliseconds: 180)
    private let rightOption = TriggerKind.modifierHold(keys: [.rightOption], mode: .bilingual, holdMilliseconds: 180)
    private let mouse5 = TriggerKind.mouseButton(number: 4, mode: .bilingual)
    private var savedTriggers: Data?
    private var savedTidy: Any?
    private var savedLanguage: String?
    private var savedRead: (() -> Int?)!
    private var savedCount: (() -> Int)!
    private var engine: MockDictationEngine!

    override func setUp() async throws {
        savedTriggers = UserDefaults.standard.data(forKey: "triggers")
        savedTidy = UserDefaults.standard.object(forKey: "tidyShortcuts")
        savedLanguage = UserDefaults.standard.string(forKey: UILanguage.key)
        savedRead = FnKeySetting.readValue
        savedCount = FnKeySetting.enabledInputSourceCount
        FnKeySetting.readValue = { 0 }
        Prefs.triggers = Prefs.defaultTriggers
        Prefs.tidyShortcuts = [.default]
    }

    override func tearDown() async throws {
        FnKeySetting.readValue = savedRead
        FnKeySetting.enabledInputSourceCount = savedCount
        if let savedTriggers { UserDefaults.standard.set(savedTriggers, forKey: "triggers") } else { UserDefaults.standard.removeObject(forKey: "triggers") }
        if let savedTidy { UserDefaults.standard.set(savedTidy, forKey: "tidyShortcuts") } else { UserDefaults.standard.removeObject(forKey: "tidyShortcuts") }
        if let savedLanguage { UILanguage.choice = savedLanguage } else { UserDefaults.standard.removeObject(forKey: UILanguage.key) }
    }

    private func makeModel(_ captures: [TriggerKind?] = []) -> OnboardingModel {
        let auth = AuthService(storage: MemoryAuthStorage())
        engine = MockDictationEngine()
        engine.scriptedCaptures = captures
        return OnboardingModel(auth: auth, api: APIClient(auth: auth), monitor: PermissionMonitor(), engine: engine)
    }

    private func makeEntitledModel(_ captures: [TriggerKind?] = []) -> OnboardingModel {
        let model = makeModel(captures)
        model.auth.previewSignedIn(UserProfile(id: "team-1", email: "dan@sundayable.com", name: "Dan", picture: nil, guest: false))
        return model
    }

    private func settle() async { for _ in 0..<5 { await Task.yield(); try? await Task.sleep(nanoseconds: 20_000_000) } }

    // MARK: 🌐 Fn setting

    func testFnUsageReadsTheSystemSettingAndItsDefault() {
        FnKeySetting.readValue = { 0 }; XCTAssertEqual(FnKeySetting.current(), .nothing)
        FnKeySetting.readValue = { 1 }; XCTAssertEqual(FnKeySetting.current(), .inputSource)
        FnKeySetting.readValue = { 2 }; XCTAssertEqual(FnKeySetting.current(), .emoji)
        FnKeySetting.readValue = { 3 }; XCTAssertEqual(FnKeySetting.current(), .dictation)
        // Never set: macOS switches input sources when more than one keyboard is on, else shows emoji.
        FnKeySetting.readValue = { nil }
        FnKeySetting.enabledInputSourceCount = { 2 }; XCTAssertEqual(FnKeySetting.current(), .inputSource)
        FnKeySetting.enabledInputSourceCount = { 1 }; XCTAssertEqual(FnKeySetting.current(), .emoji)
    }

    func testFnConflictOnlyWhenAFnKeyIsInUse() {
        let model = makeModel()
        model.fnUsage = .inputSource
        XCTAssertEqual(model.fnConflict, .inputSource)
        XCTAssertEqual(FnKeyUsage.inputSource.conflictKey, "keys.fn.conflict.input")
        model.triggers = [rightOption]
        XCTAssertNil(model.fnConflict, "no 🌐 key in use, nothing to fix")
        model.triggers = [fn]; model.fnUsage = .nothing
        XCTAssertNil(model.fnConflict)
    }

    // MARK: one key per action

    func testPrimaryAndExtraKeys() {
        let model = makeModel()
        model.triggers = [fn, mouse5, fnShift]
        XCTAssertEqual(model.primaryTrigger(for: .bilingual), fn)
        XCTAssertEqual(model.extraTriggers(for: .bilingual), [mouse5])
        XCTAssertEqual(model.primaryTrigger(for: .english), fnShift)
        XCTAssertEqual(model.extraTriggers(for: .english), [])
        XCTAssertEqual(OnboardingModel.verbKey(mouse5), "keys.hold", "mouse buttons are held to talk too")
    }

    func testChangeReplacesThePrimaryKeyInPlace() async {
        let model = makeModel([rightOption])
        model.triggers = [fn, mouse5, fnShift]
        model.captureKey(for: .bilingual, replacing: fn)
        XCTAssertTrue(model.capturing)
        await settle()
        XCTAssertFalse(model.capturing)
        XCTAssertEqual(model.triggers, [rightOption, mouse5, fnShift])
        XCTAssertEqual(Prefs.triggers, model.triggers, "saved")
        XCTAssertEqual(model.captured, OnboardingModel.describe(rightOption))
    }

    func testKeyOwnedByTheOtherActionAsksBeforeMoving() async {
        let model = makeModel([fnShift.with(mode: .bilingual)])
        model.triggers = [fn, fnShift]
        model.captureKey(for: .bilingual, replacing: fn)
        await settle()
        XCTAssertEqual(model.triggers, [fn, fnShift], "nothing moves silently")
        XCTAssertEqual(model.pendingMove?.from, .english)
        model.confirmPendingMove()
        XCTAssertNil(model.pendingMove)
        XCTAssertEqual(model.triggers, [fnShift.with(mode: .bilingual)])
    }

    func testEscapeCancelsAndTimeoutExplains() async {
        let model = makeModel([.key(keyCode: 53, modifiers: 0, mode: .bilingual), nil])
        model.captureKey(for: .bilingual, replacing: fn)
        await settle()
        XCTAssertEqual(model.triggers, Prefs.defaultTriggers)
        XCTAssertNil(model.keyMessage, "Esc is a cancel, not a refused key")
        model.captureKey(for: .bilingual, replacing: fn)
        await settle()
        XCTAssertEqual(model.keyMessage, L("keys.capture.timeout"))
    }

    func testCancelCaptureDropsTheLateResult() async {
        let model = makeModel([rightOption])
        model.captureKey(for: .bilingual, replacing: fn)
        model.cancelCapture()
        XCTAssertFalse(model.capturing)
        await settle()
        XCTAssertEqual(model.triggers, Prefs.defaultTriggers, "a result for a cancelled capture is ignored")
    }

    func testTypingKeysAreRefused() async {
        let model = makeModel([.key(keyCode: 0, modifiers: 0, mode: .bilingual)]) // "A"
        model.captureKey(for: .bilingual, replacing: fn)
        await settle()
        XCTAssertEqual(model.keyMessage, L("keys.typingKey"))
        XCTAssertEqual(model.triggers, Prefs.defaultTriggers)
    }

    func testRightOptionFallbackReplacesEveryFnKey() {
        let model = makeEntitledModel()
        model.triggers = [fn, mouse5, fnShift]
        model.useRightOption()
        XCTAssertEqual(model.triggers, [rightOption, mouse5, .modifierHold(keys: [.shift, .rightOption], mode: .english, holdMilliseconds: 180)])
        XCTAssertFalse(model.usesFnKey)
    }

    func testRestoreDefaultsPutsBackAllThreeKeys() {
        let model = makeEntitledModel()
        model.triggers = [mouse5]; model.tidyKeys = []
        model.confirmingReset = true
        model.resetTriggers()
        XCTAssertEqual(model.triggers, Prefs.defaultTriggers)
        XCTAssertEqual(model.tidyKeys, [.default])
        XCTAssertFalse(model.confirmingReset)
    }

    // MARK: live key check

    func testKeyCheckSeesTheDictationKey() async {
        let model = makeModel([fn])
        model.startKeyTest()
        XCTAssertTrue(model.keyTest.listening)
        await settle()
        XCTAssertTrue(model.keyTest.ok)
        XCTAssertFalse(model.keyTest.listening)
    }

    func testKeyCheckOffersADifferentKey() async {
        let option = TriggerKind.modifierHold(keys: [.option], mode: .bilingual, holdMilliseconds: 180)
        let model = makeModel([option])
        model.startKeyTest()
        await settle()
        XCTAssertFalse(model.keyTest.ok)
        XCTAssertEqual(model.keyTest.other, option)
        model.useTestedKey()
        XCTAssertEqual(model.primaryTrigger(for: .bilingual), option)
    }

    func testOnboardingKeyCheckRearmsAfterAChange() async {
        let model = makeModel([rightOption]) // the change; the queue is then empty, so the check stays armed
        model.keyTestAuto = true
        model.captureKey(for: .bilingual, replacing: fn)
        await settle()
        XCTAssertEqual(model.primaryTrigger(for: .bilingual), rightOption)
        XCTAssertTrue(model.keyTest.listening, "the new key gets checked right away")
        model.keyTestAuto = false
        model.stopKeyTest()
        XCTAssertFalse(model.keyTest.listening)
    }

    func testKeyCheckStaysQuietWhenTheEngineIsNotRunning() async {
        let model = makeModel([nil]) // an immediate nil = no event tap yet
        model.startKeyTest()
        await settle()
        XCTAssertFalse(model.keyTest.missedFn, "no false 'no 🌐 key' hint before permissions")
        XCTAssertFalse(model.keyTest.ok)
    }

    // MARK: copy

    func testEveryNewStringExistsInBothLanguages() {
        let keys = ["lang.label", "keys.title.onboarding", "keys.body.onboarding", "keys.title.settings", "keys.body.settings",
                    "mode.dictate.name", "mode.dictate.detail", "mode.dictate.example", "mode.english.name", "mode.english.detail",
                    "mode.english.example", "mode.polish.name", "mode.polish.detail", "mode.polish.example", "keys.hold", "keys.press",
                    "keys.mouseButton", "keys.pro.badge", "keys.pro.note", "keys.change", "keys.capture.prompt", "keys.capture.timeout",
                    "keys.capture.cancel", "keys.capture.saved", "keys.conflict.move", "keys.conflict.moveButton", "keys.test.prompt",
                    "keys.test.ok", "keys.test.other", "keys.test.useOther", "keys.test.start", "keys.noFn.title", "keys.noFn.body",
                    "keys.noFn.button", "keys.fn.conflict.input", "keys.fn.conflict.emoji", "keys.fn.conflict.dictation", "keys.fn.fix",
                    "keys.fn.step1", "keys.fn.step2", "keys.fn.step3", "keys.fn.fixed", "keys.advanced", "keys.advanced.body", "keys.add",
                    "keys.remove", "keys.restore", "keys.restore.confirm", "keys.restore.confirmButton", "keys.cancel", "keys.typingKey",
                    "keys.polishKeysOnly", "keys.takenByApp", "keyname.rightOption", "keyname.rightCommand", "ob.try.keysLabel"]
        for language in ["en", "ko"] {
            UILanguage.choice = language
            for key in keys { XCTAssertNotEqual(L(key), key, "\(key) missing in \(language)") }
        }
        UILanguage.choice = "ko"
        XCTAssertEqual(KeyNames.modifier(.rightOption), "오른쪽 Option (⌥)")
        XCTAssertTrue(UILanguage.isKorean)
        UILanguage.choice = "en"
        XCTAssertFalse(UILanguage.isKorean, "the first-screen switch flips the whole app")
        XCTAssertEqual(KeyNames.modifier(.rightOption), "Right Option (⌥)")
        XCTAssertEqual(KeyNames.mouseButton(3), "Mouse side button (Back)")
        XCTAssertEqual(OnboardingModel.locationHint(rightOption), L("keyname.rightOption.where"))
    }

    func test0326StringsExistInBothLanguages() {
        let keys = [
            "keys.capture.boxIdle", "keys.capture.subhint", "keys.capture.confirmedHold", "keys.capture.confirmedPress",
            "keyname.fn", "keyname.fn.where", "keyname.option", "keyname.option.where",
            "keyname.rightOption", "keyname.rightOption.where", "keyname.command", "keyname.command.where",
            "keyname.rightCommand", "keyname.rightCommand.where", "keyname.control", "keyname.control.where",
            "keyname.shift", "keyname.mouseMiddle", "keyname.mouseSide1", "keyname.mouseSide2",
            "badge.freeAndPro", "badge.proCloudOnly", "badge.proComingSoon",
            "settings.general.sectionApp", "settings.general.sectionAccuracy", "settings.general.sectionMode",
            "settings.language.title", "settings.language.note", "settings.recentContext.localDisabled",
            "settings.upcoming.section", "settings.upcoming.watch.title", "settings.upcoming.watch.body",
            "settings.upcoming.mcp.title", "settings.upcoming.mcp.body", "settings.upcoming.notify",
            "settings.upcoming.notified", "settings.calendar.comingSoonBody",
            "localWords.title", "localWords.body", "localWords.fromPlaceholder", "localWords.toPlaceholder",
            "localWords.add", "localWords.emptyTitle", "localWords.emptyBody", "localWords.proBanner", "localWords.saveError",
            "voice.delete", "voice.delete.confirm", "voice.delete.confirmButton", "voice.delete.error", "voice.emptyCard",
        ]
        for language in ["en", "ko"] {
            UILanguage.choice = language
            for key in keys {
                let value = L(key)
                XCTAssertNotEqual(value, key, "\(key) missing in \(language)")
                XCTAssertFalse(value.contains("대표님"), "\(key) must not contain 대표님")
            }
        }
    }

    func test0327StringsExistInBothLanguages() {
        let keys = [
            "badge.proOnly", "keys.locked.inactiveTag", "keys.locked.storedInactive", "keys.locked.noKey",
            "keys.locked.previewLabel", "keys.locked.english.input", "keys.locked.english.output",
            "keys.locked.polish.input", "keys.locked.polish.output", "keys.locked.signInNote",
            "keys.advanced.proLockedNote",
        ]
        for language in ["en", "ko"] {
            UILanguage.choice = language
            for key in keys {
                let value = L(key)
                XCTAssertNotEqual(value, key, "\(key) missing in \(language)")
                XCTAssertFalse(value.contains("대표님"), "\(key) must not contain 대표님")
            }
        }
        UILanguage.choice = "ko"
        XCTAssertEqual(L("badge.proOnly"), "Pro 전용")
        XCTAssertEqual(L("billing.upgradeButton", "19"), "Pro 시작하기 (월 $19)")
        UILanguage.choice = "en"
        XCTAssertEqual(L("badge.proOnly"), "Pro only")
    }

    func testProEntitlementMatrixForKeys() {
        let model = makeModel()
        // 1) Signed out (Free Local Mode) -> locked
        XCTAssertFalse(model.isProEntitled)
        XCTAssertTrue(model.proActionsLocked)

        // 2) Signed-in external guest without billing loaded yet -> locked
        model.auth.previewSignedIn(UserProfile(id: "g1", email: "free@example.com", name: "Free", picture: nil, guest: true))
        XCTAssertFalse(model.isProEntitled)
        XCTAssertTrue(model.proActionsLocked)

        // 3) Signed-in external guest with non-entitled billing -> locked
        model.billing = BillingSummary(plan: "free", status: "none", entitled: false, pro_required: true, price_usd_monthly: 19, current_period_end: nil, cancel_at_period_end: false, has_customer: false, checkout_available: true)
        XCTAssertFalse(model.isProEntitled)
        XCTAssertTrue(model.proActionsLocked)

        // 4) Signed-in external Pro subscriber -> unlocked
        model.billing = BillingSummary(plan: "pro", status: "active", entitled: true, pro_required: true, price_usd_monthly: 19, current_period_end: nil, cancel_at_period_end: false, has_customer: true, checkout_available: true)
        XCTAssertTrue(model.isProEntitled)
        XCTAssertFalse(model.proActionsLocked)

        // 5) Company team member -> unlocked even before billing finishes loading
        model.billing = nil
        model.auth.previewSignedIn(UserProfile(id: "c1", email: "dan@sundayable.com", name: "Dan", picture: nil, guest: false))
        XCTAssertTrue(model.isProEntitled)
        XCTAssertFalse(model.proActionsLocked)
    }

    func testLockedProActionsRefuseEditingAndKeepStoredBindingsInactive() async {
        let customEnglish = TriggerKind.modifierHold(keys: [.option, .shift], mode: .english, holdMilliseconds: 180)
        let customTidy = TidyShortcut(keyCode: 35, modifiers: 0x1800) // Ctrl+Opt+P
        let model = makeModel([rightOption, mouse5])
        model.triggers = [fn, customEnglish]
        model.tidyKeys = [customTidy]

        // Locked (signed-out free local)
        XCTAssertTrue(model.proActionsLocked)
        model.captureKey(for: .english, replacing: customEnglish)
        XCTAssertFalse(model.capturing, "Pro-only English action must never start capture when locked")
        model.captureTidyKey(replacing: customTidy)
        XCTAssertFalse(model.capturing, "Pro-only Polish action must never start capture when locked")
        model.apply(rightOption.with(mode: .english), to: .english, replacing: customEnglish)
        model.removeTrigger(customEnglish)
        model.removeTidyKey(customTidy)
        XCTAssertEqual(model.triggers, [fn, customEnglish], "stored Pro dictation shortcut must remain untouched")
        XCTAssertEqual(model.tidyKeys, [customTidy], "stored Pro polish shortcut must remain untouched")

        // Runtime filtering keeps Pro shortcuts inactive without wiping stored bindings
        XCTAssertEqual(OnboardingModel.activeTriggers(from: model.triggers, proEntitled: false), [fn])
        XCTAssertEqual(OnboardingModel.activeTriggers(from: model.triggers, proEntitled: true), [fn, customEnglish])
        XCTAssertEqual(OnboardingModel.activeTidyShortcuts(from: model.tidyKeys, proEntitled: false), [])
        XCTAssertEqual(OnboardingModel.activeTidyShortcuts(from: model.tidyKeys, proEntitled: true), [customTidy])

        // Editing bilingual Dictate still works freely and preserves stored Pro shortcut
        model.captureKey(for: .bilingual, replacing: fn)
        await settle()
        XCTAssertEqual(model.triggers, [rightOption, customEnglish])
        XCTAssertEqual(Prefs.triggers, [rightOption, customEnglish])

        // Restore defaults while locked only resets bilingual and keeps stored Pro shortcuts intact
        model.resetTriggers()
        XCTAssertEqual(model.triggers, [fn, customEnglish])
        XCTAssertEqual(model.tidyKeys, [customTidy])
    }

    func testEntitledProUserCanEditProShortcuts() async {
        let customEnglish = TriggerKind.modifierHold(keys: [.option, .shift], mode: .english, holdMilliseconds: 180)
        let model = makeModel([customEnglish])
        model.auth.previewSignedIn(UserProfile(id: "p1", email: "pro@example.com", name: "Pro", picture: nil, guest: true))
        model.billing = BillingSummary(plan: "pro", status: "active", entitled: true, pro_required: true, price_usd_monthly: 19, current_period_end: nil, cancel_at_period_end: false, has_customer: true, checkout_available: true)
        model.triggers = [fn, fnShift]

        XCTAssertFalse(model.proActionsLocked)
        model.captureKey(for: .english, replacing: fnShift)
        XCTAssertTrue(model.capturing)
        await settle()
        XCTAssertEqual(model.primaryTrigger(for: .english), customEnglish)
    }

    func testUpgradeFlowRoutesSignedOutToSignInFirstAndSignedInToCheckout() {
        let model = makeModel()
        // Signed-out user -> sign-in first
        model.startProUpgradeFlow()
        XCTAssertTrue(model.pendingProUpgradeAfterSignIn)
        model.auth.cancelSignIn()
        model.pendingProUpgradeAfterSignIn = false

        // Signed-in non-Pro user -> checkout flow directly (no sign-in flag)
        model.auth.previewSignedIn(UserProfile(id: "g1", email: "free@example.com", name: "Free", picture: nil, guest: true))
        model.billing = BillingSummary(plan: "free", status: "none", entitled: false, pro_required: true, price_usd_monthly: 19, current_period_end: nil, cancel_at_period_end: false, has_customer: false, checkout_available: true)
        model.startProUpgradeFlow()
        XCTAssertFalse(model.pendingProUpgradeAfterSignIn)
        XCTAssertTrue(model.billingActionPending)
    }

    func test0328NoDeadStateForNonProSignInCancelSignOutAndProToggle() {
        let savedLocalPref = UserDefaults.standard.object(forKey: "localDictationEnabled")
        defer {
            if let savedLocalPref { UserDefaults.standard.set(savedLocalPref, forKey: "localDictationEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "localDictationEnabled") }
        }
        Prefs.localDictationEnabled = false

        let model = makeModel()
        model.isPreview = true

        // 1) Signed-out Free Local works automatically
        XCTAssertTrue(model.effectiveLocalDictation)
        XCTAssertFalse(model.needsProUpgrade)

        // 2) Signed in as non-Pro -> NEVER stuck in broken cloud mode; stays in Free Local Mode
        model.auth.previewSignedIn(UserProfile(id: "g-free", email: "free@gmail.com", name: "Free", picture: nil, guest: true))
        model.billing = BillingSummary(plan: "free", status: "none", entitled: false, pro_required: true, price_usd_monthly: 19, current_period_end: nil, cancel_at_period_end: false, has_customer: false, checkout_available: true)
        XCTAssertTrue(model.effectiveLocalDictation, "signed-in non-Pro must stay in Free Local Mode")
        XCTAssertFalse(model.needsProUpgrade, "Pro upgrade step must never trap non-Pro users")

        // Closing onboarding window or canceling checkout returns cleanly to Free Local Mode without pinning Prefs
        model.step = .proUpgrade
        model.handleWindowClosed()
        XCTAssertTrue(model.dismissedProUpgrade)
        XCTAssertTrue(model.effectiveLocalDictation)
        XCTAssertFalse(Prefs.localDictationEnabled, "non-Pro fallback must not permanently pin local pref after future upgrade")

        // 3) Sign out -> Free Local Mode still works
        model.auth.previewSignedIn(nil)
        model.billing = nil
        XCTAssertTrue(model.effectiveLocalDictation)

        // 4) Pro subscriber / Company team -> Cloud by default, one-click toggle to Local and back
        model.auth.previewSignedIn(UserProfile(id: "p1", email: "pro@gmail.com", name: "Pro", picture: nil, guest: true))
        model.billing = BillingSummary(plan: "pro", status: "active", entitled: true, pro_required: true, price_usd_monthly: 19, current_period_end: nil, cancel_at_period_end: false, has_customer: true, checkout_available: true)
        XCTAssertFalse(model.effectiveLocalDictation, "entitled Pro defaults to Cloud")
        model.switchToFreeLocalMode()
        XCTAssertTrue(model.effectiveLocalDictation)
        XCTAssertTrue(Prefs.localDictationEnabled)
        model.switchToCloudProMode()
        XCTAssertFalse(model.effectiveLocalDictation)
        XCTAssertFalse(Prefs.localDictationEnabled)

        // Company team member -> Cloud by default
        model.billing = nil
        model.auth.previewSignedIn(UserProfile(id: "c1", email: "dan@sundayable.com", name: "Dan", picture: nil, guest: false))
        XCTAssertFalse(model.effectiveLocalDictation)

        // 5) 402 without local model maps to two-button Download local / Upgrade HUD action
        XCTAssertEqual(AppDelegate.action(.server("subscription_required_local_missing")), .downloadLocalOrUpgrade)
        XCTAssertNotEqual(AppDelegate.message(.server("subscription_required_local_missing")), "hud.error.subscriptionLocalMissing")
    }

    func test0328StringsExistInBothLanguages() {
        let keys = [
            "mode.status.freeLocal", "mode.status.freeLocalUpgrade", "mode.status.proCloud",
            "mode.switch.toLocal", "mode.switch.toProCloud", "mode.picker.local", "mode.picker.pro",
            "mode.general.freeLocalNote", "mode.general.proCloudNote", "mode.general.proLocalNote",
            "mode.general.downloadModel", "mode.general.downloadingModel", "menu.downloadLocalModel",
            "hud.error.subscriptionLocalMissing", "hud.button.downloadLocal", "billing.freeLocalReadyNote",
        ]
        for language in ["en", "ko"] {
            UILanguage.choice = language
            for key in keys {
                let value = L(key)
                XCTAssertNotEqual(value, key, "\(key) missing in \(language)")
                XCTAssertFalse(value.contains("대표님"), "\(key) must not contain 대표님")
            }
        }
        UILanguage.choice = "ko"
        XCTAssertEqual(L("mode.status.freeLocalUpgrade"), "무료 로컬 모드로 쓰는 중 · Pro로 업그레이드")
    }

    func testAnonymousStatsDefaultOffMakesZeroNetworkCallsInLocalMode() async {
        let savedEnabled = UserDefaults.standard.object(forKey: "anonymousStatsEnabled")
        defer {
            if let savedEnabled { UserDefaults.standard.set(savedEnabled, forKey: "anonymousStatsEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "anonymousStatsEnabled") }
        }
        UserDefaults.standard.removeObject(forKey: "anonymousStatsEnabled")
        XCTAssertFalse(Prefs.anonymousStatsEnabled, "anonymous usage stats MUST default OFF")

        let stats = AnonymousStats()
        var requests: [URLRequest] = []
        stats.sendRequest = { req in requests.append(req) }

        stats.recordDictation(localMode: true)
        stats.recordError("no_speech", localMode: true)
        stats.recordOnboardingStep(.keys, localMode: true)
        await settle()
        XCTAssertTrue(requests.isEmpty, "zero network calls allowed when anonymous stats are OFF in local mode")
    }

    func testAnonymousStatsOptInSendsOnlyAllowlistedFieldsAndResettableID() async throws {
        let savedEnabled = UserDefaults.standard.object(forKey: "anonymousStatsEnabled")
        let savedID = UserDefaults.standard.object(forKey: "anonymousStatsInstallID")
        defer {
            if let savedEnabled { UserDefaults.standard.set(savedEnabled, forKey: "anonymousStatsEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "anonymousStatsEnabled") }
            if let savedID { UserDefaults.standard.set(savedID, forKey: "anonymousStatsInstallID") }
            else { UserDefaults.standard.removeObject(forKey: "anonymousStatsInstallID") }
        }
        Prefs.anonymousStatsEnabled = true
        let id1 = Prefs.anonymousStatsInstallID
        let id2 = Prefs.resetAnonymousStatsInstallID()
        XCTAssertNotEqual(id1, id2, "install ID must be resettable to a new random UUID")
        XCTAssertNotNil(UUID(uuidString: id2))

        let stats = AnonymousStats()
        var bodies: [[String: Any]] = []
        stats.sendRequest = { req in
            XCTAssertNil(req.value(forHTTPHeaderField: "Authorization"), "anonymous stats never send auth headers")
            if let data = req.httpBody, let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                bodies.append(obj)
            }
        }

        stats.recordDictation(localMode: true)
        stats.recordError("arbitrary user transcript text should never leak", localMode: true)
        stats.recordOnboardingStep(.done, localMode: false)
        await settle()

        XCTAssertEqual(bodies.count, 3)
        let allowedKeys: Set<String> = ["install_id", "day", "app_version", "mode", "dictation_count", "error_code", "onboarding_step"]
        for b in bodies {
            XCTAssertTrue(Set(b.keys).isSubset(of: allowedKeys), "disallowed key in stats payload: \(b.keys)")
            XCTAssertEqual(b["install_id"] as? String, id2)
        }
        XCTAssertEqual(bodies[0]["mode"] as? String, "local")
        XCTAssertEqual(bodies[0]["dictation_count"] as? Int, 1)
        XCTAssertEqual(bodies[1]["error_code"] as? String, "unknown", "raw text must collapse to coarse allowlist")
        XCTAssertEqual(bodies[2]["mode"] as? String, "pro")
        XCTAssertEqual(bodies[2]["onboarding_step"] as? String, "done")
    }

    func testProductUpdatesRequiresExplicitConsentAndValidEmail() async throws {
        let client = ProductUpdatesClient()
        var requests: [URLRequest] = []
        client.sendRequest = { req in
            requests.append(req)
            let resp = HTTPURLResponse(url: req.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data("{\"ok\":true}".utf8), resp)
        }

        do {
            try await client.subscribe(email: "user@example.com", consent: false, source: .onboardingDone)
            XCTFail("must reject without explicit consent")
        } catch let e as ProductUpdatesError {
            XCTAssertEqual(e, .consentRequired)
        }
        do {
            try await client.subscribe(email: "not-an-email", consent: true, source: .onboardingDone)
            XCTFail("must reject invalid email")
        } catch let e as ProductUpdatesError {
            XCTAssertEqual(e, .invalidEmail)
        }
        XCTAssertTrue(requests.isEmpty)

        try await client.subscribe(email: " User@Example.com ", consent: true, source: .settingsAccount, locale: "ko")
        XCTAssertEqual(requests.count, 1)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: try XCTUnwrap(requests[0].httpBody)) as? [String: Any])
        XCTAssertEqual(json["email"] as? String, "user@example.com")
        XCTAssertEqual(json["consent"] as? Bool, true)
        XCTAssertEqual(json["source"] as? String, "settings_account")
        XCTAssertEqual(json["locale"] as? String, "ko")
    }

    func test0329StringsExistInBothLanguages() {
        let keys = [
            "stats.sectionTitle", "stats.toggleTitle", "stats.toggleBody", "stats.neverSent",
            "stats.localHonestNote", "stats.resetID", "stats.resetIDDone", "stats.privacyLink", "stats.termsLink",
            "updates.title", "updates.body", "updates.emailPlaceholder", "updates.consentCheckbox",
            "updates.submit", "updates.submitting", "updates.subscribed", "updates.error",
            "ob.done.optionalSection", "ob.welcome.local.body", "settings.account.localBody",
        ]
        for language in ["en", "ko"] {
            UILanguage.choice = language
            for key in keys {
                let value = L(key)
                XCTAssertNotEqual(value, key, "\(key) missing in \(language)")
                XCTAssertFalse(value.contains("대표님"), "\(key) must not contain 대표님")
            }
        }
    }

    func test0330InterruptedAndLocalEmptyHUDMapping() {
        for language in ["en", "ko"] {
            UILanguage.choice = language
            let interrupted = AppDelegate.message(.server("interrupted_saved"))
            let localEmpty = AppDelegate.message(.server("local_empty_saved"))
            XCTAssertNotEqual(interrupted, "dictation.interruptedSaved")
            XCTAssertNotEqual(localEmpty, "dictation.localEmptySaved")
            XCTAssertFalse(interrupted.contains("대표님"))
            XCTAssertFalse(localEmpty.contains("대표님"))
        }
        XCTAssertEqual(AppDelegate.action(.server("interrupted_saved")), .retryTranscription)
        XCTAssertEqual(AppDelegate.action(.server("local_empty_saved")), .retryTranscription)
    }

    func testCaptureSetsLiveConfirmationMessage() async {
        UILanguage.choice = "en"
        let model = makeModel([mouse5])
        model.captureKey(for: .bilingual, replacing: fn)
        await settle()
        XCTAssertEqual(model.captured, "Mouse side button (Forward)")
        XCTAssertEqual(model.capturedConfirmation, L("keys.capture.confirmedHold", "Mouse side button (Forward)"))
    }

    func testGoogleCalendarFlagGating() {
        let model = makeModel()
        XCTAssertFalse(model.googleCalendarAllowed, "signed out")
        model.auth.previewSignedIn(UserProfile(id: "c1", email: "dan@sundayable.com", name: "Dan", picture: nil, guest: false))
        XCTAssertTrue(model.googleCalendarAllowed, "company accounts stay live")
        model.auth.previewSignedIn(UserProfile(id: "g1", email: "buyer@gmail.com", name: "Buyer", picture: nil, guest: true))
        model.features = AccountFeatures(connections: false, cloud: true, google_calendar: false, watch: false)
        XCTAssertFalse(model.googleCalendarAllowed, "external Pro stays behind server flag while OAuth verification is pending")
        model.features = AccountFeatures(connections: false, cloud: true, google_calendar: true, watch: false)
        XCTAssertTrue(model.googleCalendarAllowed, "external Pro opens immediately once server flag flips on")
    }

    func testLocalWordsModelSavesEditsAndRemovesOffline() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sv-local-words-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dict = LocalPersonalDictionary(fileURL: dir.appendingPathComponent("local-replacements.json"))
        let words = LocalWordsModel(dictionary: dict)
        XCTAssertTrue(words.rules.isEmpty)

        words.fromText = "버셀"
        words.toText = "Vercel"
        words.saveEntry()
        XCTAssertEqual(words.rules, [LocalReplacementRule(from: "버셀", to: "Vercel")])
        XCTAssertEqual(words.fromText, "")
        XCTAssertEqual(dict.apply(to: "버셀에 배포해 줘"), "Vercel에 배포해 줘")

        words.edit(words.rules[0])
        words.toText = "Vercel Pro"
        words.saveEntry()
        XCTAssertEqual(words.rules, [LocalReplacementRule(from: "버셀", to: "Vercel Pro")])

        words.remove(words.rules[0])
        XCTAssertTrue(words.rules.isEmpty)
        XCTAssertTrue(dict.loadRules().isEmpty)
    }

    /// Regression for the 0.3.19–0.3.25 SwiftUI MainActor.assumeIsolated EXC_BAD_ACCESS crash:
    /// calling `buildMenu()` repeatedly inside `Task { @MainActor }` previously re-inserted retained
    /// `NSMenuItem` instances into a new `NSMenu`, throwing `NSInternalInconsistencyException` and
    /// corrupting the main thread's Swift Concurrency executor TLS.
    func testRepeatedBuildMenuNeverThrowsOrCorruptsMainActorExecutor() async {
        let prevDev = WakeController.developerEnabled
        defer { WakeController.developerEnabled = prevDev }
        WakeController.developerEnabled = true
        let delegate = AppDelegate()
        delegate.status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        defer { NSStatusBar.system.removeStatusItem(delegate.status) }
        for i in 0..<30 {
            UILanguage.choice = i % 2 == 0 ? "ko" : "en"
            await Task { @MainActor in
                delegate.buildMenu()
                delegate.render(.idle)
            }.value
            let ok = MainActor.assumeIsolated {
                delegate.status.menu === delegate.updateItem.menu
                    && delegate.status.menu === delegate.tidyItem.menu
                    && delegate.status.menu === delegate.meetingItem.menu
                    && delegate.status.menu === delegate.wakeItem.menu
            }
            XCTAssertTrue(ok, "iteration \(i): retained items must belong to the active status menu")
        }
    }

    func testWakeWordsHiddenAndDisabledByDefaultAndLoadsLocalPrivateConfig() throws {
        let prevDev = UserDefaults.standard.object(forKey: "wakeDeveloperEnabled")
        let prevEnabled = UserDefaults.standard.object(forKey: "wakeEnabled")
        defer {
            if let prevDev { UserDefaults.standard.set(prevDev, forKey: "wakeDeveloperEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "wakeDeveloperEnabled") }
            if let prevEnabled { UserDefaults.standard.set(prevEnabled, forKey: "wakeEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "wakeEnabled") }
        }
        UserDefaults.standard.removeObject(forKey: "wakeDeveloperEnabled")
        UserDefaults.standard.removeObject(forKey: "wakeEnabled")

        let emptyConfigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wake-missing-\(UUID().uuidString).json")
        XCTAssertFalse(WakeController.developerEnabled)
        XCTAssertFalse(WakeController.enabled)
        XCTAssertFalse(WakeController.isFeatureVisible(configURL: emptyConfigURL))
        XCTAssertNil(WakeTargetStore.target(id: "chat", from: emptyConfigURL))

        // Private local config unlocks custom targets without hard-coding anything in source.
        let tempConfigURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("wake-targets-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tempConfigURL) }
        let sample = WakeTargetConfig(
            menuLabel: "Custom",
            targets: [WakeTarget(id: "teamchat", displayName: "Team Chat", bundleID: "com.tinyspeck.slackmacgap")]
        )
        try JSONEncoder().encode(sample).write(to: tempConfigURL)
        XCTAssertTrue(WakeController.isFeatureVisible(configURL: tempConfigURL))
        XCTAssertEqual(WakeTargetStore.target(id: "teamchat", from: tempConfigURL)?.bundleID, "com.tinyspeck.slackmacgap")
        XCTAssertTrue(WakeController.menuTitle(configURL: tempConfigURL).contains("Custom"))
    }

    func testPerActionAutoEnterDefaultsOffAndRespectsEntitlement() {
        let prevBi = UserDefaults.standard.object(forKey: "autoEnterBilingual")
        let prevEn = UserDefaults.standard.object(forKey: "autoEnterEnglish")
        defer {
            if let prevBi { UserDefaults.standard.set(prevBi, forKey: "autoEnterBilingual") }
            else { UserDefaults.standard.removeObject(forKey: "autoEnterBilingual") }
            if let prevEn { UserDefaults.standard.set(prevEn, forKey: "autoEnterEnglish") }
            else { UserDefaults.standard.removeObject(forKey: "autoEnterEnglish") }
        }
        UserDefaults.standard.removeObject(forKey: "autoEnterBilingual")
        UserDefaults.standard.removeObject(forKey: "autoEnterEnglish")

        let engine = MockDictationEngine()
        let auth = AuthService()
        let api = APIClient(auth: auth)
        let model = OnboardingModel(auth: auth, api: api, monitor: PermissionMonitor(), engine: engine)

        XCTAssertFalse(model.autoEnterEnabled(for: .bilingual))
        XCTAssertFalse(model.autoEnterEnabled(for: .english))

        // Free Local Mode (signed out): bilingual auto-Enter works, English (Pro-only) stays locked.
        model.setAutoEnter(true, for: .bilingual)
        XCTAssertTrue(model.autoEnterEnabled(for: .bilingual))
        XCTAssertEqual(engine.autoEnterModes, [.bilingual])

        model.setAutoEnter(true, for: .english)
        XCTAssertFalse(model.autoEnterEnabled(for: .english))
        XCTAssertEqual(engine.autoEnterModes, [.bilingual])

        // Active mode helper enforces entitlement at runtime too.
        XCTAssertEqual(OnboardingModel.activeAutoEnterModes(bilingual: true, english: true, proEntitled: false), [.bilingual])
        XCTAssertEqual(OnboardingModel.activeAutoEnterModes(bilingual: true, english: true, proEntitled: true), [.bilingual, .english])
        XCTAssertEqual(OnboardingModel.activeAutoEnterModes(bilingual: false, english: true, proEntitled: true), [.english])
    }

    func testSendByVoiceDefaultsOnCustomPhrasesAndScopeSyncToEngine() {
        let prevOn = UserDefaults.standard.object(forKey: "sendByVoiceEnabled")
        let prevPhrases = UserDefaults.standard.object(forKey: "sendByVoicePhrasesText")
        let prevAll = UserDefaults.standard.object(forKey: "sendByVoiceAllApps")
        defer {
            if let prevOn { UserDefaults.standard.set(prevOn, forKey: "sendByVoiceEnabled") }
            else { UserDefaults.standard.removeObject(forKey: "sendByVoiceEnabled") }
            if let prevPhrases { UserDefaults.standard.set(prevPhrases, forKey: "sendByVoicePhrasesText") }
            else { UserDefaults.standard.removeObject(forKey: "sendByVoicePhrasesText") }
            if let prevAll { UserDefaults.standard.set(prevAll, forKey: "sendByVoiceAllApps") }
            else { UserDefaults.standard.removeObject(forKey: "sendByVoiceAllApps") }
        }
        UserDefaults.standard.removeObject(forKey: "sendByVoiceEnabled")
        UserDefaults.standard.removeObject(forKey: "sendByVoicePhrasesText")
        UserDefaults.standard.removeObject(forKey: "sendByVoiceAllApps")

        let engine = MockDictationEngine()
        let auth = AuthService()
        let api = APIClient(auth: auth)
        let model = OnboardingModel(auth: auth, api: api, monitor: PermissionMonitor(), engine: engine)

        XCTAssertTrue(model.sendByVoiceEnabled, "Send by voice defaults ON")
        XCTAssertFalse(model.sendByVoiceAllApps, "Chat-only safety list defaults ON")
        XCTAssertEqual(EndPhrase.parsePhrases(model.sendByVoicePhrasesText), EndPhrase.defaultSendPhrases)

        model.setSendByVoicePhrasesText("전송, ship it")
        XCTAssertEqual(engine.sendByVoicePhrases, ["전송", "ship it"])

        model.setSendByVoiceAllApps(true)
        XCTAssertTrue(engine.sendByVoiceAllApps)

        model.setSendByVoiceEnabled(false)
        XCTAssertFalse(engine.sendByVoiceEnabled)

        model.resetSendByVoicePhrases()
        XCTAssertEqual(engine.sendByVoicePhrases, EndPhrase.defaultSendPhrases)
    }
}

/// 0.3.25: offline local dictation sends no dictation text or dictation events to Sunday Voice servers.
@MainActor
final class LocalModePrivacyTests: XCTestCase {
    func testOfflineLocalDictationUploadsNoDictationTextOrEvents() {
        XCTAssertFalse(Diagnostics.uploadsDeliveredText(localDictation: true))
        XCTAssertTrue(Diagnostics.uploadsDeliveredText(localDictation: false), "cloud history keeps working for consented users")
        for name in ["dictation_start", "dictation_success", "dictation_fail", "dictation_stop"] {
            XCTAssertFalse(Diagnostics.uploadsEvent(name, localDictation: true), name)
            XCTAssertTrue(Diagnostics.uploadsEvent(name, localDictation: false), name)
        }
        XCTAssertTrue(Diagnostics.uploadsEvent("app_launch", localDictation: true), "content-free app events are unrelated to a dictation")
    }
}
