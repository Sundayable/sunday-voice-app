import AppKit
import Combine
import LocalMeetingEngine
import SwiftUI
import DictationEngine

@MainActor
private final class GalleryMeetingService: MeetingServiceProviding {
    var recordingContext: RecordingMeetingContext?
    var phase: MeetingPhase = .idle
    var statusMessage = "Meeting audio stays on this Mac."
    var segments: [MeetingSegment] = []
    var elapsedSeconds: TimeInterval = 0
    var modelReady = true
    var lastSavedURL: URL?
    var setupProgress: Double = 0
    var captureWarning: String?
    var transcription: MeetingTranscriptionState = .idle
    var speakerModelReady = true
    var lastTranscriptURL: URL?
    var keepsAudio = false
    var transcriptDirectory = URL(fileURLWithPath: "/private/tmp/sunday-voice-gallery-unused")
    var meetingChanges: AnyPublisher<Void, Never> { Empty().eraseToAnyPublisher() }
    func prepareModel() async throws {}
    func start() async throws {}
    func stop() async {}
    func resumePendingTranscriptions() {}
    func cancelTranscription() {}
}

private final class GalleryMeetingDetector: MeetingDetecting {
    var onCandidate: (@MainActor (MeetingCandidate) -> Void)?
    var onPresence: (@MainActor (MeetingDetectionSnapshot) -> Void)?
    func start() {}
    func stop() {}
    func dismissCurrentCandidate() {}
}

@MainActor
private final class GalleryMeetingCalendar: MeetingCalendarProviding {
    var onEvents: (([CalendarMeeting]) -> Void)?
    var onStatus: ((String) -> Void)?
    func start() {}
    func stop() {}
    func requestAccess() async {}
}

/// `--gallery <dir>`: renders every onboarding screen in its important states, light + dark,
/// English + Korean, to PNG. No permission prompts, no microphone, no event tap, no network.
@MainActor
enum Gallery {
    struct Shot { let name: String; let configure: (OnboardingModel) -> Void }

    static let sampleCards = [
        "en": "- Warm but brief; gets to the point in the first line.\n- Opens with \"Hi <name>,\" in email; no greeting in chat.\n- Short paragraphs and bullet lists for anything with steps.\n- Signs off \"Thanks!\" — rarely more formal.\n- Chat: lowercase starts, the odd emoji; email: full sentences.",
        "ko": "- 메일은 합니다체, 내부 채팅은 해요체와 반말을 섞음.\n- 문장은 짧고, 할 일이 많으면 줄바꿈과 목록을 씀.\n- 인사는 '안녕하세요 <이름>님', 끝은 '감사합니다'.\n- 서비스·툴 이름은 영어 그대로 씀.\n- 이모지는 채팅에서만 가끔.",
    ]

