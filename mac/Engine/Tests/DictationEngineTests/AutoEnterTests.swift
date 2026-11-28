import XCTest
@testable import DictationEngine

@MainActor
final class AutoEnterTests: XCTestCase {
    func testDefaultPolicyAllowsChatAppsAndBlocksEmailDocsAndBrowsers() {
        for id in [
            "com.tinyspeck.slackmacgap",
            "ru.keepcoder.Telegram",
            "com.hnc.Discord",
            "com.apple.MobileSMS",
            "com.kakao.KakaoTalkMac",
            "net.whatsapp.WhatsApp",
            "com.microsoft.teams2",
            "com.openai.chat",
            "com.anthropic.claudefordesktop",
        ] {
            XCTAssertTrue(AutoEnterPolicy.isAllowed(bundleID: id), "expected chat app \(id) to be allowed")
        }

        for id in [
            "com.apple.mail",
            "com.microsoft.Outlook",
            "com.readdle.SparkDesktop",
            "com.mimestream.Mimestream",
            "com.superhuman.electron",
            "com.apple.Notes",
            "com.apple.TextEdit",
            "com.apple.iWork.Pages",
            "com.microsoft.Word",
            "notion.id",
            "md.obsidian",
            "com.google.Chrome",
            "com.apple.Safari",
            "ca.sundayable.sunday-voice",
        ] {
            XCTAssertFalse(AutoEnterPolicy.isAllowed(bundleID: id), "expected non-chat app \(id) to be blocked")
        }
        XCTAssertFalse(AutoEnterPolicy.isAllowed(bundleID: nil))
        XCTAssertFalse(AutoEnterPolicy.isAllowed(bundleID: ""))
    }

    func testExtraAllowedBundleIDsCannotOverrideEmailAndDocBlocklist() {
        XCTAssertTrue(AutoEnterPolicy.isAllowed(bundleID: "com.example.customchat",
                                                extraAllowedBundleIDs: ["com.example.customchat"]))
        XCTAssertFalse(AutoEnterPolicy.isAllowed(bundleID: "com.apple.mail",
                                                 extraAllowedBundleIDs: ["com.apple.mail"]))
        XCTAssertFalse(AutoEnterPolicy.isAllowed(bundleID: "notion.id",
                                                 extraAllowedBundleIDs: ["notion.id"]))
    }

    func testEngineAutoEnterDefaultsOffAndRespectsPerActionModesAndSafetyGuards() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("auto-enter-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let config = EngineConfiguration(apiBaseURL: URL(string: "https://localhost")!, localDictationEnabled: true)
        XCTAssertTrue(config.autoEnterModes.isEmpty, "auto-Enter must default OFF")

        let engine = DictationEngine(
            microphone: MockAutoEnterMic(),
            pipeline: TurnPipeline(socket: FakeSocket(), rewriter: FakeRewriter { text, _ in text }),
            recovery: DictationRecoveryStore(root: dir),
            configuration: config
        )

        var returnsSent = 0
        engine.postReturnKey = { returnsSent += 1 }
        engine.frontmostPIDProvider = { 4242 }

        // Default OFF -> never fires even in Slack
        XCTAssertFalse(engine.shouldAutoEnter(mode: .bilingual, bundleID: "com.tinyspeck.slackmacgap", isHandsFree: false, isRecovery: false))
        XCTAssertFalse(engine.performAutoEnterIfSafe(mode: .bilingual, targetBundleID: "com.tinyspeck.slackmacgap", targetPID: 4242, check: .confirmed, autoEnter: false))
        XCTAssertEqual(returnsSent, 0)

        // Enable ONLY .bilingual -> fires for .bilingual in Slack, NOT for .english, NOT for Mail, NOT for recovery/handsFree
        engine.updateAutoEnterModes([.bilingual])
        XCTAssertTrue(engine.shouldAutoEnter(mode: .bilingual, bundleID: "com.tinyspeck.slackmacgap", isHandsFree: false, isRecovery: false))
        XCTAssertFalse(engine.shouldAutoEnter(mode: .english, bundleID: "com.tinyspeck.slackmacgap", isHandsFree: false, isRecovery: false))
        XCTAssertFalse(engine.shouldAutoEnter(mode: .bilingual, bundleID: "com.apple.mail", isHandsFree: false, isRecovery: false))
        XCTAssertFalse(engine.shouldAutoEnter(mode: .bilingual, bundleID: "com.tinyspeck.slackmacgap", isHandsFree: true, isRecovery: false))
        XCTAssertFalse(engine.shouldAutoEnter(mode: .bilingual, bundleID: "com.tinyspeck.slackmacgap", isHandsFree: false, isRecovery: true))

        // Paste confirmed -> sends Return
        XCTAssertTrue(engine.performAutoEnterIfSafe(mode: .bilingual, targetBundleID: "com.tinyspeck.slackmacgap", targetPID: 4242, check: .confirmed, autoEnter: true))
        XCTAssertEqual(returnsSent, 1)

        // Electron/chat app unconfirmed readback while still focused -> sends Return
        XCTAssertTrue(engine.performAutoEnterIfSafe(mode: .bilingual, targetBundleID: "ru.keepcoder.Telegram", targetPID: 4242, check: .unconfirmed, autoEnter: true))
        XCTAssertEqual(returnsSent, 2)

        // Paste failed -> MUST skip Return
        XCTAssertFalse(engine.performAutoEnterIfSafe(mode: .bilingual, targetBundleID: "com.tinyspeck.slackmacgap", targetPID: 4242, check: .failed, autoEnter: true))
        XCTAssertEqual(returnsSent, 2)

        // Focus moved to another PID -> MUST skip Return
        XCTAssertFalse(engine.performAutoEnterIfSafe(mode: .bilingual, targetBundleID: "com.tinyspeck.slackmacgap", targetPID: 9999, check: .confirmed, autoEnter: true))
        XCTAssertEqual(returnsSent, 2)

        // Email app -> MUST skip Return even if autoEnter flag passed
        XCTAssertFalse(engine.performAutoEnterIfSafe(mode: .bilingual, targetBundleID: "com.apple.mail", targetPID: 4242, check: .confirmed, autoEnter: true))
        XCTAssertEqual(returnsSent, 2)
    }

