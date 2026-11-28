import AppKit
import Combine
import SwiftUI
import Sparkle
import UserNotifications
import ServiceManagement
import DictationEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    lazy var auth = AuthService()
    lazy var api = APIClient(auth: auth)
    lazy var diagnostics = Diagnostics(auth: auth, api: api)
    private var consentObserver: AnyCancellable?
    private var consentPromptObserver: AnyCancellable?
    private var transcriptionObserver: AnyCancellable?
    private var languageObserver: NSObjectProtocol?
    private var consentTimer: Timer?
    private var bugWindow: NSWindow?
    let monitor = PermissionMonitor()
    let engine = EngineFactory.make()
    let hud = HUD()
    lazy var meetings = MeetingCoordinator()
    lazy var watchRecordingCalendarSync = WatchRecordingCalendarSync(api: api, calendar: meetings.googleCalendar)
    private var meetingCaptureActive = false
    private var endingSession = false
    private var terminatingAfterMeeting = false
    let meetingItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let tidyHotKey = GlobalHotKey()
    lazy var wake: WakeController? = WakeController(engine: engine)
    let wakeItem = NSMenuItem()
    let tidyItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private var tidier: Tidier?
    let selectedTextReader = SelectedTextReader()
    lazy var clipboardTidy = ClipboardTidy(hud: hud) { [weak self] in
        guard let self, self.auth.isSignedIn, let base = AppIdentity.apiBaseURL else { return nil }
        let tidier = self.tidier ?? Tidier(apiBaseURL: base, tokens: self.auth)
        self.tidier = tidier
        return { try await tidier.tidy($0) }
    }
    var status: NSStatusItem!
    var onboardingWindow: NSWindow?
    var onboarding: OnboardingModel?
    var updater: SPUStandardUpdaterController?
    let updateReminder = UpdateReminder()
    let recentTranscripts = RecentTranscripts()
    let updateItem = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    var wordsWindow: NSWindow?
    var settingsWindow: NSWindow?
    var settingsModel: OnboardingModel?
    let settingsNavigation = SettingsNavigation()
    let info = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    let header = MenuHeaderModel()
    var lastLevel: Float = 0
    private var billingEntitledOverride: Bool?

    /// True for company team accounts and paying Pro subscribers; false for signed-out or free accounts.
    var isProEntitled: Bool {
        guard auth.user != nil else { return false }
        if let billingEntitledOverride { return billingEntitledOverride }
        return auth.user?.guest != true
    }

    private func syncActiveShortcuts() {
        engine.updateTriggers(OnboardingModel.activeTriggers(from: Prefs.triggers, proEntitled: isProEntitled))
        engine.updateAutoEnterModes(
            OnboardingModel.activeAutoEnterModes(bilingual: Prefs.autoEnterBilingual,
                                                 english: Prefs.autoEnterEnglish,
                                                 proEntitled: isProEntitled),
            extraAllowedBundleIDs: Set(Prefs.autoEnterExtraBundleIDs)
        )
        _ = applyTidyKeys(OnboardingModel.activeTidyShortcuts(from: Prefs.tidyShortcuts, proEntitled: isProEntitled))
    }

    private func ensureLocalModelDownloadingIfNeeded() {
        guard effectiveLocalDictation, !meetings.modelReady, meetings.phase != .preparing else { return }
        Task { [weak self] in
            await self?.meetings.prepareModel(presentPanel: false)
            self?.buildMenu()
            self?.render(self?.engine.state ?? .idle)
        }
    }

    private func applyBillingUpdate(_ billing: BillingSummary?) {
        billingEntitledOverride = billing?.entitled
        engine.updateLocalDictationEnabled(effectiveLocalDictation)
        syncActiveShortcuts()
        if !isProEntitled { ensureLocalModelDownloadingIfNeeded() }
        buildMenu()
        render(engine.state)
    }

    func windowWillClose(_ notification: Notification) {
        if let win = notification.object as? NSWindow, win === onboardingWindow {
            onboarding?.handleWindowClosed()
            if PermissionMonitor.read(previous: nil).allGranted { startEngine() }
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Theme.registerFonts()
        if let index = CommandLine.arguments.firstIndex(of: "--vocab-dry-run") {
            // On-device extraction only (no upload): writes terms + counts to a private file for QA.
            let out = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : NSTemporaryDirectory() + "vocab-dry-run.json"
            let begin = Date(); let r = LocalHistoryImporter().run()
            let payload: [String: Any] = ["messages": r.messages, "latin": r.latin.map { ["term": $0.term, "count": $0.count, "score": $0.score, "forms": $0.forms, "cap_ratio": $0.cap_ratio ?? 0] },
                                          "hangul": r.hangul.map { ["term": $0.term, "count": $0.count, "score": $0.score, "forms": $0.forms] },
                                          "latin_counts": r.latinCounts, "hangul_counts": r.hangulCounts]
            if let data = try? JSONSerialization.data(withJSONObject: payload) {
                FileManager.default.createFile(atPath: out, contents: data, attributes: [.posixPermissions: 0o600])
            }
            print("VOCAB_DRY_RUN messages=\(r.messages) latin=\(r.latin.count) hangul=\(r.hangul.count) seconds=\(Int(Date().timeIntervalSince(begin)))")
            NSApp.terminate(nil); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--tester-guide"), CommandLine.arguments.count > index + 1 {
            Gallery.renderTesterGuide(to: URL(fileURLWithPath: CommandLine.arguments[index + 1]), auth: auth, api: api, monitor: monitor, engine: engine)
            NSApp.terminate(nil); return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--gallery") {
            let out = CommandLine.arguments.count > index + 1 ? CommandLine.arguments[index + 1] : NSTemporaryDirectory()
            Gallery.render(to: URL(fileURLWithPath: out), auth: auth, api: api, monitor: monitor, engine: engine)
            NSApp.terminate(nil); return
        }
        NSApp.setActivationPolicy(.accessory)
        // Hosting unit tests: no menu bar item, no windows, no engine.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }
        // One copy only: a second launch (e.g. a build folder copy) hands over and quits.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: AppIdentity.bundleID).filter { $0 != NSRunningApplication.current }
        if let other = others.first { other.activate(); NSApp.terminate(nil); return }
        setUpUpdater()
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        configureMeetings()
        buildMenu(); hud.prepare(); render(.idle)
        languageObserver = NotificationCenter.default.addObserver(forName: .uiLanguageDidChange, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.buildMenu()
                self.render(self.engine.state)
            }
        }
        transcriptionObserver = meetings.$transcription.receive(on: DispatchQueue.main).sink { [weak self] _ in
            guard let self else { return }
            self.updateMeetingMenuStatus()
            self.syncRuntimeActivityAndUpdates()
            self.render(self.engine.state)
        }
        meetings.startMonitoring()
        engine.localTranscriber = LocalDictationBridge()
        engine.onStateChange = { [weak self] state in
            self?.render(state)
            self?.syncRuntimeActivityAndUpdates()
        }
        engine.onSubscriptionFallbackToLocal = { [weak self] in
            guard let self else { return }
            self.billingEntitledOverride = false
            self.syncActiveShortcuts()
            self.buildMenu()
            self.render(self.engine.state)
        }
        _ = wake // installs the hands-free audio tap before any wake URL arrives
        HandsFreeCursorBridge.shared.onTrigger = { [weak self] source in
            guard let self, !self.meetingCaptureActive, !self.endingSession else { return }
            self.wake?.startAtCurrentCursor(source: source)
        }
        AnonymousStats.shared.recordFirstLaunchIfNeeded(localMode: effectiveLocalDictation)
        engine.onRecordingNotice = { [weak self] notice in
            let text: String?
            switch notice {
            case .finishingSoon(let seconds): text = L("dictation.finishingSoon", seconds)
            case .recordingLocally: text = L("dictation.recordingLocally")
            case .retrying: text = L("dictation.retrying")
            case .saveFailed: text = L("dictation.saveFailed")
            case .recoveryAvailable: text = L("dictation.audioSaved")
            case .recoveredHeld: text = L("dictation.recoveredHeld")
            case nil: text = nil
            }
            self?.hud.setRecordingNotice(text)
        }
        engine.onLevel = { [weak self] level in Task { @MainActor in self?.lastLevel = level } }
        hud.levelProvider = { [weak self] in self?.lastLevel ?? 0 }
        hud.onPaste = { [weak self] in self?.engine.pasteLastResult() }
        hud.onDiscard = { [weak self] in self?.hud.show(.hidden) }
        engine.onDelivery = { [weak self] record in
            if let self, !record.isDiagnostic {
                AnonymousStats.shared.recordDictation(localMode: self.effectiveLocalDictation)
            }
            self?.diagnostics.delivery(record)
            return self?.recentTranscripts.record(record) ?? false
        }
        auth.onDiagnosticError = { [weak self] code in self?.diagnostics.event(DiagnosticEvent("client_error", errorCode: code)) }
        engine.onDiagnostic = { [weak self] event in
            if let self, event.name == "dictation_fail" {
                AnonymousStats.shared.recordError(event.errorCode, localMode: self.effectiveLocalDictation)
            }
            self?.diagnostics.event(event)
        }
        consentObserver = auth.$consentRequired.removeDuplicates().dropFirst().sink { [weak self] required in
            Task { @MainActor in
                guard let self else { return }
                if required {
                    if self.auth.user != nil {
                        self.engine.stop()
                        self.diagnostics.reset()
                    }
                } else {
                    self.diagnostics.begin()
                    self.buildMenu()
                    if PermissionMonitor.read(previous: nil).allGranted { self.startEngine() }
                    self.render(self.engine.state)
                }
            }
        }
        consentPromptObserver = auth.$consentRequired.combineLatest(auth.$consentChecked).removeDuplicates { $0 == $1 }.sink { [weak self] required, checked in
            Task { @MainActor in
                guard let self else { return }
                if required {
                    if self.auth.user != nil && checked { self.showOnboarding(at: .signIn) }
                } else if self.onboardingWindow?.isVisible == true, self.onboarding?.step == .signIn,
                          Prefs.onboardingCompleted, PermissionMonitor.read(previous: nil).allGranted {
                    self.onboardingWindow?.close()
                }
            }
        }
        if auth.user != nil {
            if auth.isSignedIn { diagnostics.begin() }
            Task {
                do { try await auth.refreshConsent() }
                catch {
                    if self.auth.user != nil && self.auth.consentRequired {
                        self.showOnboarding(at: .signIn)
                    }
                }
            }
        }
        consentTimer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in guard let self, self.auth.user != nil else { return }; try? await self.auth.refreshConsent() }
        }
        installCopyLatestHotkey()
        hud.onUndo = { [weak self] in self?.clipboardTidy.undo() }
        applyTidyKeys(OnboardingModel.activeTidyShortcuts(from: Prefs.tidyShortcuts, proEntitled: isProEntitled))
        if auth.isSignedIn && auth.user?.guest == true {
            Task { [weak self] in
                guard let self, let summary = try? await self.api.me() else { return }
                self.applyBillingUpdate(summary.billing)
            }
        }
        engine.insertIntoOwnWindow = { [weak self] text in self?.insertIntoOwnWindow(text) ?? false }
        hud.onAction = { [weak self] action in
            switch action {
            case .retryTranscription:
                guard let self, !self.meetingCaptureActive, !self.endingSession,
                      let record = self.engine.recoveryRecords.first(where: { !$0.complete && $0.audioBytes > 0 }) else { return }
                Task { await self.engine.retryTranscription(id: record.id) }
            case .microphoneSettings: NSWorkspace.shared.open(SettingsLink.url(.microphone))
            case .accessibilitySettings: NSWorkspace.shared.open(SettingsLink.url(.accessibility))
            case .openAccount: self?.openAccountSettings()
            case .openLocalModel: self?.openLocalModelSetup()
            default: break
            }
        }
        let tryItCheck = CommandLine.arguments.contains("--tryit-check") && UserDefaults.standard.bool(forKey: "diagnostics")
        if !tryItCheck { updateLoginItem() } // a diagnostics copy must never take over the login item
        let permissions = PermissionMonitor.read(previous: nil)
        let needsBlockingConsent = auth.user != nil && auth.consentRequired
        // Dictation works as soon as permissions are in place (Free Local Mode by default when signed out;
        // Pro cloud mode once signed in and consented).
        if (auth.isSignedIn || auth.user == nil) && permissions.allGranted { startEngine() }
        if !Prefs.onboardingCompleted || !permissions.allGranted || (needsBlockingConsent && auth.consentChecked) { showOnboarding() }
        if tryItCheck { Task { await runTryItCheck(URL(string: "\(AppIdentity.urlScheme)://diagnostic/tryit")!) } }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme != AppIdentity.urlScheme {
            if GoogleCalendarAuth.handle(url) { NSApp.activate(ignoringOtherApps: true) }
        }
        for url in urls where url.scheme == AppIdentity.urlScheme {
            if url.host == "wake" { wake?.handle(url); continue }
            if url.host == "diagnostic", url.path == "/handsfree", UserDefaults.standard.bool(forKey: "diagnostics") { wake?.debugDeliver(url); continue }
            if url.host == "diagnostic", url.path == "/handsfreebench", UserDefaults.standard.bool(forKey: "diagnostics") { wake?.bench(url); continue }
            if url.host == "diagnostic", url.path == "/meeting", UserDefaults.standard.bool(forKey: "diagnostics") { runMeetingCheck(url); continue }
            if url.host == "connected" {
                onboarding?.connectedCallback(url)
                settingsModel?.connectedCallback(url)
            }
            if url.host == "billing" {
                onboarding?.billingCallback(url)
                settingsModel?.billingCallback(url)
            }
            if url.host == "auth" { auth.handleCallback(url); NSApp.activate(ignoringOtherApps: true) }
            if url.host == "diagnostic", !meetingCaptureActive, !endingSession, UserDefaults.standard.bool(forKey: "diagnostics") {
                if url.path == "/tryit" { Task { await runTryItCheck(url) } }
                else if url.path == "/tidyfixture", auth.isSignedIn, let base = AppIdentity.apiBaseURL {
                    Task { await Benchmark.runTidyFixture(apiBaseURL: base, tokens: auth) }
                } else { Task { await Benchmark.run(url, engine: engine) } }
            }
        }
    }

    /// Diagnostics only (`diagnostics` default on): records a short meeting through the real capture
    /// path and stops by itself, so an installed build can be checked end to end without a call.
    private func runMeetingCheck(_ url: URL) {
        let requested = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
            .first { $0.name == "seconds" }?.value.flatMap(Double.init) ?? 20
        let seconds = min(120, max(5, requested))
        Task { @MainActor in
            guard !meetings.isBusy else { return }
            await meetings.startRecording()
            guard meetings.phase == .recording || meetings.phase == .recovering else { return }
            try? await Task.sleep(for: .seconds(seconds))
            await meetings.stop()
        }
    }

    /// Free Local Mode is active whenever signed out, not entitled to Pro, or explicitly chosen.
    var effectiveLocalDictation: Bool { auth.user == nil || !isProEntitled || Prefs.localDictationEnabled }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if Prefs.onboardingCompleted && !(auth.user != nil && auth.consentRequired) { openSettings() } else { showOnboarding() }
        return true
    }

    /// Open at login (on by default), via the system's login-items service — no LaunchAgent.
    func updateLoginItem() {
        let service = SMAppService.mainApp
        do {
            if Prefs.openAtLogin, service.status != .enabled { try service.register() }
            if !Prefs.openAtLogin, service.status == .enabled { try service.unregister() }
        } catch { NSLog("login item: \(error.localizedDescription)") }
        NSLog("login item status=%ld", service.status.rawValue) // 1 = enabled, 2 = requires approval
    }

    // MARK: engine

    func startEngine() {
        guard !meetingCaptureActive, !endingSession else { return }
        meetings.startMonitoring()
        let local = effectiveLocalDictation
        guard auth.isSignedIn || (auth.user == nil && local) else { return }
        guard let base = AppIdentity.apiBaseURL ?? (local ? URL(string: "https://localhost") : nil) else { return }
        let activeTriggers = OnboardingModel.activeTriggers(from: Prefs.triggers, proEntitled: isProEntitled)
        let activeAutoEnter = OnboardingModel.activeAutoEnterModes(bilingual: Prefs.autoEnterBilingual,
                                                                   english: Prefs.autoEnterEnglish,
                                                                   proEntitled: isProEntitled)
        let config = EngineConfiguration(apiBaseURL: base, triggers: activeTriggers, soundsEnabled: Prefs.soundsEnabled,
                                         useRecentContext: Prefs.useRecentContext,
                                         useScreenContext: Prefs.useScreenContext,
                                         localDictationEnabled: local,
                                         autoEnterModes: activeAutoEnter,
                                         autoEnterExtraBundleIDs: Set(Prefs.autoEnterExtraBundleIDs),
                                         sendByVoiceEnabled: Prefs.sendByVoiceEnabled,
                                         sendByVoicePhrases: Prefs.sendByVoicePhrases,
                                         sendByVoiceAllApps: Prefs.sendByVoiceAllApps,
                                         keepTranscriptOnClipboard: Prefs.keepTranscriptOnClipboard)
        do { try engine.start(configuration: config, tokens: auth) } catch EngineError.inputMonitoringMissing {
            monitor.markInputMonitoringNeeded(); showOnboarding()
        } catch { showOnboarding() }
    }

    private func handleAuthChanged() {
        if auth.user == nil { billingEntitledOverride = nil }
        buildMenu()
        syncActiveShortcuts()
        if PermissionMonitor.read(previous: nil).allGranted { startEngine() }
        render(engine.state)
    }

    func render(_ state: EngineState) {
        var symbol = "mic", title = L("menu.ready")
        switch state {
        case .idle: if !hud.state.isTidy { hud.show(.hidden) }
        case .connecting: title = L("menu.connecting"); if !hud.state.isTidy { hud.show(.hidden) }
        case .preparing(let m): symbol = "mic.fill"; title = L("menu.preparing"); hud.show(.preparing(mode: m.hudMode, connecting: false))
        case .listening(let m): symbol = "mic.fill"; title = L(m == .bilingual ? "menu.listening.bilingual" : "menu.listening.translate"); hud.show(.listening(mode: m.hudMode, meter: true))
        case .processing(let m): symbol = "ellipsis.circle"; title = L("menu.processing"); hud.show(.processing(mode: m.hudMode))
        case .pasted: hud.show(.done)
        case .held: symbol = "doc.on.clipboard"; title = L("menu.pending"); hud.show(.pending)
        case .failed(let e): symbol = "exclamationmark.circle"; title = Self.message(e); hud.show(.error(title, Self.action(e)))
        }
        if meetingCaptureActive {
            symbol = "record.circle.fill"
            title = L("meeting.recording")
        } else if let detail = meetings.transcriptionDetail {
            let summary = MeetingCoordinator.transcriptionStatusSummary(detail, isKorean: UILanguage.isKorean)
            title = UILanguage.isKorean
                ? "미팅 전사 중 · \(summary.etaLabel)"
                : "Transcribing meeting · \(summary.etaLabel)"
        } else if case .idle = state {
            title = effectiveLocalDictation ? L("mode.status.freeLocal") : L("mode.status.proCloud")
        }
        info.title = title
        header.state = title
        header.account = auth.user?.email ?? (UILanguage.isKorean ? "무료 로컬 모드" : "Free Local Mode")
        // Brand letterform in the menu bar; a small system glyph beside it carries the live state.
        status?.button?.image = MenuStyle.statusImage
        status?.button?.imagePosition = .imageLeading
        let live = symbol == "mic" ? "" : " "
        status?.button?.attributedTitle = NSAttributedString(string: live, attributes: [:])
        if symbol != "mic", let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            glyph.isTemplate = true
            let attachment = NSTextAttachment(); attachment.image = glyph
            attachment.bounds = NSRect(x: 0, y: -2, width: 13, height: 13)
            status?.button?.attributedTitle = NSAttributedString(attachment: attachment)
        }
        status?.button?.toolTip = title
        status?.button?.setAccessibilityLabel("\(AppIdentity.name): \(title)")
    }

    static func message(_ e: EngineError) -> String {
        switch e {
        case .noSpeech: return L("error.noSpeech")
        case .tooShort: return L("error.tooShort")
        case .microphoneDenied: return L("error.micPermission")
        case .accessibilityMissing, .inputMonitoringMissing: return L("error.axPermission")
        case .network: return L("error.connectionLost")
        case .quotaExceeded: return L("error.quota")
        case .server("audio_saved"): return L("dictation.audioSaved")
        case .server("audio_partial_saved"): return L("dictation.partialSaved")
        case .server("interrupted_saved"): return L("dictation.interruptedSaved")
        case .server("local_empty_saved"): return L("dictation.localEmptySaved")
        case .server("local_storage_unavailable"): return L("dictation.storageUnavailable")
        case .server("local_model_missing"): return L("dictation.localModelMissing")
        case .server("subscription_required_local_missing"): return L("hud.error.subscriptionLocalMissing")
        case .server("subscription_required"), .server("STT_subscription_required"): return L("error.subscriptionRequired")
        case .server(let code) where code == "secure_field": return L("error.password")
        default: return L("error.couldNotFinish", "\(e)")
        }
    }
    static func action(_ e: EngineError) -> HUDAction {
        switch e {
        case .server("audio_saved"), .server("audio_partial_saved"), .server("interrupted_saved"), .server("local_empty_saved"): return .retryTranscription
        case .server("subscription_required_local_missing"): return .downloadLocalOrUpgrade
        case .server("subscription_required"), .server("STT_subscription_required"): return .openAccount
        case .server("local_model_missing"): return .openLocalModel
        case .microphoneDenied: return .microphoneSettings
        case .accessibilityMissing, .inputMonitoringMissing: return .accessibilitySettings
        default: return .close
        }
    }

    // MARK: menu

    func buildMenu() {
        // Reuse the existing NSMenu and detach retained items before re-adding. Creating a new NSMenu
        // while `updateItem`/`tidyItem`/`meetingItem`/`wakeItem` still belonged to the previous menu
        // threw NSInternalInconsistencyException inside Task { @MainActor }, corrupting the main
        // thread's Swift Concurrency executor TLS and crashing later SwiftUI MainActor.assumeIsolated calls.
        let menu = status?.menu ?? NSMenu()
        menu.removeAllItems()
        for retained in [updateItem, tidyItem, meetingItem, wakeItem] {
            retained.menu?.removeItem(retained)
        }
        menu.autoenablesItems = false
        let headerItem = NSMenuItem(); headerItem.isEnabled = false
        let host = NSHostingView(rootView: MenuHeader(model: header)); host.frame.size = host.fittingSize
        headerItem.view = host
        menu.addItem(headerItem); menu.addItem(.separator())
        // Shown only while a scheduled check found an update the user has not looked at yet.
        updateItem.target = self; updateItem.action = #selector(checkUpdates)
        updateItem.isHidden = updateReminder.availableVersion == nil
        if let v = updateReminder.availableVersion { updateItem.title = L("menu.updateAvailable", v); MenuStyle.apply(updateItem) }
        menu.addItem(updateItem)
        // One-obvious dictation mode / upgrade control right at the top of the menu.
        if isProEntitled {
            add(menu, effectiveLocalDictation ? L("mode.switch.toProCloud") : L("mode.switch.toLocal"), #selector(toggleDictationMode))
        } else {
            add(menu, L("mode.status.freeLocalUpgrade"), #selector(upgradeFromMenu))
            if !meetings.modelReady && meetings.phase != .preparing {
                add(menu, L("menu.downloadLocalModel"), #selector(downloadLocalModelFromMenu))
            }
        }
        menu.addItem(.separator())
        add(menu, L("menu.pasteLast"), #selector(pasteLast))
        let recentItem = NSMenuItem(title: L("menu.recent"), action: nil, keyEquivalent: "")
        let recentMenu = NSMenu(); recentMenu.autoenablesItems = false; recentMenu.delegate = self
        recentItem.submenu = recentMenu
        MenuStyle.apply(recentItem)
        menu.addItem(recentItem)
        tidyItem.title = L("menu.tidy"); tidyItem.target = self; tidyItem.action = #selector(tidyClipboard)
        MenuStyle.apply(tidyItem); menu.addItem(tidyItem)
        showTidyShortcut(isProEntitled ? Prefs.tidyShortcuts.first : nil)
        if auth.isSignedIn && auth.user?.guest != true {
            add(menu, L("menu.refreshVoice"), #selector(refreshVoice))
        }
        add(menu, L("menu.myWords"), #selector(openWords))
        add(menu, L("menu.settings"), #selector(openSettings)).keyEquivalent = ","
        menu.addItem(.separator())
        meetingItem.target = self; meetingItem.action = #selector(toggleMeeting)
        updateMeetingMenuStatus()
        menu.addItem(meetingItem)
        add(menu, L("meeting.settings"), #selector(openMeetingSettings))
        add(menu, L("meeting.folder"), #selector(openMeetingTranscripts))

        if WakeController.isFeatureVisible() {
            wakeItem.title = WakeController.menuTitle()
            wakeItem.target = self; wakeItem.action = #selector(toggleWake)
            wakeItem.state = WakeController.enabled ? .on : .off
            MenuStyle.apply(wakeItem); menu.addItem(wakeItem)
        }
        add(menu, L("menu.setup"), #selector(openSetup))
        menu.addItem(.separator())
        if updater != nil { add(menu, L("menu.updates"), #selector(checkUpdates)) }
        add(menu, UILanguage.isKorean ? "문제 신고…" : "Report a bug…", #selector(reportBug))
        if auth.isSignedIn {
            add(menu, L("menu.signOut"), #selector(signOut))
        } else {
            add(menu, L("menu.upgradePro"), #selector(openAccountSettings))
        }
        add(menu, MenuStyle.quitTitle, #selector(quit)).keyEquivalent = "q"
        status.menu = menu
    }

    private func updateMeetingMenuStatus() {
        if meetingCaptureActive {
            meetingItem.title = L("meeting.stop")
        } else if let detail = meetings.transcriptionDetail {
            let pct = Int((min(1, max(0, detail.fraction)) * 100).rounded())
            let summary = MeetingCoordinator.transcriptionStatusSummary(detail, isKorean: UILanguage.isKorean)
            meetingItem.title = UILanguage.isKorean
                ? "미팅 전사 중 · \(pct)% (\(summary.etaLabel))"
                : "Transcribing meeting · \(pct)% (\(summary.etaLabel))"
        } else {
            meetingItem.title = L("meeting.start")
        }
        MenuStyle.apply(meetingItem)
    }

    @discardableResult func add(_ menu: NSMenu, _ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: ""); item.target = self
        MenuStyle.apply(item); menu.addItem(item); return item
    }

    @objc func pasteLast() { engine.pasteLastResult() }

    @objc func toggleWake() {
        WakeController.enabled.toggle()
        wakeItem.state = WakeController.enabled ? .on : .off
    }

    // MARK: tidy clipboard

    @objc func tidyClipboard() {
        guard isProEntitled else {
            hud.show(.error(ClipboardTidy.message(TidyError.subscriptionRequired), ClipboardTidy.action(TidyError.subscriptionRequired)))
            return
        }
        let target = NSWorkspace.shared.frontmostApplication
        clipboardTidy.readSelection = { [selectedTextReader] in
            try await selectedTextReader.read(from: target, board: .general)
        }
        clipboardTidy.run()
    }

    /// Registers the global tidy keys (the "Tidy clipboard" card). Returns the ones another app already owns.
    @discardableResult func applyTidyKeys(_ keys: [TidyShortcut]) -> [TidyShortcut] {
        let failed = tidyHotKey.register(keys) { [weak self] in self?.tidyClipboard() }
        showTidyShortcut(keys.first { !failed.contains($0) })
        return failed
    }

    /// The menu shows the shortcut (it fires through the global hot key, not the menu).
    private func showTidyShortcut(_ shortcut: TidyShortcut?) {
        tidyItem.keyEquivalent = shortcut?.keyCharacter.lowercased() ?? ""
        tidyItem.keyEquivalentModifierMask = shortcut?.cocoaModifiers ?? []
    }

    // MARK: recent transcripts (local only)

    /// Rebuilt each time the "Recent transcripts" submenu opens.
    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu.supermenu != nil else { return }
        menu.removeAllItems()
        let latest = NSMenuItem(title: L("menu.recent.copyLatest"), action: #selector(copyLatestTranscript), keyEquivalent: "v")
        latest.keyEquivalentModifierMask = [.control, .option]; latest.target = self
        latest.isEnabled = recentTranscripts.latest != nil
        menu.addItem(latest)
        menu.addItem(.separator())
        let recoveries = engine.recoveryRecords.filter { !$0.complete && $0.audioBytes > 0 }
        for r in recoveries {
            let date = DateFormatter.localizedString(from: r.startedAt, dateStyle: .short, timeStyle: .short)
            let item = NSMenuItem(title: L("dictation.retryMenu", date, Int(Double(r.audioBytes) / 48_000)), action: #selector(retrySavedDictation(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = r.id
            item.isEnabled = !meetingCaptureActive && !endingSession
            menu.addItem(item)
            let text = r.finalText.isEmpty ? r.rawText : r.finalText
            if !text.isEmpty {
                let copy = NSMenuItem(title: L("dictation.copySavedText"), action: #selector(copyRecoveryText(_:)), keyEquivalent: "")
                copy.target = self; copy.representedObject = r.id; menu.addItem(copy)
            }
        }
        if !recoveries.isEmpty {
            let discard = NSMenuItem(title: L("dictation.discardRecovery"), action: #selector(discardRecoveryAudio), keyEquivalent: "")
            discard.target = self
            discard.isEnabled = !meetingCaptureActive && !endingSession
            menu.addItem(discard); menu.addItem(.separator())
        }
        if recentTranscripts.items.isEmpty {
            let none = NSMenuItem(title: L("menu.recent.empty"), action: nil, keyEquivalent: ""); none.isEnabled = false
            menu.addItem(none)
        }
        for record in recentTranscripts.items {
            let item = NSMenuItem(title: RecentTranscripts.title(record), action: #selector(copyTranscript(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = record.id; item.toolTip = record.text
            if record.outcome == .failed {
                item.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: L("menu.recent.failed"))
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let clear = NSMenuItem(title: L("menu.recent.clear"), action: #selector(clearRecentTranscripts), keyEquivalent: "")
        clear.target = self; clear.isEnabled = !recentTranscripts.items.isEmpty
        menu.addItem(clear)
    }

    @objc func retrySavedDictation(_ sender: NSMenuItem) {
        guard !meetingCaptureActive, !endingSession, let id = sender.representedObject as? String else { return }
        Task { await engine.retryTranscription(id: id) }
    }

    @objc func copyRecoveryText(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let r = engine.recoveryRecords.first(where: { $0.id == id }) else { return }
        RecentTranscripts.copy(r.finalText.isEmpty ? r.rawText : r.finalText); hud.show(.copied)
    }

    @objc func copyTranscript(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let r = recentTranscripts.items.first(where: { $0.id == id }) else { return }
        RecentTranscripts.copy(r.text); hud.show(.copied)
    }

    @objc func copyLatestTranscript() {
        guard let r = recentTranscripts.latest else { return }
        RecentTranscripts.copy(r.text); hud.show(.copied)
    }

    @objc func clearRecentTranscripts() { recentTranscripts.clear(); engine.clearRecentContext() }

    @objc func discardRecoveryAudio() {
        guard !meetingCaptureActive, !endingSession else { return }
        let alert = NSAlert()
        alert.messageText = L("dictation.discardRecovery")
        alert.informativeText = L("dictation.discardRecovery.body")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("dictation.discardRecovery.confirm"))
        alert.addButton(withTitle: L("vocab.cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try engine.discardRecoveryAudio() }
        catch { let failure = NSAlert(); failure.messageText = L("dictation.discardRecovery.failed"); failure.runModal() }
    }

    /// ⌃⌥V anywhere: copy the latest transcript to the clipboard (needs Accessibility, which the app has).
    private func installCopyLatestHotkey() {
        let matches = { (e: NSEvent) in e.keyCode == 9 && e.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.control, .option] }
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
            if matches(e) { MainActor.assumeIsolated { self?.copyLatestTranscript() } }
        }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            guard matches(e) else { return e }
            MainActor.assumeIsolated { self?.copyLatestTranscript() }
            return nil
        }
    }
    @objc func reportBug() {
        guard auth.isSignedIn else { showOnboarding(at: .signIn); return }
        diagnostics.begin()
        if bugWindow?.isVisible != true {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 596, height: 536), styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = UILanguage.isKorean ? "문제 신고" : "Report a bug"
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: BugReportView(diagnostics: diagnostics))
            window.center(); bugWindow = window
        }
        bugWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc func refreshVoice() { if auth.user?.guest == true || auth.user == nil { openSettings(); return }; showOnboarding(at: .voice) }
    @objc func openSetup() { showOnboarding() }
    @objc func openAccountSettings() { settingsNavigation.pane = .account; openSettings() }
    @objc func upgradeFromMenu() {
        if auth.user != nil && !isProEntitled {
            settingsNavigation.pane = .account
            openSettings()
            settingsModel?.startProUpgradeFlow()
        } else {
            openAccountSettings()
        }
    }
    @objc func toggleDictationMode() {
        guard isProEntitled else { upgradeFromMenu(); return }
        let nextLocal = !effectiveLocalDictation
        Prefs.localDictationEnabled = nextLocal
        engine.updateLocalDictationEnabled(nextLocal)
        if nextLocal { ensureLocalModelDownloadingIfNeeded() }
        buildMenu()
        render(engine.state)
    }
    @objc func downloadLocalModelFromMenu() {
        ensureLocalModelDownloadingIfNeeded()
        settingsNavigation.pane = .general
        openSettings()
    }
    @objc func openLocalModelSetup() {
        ensureLocalModelDownloadingIfNeeded()
        if !Prefs.onboardingCompleted {
            showOnboarding(at: .localModel)
        } else {
            settingsNavigation.pane = .general
            openSettings()
        }
    }
    @objc func openSettings() {
        guard !meetingCaptureActive else { meetings.presentManualStart(); return }
        if settingsWindow == nil {
            let model = OnboardingModel(auth: auth, api: api, monitor: monitor, engine: engine)
            model.attachMeetings(meetings)
            model.startEngine = { [weak self] in self?.startEngine() }
            model.onAuthChanged = { [weak self] in self?.handleAuthChanged() }
            model.onBillingUpdated = { [weak self] billing in self?.applyBillingUpdate(billing) }
            settingsModel = model
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 820, height: 600), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.contentMinSize = NSSize(width: 720, height: 520)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isReleasedWhenClosed = false
            model.applyTidyKeys = { [weak self] in self?.applyTidyKeys($0) ?? [] }
            w.contentView = NSHostingView(rootView: SettingsView(model: model, words: VocabularyModel(api: api), meetings: meetings, navigation: settingsNavigation, onSignOut: { [weak self] in self?.signOut() }, onLocalDictationToggled: { [weak self] _ in
                guard let self else { return }
                self.buildMenu()
                self.render(self.engine.state)
            }))
            w.center(); settingsWindow = w
        }
        settingsModel?.triggers = Prefs.triggers
        settingsModel?.tidyKeys = Prefs.tidyShortcuts
        settingsModel?.autoEnterBilingual = Prefs.autoEnterBilingual
        settingsModel?.autoEnterEnglish = Prefs.autoEnterEnglish
        settingsModel?.sendByVoiceEnabled = Prefs.sendByVoiceEnabled
        settingsModel?.sendByVoicePhrasesText = Prefs.sendByVoicePhrasesText
        settingsModel?.sendByVoiceAllApps = Prefs.sendByVoiceAllApps
        if let model = settingsModel { Task { await model.loadVoice(); await model.loadBilling() } }
        settingsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    @objc func openWords() {
        if auth.user == nil { settingsNavigation.pane = .words; openSettings(); return }
        if wordsWindow == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 620), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true; w.titleVisibility = .hidden; w.isReleasedWhenClosed = false
            w.contentView = NSHostingView(rootView: VocabularyView(model: VocabularyModel(api: api), isGuest: auth.user?.guest == true))
            w.center(); wordsWindow = w
        }
        wordsWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    @objc func checkUpdates() { NSApp.activate(ignoringOtherApps: true); updater?.checkForUpdates(nil) }
    @objc func signOut() {
        endingSession = true
        engine.stop()
        recentTranscripts.clear()
        engine.clearRecentContext()
        onboarding?.end(); settingsModel?.end()
        settingsWindow?.close(); settingsWindow = nil; settingsModel = nil
        wordsWindow?.close(); wordsWindow = nil
        Task {
            await meetings.suspend()
            meetings.googleCalendar.disconnect()
            meetingCaptureActive = false
            await auth.signOut { [weak self] in
                guard let self else { return }
                self.diagnostics.reset(); self.bugWindow?.close(); self.bugWindow = nil
                self.billingEntitledOverride = nil
                self.endingSession = false
                self.buildMenu()
                self.syncActiveShortcuts()
                if Prefs.onboardingCompleted && PermissionMonitor.read(previous: nil).allGranted {
                    self.startEngine()
                } else {
                    self.onboarding?.resetForSignIn()
                    self.showOnboarding(at: .signIn)
                }
                self.render(self.engine.state)
            }
        }
    }
    @objc func quit() { engine.stop(); NSApp.terminate(nil) }

    // MARK: local meetings (separate from the cloud dictation pipeline)

    private func configureMeetings() {
        meetings.onShowSettings = { [weak self] in
            self?.settingsNavigation.pane = .meetings
            self?.openSettings()
        }
        meetings.onManualPresentation = { [weak self] in self?.settingsWindow?.close() }
        meetings.googleCalendar.loginHint = { [weak self] in self?.auth.user?.email }
        meetings.onCalendarSynchronized = { [weak self] in
            guard let self, self.settingsModel?.watchEnabled == true else { return }
            self.watchRecordingCalendarSync.tick()
        }
        meetings.googleCalendar.accessAllowed = { [weak self] in
            guard let self, self.auth.isSignedIn else { return false }
            if self.auth.user?.guest != true { return true }
            return self.settingsModel?.googleCalendarAllowed == true
        }
        meetings.canStartRecording = { [weak self] in
            guard let self, !self.endingSession else { return false }
            switch self.engine.state {
            case .preparing, .listening, .processing: return false
            default: return true
            }
        }
        meetings.onRecordingChanged = { [weak self] active in
            guard let self else { return }
            self.meetingCaptureActive = active
            if active {
                // Synchronous ownership handoff: closes cloud socket and releases mic BEFORE local capture.
                self.engine.stop()
                self.settingsModel?.end()
                self.onboarding?.end()
                self.settingsWindow?.close()
                self.onboardingWindow?.close()
                self.hud.show(.hidden)
            } else if !self.endingSession && PermissionMonitor.read(previous: nil).allGranted {
                self.startEngine()
            }
            self.updateMeetingMenuStatus()
            self.syncRuntimeActivityAndUpdates()
            self.render(self.engine.state)
        }
    }

    /// True while a meeting recording, offline meeting transcription, or live dictation is active.
    /// Used to postpone Sparkle update checks/relaunches and to guard `scripts/install-mac.sh`.
    private var activeWorkKind: String? {
        if meetingCaptureActive || meetings.isBusy { return "meeting_recording" }
        if case .running = meetings.transcription { return "meeting_transcription" }
        switch engine.state {
        case .preparing, .listening, .processing: return "dictation"
        default: return nil
        }
    }

    private func syncRuntimeActivityAndUpdates() {
        let kind = activeWorkKind
        // Only block external installs for meeting recording / offline transcription (long-running sessions).
        let markerKind = (kind == "meeting_recording" || kind == "meeting_transcription") ? kind : nil
        RuntimeActivityMarker.update(activeKind: markerKind)
        if kind == nil {
            updateReminder.flushDeferredRelaunchIfIdle()
        }
    }

    @objc private func toggleMeeting() {
        if meetingCaptureActive { Task { await meetings.stop() } }
        else { meetings.presentManualStart() }
    }
    @objc private func openMeetingSettings() { meetings.presentSettings() }
    @objc private func openMeetingTranscripts() { meetings.openTranscripts() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminatingAfterMeeting else { return .terminateLater }
        terminatingAfterMeeting = true
        endingSession = true
        engine.stop()
        Task {
            await meetings.shutdown()
            RuntimeActivityMarker.update(activeKind: nil)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Sparkle starts only once a real EdDSA public key and feed are configured.
    func setUpUpdater() {
        let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String ?? ""
        guard !key.isEmpty, !key.hasPrefix("REPLACE") else { return }
        updateReminder.isBusy = { [weak self] in self?.activeWorkKind != nil }
        updateReminder.showUpdate = { [weak self] in self?.checkUpdates() }
        updateReminder.onChange = { [weak self] version in
            guard let self else { return }
            self.updateItem.isHidden = version == nil
            if let version { self.updateItem.title = L("menu.updateAvailable", version) }
        }
        UNUserNotificationCenter.current().delegate = updateReminder
        updater = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: updateReminder, userDriverDelegate: updateReminder)
    }

    // MARK: onboarding window

    /// Diagnostics `<scheme>://diagnostic/tryit?mode=bilingual,english`: opens onboarding at "Try it" and plays
    /// the bundled fixture through the real path (STT → rewrite → deliver) with our own window frontmost.
    /// Writes ~/Library/Application Support/SundayVoice/tryit.json (fixture text only).
    func runTryItCheck(_ url: URL) async {
        guard !meetingCaptureActive, !endingSession else { return }
        guard let real = engine as? DictationEngine,
              let wav = Bundle.main.url(forResource: "mixed", withExtension: "wav"), let data = try? Data(contentsOf: wav) else { return }
        let modes = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "mode" }?.value ?? "bilingual,english")
            .split(separator: ",").compactMap { DictationMode(rawValue: String($0)) }
        if !auth.isSignedIn && ProcessInfo.processInfo.environment["SUNDAY_VOICE_DEV_LOGIN_SECRET"] != nil { try? await auth.signIn() } // Debug builds: dev-login from the environment
        startEngine()
        showOnboarding(at: .tryIt)
        var rows: [[String: Any]] = []
        for mode in modes {
            onboarding?.tryText = ""
            onboardingWindow?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
            try? await Task.sleep(nanoseconds: 800_000_000)
            let frontIsUs = NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier
            let started = Date()
            var began = false
            for _ in 0..<20 where !began { // the STT socket may still be connecting right after start
                began = await real.runFixture(data.subdata(in: 44..<data.count), mode: mode) != nil
                if !began { try? await Task.sleep(nanoseconds: 500_000_000) }
            }
            guard began else { rows.append(["mode": mode.rawValue, "error": "start", "signed_in": auth.isSignedIn]); continue }
            var row: [String: Any] = ["mode": mode.rawValue, "front_is_us": frontIsUs, "ax": AXIsProcessTrusted()]
            while Date().timeIntervalSince(started) < 15 {
                if let text = onboarding?.tryText, !text.isEmpty { row["text"] = text; row["ok"] = true; break }
                if case .failed(let e) = real.state { row["error"] = "\(e)"; break }
                if case .held = real.state { row["error"] = "held"; break }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            row["ms"] = Int(Date().timeIntervalSince(started) * 1000)
            row["can_continue"] = onboarding?.canContinueStrict ?? false
            rows.append(row)
            try? await Task.sleep(nanoseconds: 800_000_000)
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SundayVoice")
        if let out = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) { try? out.write(to: dir.appendingPathComponent("tryit.json")) }
    }

    /// Dictation while one of our own windows is frontmost. The onboarding "Try it" box always takes it;
    /// otherwise the focused text view (e.g. "My words" add field) gets it like a normal paste.
    func insertIntoOwnWindow(_ text: String) -> Bool {
        if let model = onboarding, onboardingWindow?.isVisible == true, model.step == .tryIt {
            model.receiveTry(text)
            return true
        }
        if settingsWindow?.isVisible == true, settingsNavigation.pane == .handsFree, HandsFreeCursorBridge.shared.isTestArmed {
            HandsFreeCursorBridge.shared.receiveTestText(text)
            return true
        }
        if let view = NSApp.keyWindow?.firstResponder as? NSTextView, view.isEditable {
            view.insertText(text, replacementRange: view.selectedRange())
            return true
        }
        return false
    }

    func showOnboarding(at step: OnboardingStep? = nil) {
        guard !meetingCaptureActive else { meetings.presentManualStart(); return }
        if onboardingWindow == nil {
            let model = OnboardingModel(auth: auth, api: api, monitor: monitor, engine: engine)
            model.attachMeetings(meetings)
            model.startEngine = { [weak self] in self?.startEngine() }
            model.onAuthChanged = { [weak self] in self?.handleAuthChanged() }
            model.onBillingUpdated = { [weak self] billing in self?.applyBillingUpdate(billing) }
            model.openWords = { [weak self] in self?.openWords() }
            model.openHandsFreeSettings = { [weak self] in
                guard let self, HandsFreeSupport.isAvailable() else { return }
                self.onboardingWindow?.close()
                self.settingsNavigation.pane = .handsFree
                self.openSettings()
            }
            model.applyTidyKeys = { [weak self] in self?.applyTidyKeys($0) ?? [] }
            model.onFinish = { [weak self] in self?.onboardingWindow?.close(); self?.startEngine() }
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 600), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            window.delegate = self
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView: OnboardingView(model: model))
            window.center()
            onboarding = model; onboardingWindow = window
        }
        if let model = onboarding, onboardingWindow?.isVisible != true || step != nil { model.begin(at: step) }
        onboardingWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

extension DictationMode { var hudMode: String { self == .bilingual ? "bilingual" : "translate" } }

MainActor.assumeIsolated {
    let delegate = AppDelegate()
    NSApplication.shared.delegate = delegate
    withExtendedLifetime(delegate) { NSApplication.shared.run() }
}