    static var shots: [Shot] {
        var list: [Shot] = []
        func add(_ name: String, _ c: @escaping (OnboardingModel) -> Void) { list.append(Shot(name: name, configure: c)) }
        let user = UserProfile(id: "preview", email: "you@company.com", name: "You", picture: nil)
        add("01-signin") { m in m.auth.previewSignedIn(nil); m.step = .signIn }
        add("01-consent") { m in m.auth.previewSignedIn(user); m.auth.previewNeedsConsent(); m.step = .signIn }
        add("01-signin-done") { m in m.auth.previewSignedIn(user); m.step = .signIn }
        add("01b-pro-upgrade") { m in
            m.auth.previewSignedIn(UserProfile(id: "ext", email: "user@gmail.com", name: "Minji", picture: nil, guest: true))
            m.step = .proUpgrade
        }
        add("04b-local-model-download") { m in
            m.auth.previewSignedIn(nil); m.step = .localModel; m.localModelReady = false
        }
        add("04b-local-model-progress") { m in
            m.auth.previewSignedIn(nil); m.step = .localModel; m.localModelReady = false; m.localModelDownloading = true; m.localModelProgress = 0.42
        }
        add("04b-local-model-ready") { m in
            m.auth.previewSignedIn(nil); m.step = .localModel; m.localModelReady = true
        }
        add("04-keys-local-mode") { m in
            m.auth.previewSignedIn(nil); m.step = .keys; m.triggers = Prefs.defaultTriggers; m.keyTest.listening = true
        }
        add("07-try-local-missing") { m in
            m.auth.previewSignedIn(nil); m.step = .tryIt; m.localModelReady = false
        }
        add("02-permissions-none") { m in m.auth.previewSignedIn(user); m.step = .permissions; m.permissions = PermissionState(microphone: .notDetermined, accessibility: false) }
        add("02-permissions-mic-on") { m in m.auth.previewSignedIn(user); m.step = .permissions; m.permissions = PermissionState(microphone: .authorized, accessibility: false) }
        add("02-permissions-retry") { m in m.auth.previewSignedIn(user); m.step = .permissions; m.permissions = PermissionState(microphone: .authorized, accessibility: false); m.retryVisible = [.accessibility] }
        add("02-permissions-all") { m in m.auth.previewSignedIn(user); m.step = .permissions; m.permissions = PermissionState(microphone: .authorized, accessibility: true) }
        add("02-permissions-input-monitoring") { m in m.auth.previewSignedIn(user); m.step = .permissions; m.permissions = PermissionState(microphone: .authorized, accessibility: true, inputMonitoringNeeded: true, inputMonitoring: false) }
        add("03-mic-quiet") { m in m.auth.previewSignedIn(user); m.step = .mic; m.micLevel = 0.01 }
        add("03-mic-heard") { m in m.auth.previewSignedIn(user); m.step = .mic; m.micLevel = 0.2; m.micHeard = true }
        add("04-keys-new-user") { m in m.auth.previewSignedIn(user); m.step = .keys; m.triggers = Prefs.defaultTriggers; m.keyTest.listening = true }
        add("04-keys-signedin-free") { m in
            m.auth.previewSignedIn(UserProfile(id: "free-user", email: "free@example.com", name: "Minji", picture: nil, guest: true))
            m.billing = BillingSummary(plan: "free", status: "none", entitled: false, pro_required: true, price_usd_monthly: 19, current_period_end: nil, cancel_at_period_end: false, has_customer: false, checkout_available: true)
            m.step = .keys; m.triggers = Prefs.defaultTriggers; m.tidyKeys = [.default]; m.keyTest.listening = true
        }
        add("04-keys-test-ok") { m in m.auth.previewSignedIn(user); m.step = .keys; m.triggers = Prefs.defaultTriggers; m.keyTest.ok = true }
        add("04-keys-fn-conflict") { m in m.auth.previewSignedIn(nil); m.step = .keys; m.triggers = Prefs.defaultTriggers; m.fnUsage = .inputSource; m.keyTest.listening = true }
        add("04-keys-fn-emoji") { m in m.auth.previewSignedIn(user); m.step = .keys; m.triggers = Prefs.defaultTriggers; m.fnUsage = .emoji; m.keyTest.listening = true }
        add("04-keys-no-fn") { m in m.auth.previewSignedIn(user); m.step = .keys; m.triggers = Prefs.defaultTriggers; m.keyTest.missedFn = true; m.keyTest.listening = true }
        add("04-keys-test-other") { m in
            m.auth.previewSignedIn(user); m.step = .keys; m.triggers = Prefs.defaultTriggers
            m.keyTest.other = .modifierHold(keys: [.rightOption], mode: .bilingual, holdMilliseconds: 180)
        }
        add("04-keys-dan") { m in
            m.auth.previewSignedIn(user); m.step = .keys
            m.triggers = [.modifierHold(keys: [.fn], mode: .bilingual, holdMilliseconds: 180), .mouseButton(number: 3, mode: .bilingual), .mouseButton(number: 4, mode: .bilingual),
                          .modifierHold(keys: [.control], mode: .bilingual, holdMilliseconds: 180), .modifierHold(keys: [.fn, .shift], mode: .english, holdMilliseconds: 180)]
            m.tidyKeys = [.default, TidyShortcut(trigger: .key(keyCode: 79, modifiers: 0, mode: .bilingual)) ?? .default]
            m.keyTest.ok = true
        }
        add("04-keys-capturing") { m in
            m.auth.previewSignedIn(user); m.step = .keys; m.triggers = Prefs.defaultTriggers; m.capturing = true; m.capturingMode = .bilingual
            m.capturingReplacement = Prefs.defaultTriggers.first
        }
        add("04-keys-move") { m in
            m.auth.previewSignedIn(user); m.step = .keys; m.triggers = Prefs.defaultTriggers
            m.pendingMove = PendingKeyMove(trigger: .modifierHold(keys: [.fn, .shift], mode: .bilingual, holdMilliseconds: 180), mode: .bilingual, replacing: Prefs.defaultTriggers.first, from: .english)
        }
        add("04-keys-typing-key") { m in m.auth.previewSignedIn(user); m.step = .keys; m.triggers = Prefs.defaultTriggers; m.keyMessage = L("keys.typingKey") }
        add("04-keys-reset-confirm") { m in m.auth.previewSignedIn(user); m.step = .keys; m.triggers = Prefs.defaultTriggers; m.confirmingReset = true; m.keyTest.ok = true }
        add("05-connect") { m in m.auth.previewSignedIn(user); m.step = .connect }
        add("05-connect-pending") { m in m.auth.previewSignedIn(user); m.step = .connect; m.connections = ["gmail": "pending", "slack": "not_connected"] }
        add("05-connect-done") { m in m.auth.previewSignedIn(user); m.step = .connect; m.connections = ["gmail": "active", "slack": "active"] }
        add("06-voice-presets") { m in m.auth.previewSignedIn(user); m.step = .voice }
        add("06-voice-build") { m in m.auth.previewSignedIn(user); m.step = .voice; m.connections = ["gmail": "active", "slack": "active"]; m.buildingVoice = true }
        add("06-voice-cards") { m in
            m.auth.previewSignedIn(user); m.step = .voice; m.connections = ["gmail": "active", "slack": "active"]
            m.cards = sampleCards; m.savedCards = sampleCards
            m.voiceStats = .init(gmail_messages: 200, slack_messages: 500, en_samples: 80, ko_samples: 80, vocab_terms: 118)
        }
        add("07-try") { m in m.auth.previewSignedIn(user); m.step = .tryIt }
        add("07-try-done") { m in m.auth.previewSignedIn(user); m.step = .tryIt; m.tryText = "내일 오후 세 시에 Lauren이랑 미팅 잡아 줘." }
        add("08-done") { m in m.auth.previewSignedIn(user); m.step = .done }
        return list
    }