    func testSendByVoiceWorksInLocalAndCloudModesSendsReturnOnceAndRespectsSafetyList() throws {
        for localMode in [true, false] {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("send-by-voice-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }

            let config = EngineConfiguration(apiBaseURL: URL(string: "https://localhost")!, localDictationEnabled: localMode)
            XCTAssertTrue(config.sendByVoiceEnabled, "Send by voice must default ON")
            XCTAssertFalse(config.sendByVoiceAllApps, "Chat-only safety list must default ON")

            let engine = DictationEngine(
                microphone: MockAutoEnterMic(),
                pipeline: TurnPipeline(socket: FakeSocket(), rewriter: FakeRewriter { text, _ in text }),
                recovery: DictationRecoveryStore(root: dir),
                configuration: config
            )
            var returnsSent = 0
            engine.postReturnKey = { returnsSent += 1 }
            engine.frontmostPIDProvider = { 7777 }

            // 1. Allowed chat app + KO end command -> strips phrase, sets autoEnter, presses Return ONCE
            let koPrepared = engine.prepareDelivery(raw: "지금 출발해요 입력완료", mode: .bilingual,
                                                    bundleID: "com.tinyspeck.slackmacgap", isHandsFree: false, isRecovery: false)
            XCTAssertEqual(koPrepared.text, "지금 출발해요")
            XCTAssertTrue(koPrepared.autoEnter)
            XCTAssertTrue(koPrepared.triggeredByVoiceCommand)
            XCTAssertTrue(engine.performAutoEnterIfSafe(mode: .bilingual, targetBundleID: "com.tinyspeck.slackmacgap",
                                                        targetPID: 7777, check: .confirmed, autoEnter: koPrepared.autoEnter,
                                                        allowNonBlockedApps: koPrepared.allowNonBlockedApps))
            XCTAssertEqual(returnsSent, 1, "localMode=\(localMode): Return must fire once")

            // 2. Both Send by voice AND Press Enter after pasting enabled -> STILL presses Return ONCE
            engine.updateAutoEnterModes([.bilingual])
            let bothPrepared = engine.prepareDelivery(raw: "On my way, send it.", mode: .bilingual,
                                                      bundleID: "ru.keepcoder.Telegram", isHandsFree: false, isRecovery: false)
            XCTAssertEqual(bothPrepared.text, "On my way")
            XCTAssertTrue(bothPrepared.autoEnter)
            XCTAssertTrue(engine.performAutoEnterIfSafe(mode: .bilingual, targetBundleID: "ru.keepcoder.Telegram",
                                                        targetPID: 7777, check: .unconfirmed, autoEnter: bothPrepared.autoEnter,
                                                        allowNonBlockedApps: bothPrepared.allowNonBlockedApps))
            XCTAssertEqual(returnsSent, 2, "localMode=\(localMode): combined modes must never double-send Return")
            engine.updateAutoEnterModes([])

            // 3. Mid-sentence mention -> does NOT strip or send Return
            let midPrepared = engine.prepareDelivery(raw: "보내기 전에 확인해 줘", mode: .bilingual,
                                                     bundleID: "com.tinyspeck.slackmacgap", isHandsFree: false, isRecovery: false)
            XCTAssertEqual(midPrepared.text, "보내기 전에 확인해 줘")
            XCTAssertFalse(midPrepared.autoEnter)
            XCTAssertFalse(midPrepared.triggeredByVoiceCommand)

            // 4. Command-only utterance -> stripped to empty, NEVER presses Return
            let emptyPrepared = engine.prepareDelivery(raw: "입력완료", mode: .bilingual,
                                                       bundleID: "com.tinyspeck.slackmacgap", isHandsFree: false, isRecovery: false)
            XCTAssertEqual(emptyPrepared.text, "")
            XCTAssertFalse(emptyPrepared.autoEnter)
            XCTAssertTrue(emptyPrepared.triggeredByVoiceCommand)

            // 5. Blocked email/doc app (Mail, Notion) -> NEVER strips and NEVER presses Return even with allowOtherApps=true
            for blocked in ["com.apple.mail", "notion.id", "ca.sundayable.sunday-voice"] {
                engine.updateSendByVoice(enabled: true, phrases: EndPhrase.defaultSendPhrases, allowOtherApps: true)
                let blockedPrepared = engine.prepareDelivery(raw: "Send draft send it", mode: .bilingual,
                                                             bundleID: blocked, isHandsFree: false, isRecovery: false)
                XCTAssertEqual(blockedPrepared.text, "Send draft send it", "must not strip in blocked app \(blocked)")
                XCTAssertFalse(blockedPrepared.autoEnter)
                XCTAssertFalse(engine.performAutoEnterIfSafe(mode: .bilingual, targetBundleID: blocked,
                                                             targetPID: 7777, check: .confirmed, autoEnter: true,
                                                             allowNonBlockedApps: true))
            }

            // 6. Non-chat app (e.g. Terminal) blocked by default, allowed only when sendByVoiceAllApps=true
            engine.updateSendByVoice(enabled: true, phrases: EndPhrase.defaultSendPhrases, allowOtherApps: false)
            let termBlocked = engine.prepareDelivery(raw: "git status enter", mode: .bilingual,
                                                     bundleID: "com.apple.Terminal", isHandsFree: false, isRecovery: false)
            XCTAssertFalse(termBlocked.autoEnter)
            XCTAssertEqual(termBlocked.text, "git status enter")

            engine.updateSendByVoice(enabled: true, phrases: EndPhrase.defaultSendPhrases, allowOtherApps: true)
            let termAllowed = engine.prepareDelivery(raw: "git status enter", mode: .bilingual,
                                                     bundleID: "com.apple.Terminal", isHandsFree: false, isRecovery: false)
            XCTAssertEqual(termAllowed.text, "git status")
            XCTAssertTrue(termAllowed.autoEnter)
            XCTAssertTrue(engine.performAutoEnterIfSafe(mode: .bilingual, targetBundleID: "com.apple.Terminal",
                                                        targetPID: 7777, check: .confirmed, autoEnter: termAllowed.autoEnter,
                                                        allowNonBlockedApps: termAllowed.allowNonBlockedApps))
            XCTAssertEqual(returnsSent, 3)
        }
    }
}

private final class MockAutoEnterMic: EngineMicrophone {
    var onFailure: ((String) -> Void)?
    var level: Float = 0
    func prepare() {}
    func warm(keepAlive: Double) {}
    func beginStreaming(since: Double, maxPreRoll: Double, sink: @escaping (Data) -> Void) -> Double { 0 }
    func endStreaming(keepAlive: Double) {}
    func shutdown() {}
}
