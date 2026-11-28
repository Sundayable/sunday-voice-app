import AppKit
import Combine
import DictationEngine
import LocalMeetingEngine

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case signIn, proUpgrade, permissions, mic, keys, localModel, connect, voice, tryIt, done
    var id: Int { rawValue }
    var railKey: String {
        switch self {
        case .signIn: return "ob.step.signin"
        case .proUpgrade: return "ob.step.pro"
        case .permissions: return "ob.step.permissions"
        case .mic: return "ob.step.mic"
        case .keys: return "ob.step.keys"
        case .localModel: return "ob.step.localModel"
        case .connect: return "ob.step.connect"
        case .voice: return "ob.step.voice"
        case .tryIt: return "ob.step.try"
        case .done: return "ob.step.done"
        }
    }
    /// Only sign-in, Pro upgrade, and permissions can block; every other step can be skipped so setup never dead-ends.
    var skippable: Bool { self == .mic || self == .keys || self == .localModel || self == .connect || self == .voice || self == .tryIt }
}

/// Pure navigation rules, unit-tested.
enum OnboardingFlow {
    struct Facts: Equatable {
        var signedIn: Bool
        var needsConsent: Bool = false
        var needsProUpgrade: Bool = false
        var permissions: PermissionState
        var micHeard: Bool
        var hasTrigger: Bool
        var localModelReady: Bool = true
    }

    static func canContinue(_ step: OnboardingStep, _ f: Facts) -> Bool {
        switch step {
        case .signIn: return !f.needsConsent
        case .proUpgrade: return !f.needsProUpgrade
        case .permissions: return f.permissions.allGranted
        case .mic: return f.micHeard
        case .keys: return f.hasTrigger
        case .localModel: return f.localModelReady
        case .connect, .voice, .tryIt, .done: return true
        }
    }

    /// Where a (re)launch should resume: the first step whose requirement is unmet.
    /// Signed-out users start directly in Free Local Mode without a login wall.
    static func resumeStep(_ f: Facts, completed: Bool) -> OnboardingStep? {
        if f.needsConsent { return .signIn }
        if f.needsProUpgrade && !completed { return .proUpgrade }
        if !f.permissions.allGranted { return completed ? .permissions : .signIn }
        return completed ? nil : .mic
    }
}

@MainActor
final class OnboardingModel: ObservableObject {
    @Published var step: OnboardingStep = .signIn
    @Published var permissions = PermissionState()
    @Published var micLevel: Float = 0
    @Published var micHeard = false
    @Published var triggers: [TriggerKind] = Prefs.triggers
    @Published var autoEnterBilingual: Bool = Prefs.autoEnterBilingual
    @Published var autoEnterEnglish: Bool = Prefs.autoEnterEnglish
    @Published var sendByVoiceEnabled: Bool = Prefs.sendByVoiceEnabled
    @Published var sendByVoicePhrasesText: String = Prefs.sendByVoicePhrasesText
    @Published var sendByVoiceAllApps: Bool = Prefs.sendByVoiceAllApps
    @Published var capturing = false
    @Published var captured: String?
    @Published var connections: [String: String] = ["gmail": "not_connected", "slack": "not_connected"]
    @Published var cards: [String: String] = [:]
    @Published var savedCards: [String: String] = [:]
    @Published var buildingVoice = false
    @Published var voiceStats: VoiceRefresh.Stats?
    @Published var voiceError: String?
    @Published var connectionError: String?
    @Published var disconnecting: Set<String> = []
    @Published var tryText = ""
    /// Dictated text for the "Try it" box (inserted directly, not through the clipboard).
    func receiveTry(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tryText = tryText.isEmpty ? trimmed : tryText + (tryText.hasSuffix(" ") || tryText.hasSuffix("\n") ? "" : " ") + trimmed
    }
    @Published var signInError: String?
    @Published var billing: BillingSummary?
    @Published var features: AccountFeatures?
    @Published var loadingBilling = false
    @Published var billingActionPending = false
    @Published var billingError: String?
    @Published var localModelReady = false
    @Published var localModelDownloading = false
    @Published var localModelProgress: Double = 0
    @Published var localModelError: String?
    @Published var retryVisible: Set<Permission> = []

    /// Minimum free disk space required before downloading & preparing the ~660 MB Whisper model.
    static let minimumModelDiskSpaceBytes: Int64 = 1_500_000_000
    var diskSpaceProvider: () -> Int64? = { OnboardingModel.availableDiskSpaceBytes() }

    let auth: AuthService
    let api: APIClient
    let monitor: PermissionMonitor
    let engine: DictationEngineProtocol
    var onFinish: (() -> Void)?
    var startEngine: (() -> Void)?
    var openWords: (() -> Void)?
    var openHandsFreeSettings: (() -> Void)?
    var onAuthChanged: (() -> Void)?
    var onBillingUpdated: ((BillingSummary?) -> Void)?
    @Published var pendingProUpgradeAfterSignIn = false
    @Published var dismissedProUpgrade = false
    private var pollTask: Task<Void, Never>?
    private var stateTimer: Timer?
    private var authObserver: AnyCancellable?
    private var meetingsObserver: AnyCancellable?
    private weak var meetings: MeetingCoordinator?
    var isPreview = false
    private var generation = 0
    private var connectionRevision = 0
    private var micCheck = MicCheckDetector()