    /// Four current, synthetic first-run screens for the public installation guide. No permissions,
    /// input events, live accounts or model downloads; finishes before the app installs its menu.
    static func renderTesterGuide(to dir: URL, auth: AuthService, api: APIClient, monitor: PermissionMonitor, engine: DictationEngineProtocol) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let originalLanguage = UILanguage.choice
        defer { UILanguage.choice = originalLanguage }
        UILanguage.choice = "ko"
        for shot in shots.filter({ ["01-signin", "01-consent", "02-permissions-none", "04-keys-new-user", "07-try-done"].contains($0.name) }) {
            let model = OnboardingModel(auth: auth, api: api, monitor: monitor, engine: engine)
            model.isPreview = true; model.fnUsage = .nothing; shot.configure(model)
            model.triggers = Prefs.defaultTriggers
            if shot.name != "01-signin" {
                model.auth.previewSignedIn(UserProfile(id: "tester-guide", email: "user@example.com", name: "Minji", picture: nil, guest: true))
            }
            if shot.name == "01-consent" { model.auth.previewNeedsConsent() }
            if shot.name == "07-try-done" { model.tryText = "내일 오후 세 시에 예약 확인해 주세요." }
            let host = NSHostingView(rootView: OnboardingView(model: model))
            host.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
            let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: .aqua); window.contentView = host
            host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(shot.name).png"))
            }
        }
        print("TESTER_GUIDE_OK 5")
    }

    static func render(to dir: URL, auth: AuthService, api: APIClient, monitor: PermissionMonitor, engine: DictationEngineProtocol) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let originalLanguage = UILanguage.choice
        defer { UILanguage.choice = originalLanguage }
        var count = 0
        for language in ["ko", "en"] {
            UILanguage.choice = language
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for shot in shots {
                    let model = OnboardingModel(auth: auth, api: api, monitor: monitor, engine: engine)
                    model.isPreview = true
                    model.fnUsage = .nothing
                    shot.configure(model)
                    let view = OnboardingView(model: model)
                    let host = NSHostingView(rootView: view)
                    host.frame = NSRect(x: 0, y: 0, width: 760, height: 600)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance)
                    window.contentView = host
                    host.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.15)) // let SwiftUI settle animations' first frame
                    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { continue }
                    host.cacheDisplay(in: host.bounds, to: rep)
                    let url = dir.appendingPathComponent("\(shot.name)-\(language)-\(appearanceName).png")
                    try? rep.representation(using: .png, properties: [:])?.write(to: url)
                    count += 1
                }
            }
        }
        // Settings window panes (including live preview Meetings coordinator).
        let previewDefaultsSuite = "SundayVoice.Gallery.\(UUID().uuidString)"
        let previewDefaults = UserDefaults(suiteName: previewDefaultsSuite) ?? .standard
        defer { UserDefaults.standard.removePersistentDomain(forName: previewDefaultsSuite) }
        func makePreviewMeetings() -> MeetingCoordinator {
            let coord = MeetingCoordinator(service: GalleryMeetingService(), detector: GalleryMeetingDetector(),
                                           defaults: previewDefaults, presentsPanels: false, calendar: GalleryMeetingCalendar())
            coord.applyPreviewState(modelReady: true, speakerModelReady: true, microphoneGranted: true, systemAudioGranted: true)
            return coord
        }

        for language in ["ko", "en"] {
            UILanguage.choice = language
            for (appearanceName, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                for (sizeName, size) in [("default", NSSize(width: 820, height: 600)), ("minimum", NSSize(width: 720, height: 520))] {
                for pane in SettingsView.Pane.allCases {
                    let model = OnboardingModel(auth: auth, api: api, monitor: monitor, engine: engine)
                    model.isPreview = true; model.fnUsage = .nothing
                    model.auth.previewSignedIn(UserProfile(id: "preview", email: "you@company.com", name: "You", picture: nil))
                    model.connections = ["gmail": "active", "slack": "active"]
                    model.cards = sampleCards; model.savedCards = sampleCards
                    model.triggers = Prefs.defaultTriggers
                    let words = VocabularyModel(api: api)
                    words.preview = true; words.list = Self.sampleVocab
                    let meetings = makePreviewMeetings()
                    let host = NSHostingView(rootView: SettingsView(model: model, words: words, pane: pane, meetings: meetings, onSignOut: {}))
                    host.frame = NSRect(origin: .zero, size: size)
                    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    window.appearance = NSAppearance(named: appearance); window.contentView = host
                    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings-\(pane.rawValue)-\(sizeName)-\(language)-\(appearanceName).png"))
                        count += 1
                    }
                }
            }
                // Locked Pro Keys states in Settings (signed-out Free Local + signed-in Free with stored binding).
                for (shotName, signedInFree, pane) in [
                    ("settings-keys-free-local", false, SettingsView.Pane.keys),
                    ("settings-keys-signedin-free", true, SettingsView.Pane.keys),
                    ("settings-general-signedin-free", true, SettingsView.Pane.general),
                ] {
                    let lockedModel = OnboardingModel(auth: auth, api: api, monitor: monitor, engine: engine)
                    lockedModel.isPreview = true; lockedModel.fnUsage = .nothing
                    if signedInFree {
                        lockedModel.auth.previewSignedIn(UserProfile(id: "free-user", email: "free@example.com", name: "Minji", picture: nil, guest: true))
                        lockedModel.billing = BillingSummary(plan: "free", status: "none", entitled: false, pro_required: true, price_usd_monthly: 19, current_period_end: nil, cancel_at_period_end: false, has_customer: false, checkout_available: true)
                    } else {
                        lockedModel.auth.previewSignedIn(nil)
                    }
                    lockedModel.triggers = Prefs.defaultTriggers
                    lockedModel.tidyKeys = [.default]
                    let lockedWords = VocabularyModel(api: api); lockedWords.preview = true
                    let lockedHost = NSHostingView(rootView: SettingsView(model: lockedModel, words: lockedWords, pane: pane, meetings: makePreviewMeetings(), onSignOut: {}))
                    lockedHost.frame = NSRect(x: 0, y: 0, width: 820, height: 600)
                    let lockedWin = NSWindow(contentRect: lockedHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    lockedWin.appearance = NSAppearance(named: appearance); lockedWin.contentView = lockedHost
                    lockedHost.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.15))
                    if let rep = lockedHost.bitmapImageRepForCachingDisplay(in: lockedHost.bounds) {
                        lockedHost.cacheDisplay(in: lockedHost.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(shotName)-\(language)-\(appearanceName).png"))
                        count += 1
                    }
                }

                // Empty "My words" state.
                let emptyModel = OnboardingModel(auth: auth, api: api, monitor: monitor, engine: engine)
                emptyModel.isPreview = true; emptyModel.fnUsage = .nothing
                emptyModel.auth.previewSignedIn(UserProfile(id: "preview", email: "you@company.com", name: "You", picture: nil))
                let emptyWords = VocabularyModel(api: api); emptyWords.preview = true; emptyWords.list = VocabList(terms: [], stats: .init(total: 0, hints: 0, replacements: 0))
                let emptyHost = NSHostingView(rootView: SettingsView(model: emptyModel, words: emptyWords, pane: .words, meetings: makePreviewMeetings(), onSignOut: {}))
                emptyHost.frame = NSRect(x: 0, y: 0, width: 820, height: 600)
                let emptyWin = NSWindow(contentRect: emptyHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                emptyWin.appearance = NSAppearance(named: appearance); emptyWin.contentView = emptyHost
                emptyHost.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                if let rep = emptyHost.bitmapImageRepForCachingDisplay(in: emptyHost.bounds) {
                    emptyHost.cacheDisplay(in: emptyHost.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("settings-words-empty-\(language)-\(appearanceName).png"))
                    count += 1
                }

                // Meeting panel states (invitation, recording pill/card, call-ended countdown, saved+progress+ETA, almost done, finished, error).
                let sampleURL = URL(fileURLWithPath: "/private/tmp/Transcript.txt")
                let meetingShots: [(String, Bool, (MeetingCoordinator) -> Void)] = [
                    ("meeting-invitation", false, { c in
                        c.applyPreviewState(panelKind: .invitation, phase: .idle, suggestedApp: "Google Meet")
                    }),
                    ("meeting-recording-pill", true, { c in
                        c.applyPreviewState(panelKind: .recording, phase: .recording, statusMessage: "Recording on this Mac — microphone + Mac audio", elapsedSeconds: 742)
                    }),
                    ("meeting-recording-card", false, { c in
                        c.applyPreviewState(panelKind: .recording, phase: .recording, statusMessage: "Recording on this Mac — microphone + Mac audio", elapsedSeconds: 742)
                    }),
                    ("meeting-ended-countdown", false, { c in
                        c.applyPreviewState(panelKind: .recording, phase: .recording, elapsedSeconds: 1167, autoStopDeadline: Date().addingTimeInterval(8))
                    }),
                    ("meeting-result-progress", false, { c in
                        c.applyPreviewState(panelKind: .result, phase: .idle,
                                            transcription: .running(progress: 0.42, pending: 1, detail: MeetingTranscriptionProgress(fraction: 0.42, processedAudioSeconds: 490, totalAudioSeconds: 1167, estimatedRemainingSeconds: 145)),
                                            lastSavedURL: sampleURL)
                    }),
                    ("meeting-result-almost-done", false, { c in
                        c.applyPreviewState(panelKind: .result, phase: .idle,
                                            transcription: .running(progress: 0.96, pending: 1, detail: MeetingTranscriptionProgress(fraction: 0.96, processedAudioSeconds: 1120, totalAudioSeconds: 1167, estimatedRemainingSeconds: 5)),
                                            lastSavedURL: sampleURL)
                    }),
                    ("meeting-result-finished", false, { c in
                        c.applyPreviewState(panelKind: .result, phase: .idle, statusMessage: "Transcript ready on this Mac.",
                                            transcription: .idle, lastSavedURL: sampleURL)
                    }),
                    ("meeting-result-error", false, { c in
                        c.applyPreviewState(panelKind: .result, phase: .failed, statusMessage: "Allow Microphone access in System Settings to record your voice.",
                                            transcription: .idle)
                    }),
                ]
                let backdrop = appearanceName == "dark" ? Color(red: 0.13, green: 0.13, blue: 0.15) : Color(red: 0.93, green: 0.93, blue: 0.94)
                for (shotName, compact, configure) in meetingShots {
                    let coord = makePreviewMeetings()
                    configure(coord)
                    let host = NSHostingView(rootView: MeetingPanelView(coordinator: coord, startCompact: compact).padding(8).background(backdrop))
                    host.frame = NSRect(origin: .zero, size: host.fittingSize)
                    let win = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                    win.appearance = NSAppearance(named: appearance); win.contentView = host
                    host.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                    if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                        host.cacheDisplay(in: host.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("\(shotName)-\(language)-\(appearanceName).png"))
                        count += 1
                    }
                }
        }
        }
        // Recording pill, every state, light + dark, both languages.
        let wave: [Float] = [0.04, 0.09, 0.2, 0.31, 0.18, 0.26, 0.12, 0.22, 0.3, 0.15, 0.08, 0.19, 0.1, 0.05]
        let pills: [(String, HUDState)] = [
            ("preparing", .preparing(mode: "bilingual", connecting: false)), ("connecting", .preparing(mode: "bilingual", connecting: true)),
            ("listening-original", .listening(mode: "bilingual", meter: true)), ("listening-en", .listening(mode: "translate", meter: true)),
            ("processing", .processing(mode: "translate")), ("done", .done), ("pending", .pending),
            ("error-mic", .error(L("error.micPermission"), .microphoneSettings)), ("error-short", .error(L("error.tooShort"), .close)),
            ("error-quota", .error(L("error.quota"), .close)),
            ("tidying", .tidying), ("tidied", .tidied), ("tidy-unchanged", .tidyUnchanged), ("tidy-restored", .tidyRestored),
            ("tidy-error-empty", .error(L("tidy.error.empty"), .close)),
        ]
        for language in ["ko", "en"] {
            UILanguage.choice = language
            for (name, state) in pills {
                for dark in [false, true] {
                    let resolved: HUDState
                    if case .error(_, let action) = state { resolved = .error(L(name == "error-mic" ? "error.micPermission" : name == "error-quota" ? "error.quota" : name == "tidy-error-empty" ? "tidy.error.empty" : "error.tooShort"), action) } else { resolved = state }
                    if let rep = HUD.snapshot(resolved, dark: dark, level: wave) {
                        try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("hud-\(name)-\(language)-\(dark ? "dark" : "light").png"))
                        count += 1
                    }
                }
            }
            // Menu header
            for dark in [false, true] {
                let header = MenuHeaderModel(); header.state = L("menu.ready"); header.account = "you@company.com"
                let host = NSHostingView(rootView: MenuHeader(model: header).padding(.vertical, 6).background(Color(nsColor: .windowBackgroundColor)))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua); window.contentView = host
                host.layoutSubtreeIfNeeded()
                if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                    host.cacheDisplay(in: host.bounds, to: rep)
                    try? rep.representation(using: .png, properties: [:])?.write(to: dir.appendingPathComponent("menu-header-\(language)-\(dark ? "dark" : "light").png"))
                    count += 1
                }
            }
        }
        print("GALLERY_OK \(count) \(dir.path)")
    }

    /// Realistic "My words" rows, including long names and many variants, for layout checks.
    static let sampleVocab: VocabList = {
        func e(_ term: String, _ type: String, _ count: Int, hint: Bool, variants: [String] = [], manual: Bool = false) -> VocabEntry {
            VocabEntry(term: term, type: type, count: count, sources: ["gmail", "slack"], enabled: true, manual: manual, hint: hint, variants: variants)
        }
        return VocabList(terms: [
            e("Sundayable", "brand", 245, hint: true, variants: ["선데이어블", "선데이에이블", "Sunday able"]),
            e("Lauren", "person", 84, hint: true, variants: ["Loren", "Lauran", "로렌"]),
            e("Westgate Homes Development Corporation", "client", 61, hint: true, variants: ["웨스트게이트", "West gate"]),
            e("Figtree", "tool", 52, hint: true, variants: ["피그트리"]),
            e("Paris Baguette Eglinton", "client", 40, hint: true, variants: ["파리바게뜨", "파리 바게트 에글린턴", "Paris baguet"]),
            e("Composio", "tool", 33, hint: true, variants: ["컴포지오", "Compozio"]),
            e("HyperFrames", "tool", 21, hint: false),
            e("Derma 9", "client", 18, hint: true, variants: ["더마나인", "Derma nine"]),
            e("프라이데이", "other", 0, hint: false, variants: [], manual: true),
        ], stats: .init(total: 244, hints: 100, replacements: 679))
    }()
}
