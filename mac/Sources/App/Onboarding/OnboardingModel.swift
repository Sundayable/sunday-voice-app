import AppKit
import Combine
import DictationEngine

enum OnboardingStep: Int, CaseIterable, Identifiable {
    case signIn, permissions, mic, keys, connect, voice, tryIt, done
    var id: Int { rawValue }
    var railKey: String {
        switch self {
        case .signIn: return "ob.step.signin"
        case .permissions: return "ob.step.permissions"
        case .mic: return "ob.step.mic"
        case .keys: return "ob.step.keys"
        case .connect: return "ob.step.connect"
        case .voice: return "ob.step.voice"
        case .tryIt: return "ob.step.try"
        case .done: return "ob.step.done"
        }
    }
    /// Only sign-in and permissions can block; every other step can be skipped so setup never dead-ends.
    var skippable: Bool { self == .mic || self == .keys || self == .connect || self == .voice || self == .tryIt }
}

/// Pure navigation rules, unit-tested.
enum OnboardingFlow {
    struct Facts: Equatable {
        var signedIn: Bool
        var permissions: PermissionState
        var micHeard: Bool
        var hasTrigger: Bool
    }

    static func canContinue(_ step: OnboardingStep, _ f: Facts) -> Bool {
        switch step {
        case .signIn: return f.signedIn
        case .permissions: return f.permissions.allGranted
        case .mic: return f.micHeard
        case .keys: return f.hasTrigger
        case .connect, .voice, .tryIt, .done: return true
        }
    }

    /// Where a (re)launch should resume: the first step whose requirement is unmet.
    static func resumeStep(_ f: Facts, completed: Bool) -> OnboardingStep? {
        if !f.signedIn { return .signIn }
        if !f.permissions.allGranted { return .permissions }
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
    @Published var retryVisible: Set<Permission> = []

    let auth: AuthService
    let api: APIClient
    let monitor: PermissionMonitor
    let engine: DictationEngineProtocol
    var onFinish: (() -> Void)?
    var startEngine: (() -> Void)?
    var openWords: (() -> Void)?
    private var pollTask: Task<Void, Never>?
    private var stateTimer: Timer?
    private var authObserver: AnyCancellable?
    var isPreview = false
    private var generation = 0
    private var connectionRevision = 0
    private var micCheck = MicCheckDetector()

    init(auth: AuthService, api: APIClient, monitor: PermissionMonitor, engine: DictationEngineProtocol) {
        self.auth = auth; self.api = api; self.monitor = monitor; self.engine = engine
        permissions = monitor.state
        authObserver = auth.objectWillChange.sink { [weak self] in
            Task { @MainActor in self?.objectWillChange.send() }
        }
    }

    var facts: OnboardingFlow.Facts {
        .init(signedIn: auth.isSignedIn, permissions: permissions, micHeard: micHeard, hasTrigger: !triggers.isEmpty)
    }
    var canContinue: Bool { OnboardingFlow.canContinue(step, facts) }

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
        tryText = ""; micHeard = false; buildingVoice = false
        Prefs.onboardingCompleted = false
        begin()
    }