    init(auth: AuthService, api: APIClient, monitor: PermissionMonitor, engine: DictationEngineProtocol) {
        self.auth = auth; self.api = api; self.monitor = monitor; self.engine = engine
        permissions = monitor.state
        localModelReady = engine.localTranscriber?.isReady ?? false
        authObserver = auth.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    func attachMeetings(_ coordinator: MeetingCoordinator) {
        meetings = coordinator
        syncLocalModelState()
        meetingsObserver = coordinator.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.syncLocalModelState() }
        }
    }

    func syncLocalModelState() {
        let ready = (meetings?.modelReady ?? false) || (engine.localTranscriber?.isReady ?? false)
        localModelReady = ready
        if let meetings {
            localModelDownloading = meetings.phase == .preparing
            localModelProgress = meetings.setupProgress
        }
        if ready { localModelError = nil }
    }

    static func availableDiskSpaceBytes(at url: URL? = nil) -> Int64? {
        var dir = url ?? LocalDictationBridge.defaultModelsDirectory()
        while !FileManager.default.fileExists(atPath: dir.path) {
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        guard let values = try? dir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]) else {
            return nil
        }
        if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
            return important
        }
        if let basic = values.volumeAvailableCapacity {
            return Int64(basic)
        }
        return nil
    }

    func downloadLocalModel() {
        guard !localModelDownloading else { return }
        localModelError = nil
        if let bytes = diskSpaceProvider(), bytes < Self.minimumModelDiskSpaceBytes {
            let gb = String(format: "%.1f", max(0, Double(bytes) / 1_000_000_000))
            localModelError = L("ob.localModel.lowDisk", gb)
            return
        }
        guard let meetings else {
            localModelError = L("ob.localModel.failed")
            return
        }
        localModelDownloading = true
        localModelProgress = 0
        Task {
            await meetings.prepareModel(presentPanel: false)
            syncLocalModelState()
            if !localModelReady {
                localModelError = L("ob.localModel.failed")
            } else {
                localModelError = nil
                Task { await engine.localTranscriber?.prewarm() }
            }
        }
    }

    /// "Start free": go on to permissions and fetch the one-time speech model meanwhile, so it is
    /// usually ready by "Try it" instead of blocking there.
    func startFreeLocal() {
        next()
        if !isPreview && effectiveLocalDictation && !localModelReady { downloadLocalModel() }
    }

    func ensureLocalModelIfNeeded() {
        guard !isPreview, effectiveLocalDictation else { return }
        syncLocalModelState()
        if !localModelReady && !localModelDownloading {
            downloadLocalModel()
        }
    }

    func switchToFreeLocalMode() {
        dismissedProUpgrade = true
        // Entitled Pro/team users explicitly pin local mode; non-Pro users stay in local mode
        // automatically so upgrading to Pro later switches them smoothly into Pro Cloud.
        if isProEntitled { Prefs.localDictationEnabled = true }
        engine.updateLocalDictationEnabled(true)
        ensureLocalModelIfNeeded()
        onAuthChanged?()
        objectWillChange.send()
        if step == .proUpgrade { next() }
    }

    func switchToCloudProMode() {
        guard isProEntitled else { startProUpgradeFlow(); return }
        Prefs.localDictationEnabled = false
        engine.updateLocalDictationEnabled(false)
        onAuthChanged?()
        objectWillChange.send()
    }

    /// Closing onboarding (e.g. after canceling Pro checkout) must never leave a dead state.
    func handleWindowClosed() {
        guard !isProEntitled else { return }
        dismissedProUpgrade = true
        engine.updateLocalDictationEnabled(true)
        ensureLocalModelIfNeeded()
        onAuthChanged?()
    }

    /// Non-Pro users are never blocked on `.proUpgrade`: Free Local Mode works immediately.
    var needsProUpgrade: Bool { false }

    /// Optional Pro upgrade prompt during onboarding right after a non-Pro account signs in.
    var showProUpgradeStep: Bool { auth.isSignedIn && !isProEntitled && !dismissedProUpgrade }

    var facts: OnboardingFlow.Facts {
        .init(signedIn: auth.isSignedIn,
              needsConsent: auth.user != nil && auth.consentRequired,
              needsProUpgrade: needsProUpgrade,
              permissions: permissions,
              micHeard: micHeard,
              hasTrigger: !triggers.isEmpty,
              localModelReady: localModelReady)
    }
    var canContinue: Bool { OnboardingFlow.canContinue(step, facts) }
    /// Native Google Calendar: live for company accounts; external Pro accounts are gated by
    /// the server `features.google_calendar` flag until Google OAuth sensitive-scope verification completes.
    var googleCalendarAllowed: Bool {
        guard auth.isSignedIn else { return false }
        if !isGuest { return true }
        return features?.google_calendar == true
    }

    var watchEnabled: Bool { features?.watch == true }

    /// True for active/trialing Pro subscribers and company team accounts; false for signed-out
    /// Free Local users and signed-in external users without an active Pro subscription.
    var isProEntitled: Bool {
        guard auth.user != nil else { return false }
        if let billing { return billing.entitled }
        return !isGuest
    }

    /// Pro-only actions (Dictate in English, Polish to English) are locked for non-entitled users.
    var proActionsLocked: Bool { !isProEntitled }

    /// Stored Pro bindings are never erased when a user is on Free; at runtime only entitled users arm them.
    static func activeTriggers(from stored: [TriggerKind], proEntitled: Bool) -> [TriggerKind] {
        proEntitled ? stored : stored.filter { $0.mode == .bilingual }
    }

    static func activeTidyShortcuts(from stored: [TidyShortcut], proEntitled: Bool) -> [TidyShortcut] {
        proEntitled ? stored : []
    }

    static func activeAutoEnterModes(bilingual: Bool, english: Bool, proEntitled: Bool) -> Set<DictationMode> {
        var modes: Set<DictationMode> = []
        if bilingual { modes.insert(.bilingual) }
        if english && proEntitled { modes.insert(.english) }
        return modes
    }

    func autoEnterEnabled(for mode: DictationMode) -> Bool {
        mode == .bilingual ? autoEnterBilingual : autoEnterEnglish
    }

    func setAutoEnter(_ enabled: Bool, for mode: DictationMode) {
        if mode == .english && proActionsLocked { return }
        if mode == .bilingual {
            autoEnterBilingual = enabled
            Prefs.autoEnterBilingual = enabled
        } else {
            autoEnterEnglish = enabled
            Prefs.autoEnterEnglish = enabled
        }
        let activeModes = Self.activeAutoEnterModes(bilingual: autoEnterBilingual,
                                                    english: autoEnterEnglish,
                                                    proEntitled: isProEntitled)
        engine.updateAutoEnterModes(activeModes, extraAllowedBundleIDs: Set(Prefs.autoEnterExtraBundleIDs))
    }

    func setSendByVoiceEnabled(_ enabled: Bool) {
        sendByVoiceEnabled = enabled
        Prefs.sendByVoiceEnabled = enabled
        pushSendByVoiceToEngine()
    }

    func setSendByVoicePhrasesText(_ raw: String) {
        sendByVoicePhrasesText = raw
        Prefs.sendByVoicePhrasesText = raw
        pushSendByVoiceToEngine()
    }

    func resetSendByVoicePhrases() {
        setSendByVoicePhrasesText(EndPhrase.defaultSendPhrasesText)
    }

    func setSendByVoiceAllApps(_ allow: Bool) {
        sendByVoiceAllApps = allow
        Prefs.sendByVoiceAllApps = allow
        pushSendByVoiceToEngine()
    }

    func pushSendByVoiceToEngine() {
        engine.updateSendByVoice(
            enabled: sendByVoiceEnabled,
            phrases: EndPhrase.parsePhrases(sendByVoicePhrasesText),
            allowOtherApps: sendByVoiceAllApps
        )
    }

    /// Free Local Mode is active whenever signed out, not entitled to Pro, or explicitly chosen.
    var isLocalOnly: Bool { auth.user == nil }
    var effectiveLocalDictation: Bool { auth.user == nil || !isProEntitled || Prefs.localDictationEnabled }

    // MARK: lifecycle

    func begin(at requestedStep: OnboardingStep? = nil) {
        end()
        monitor.onGranted = { [weak self] p in self?.granted(p) }
        monitor.start()
        permissions = monitor.state
        step = requestedStep ?? OnboardingFlow.resumeStep(facts, completed: false) ?? .mic
        enter(step)
        stateTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.permissions = self.monitor.state
                self.retryVisible = Set(Permission.allCases.filter { self.monitor.showRetry($0) })
            }
        }
    }

    func end() {
        generation += 1
        stateTimer?.invalidate(); stateTimer = nil
        pollTask?.cancel(); pollTask = nil
        if step == .mic { engine.stopMicLevelCheck() }
        monitor.stop()
        PermissionCoach.shared.hide()
    }

    func resetForSignIn() {
        end()
        cards = [:]; savedCards = [:]; voiceStats = nil
        connections = ["gmail": "not_connected", "slack": "not_connected"]
        disconnecting = []
        connectionError = nil; voiceError = nil; signInError = nil
        billing = nil; features = nil; billingError = nil; loadingBilling = false; billingActionPending = false
        pendingProUpgradeAfterSignIn = false; dismissedProUpgrade = false
        tryText = ""; micHeard = false; buildingVoice = false
        Prefs.onboardingCompleted = false
        begin()
    }

    func didSignIn() {
        guard auth.isSignedIn else { return }
        let continueToPro = pendingProUpgradeAfterSignIn
        pendingProUpgradeAfterSignIn = false
        dismissedProUpgrade = false
        onAuthChanged?()
        if step == .signIn { next() }
        Task {
            await loadBilling()
            if self.isProEntitled {
                if self.step == .proUpgrade { self.next() }
            } else {
                // Keep non-Pro users working immediately in Free Local Mode even before/without checkout.
                self.engine.updateLocalDictationEnabled(true)
                self.ensureLocalModelIfNeeded()
                self.onAuthChanged?()
                if continueToPro {
                    self.startProUpgradeFlow()
                }
            }
        }
        if permissions.allGranted { startEngine?() }
    }

    private func granted(_ p: Permission) {
        permissions = monitor.state
        PermissionCoach.shared.hide()
        // Bring our window back over System Settings and tick the card (no silent page jump).
        NSApp.activate(ignoringOtherApps: true)
        if p == .accessibility || p == .inputMonitoring {
            do { try engine.reinstallInputTap() } catch EngineError.inputMonitoringMissing {
                monitor.markInputMonitoringNeeded(); permissions = monitor.state
            } catch {}
        }
        if permissions.allGranted { startEngine?() }
    }

    /// Guests have no Gmail/Slack connections; signed-out local users skip cloud-only connect and voice steps.
    var isGuest: Bool { auth.user?.guest == true }
    var hidesCloudSteps: Bool { isGuest || isLocalOnly }
    var visibleSteps: [OnboardingStep] {
        OnboardingStep.allCases.filter { s in
            if s == .proUpgrade { return showProUpgradeStep || step == .proUpgrade }
            if s == .localModel { return effectiveLocalDictation }
            if hidesCloudSteps && (s == .connect || s == .voice) { return false }
            return true
        }
    }
    private var steps: [OnboardingStep] { visibleSteps }

    func next() {
        let steps = self.steps
        if !isPreview {
            AnonymousStats.shared.recordOnboardingStep(step, localMode: effectiveLocalDictation)
        }
        guard let i = steps.firstIndex(of: step) ?? OnboardingStep.allCases.firstIndex(of: step).map({ min($0, steps.count - 1) }),
              i + 1 < steps.count else { finish(); return }
        leave(step)
        step = steps[i + 1]
        enter(step)
    }

    /// Jump to a visible step (e.g. "Try it" → key setup when the key does nothing).
    func go(to target: OnboardingStep) {
        guard target != step, steps.contains(target) else { return }
        leave(step)
        step = target
        enter(step)
    }

    func back() {
        let steps = self.steps
        guard let i = steps.firstIndex(of: step), i > 0 else { return }
        leave(step)
        step = steps[i - 1]
        enter(step)
    }

    func finish() {
        if !isPreview {
            AnonymousStats.shared.recordOnboardingStep(.done, localMode: effectiveLocalDictation)
        }
        leave(step)
        end()
        Prefs.onboardingCompleted = true
        onFinish?()
    }

    private func enter(_ s: OnboardingStep) {
        switch s {
        case .proUpgrade: Task {
            await loadBilling()
            if self.isProEntitled {
                if self.step == .proUpgrade { self.next() }
            } else {
                self.ensureLocalModelIfNeeded()
            }
        }
        case .mic: startMicCheck()
        case .localModel, .tryIt: syncLocalModelState()
        case .connect, .voice: Task {
            await loadVoice()
            if connections.values.contains("pending") { pollConnections() }
        }
        default: break
        }
    }

    private func leave(_ s: OnboardingStep) {
        if s == .mic { engine.stopMicLevelCheck() }
        PermissionCoach.shared.hide()
    }

    // MARK: steps

    func signIn() {
        signInError = nil
        Task {
            do {
                try await auth.signIn(); didSignIn(); objectWillChange.send()
                // The browser had focus; bring setup back so the next step is in front of the user.
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.filter { $0.isVisible && $0.canBecomeKey }.forEach { $0.makeKeyAndOrderFront(nil) }
            } catch AuthError.cancelled {
                pendingProUpgradeAfterSignIn = false
            } catch AuthError.server(let code) where code == "not_invited" {
                pendingProUpgradeAfterSignIn = false
                signInError = L("error.notInvited")
            } catch {
                pendingProUpgradeAfterSignIn = false
                signInError = L("error.signInRetry")
            }
        }
    }

    func request(_ p: Permission) { monitor.request(p) }

    /// Display scale for raw peak levels: quiet built-in mics peak around 0.02–0.05 while speaking.
    static func displayLevel(_ peak: Float) -> Float { min(1, (max(0, peak)).squareRoot() * 2.2) }

    func startMicCheck() {
        micHeard = false; micCheck = MicCheckDetector()
        engine.startMicLevelCheck { [weak self] level in
            Task { @MainActor in
                guard let self else { return }
                self.micLevel = Self.displayLevel(level)
                if self.micCheck.receive(level, at: Date()) { self.micHeard = true }
            }
        }
    }

    @Published var capturingMode: DictationMode?
    @Published var keyMessage: String?
    /// Live confirmation after capturing a shortcut ("이제 마우스 옆 버튼 누르고 말하면 돼요.").
    @Published var capturedConfirmation: String?
    /// The key being replaced by the running capture (nil = adding an extra key).
    @Published var capturingReplacement: TriggerKind?
    /// A captured key another action already uses, waiting for "Move it" / "Cancel".
    @Published var pendingMove: PendingKeyMove?
    /// Live "hold your key now" check on the key step.
    @Published var keyTest = KeyTestState()
    /// macOS "Press 🌐 key to" setting; anything but Do Nothing fights a 🌐 Fn dictation key.
    @Published var fnUsage: FnKeyUsage = FnKeySetting.current()
    @Published var confirmingReset = false
    var captureToken = 0
    /// Set while the onboarding key step is on screen: the live check re-arms after every change.
    var keyTestAuto = false
    var keyTestToken = 0

    func triggers(for mode: DictationMode) -> [TriggerKind] { triggers.filter { $0.mode == mode } }

    func removeTrigger(_ trigger: TriggerKind) {
        if trigger.mode == .english && proActionsLocked { return }
        triggers.removeAll { $0 == trigger }
        saveTriggers()
    }

    func resetTriggers() {
        cancelCapture()
        if proActionsLocked {
            // Preserve any stored Pro (.english / tidy) bindings untouched; only reset Free bilingual triggers.
            let storedPro = triggers.filter { $0.mode != .bilingual }
            triggers = Prefs.defaultTriggers.filter { $0.mode == .bilingual } + storedPro
            saveTriggers()
        } else {
            triggers = Prefs.defaultTriggers; saveTriggers()
            tidyKeys = [.default]; saveTidyKeys()
        }
        confirmingReset = false; pendingMove = nil
        captured = nil; capturedConfirmation = nil
    }

    func saveTriggers() {
        Prefs.triggers = triggers
        engine.updateTriggers(Self.activeTriggers(from: triggers, proEntitled: isProEntitled))
        keyMessage = nil
    }

    // MARK: tidy clipboard keys (third card; one setting shared by onboarding and Settings › Keys)

    @Published var tidyKeys: [TidyShortcut] = Prefs.tidyShortcuts
    @Published var capturingTidy = false
    /// Polish capture from the card ("Change") vs. the advanced section ("+ Add").
    @Published var tidyCaptureReplacesPrimary = false
    /// Registers the keys system-wide; returns the ones another app owns. Set by the app delegate.
    var applyTidyKeys: ([TidyShortcut]) -> [TidyShortcut] = { _ in [] }

    func removeTidyKey(_ key: TidyShortcut) {
        if proActionsLocked { return }
        tidyKeys.removeAll { $0 == key }
        saveTidyKeys()
    }

    /// Saves and registers; a key another app already owns is dropped with a message.
    func saveTidyKeys() {
        let active = Self.activeTidyShortcuts(from: tidyKeys, proEntitled: isProEntitled)
        let taken = applyTidyKeys(active)
        if !taken.isEmpty && isProEntitled {
            tidyKeys.removeAll { taken.contains($0) }
            _ = applyTidyKeys(tidyKeys)
            keyMessage = L("settings.tidy.taken")
        } else {
            keyMessage = nil
        }
        Prefs.tidyShortcuts = tidyKeys
    }

    /// Why a captured input can't be a tidy key, or nil.
    static func tidyProblem(_ raw: TriggerKind, tidyKeys: [TidyShortcut], triggers: [TriggerKind]) -> String? {
        guard let key = TidyShortcut(trigger: raw) else { return L("keys.polishKeysOnly") }
        if key.needsModifier { return L("settings.tidy.needsModifier") }
        if tidyKeys.contains(key) { return L("ob.keys.already", describe(raw)) }
        if key == .copyLatest { return L("settings.tidy.conflict") }
        if key.conflicts(with: triggers) { return L("ob.keys.usedForDictation", describe(raw)) }
        return nil
    }

    static func describe(_ t: TriggerKind) -> String {
        switch t {
        case .controlHold: return KeyNames.modifier(.control)
        case .modifierHold(let keys, _, _): return keys.map(KeyNames.modifier).joined(separator: " + ")
        case .mouseButton(let n, _): return KeyNames.mouseButton(n)
        case .key(let code, let mods, _):
            let prefix = KeyNames.modifierPrefix(mods)
            return prefix.isEmpty ? KeyNames.name(code) : prefix + " + " + KeyNames.name(code)
        }
    }

    /// Plain-word physical location hint so users know where keys like Option (Alt) or Fn sit on the keyboard.
    static func locationHint(_ t: TriggerKind) -> String? {
        switch t {
        case .controlHold: return L("keyname.control.where")
        case .modifierHold(let keys, _, _):
            if keys.contains(.rightOption) { return L("keyname.rightOption.where") }
            if keys.contains(.option) { return L("keyname.option.where") }
            if keys.contains(.rightCommand) { return L("keyname.rightCommand.where") }
            if keys.contains(.command) { return L("keyname.command.where") }
            if keys.contains(.fn) { return L("keyname.fn.where") }
            if keys.contains(.control) { return L("keyname.control.where") }
            return nil
        case .key(_, let mods, _):
            if mods & 0x0800 != 0 { return L("keyname.option.where") }
            if mods & 0x0100 != 0 { return L("keyname.command.where") }
            if mods & 0x1000 != 0 { return L("keyname.control.where") }
            return nil
        case .mouseButton:
            return nil
        }
    }

    static func isHold(_ t: TriggerKind) -> Bool {
        switch t { case .controlHold, .modifierHold: return true; default: return false }
    }

    /// Keys people type with can't be dictation triggers.
    static func problem(with trigger: TriggerKind) -> String? {
        switch trigger {
        case .key(let code, let mods, _):
            let typing: Set<UInt16> = Set(0...50).union([65, 67, 69, 75, 78, 81, 82, 83, 84, 85, 86, 87, 88, 89, 91, 92]).subtracting([48, 49])
            if mods == 0 && (typing.contains(code) || code == 36 || code == 48 || code == 49 || code == 51 || code == 53) { return L("keys.typingKey") }
            return nil
        case .modifierHold(let keys, _, _) where keys == [.shift] || keys == [.command]:
            return L("keys.typingKey")
        default: return nil
        }
    }

    // MARK: connections and voice

    func loadVoice() async {
        guard auth.isSignedIn, !isPreview else { return }
        let current = generation, revision = connectionRevision
        do {
            let summary = try await api.voice()
            guard current == generation, auth.isSignedIn else { return }
            if revision == connectionRevision {
                connections = summary.connections.mapValues(\.status)
                connectionError = nil
            }
            for (lang, card) in summary.cards {
                if cards[lang] == savedCards[lang] { cards[lang] = card?.text }
                savedCards[lang] = card?.text
            }
        } catch {
            guard current == generation else { return }
            connectionError = L("error.connectionsRetry")
        }
    }

    func connect(_ toolkit: String) {
        guard connections[toolkit] != "pending", auth.isSignedIn else { return }
        connectionRevision += 1
        connections[toolkit] = "pending"; connectionError = nil
        let current = generation
        Task {
            do {
                let url = try await api.link(toolkit)
                guard current == generation, auth.isSignedIn else { return }
                NSWorkspace.shared.open(url)
                pollConnections()
            } catch {
                guard current == generation else { return }
                connections[toolkit] = "error"
                connectionError = L("error.connectionsRetry")
            }
        }
    }

    func disconnect(_ toolkit: String) {
        guard auth.isSignedIn, !disconnecting.contains(toolkit) else { return }
        connectionRevision += 1
        disconnecting.insert(toolkit); connectionError = nil
        let current = generation
        Task {
            defer { if current == generation { disconnecting.remove(toolkit) } }
            do {
                try await api.disconnect(toolkit)
                guard current == generation else { return }
                connectionRevision += 1
                connections[toolkit] = "not_connected"
            } catch {
                if current == generation { connectionError = L("error.disconnectRetry") }
            }
        }
    }

    func expirePendingConnections() {
        for key in connections.keys where connections[key] == "pending" { connections[key] = "error" }
        connectionError = L("error.connectionTimeout")
    }

    func pollConnections() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            let end = Date().addingTimeInterval(180)
            while !Task.isCancelled, Date() < end {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) } catch { return }
                guard let self else { return }
                await self.loadVoice()
                if !self.connections.values.contains("pending") { return }
            }
            guard !Task.isCancelled else { return }
            self?.expirePendingConnections()
        }
    }

    /// `<scheme>://connected?toolkit=…` from the browser.
    func connectedCallback(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        Task { await loadVoice() }
    }

    // MARK: billing

    func loadBilling() async {
        guard auth.user != nil, !isPreview else { return }
        loadingBilling = true
        defer { loadingBilling = false }
        do {
            let summary = try await api.me()
            billing = summary.billing
            features = summary.features
            billingError = nil
            onBillingUpdated?(summary.billing)
        } catch {
            // Keep prior billing state if a background refresh fails transiently.
        }
    }

    /// Entry point for the "Start Pro ($19/mo)" button on locked Pro cards (Keys / onboarding).
    /// Signed-out users go through Google sign-in first, then continue directly into checkout if not entitled.
    func startProUpgradeFlow() {
        if auth.user == nil {
            guard !auth.signingIn else { return }
            pendingProUpgradeAfterSignIn = true
            signIn()
            return
        }
        let status = billing?.status ?? "none"
        let isPastDue = status == "past_due" || status == "unpaid"
        if isPastDue && billing?.has_customer == true {
            manageSubscription()
        } else {
            upgradeToPro()
        }
    }

    func upgradeToPro() {
        guard auth.user != nil, !billingActionPending else { return }
        billingActionPending = true
        billingError = nil
        Task {
            defer { billingActionPending = false }
            do {
                let url = try await api.startProCheckout()
                NSWorkspace.shared.open(url)
            } catch APIError.http(_, let code) where code == "billing_not_configured" {
                billingError = L("billing.error.notConfigured")
            } catch {
                billingError = L("billing.error.checkout")
            }
        }
    }

    func manageSubscription() {
        guard auth.user != nil, !billingActionPending else { return }
        billingActionPending = true
        billingError = nil
        Task {
            defer { billingActionPending = false }
            do {
                let url = try await api.openBillingPortal()
                NSWorkspace.shared.open(url)
            } catch APIError.http(_, let code) where code == "no_billing_account" {
                billingError = L("billing.error.noAccount")
            } catch APIError.http(_, let code) where code == "billing_not_configured" {
                billingError = L("billing.error.notConfigured")
            } catch {
                billingError = L("billing.error.portal")
            }
        }
    }

    /// `<scheme>://billing?status=…` from Stripe Checkout / Customer Portal return page.
    func billingCallback(_ url: URL) {
        NSApp.activate(ignoringOtherApps: true)
        Task {
            await loadBilling()
            if self.isProEntitled {
                Prefs.localDictationEnabled = false
                self.engine.updateLocalDictationEnabled(false)
                self.onAuthChanged?()
                if self.step == .proUpgrade { self.next() }
            } else {
                // Checkout cancelled or unpaid: immediately return to working Free Local Mode.
                self.switchToFreeLocalMode()
            }
        }
    }

    var anyConnected: Bool { connections.values.contains("active") }

    func buildVoice() {
        guard !buildingVoice else { return }
        buildingVoice = true; voiceError = nil
        let current = generation
        Task {
            defer { if current == generation { buildingVoice = false } }
            do {
                let result = try await api.refreshVoice()
                guard current == generation, auth.isSignedIn else { return }
                voiceStats = result.stats
                if let failed = result.failed, !failed.isEmpty { voiceError = L("error.voicePartial", failed.map { $0 == "gmail" ? "Gmail" : "Slack" }.joined(separator: ", ")) }
                for (lang, card) in result.cards { if let card { cards[lang] = card.text; savedCards[lang] = card.text } }
            } catch { if current == generation { voiceError = L("error.voiceRetry") } }
        }
    }

    func saveCard(_ lang: String) {
        guard let text = cards[lang], !text.isEmpty else { return }
        let current = generation
        Task {
            do {
                let card = try await api.saveCard(lang, text)
                guard current == generation else { return }
                savedCards[lang] = card.text; voiceError = nil
            } catch { if current == generation { voiceError = L("error.voiceSave") } }
        }
    }

    func deleteCard(_ lang: String) {
        let current = generation
        Task {
            do {
                try await api.deleteCard(lang)
                guard current == generation else { return }
                cards[lang] = nil
                savedCards[lang] = nil
                voiceError = nil
            } catch {
                if current == generation { voiceError = L("voice.delete.error") }
            }
        }
    }

    static let presets: [String: [(key: String, text: String)]] = [
        "ko": [("ob.voice.preset.ko.haeyo", "- 해요체 위주, 문장은 짧게.\n- 인사는 '안녕하세요', 끝은 '감사해요'.\n- 이모지는 거의 쓰지 않음."),
               ("ob.voice.preset.ko.hamnida", "- 합니다체, 정중하고 간결하게.\n- 인사는 '안녕하세요', 끝은 '감사합니다'.\n- 이모지 쓰지 않음."),
               ("ob.voice.preset.ko.banmal", "- 반말, 친구에게 말하듯 짧게.\n- 인사·끝인사 생략.\n- 가벼운 이모지 괜찮음.")],
        "en": [("ob.voice.preset.en.casual", "- Casual and warm; short sentences, contractions.\n- Opens with 'Hey' or no greeting; signs off 'Thanks!'."),
               ("ob.voice.preset.en.business", "- Friendly business tone; clear, direct sentences.\n- Opens with 'Hi <name>,'; signs off 'Thanks,'."),
               ("ob.voice.preset.en.formal", "- Formal and polite; complete sentences, no slang.\n- Opens with 'Hello <name>,'; signs off 'Best regards,'.")],
    ]

    func applyPreset(_ lang: String, _ text: String) { cards[lang] = text; saveCard(lang) }
}