    func didSignIn() {
        guard auth.isSignedIn else { return }
        if step == .signIn { next() }
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

    /// Guests have no Gmail/Slack connections, so the connect and voice-import steps are skipped.
    var isGuest: Bool { auth.user?.guest == true }
    private var steps: [OnboardingStep] { OnboardingStep.allCases.filter { !isGuest || ($0 != .connect && $0 != .voice) } }

    func next() {
        let steps = self.steps
        guard let i = steps.firstIndex(of: step) ?? OnboardingStep.allCases.firstIndex(of: step).map({ min($0, steps.count - 1) }),
              i + 1 < steps.count else { finish(); return }
        leave(step)
        step = steps[i + 1]
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
        leave(step)
        end()
        Prefs.onboardingCompleted = true
        onFinish?()
    }

    private func enter(_ s: OnboardingStep) {
        switch s {
        case .mic: startMicCheck()
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
            } catch AuthError.server(let code) where code == "not_invited" {
                signInError = L("error.notInvited")
            } catch { signInError = L("error.signInRetry") }
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

    func triggers(for mode: DictationMode) -> [TriggerKind] { triggers.filter { $0.mode == mode } }

    func removeTrigger(_ trigger: TriggerKind) {
        triggers.removeAll { $0 == trigger }
        saveTriggers()
    }

    func resetTriggers() {
        triggers = Prefs.defaultTriggers; saveTriggers()
        tidyKeys = [.default]; saveTidyKeys()
    }

    private func saveTriggers() {
        Prefs.triggers = triggers
        engine.updateTriggers(triggers)
        keyMessage = nil
    }

    /// "Click, then press any key, key combo or mouse button."
    func captureKey(for mode: DictationMode) {
        capturing = true; capturingMode = mode; captured = nil; keyMessage = nil
        engine.captureNextTrigger(timeout: 10) { [weak self] trigger in
            guard let self else { return }
            self.capturing = false; self.capturingMode = nil
            guard let raw = trigger else { return }
            let trigger = raw.with(mode: mode)
            if let problem = Self.problem(with: trigger) { self.keyMessage = problem; return }
            if let key = TidyShortcut(trigger: trigger), self.tidyKeys.contains(key) {
                self.keyMessage = L("ob.keys.usedForTidy", Self.describe(trigger)); return
            }
            if let clash = self.triggers.first(where: { $0.inputKey == trigger.inputKey }) {
                if clash.mode == mode { self.keyMessage = L("ob.keys.already", Self.describe(trigger)); return }
                self.triggers.removeAll { $0 == clash } // moving it to the other mode
            }
            self.triggers.append(trigger)
            self.captured = Self.describe(trigger)
            self.saveTriggers()
        }
    }

    // MARK: tidy clipboard keys (third card; one setting shared by onboarding and Settings › Keys)

    @Published var tidyKeys: [TidyShortcut] = Prefs.tidyShortcuts
    @Published var capturingTidy = false
    /// Registers the keys system-wide; returns the ones another app owns. Set by the app delegate.
    var applyTidyKeys: ([TidyShortcut]) -> [TidyShortcut] = { _ in [] }

    func removeTidyKey(_ key: TidyShortcut) {
        tidyKeys.removeAll { $0 == key }
        saveTidyKeys()
    }

    /// Saves and registers; a key another app already owns is dropped with a message.
    private func saveTidyKeys() {
        let taken = applyTidyKeys(tidyKeys)
        if !taken.isEmpty {
            tidyKeys.removeAll { taken.contains($0) }
            _ = applyTidyKeys(tidyKeys)
            keyMessage = L("settings.tidy.taken")
        } else {
            keyMessage = nil
        }
        Prefs.tidyShortcuts = tidyKeys
    }

    /// Press to tidy: keys and key combos only (system hot keys); mouse buttons and holds belong to dictation.
    func captureTidyKey() {
        capturing = true; capturingTidy = true; captured = nil; keyMessage = nil
        _ = applyTidyKeys([]) // the current tidy keys must reach the recorder, not start a tidy
        engine.captureNextTrigger(timeout: 10) { [weak self] raw in
            guard let self else { return }
            self.capturing = false; self.capturingTidy = false
            _ = self.applyTidyKeys(self.tidyKeys)
            guard let raw else { return }
            self.keyMessage = Self.tidyProblem(raw, tidyKeys: self.tidyKeys, triggers: self.triggers)
            guard self.keyMessage == nil, let key = TidyShortcut(trigger: raw) else { return }
            self.tidyKeys.append(key)
            self.captured = Self.describe(raw)
            self.saveTidyKeys()
        }
    }

    /// Why a captured input can't be a tidy key, or nil.
    static func tidyProblem(_ raw: TriggerKind, tidyKeys: [TidyShortcut], triggers: [TriggerKind]) -> String? {
        guard let key = TidyShortcut(trigger: raw) else { return L("ob.keys.tidyKeysOnly") }
        if key.needsModifier { return L("settings.tidy.needsModifier") }
        if tidyKeys.contains(key) { return L("ob.keys.already", describe(raw)) }
        if key == .copyLatest { return L("settings.tidy.conflict") }
        if key.conflicts(with: triggers) { return L("ob.keys.usedForDictation", describe(raw)) }
        return nil
    }

    static func describe(_ t: TriggerKind) -> String {
        switch t {
        case .controlHold: return "⌃ Control"
        case .modifierHold(let keys, _, _): return keys.map(KeyNames.modifier).joined(separator: " + ")
        case .mouseButton(let n, _): return L("ob.keys.mouseButton", "\(n + 1)")
        case .key(let code, let mods, _): return KeyNames.modifierPrefix(mods) + KeyNames.name(code)
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
            if mods == 0 && (typing.contains(code) || code == 36 || code == 48 || code == 49 || code == 51 || code == 53) { return L("ob.keys.typingKey") }
            return nil
        case .modifierHold(let keys, _, _) where keys == [.shift] || keys == [.command]:
            return L("ob.keys.typingKey")
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
        case .fn: return "🌐 Fn"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        case .command: return "⌘ Command"
        case .shift: return "⇧ Shift"
        case .rightOption: return "Right ⌥ Option"
        case .rightCommand: return "Right ⌘ Command"
        }
    }
    static func modifierPrefix(_ carbon: UInt32) -> String {
        var s = ""
        if carbon & 0x1000 != 0 { s += "⌃" }
        if carbon & 0x0800 != 0 { s += "⌥" }
        if carbon & 0x0200 != 0 { s += "⇧" }
        if carbon & 0x0100 != 0 { s += "⌘" }
        return s
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
}