struct MicCheckDetector {
    private var floor: Float = 0.0002
    private var started: Date?
    private var lastSpeech: Date?
    mutating func receive(_ level: Float, at now: Date) -> Bool {
        let speech = level >= max(0.003, floor * 4)
        if speech {
            if let lastSpeech, now.timeIntervalSince(lastSpeech) > 0.12 { started = nil }
            started = started ?? now
            lastSpeech = now
        } else {
            floor = min(0.002, floor * 0.98 + max(0.0001, level) * 0.02)
            if let lastSpeech, now.timeIntervalSince(lastSpeech) > 0.12 { started = nil }
        }
        return speech && started.map { now.timeIntervalSince($0) >= 0.25 } == true
    }
}

enum KeyNames {
    static func modifier(_ k: ModifierKey) -> String {
        switch k {
        case .fn: return L("keyname.fn")
        case .control: return L("keyname.control")
        case .option: return L("keyname.option")
        case .command: return L("keyname.command")
        case .shift: return L("keyname.shift")
        case .rightOption: return L("keyname.rightOption")
        case .rightCommand: return L("keyname.rightCommand")
        }
    }
    static func mouseButton(_ number: Int) -> String {
        switch number {
        case 2: return L("keyname.mouseMiddle")
        case 3: return L("keyname.mouseSide1")
        case 4: return L("keyname.mouseSide2")
        default: return L("keys.mouseButton", "\(number + 1)")
        }
    }
    static func modifierPrefix(_ carbon: UInt32) -> String {
        var parts: [String] = []
        if carbon & 0x1000 != 0 { parts.append(L("keyname.control")) }
        if carbon & 0x0800 != 0 { parts.append(L("keyname.option")) }
        if carbon & 0x0200 != 0 { parts.append(L("keyname.shift")) }
        if carbon & 0x0100 != 0 { parts.append(L("keyname.command")) }
        return parts.joined(separator: " + ")
    }
    static func name(_ code: UInt16) -> String {
        let table: [UInt16: String] = [79: "F18", 80: "F19", 64: "F17", 106: "F16", 113: "F15", 107: "F14", 105: "F13",
                                       122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8",
                                       101: "F9", 109: "F10", 103: "F11", 111: "F12", 49: "Space", 53: "Esc"]
        if let named = table[code] { return named }
        // Letters/digits through the current keyboard layout.
        let letters: [UInt16: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J", 40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T", 32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z"]
        return letters[code] ?? "Key \(code)"
    }
}

/// App-level settings (UserDefaults). No secrets here.
enum Prefs {
    static var onboardingCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: "onboardingCompleted") }
        set { UserDefaults.standard.set(newValue, forKey: "onboardingCompleted") }
    }
    /// Defaults that exist on every Mac keyboard: hold 🌐 Fn to dictate as spoken,
    /// hold 🌐 Fn + ⇧ Shift for English.
    static let defaultTriggers: [TriggerKind] = [
        .modifierHold(keys: [.fn], mode: .bilingual, holdMilliseconds: 180),
        .modifierHold(keys: [.fn, .shift], mode: .english, holdMilliseconds: 180),
    ]

    static var triggers: [TriggerKind] {
        get {
            if let data = UserDefaults.standard.data(forKey: "triggers"), let t = try? JSONDecoder().decode([TriggerKind].self, from: data) { return t }
            return defaultTriggers
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: "triggers") }
    }

    static var openAtLogin: Bool {
        get { UserDefaults.standard.object(forKey: "openAtLogin") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openAtLogin") }
    }

    static var soundsEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "soundsEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "soundsEnabled") }
    }

    /// Leave the latest transcript on the clipboard after every dictation. Default on (Dan, 2026-10-06).
    static var keepTranscriptOnClipboard: Bool {
        get { UserDefaults.standard.object(forKey: "keepTranscriptOnClipboard") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "keepTranscriptOnClipboard") }
    }

    /// Recent dictations (in memory on this Mac) as context for the next one. Default on.
    static var useRecentContext: Bool {
        get { UserDefaults.standard.object(forKey: "useRecentContext") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "useRecentContext") }
    }

    /// Extract proper-noun / Latin terms from the frontmost window title and caret ±300 chars (opt-in, never logged).
    static var useScreenContext: Bool {
        get { UserDefaults.standard.object(forKey: "useScreenContext") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "useScreenContext") }
    }

    /// Free Local Mode: transcribe dictation 100% locally via WhisperKit + personal replacements (zero cloud APIs).
    static var localDictationEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "localDictationEnabled") as? Bool ?? false }
        set { UserDefaults.standard.set(newValue, forKey: "localDictationEnabled") }
    }

    /// Local opt-in flags for upcoming Pro features ("Notify me when ready").
    static var notifyAppleWatch: Bool {
        get { UserDefaults.standard.bool(forKey: "notifyAppleWatch") }
        set { UserDefaults.standard.set(newValue, forKey: "notifyAppleWatch") }
    }

    static var notifyPersonalMCP: Bool {
        get { UserDefaults.standard.bool(forKey: "notifyPersonalMCP") }
        set { UserDefaults.standard.set(newValue, forKey: "notifyPersonalMCP") }
    }

    /// Optional per-action "Press Enter after pasting" (default OFF). Applies only in safe chat apps.
    static var autoEnterBilingual: Bool {
        get { UserDefaults.standard.bool(forKey: "autoEnterBilingual") }
        set { UserDefaults.standard.set(newValue, forKey: "autoEnterBilingual") }
    }

    static var autoEnterEnglish: Bool {
        get { UserDefaults.standard.bool(forKey: "autoEnterEnglish") }
        set { UserDefaults.standard.set(newValue, forKey: "autoEnterEnglish") }
    }

    /// Optional extra chat-app bundle IDs allowed for auto-Enter (email/doc blocklist still applies).
    static var autoEnterExtraBundleIDs: [String] {
        get { UserDefaults.standard.stringArray(forKey: "autoEnterExtraBundleIDs") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "autoEnterExtraBundleIDs") }
    }

    /// Spoken "Send by voice" end command (default ON; triggers only on exact final command phrase).
    static var sendByVoiceEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sendByVoiceEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sendByVoiceEnabled") }
    }

    static var sendByVoicePhrasesText: String {
        get { UserDefaults.standard.string(forKey: "sendByVoicePhrasesText") ?? EndPhrase.defaultSendPhrasesText }
        set { UserDefaults.standard.set(newValue, forKey: "sendByVoicePhrasesText") }
    }

    static var sendByVoicePhrases: [String] {
        EndPhrase.parsePhrases(sendByVoicePhrasesText)
    }

    /// When false (default), Send by voice only runs in safe chat apps. When true, allows other non-email/doc apps.
    static var sendByVoiceAllApps: Bool {
        get { UserDefaults.standard.bool(forKey: "sendByVoiceAllApps") }
        set { UserDefaults.standard.set(newValue, forKey: "sendByVoiceAllApps") }
    }
}
