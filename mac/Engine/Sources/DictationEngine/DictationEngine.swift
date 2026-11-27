import AppKit
import AVFoundation
import ApplicationServices
import Carbon

/// Invalidates callbacks already queued before stop, including across a later restart.
struct EngineLifecycle {
    private(set) var generation: UInt64 = 0
    private(set) var isRunning = false
    private(set) var isStopped = false

    mutating func start() -> UInt64 {
        if !isRunning { generation &+= 1 }
        isRunning = true; isStopped = false
        return generation
    }

    mutating func stop() {
        generation &+= 1; isRunning = false; isStopped = true
    }

    func accepts(_ generation: UInt64) -> Bool { isRunning && self.generation == generation }
    // First-run onboarding checks the mic before Accessibility and engine startup.
    func allowsMicCheck(_ generation: UInt64) -> Bool { !isStopped && self.generation == generation }
}

protocol EngineMicrophone: AnyObject {
    var onFailure: ((String) -> Void)? { get set }
    var level: Float { get }
    func prepare()
    func warm(keepAlive: Double)
    @discardableResult func beginStreaming(since: Double, maxPreRoll: Double, sink: @escaping (Data) -> Void) -> Double
    func endStreaming(keepAlive: Double)
    func shutdown()
}

extension MicEngine: EngineMicrophone {}

/// The real engine: triggers → microphone (pre-warmed, pre-roll) → STT socket → speculative
/// rewrite → paste. Ported from KoEn Dictation v1.4 (main.swift + worker.py) without Python
/// and without API keys on the device.
@MainActor
public final class DictationEngine: DictationEngineProtocol {
    public nonisolated static var allowedSpeechLanguages: [String] { SpeechLanguagePolicy.allowedLanguages }
    public private(set) var state: EngineState = .idle { didSet { if state != oldValue { onStateChange?(state) } } }
    public var onStateChange: ((EngineState) -> Void)?
    public var onLevel: LevelHandler?
    public var insertIntoOwnWindow: ((String) -> Bool)?
    public var onRecordingNotice: ((DictationNotice?) -> Void)?
    private let recovery: DictationRecoveryStore
    private var fixtureTarget: Paster.Target?
    public var recoveryRecords: [DictationRecoveryRecord] { recovery.list().filter { !$0.id.hasPrefix(DeliveryRecord.diagnosticIDPrefix) } }
    public var onDiagnostic: ((DiagnosticEvent) -> Void)?
    public var onDelivery: ((DeliveryRecord) -> Bool)?
    public var localTranscriber: LocalDictationTranscriber?
    private let localDictionary: LocalPersonalDictionary
    /// Hands-free sessions only: every PCM chunk (24 kHz mono Int16) sent to STT, on the audio queue.
    /// The app feeds an on-device recognizer that listens for the end phrase. Never stored or logged.
    public var onHandsFreeAudio: ((Data) -> Void)?
    /// STT prompt hint appended for hands-free turns (e.g. the end phrases). Empty = none.
    public var handsFreePromptHint = ""
    /// False in the app's dry-run mode: hands-free never presses Return.
    public var handsFreeSubmitAllowed = true
    /// Prepended to the next hands-free insertion (e.g. a space after the user's own draft). Reset after use.
    public var handsFreeInsertPrefix = ""
    /// Hands-free text actually inserted (bundle id, text), so the app can recognise its own leftovers later.
    public var onHandsFreeInserted: ((String?, String) -> Void)?
    /// Hands-free only: called right before typing (target bundle id) so the app can re-activate the
    /// target and re-focus its input field. Returns how long to wait before typing.
    public var prepareHandsFreeDelivery: ((String?) -> Double)?
    private var completeAudio: [String: Bool] = [:]

    private enum Origin: Equatable { case modifier(Int), mouse(Int), key(Int), manual, handsFree }
    private struct Active {
        let id: String
        let mode: DictationMode
        let origin: Origin
        let target: Paster.Target
        let pressAt: Double
        let beganAt: Double
        var firstAudioAt: Double?
        var started = false
        var released: Double?
        /// The start cue played for this dictation, so the end cue pairs with it.
        var cued = false
        var stopping = false
        /// Hands-free (wake phrase) dictation: press Return after a confirmed paste.
        var submit = false
        /// Ephemeral AX screen terms captured at turn start (never logged).
        var screenTerms: [String] = []
        /// True when this turn runs 100% locally (Free Local Mode, zero external APIs).
        var localMode = false
        /// Captured 24 kHz mono Int16 PCM for local transcription turns.
        var localAudio = Data()
        /// Benchmark only: receives the stripped result instead of delivery.
        var sink: ((String, Double, Bool) -> Void)?
        init(id: String, mode: DictationMode, origin: Origin, target: Paster.Target, pressAt: Double, beganAt: Double = uptime(),
             screenTerms: [String] = [], localMode: Bool = false) {
            self.id = id; self.mode = mode; self.origin = origin; self.target = target; self.pressAt = pressAt; self.beganAt = beganAt
            self.screenTerms = screenTerms; self.localMode = localMode
        }
    }

    private var configuration: EngineConfiguration?
    private var server: ServerClient?
    private var socket: RealtimeSTTSocket?
    private var pipeline: TurnPipeline?
    private lazy var mic: EngineMicrophone = MicEngine()
    private var lifecycle = EngineLifecycle()
    private let paster = Paster()
    private var router: InputTapRouter?
    private var gate = ControlGate()
    private var heldKeys = HeldKeys()
    private var timers: [Timer] = []
    private var wakeObservers: [(center: NotificationCenter, token: NSObjectProtocol)] = []
    private var busyWithoutDictation = 0
    /// A released dictation always ends within the pipeline timeouts (STT final 15 s + rewrite 12 s).
    static let stuckAfterRelease = 60.0
    private var hotkeyRefs: [EventHotKeyRef] = []
    private var hotkeyModes: [UInt32: DictationMode] = [:]
    private var hotkeyHandler: EventHandlerRef?
    private var heldHotkey: UInt32?
    private var active: Active?
    private var lastResult = ""
    private let recent = RecentContext()
    private let learner = CorrectionLearner()
    /// Recent external pastes to check once for an in-place correction (element + offset + text only).
    private struct PasteWatch { let id: String; let pid: pid_t?; let insertion: Paster.Insertion; let at: Double }
    private var watches: [PasteWatch] = []
    private var watchTimer: Timer?
    private var captureHandler: ((TriggerKind?) -> Void)?
    private var captureTimeout: Timer?
    private var levelTimer: Timer?
    private var maxRecordingTimer: Timer?
    private var recordingWarningTimer: Timer?
    // Audio cues (KoEn's start "Tink" kept; "Pop" added as its end pair). NSSound plays at this
    // volume relative to the system output volume, so muting the Mac silences them.
    // Levels (Dan 2026-10-05: start was too quiet): Tink is a ~16 ms click that lands on the first
    // syllable and gets masked, Pop plays into silence — start 0.9 (+11 dB), end 0.45 (+5 dB).
    // Peaks stay at -9.7 / -18 dBFS (no clipping).
    static let startCueVolume: Float = 0.9
    static let endCueVolume: Float = 0.45
    private lazy var tick: NSSound? = { let s = NSSound(named: "Tink"); s?.volume = Self.startCueVolume; return s }()
    private lazy var endCue: NSSound? = { let s = NSSound(named: "Pop"); s?.volume = Self.endCueVolume; return s }()
    private lazy var errorSound: NSSound? = { let s = NSSound(named: "Basso"); s?.volume = 0.4; return s }()
    /// Until this uptime the end cue may still be audible; the next pre-roll starts after it.
    private var endCueAudibleUntil = 0.0

    public nonisolated init() { recovery = DictationRecoveryStore(); localDictionary = LocalPersonalDictionary() }
    init(microphone: EngineMicrophone) { recovery = DictationRecoveryStore(); localDictionary = LocalPersonalDictionary(); mic = microphone }
    /// Dependency-injected engine runs the same capture/finalization path without input taps or a live microphone.
    init(microphone: EngineMicrophone, pipeline: TurnPipeline, recovery: DictationRecoveryStore, configuration: EngineConfiguration,
         localDictionary: LocalPersonalDictionary = LocalPersonalDictionary()) {
        self.recovery = recovery; self.localDictionary = localDictionary; self.mic = microphone; self.pipeline = pipeline; self.configuration = configuration
        fixtureTarget = Paster.Target(app: nil, element: nil)
        _ = lifecycle.start()
        pipeline.onEvent = { [weak self] in self?.pipelineEvent($0) }
    }

    // MARK: lifecycle

    public func start(configuration: EngineConfiguration, tokens: AccessTokenProvider) throws {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw EngineError.microphoneDenied }
        guard AXIsProcessTrusted() else { throw EngineError.accessibilityMissing }
        let wasRunning = lifecycle.isRunning
        let previousLocal = self.configuration?.localDictationEnabled
        self.configuration = configuration
        recent.enabled = configuration.useRecentContext
        paster.keepTranscriptOnClipboard = configuration.keepTranscriptOnClipboard
        let generation = lifecycle.start()
        if server == nil || server?.baseURL != configuration.apiBaseURL {
            let server = ServerClient(baseURL: configuration.apiBaseURL, tokens: tokens)
            let socket = RealtimeSTTSocket(server: server)
            let pipeline = TurnPipeline(socket: socket, rewriter: server, context: recent)
            pipeline.onEvent = { [weak self] event in
                guard let self, self.lifecycle.accepts(generation) else { return }
                self.pipelineEvent(event)
            }
            self.server = server; self.socket = socket; self.pipeline = pipeline
        }
        do { try reinstallInputTap() } catch { stop(); throw error }
        registerHotkeys(configuration.triggers)
        mic.onFailure = { [weak self] code in Task { @MainActor in
            guard let self, self.lifecycle.accepts(generation) else { return }
            self.microphoneFailed(code)
        } }
        mic.prepare()
        _ = tick; _ = endCue // load the cues now so the first one plays without a disk read
        timers.forEach { $0.invalidate() }
        let gateTimer = Timer(timeInterval: 0.015, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lifecycle.accepts(generation) else { return }
                self.perform(self.gate.poll(now: uptime()))
            }
        }
        let maintenance = Timer(timeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lifecycle.accepts(generation) else { return }
                self.checkInputHealth()
                guard self.active == nil, self.configuration?.localDictationEnabled != true else { return }
                await self.pipeline?.maintain()
                guard self.lifecycle.accepts(generation) else { return }
                await self.server?.warm()
            }
        }
        timers = [gateTimer, maintenance]
        timers.forEach { RunLoop.main.add($0, forMode: .common) }
        observeWakeAndUnlock()
        if configuration.localDictationEnabled {
            state = .idle
            let local = localTranscriber
            Task { await local?.prewarm() }
        } else {
            if !(wasRunning && previousLocal == false && state == .idle) {
                state = .connecting
            }
            Task { [weak self] in
                guard let self, self.lifecycle.accepts(generation) else { return }
                await self.server?.warm()
                guard self.lifecycle.accepts(generation) else { return }
                await self.pipeline?.maintain()
                guard self.lifecycle.accepts(generation) else { return }
                if self.state == .connecting { self.state = .idle }
            }
        }
    }

    /// Recreate the event tap (e.g. right after Accessibility flips to granted). No relaunch needed.
    public func reinstallInputTap() throws {
        guard lifecycle.isRunning else { return }
        let generation = lifecycle.generation
        router?.uninstall(); router = nil
        let kinds: [CGEventType] = [.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .otherMouseUp, .scrollWheel]
        let mask = kinds.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let router = InputTapRouter(mouseButtons: mouseButtons(configuration?.triggers ?? [])) { [weak self] type, event in
            MainActor.assumeIsolated {
                guard let self, self.lifecycle.accepts(generation) else { return }
                self.inputEvent(type, event)
            }
        }
        guard router.install(mask: mask) != nil else {
            // Active taps need Accessibility; if that is granted and the tap still fails, Input Monitoring is the gap.
            throw AXIsProcessTrusted() ? EngineError.inputMonitoringMissing : EngineError.accessibilityMissing
        }
        self.router = router
    }

    /// Runs every 20 s: the tap is valid and enabled, expired keys are dropped, and a dictation or
    /// pipeline turn stuck past every timeout is cancelled, so a trigger can never stay dead.
    private func checkInputHealth() {
        guard lifecycle.isRunning else { return }
        heldKeys.expireKeys(now: uptime())
        if let tap = router?.tap {
            if !CFMachPortIsValid(tap) {
                Log.input.error("tap_invalid_reinstall")
                do { try reinstallInputTap() } catch { Log.input.error("tap_reinstall_failed") }
            } else if !CGEvent.tapIsEnabled(tap: tap) {
                Log.input.notice("tap_reenabled")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        if let released = active?.released, uptime() - released > Self.stuckAfterRelease {
            Log.engine.error("dictation_stuck_cancelled")
            cancelActive()
        }
        busyWithoutDictation = active == nil && pipeline?.isBusy == true ? busyWithoutDictation + 1 : 0
        if busyWithoutDictation >= 3 {
            Log.engine.error("pipeline_stuck_cancelled")
            busyWithoutDictation = 0
            let generation = lifecycle.generation
            Task { [weak self] in
                guard let self, self.lifecycle.accepts(generation) else { return }
                await self.pipeline?.cancel()
            }
        }
    }

    /// Key-ups at the lock screen or during sleep never reach the tap: start clean after wake/unlock.
    private func observeWakeAndUnlock() {
        let generation = lifecycle.generation
        wakeObservers.forEach { $0.center.removeObserver($0.token) }; wakeObservers = []
        let reset: @Sendable (Notification) -> Void = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lifecycle.accepts(generation) else { return }
                Log.input.notice("input_reset_after_wake")
                if case .modifier? = self.active?.origin, self.active?.released == nil { self.cancelActive() }
                self.gate.reset(); self.modifierCandidate = nil; self.heldKeys.reset()
                self.checkInputHealth()
            }
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification, NSWorkspace.sessionDidBecomeActiveNotification] {
            wakeObservers.append((workspace, workspace.addObserver(forName: name, object: nil, queue: .main, using: reset)))
        }
        let distributed = DistributedNotificationCenter.default()
        wakeObservers.append((distributed, distributed.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main, using: reset)))
    }

    public func stop() {
        guard !lifecycle.isStopped else { return }
        lifecycle.stop() // Fence queued input before any callback can run again.
        if let id = active?.id {
            mic.endStreaming(keepAlive: 0)
            try? recovery.seal(id)
            try? recovery.checkpoint(id, error: "engine_stopped")
        }
        active = nil
        gate.reset(); heldKeys.reset(); modifierCandidate = nil; modifierDownAt = nil
        heldHotkey = nil; captureHeld = []; captureTypedKey = false; busyWithoutDictation = 0
        levelTimer?.invalidate(); levelTimer = nil
        maxRecordingTimer?.invalidate(); maxRecordingTimer = nil
        recordingWarningTimer?.invalidate(); recordingWarningTimer = nil
        watches = []; watchTimer?.invalidate(); watchTimer = nil
        timers.forEach { $0.invalidate() }; timers = []
        wakeObservers.forEach { $0.center.removeObserver($0.token) }; wakeObservers = []
        router?.uninstall(); router = nil
        unregisterHotkeys()
        if let hotkeyHandler { RemoveEventHandler(hotkeyHandler); self.hotkeyHandler = nil }
        pipeline?.shutdown()
        socket?.close()
        pipeline = nil; socket = nil; server = nil
        mic.onFailure = nil
        mic.endStreaming(keepAlive: 0)
        mic.shutdown()
        state = .idle
        finishCapture(nil)
    }

    public func updateTriggers(_ triggers: [TriggerKind]) {
        configuration?.triggers = triggers
        guard lifecycle.isRunning else { return }
        router?.mouseButtons.withValue { $0 = mouseButtons(triggers) }
        registerHotkeys(triggers)
    }

    public func updateSoundsEnabled(_ enabled: Bool) { configuration?.soundsEnabled = enabled }

    public func updateRecentContextEnabled(_ enabled: Bool) {
        configuration?.useRecentContext = enabled
        recent.enabled = enabled
        if !enabled { watches = [] }
    }

    public func updateScreenContextEnabled(_ enabled: Bool) {
        configuration?.useScreenContext = enabled
    }

    public func updateLocalDictationEnabled(_ enabled: Bool) {
        configuration?.localDictationEnabled = enabled
        if enabled {
            socket?.close()
            let local = localTranscriber
            Task { await local?.prewarm() }
        } else {
            let local = localTranscriber
            Task { await local?.unload() }
        }
    }

    public func updateKeepTranscriptOnClipboard(_ enabled: Bool) {
        configuration?.keepTranscriptOnClipboard = enabled
        paster.keepTranscriptOnClipboard = enabled
    }

    public func discardRecoveryAudio() throws {
        guard active == nil, pipeline?.isBusy != true else { throw FailureCode("dictation_busy") }
        try recovery.discardAll()
    }

    public func clearRecentContext() {
        recent.clear(); learner.clear(); watches = []
    }

    public func captureNextTrigger(timeout: TimeInterval, _ handler: @escaping (TriggerKind?) -> Void) {
        guard lifecycle.isRunning else { handler(nil); return }
        let generation = lifecycle.generation
        captureTimeout?.invalidate()
        captureHandler = handler
        captureTimeout = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lifecycle.accepts(generation) else { return }
                self.finishCapture(nil)
            }
        }
    }

    public func pasteLastResult() {
        guard !lastResult.isEmpty, active == nil else { return }
        deliver(lastResult, to: paster.captureTarget())
    }

    /// Diagnostics: run one dictation through the real path (STT socket → rewrite → paste into the
    /// focused field) with a recorded PCM16 mono 24 kHz clip instead of the microphone, paced in
    /// real time with no added silence. Returns the release time (uptime) or nil if it could not start.
    // MARK: hands-free (wake phrase)

    public var isHandsFreeActive: Bool { active?.origin == .handsFree && active?.released == nil }

    /// Start a dictation without a held key, into the field focused right now. Returns false if busy.
    /// `expectedBundleID`: refuse unless that app is frontmost right now, so a focus race can never
    /// paste (or press Return) into whatever app the user switched to.
    @discardableResult public func beginHandsFree(mode: DictationMode, expectedBundleID: String? = nil) -> Bool {
        if let expectedBundleID, NSWorkspace.shared.frontmostApplication?.bundleIdentifier != expectedBundleID {
            Log.engine.notice("handsfree_refused_focus_changed"); return false
        }
        if !handsFreePromptHint.isEmpty { pipeline?.turnPromptSuffix = handsFreePromptHint }
        begin(mode: mode, origin: .handsFree, pressAt: uptime())
        if active?.origin != .handsFree { pipeline?.turnPromptSuffix = "" }
        return active?.origin == .handsFree
    }

    /// End a hands-free dictation. `submit`: press Return after the text is pasted.
    public func finishHandsFree(submit: Bool) {
        guard active?.origin == .handsFree, active?.released == nil else { return }
        active?.submit = submit
        release()
    }

    public func cancelHandsFree() { if active?.origin == .handsFree { cancelActive() } }

    /// Diagnostics benchmark: stream a fixed 24 kHz mono PCM clip in real time as a hands-free turn
    /// (the app's end-phrase listener sees the same audio). Never pastes; `sink` gets the stripped
    /// result and release-to-ready ms. Returns the start uptime, or nil if busy.
    public func runHandsFreeFixture(_ pcm: Data, sink: @escaping (String, Double, Bool) -> Void) async -> Double? {
        guard let pipeline, canStart else { return nil }
        let id = DeliveryRecord.diagnosticIDPrefix + UUID().uuidString
        do { try recovery.begin(id: id, mode: .bilingual, appName: "Synthetic QA", bundleID: nil) } catch { return nil }
        if !handsFreePromptHint.isEmpty { pipeline.turnPromptSuffix = handsFreePromptHint }
        var a = Active(id: id, mode: .bilingual, origin: .handsFree, target: Paster.Target(app: nil, element: nil), pressAt: uptime())
        a.sink = sink
        active = a
        pipeline.prepare(id: id, mode: .bilingual, app: nil)
        announceListening()
        let generation = lifecycle.generation
        Task { [weak self] in
            guard let self, self.lifecycle.accepts(generation), self.active?.id == id else { return }
            await pipeline.start(id: id, mode: .bilingual, app: nil)
        }
        guard active?.id == id else { return nil }
        active?.firstAudioAt = uptime()
        let begin = uptime(); var offset = 0
        while offset < pcm.count, active?.id == id, active?.released == nil, active?.stopping == false {
            let end = min(offset + 2400, pcm.count)
            let chunk = pcm.subdata(in: offset..<end)
            try? recovery.append(chunk, id: id)
            pipeline.audio(chunk); onHandsFreeAudio?(chunk); offset = end
            let due = begin + Double(offset) / 48000
            if due > uptime() { try? await Task.sleep(nanoseconds: UInt64((due - uptime()) * 1e9)) }
        }
        if active?.id == id, active?.released == nil, active?.stopping == false { release() }
        return begin
    }

    /// Diagnostics only: run a fixed transcript through the exact hands-free delivery (strip, type,
    /// Return) into the field focused right now. No microphone, no STT.
    public func debugDeliverHandsFree(_ text: String, submit: Bool) {
        guard active == nil else { return }
        deliver(text, to: paster.captureTarget(), handsFree: true, submit: submit)
    }

    public func runFixture(_ pcm: Data, mode: DictationMode) async -> Double? {
        guard let pipeline, canStart else { return nil }
        let id = DeliveryRecord.diagnosticIDPrefix + UUID().uuidString
        do { try recovery.begin(id: id, mode: mode, appName: "Synthetic QA", bundleID: nil) }
        catch { return nil }
        onRecordingNotice?(nil)
        active = Active(id: id, mode: mode, origin: .manual, target: fixtureTarget ?? paster.captureTarget(), pressAt: uptime())
        pipeline.prepare(id: id, mode: mode, app: active?.target.bundleID)
        announceListening()
        let generation = lifecycle.generation
        let appBundle = active?.target.bundleID
        Task { [weak self] in
            guard let self, self.lifecycle.accepts(generation), self.active?.id == id else { return }
            await pipeline.start(id: id, mode: mode, app: appBundle)
        }
        guard active?.id == id else { return nil }
        active?.firstAudioAt = uptime()
        if let configuration { armRecordingLimit(id: id, generation: lifecycle.generation, configuration: configuration) }
        let begin = uptime(); var offset = 0
        while offset < pcm.count, active?.id == id, active?.released == nil, active?.stopping == false {
            let end = min(offset + 2400, pcm.count)
            let chunk = pcm.subdata(in: offset..<end)
            do { try recovery.append(chunk, id: id) } catch { break }
            pipeline.audio(chunk); offset = end
            let due = begin + Double(offset) / 48000
            if due > uptime() { try? await Task.sleep(nanoseconds: UInt64((due - uptime()) * 1e9)) }
        }
        guard active?.id == id else { return nil }
        release()
        while active?.id == id, active?.released == nil { await Task.yield() }
        return active?.released ?? uptime()
    }

    /// Onboarding microphone check: runs the mic without STT and reports levels.
    public func startMicLevelCheck(_ handler: @escaping LevelHandler) {
        let generation = lifecycle.generation
        guard lifecycle.allowsMicCheck(generation) else { return }
        mic.warm(keepAlive: 30)
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lifecycle.allowsMicCheck(generation), self.levelTimer != nil else { return }
                handler(self.mic.level)
                guard self.lifecycle.allowsMicCheck(generation), self.levelTimer != nil else { return }
                self.mic.warm(keepAlive: 2)
            }
        }
    }

    public func stopMicLevelCheck() {
        levelTimer?.invalidate(); levelTimer = nil
        guard !lifecycle.isStopped else { return }
        mic.endStreaming(keepAlive: 1)
    }

    // MARK: triggers

    private func mouseButtons(_ triggers: [TriggerKind]) -> Set<Int> {
        Set(triggers.compactMap { if case .mouseButton(let number, _) = $0 { return number }; return nil })
    }

    /// Modifier-hold triggers (Control alone, Fn, Fn+Shift, Right Option, …) with their hold delay.
    private var modifierTriggers: [(keys: Set<ModifierKey>, mode: DictationMode, delay: Double)] {
        (configuration?.triggers ?? []).compactMap { trigger in
            switch trigger {
            case .controlHold(let mode, let ms): return ([.control], mode, Double(ms) / 1000)
            case .modifierHold(let keys, let mode, let ms): return (Set(keys), mode, Double(ms) / 1000)
            default: return nil
            }
        }
    }

    private func mouseMode(_ button: Int) -> DictationMode? {
        for trigger in configuration?.triggers ?? [] {
            if case .mouseButton(let number, let mode) = trigger, number == button { return mode }
        }
        return nil
    }

    private var modifierCandidate: Int?
    private var modifierDownAt: Double?
    private var captureHeld = Set<ModifierKey>()
    private var captureTypedKey = false

    private var heldModifiers: Set<ModifierKey> { heldKeys.held }

    /// Exact match: the held groups equal the trigger's groups, and side-specific keys are the right ones.
    nonisolated static func matches(_ keys: Set<ModifierKey>, held: Set<ModifierKey>) -> Bool {
        func group(_ k: ModifierKey) -> ModifierKey { k == .rightOption ? .option : k == .rightCommand ? .command : k }
        let want = Set(keys.map(group)), have = Set(held.filter { $0 != .rightOption && $0 != .rightCommand })
        guard want == have else { return false }
        if keys.contains(.rightOption) && !held.contains(.rightOption) { return false }
        if keys.contains(.rightCommand) && !held.contains(.rightCommand) { return false }
        return true
    }

    private func inputEvent(_ type: CGEventType, _ event: CGEvent) {
        guard lifecycle.isRunning else { return }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if case .modifier? = active?.origin { cancelActive() }
            Log.input.notice("tap_disabled reason=\(type == .tapDisabledByTimeout ? "timeout" : "user_input", privacy: .public)")
            gate.reset(); modifierCandidate = nil; heldKeys.reset(); return
        }
        if type == .flagsChanged {
            heldKeys.flagsChanged(code: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags)
        } else if type != .keyDown, type != .keyUp, heldKeys.resync(flags: event.flags) > 0 {
            // Key events carry an Fn flag for arrows/F-keys; mouse events carry exactly what's held.
            Log.input.notice("stale_modifiers_dropped")
        }
        if captureHandler != nil, capture(type, event) { return }
        switch type {
        case .flagsChanged:
            modifiersChanged(at: Self.eventTime(event))
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            heldKeys.keyDown(code, at: uptime()); perform(gate.interfere())
            if code == 53 { escape() } // Esc also reaches the frontmost app.
        case .keyUp:
            heldKeys.keyUp(event.getIntegerValueField(.keyboardEventKeycode))
        case .leftMouseDown, .rightMouseDown, .scrollWheel:
            perform(gate.interfere())
        case .otherMouseDown, .otherMouseUp:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard let mode = mouseMode(button) else { perform(gate.interfere()); break }
            if type == .otherMouseDown, heldModifiers.isEmpty {
                if canStart { begin(mode: mode, origin: .mouse(button), pressAt: Self.eventTime(event)) }
            } else if type == .otherMouseUp, active?.origin == .mouse(button) {
                release()
            }
        default: break
        }
    }

    private func modifiersChanged(at time: Double) {
        let held = heldModifiers
        let triggers = modifierTriggers
        if case .modifier(let index)? = active?.origin, active?.released == nil, index < triggers.count {
            let keys = triggers[index].keys
            if Self.matches(keys, held: held) { return }
            // Letting go of any part of the combo ends the dictation; adding another modifier is a chord → cancel.
            let groups = { (s: Set<ModifierKey>) in Set(s.map { $0 == .rightOption ? .option : $0 == .rightCommand ? .command : $0 }) }
            if groups(held).isSubset(of: groups(keys)) { gate.reset(); modifierCandidate = nil; release() } else { gate.reset(); modifierCandidate = nil; cancelActive() }
            return
        }
        let match = triggers.firstIndex { Self.matches($0.keys, held: held) }
        if match != modifierCandidate {
            gate.reset(); modifierCandidate = match
            if match != nil {
                modifierDownAt = time
                // Warm the microphone the moment the combo is down, inside the hold delay.
                if canStart, micAllowed { mic.warm(keepAlive: 1.5) }
            }
        }
        if let m = match {
            perform(gate.modifiers(control: true, other: false, keysDown: heldKeys.anyKeyDown(now: uptime()), now: uptime(), delay: triggers[m].delay))
        } else {
            _ = gate.modifiers(control: false, other: false, keysDown: false, now: uptime(), delay: 0)
        }
    }

    private func perform(_ action: ControlGate.Action) {
        guard lifecycle.isRunning else { return }
        switch action {
        case .start:
            let triggers = modifierTriggers
            if canStart, let m = modifierCandidate, m < triggers.count {
                begin(mode: triggers[m].mode, origin: .modifier(m), pressAt: modifierDownAt ?? uptime())
            }
        case .stop:
            if case .modifier? = active?.origin { release() }
        case .cancel:
            if case .modifier? = active?.origin, active?.released == nil { cancelActive() }
        case .none: break
        }
    }

    /// While capturing ("click, then press any key or mouse button"), the next input is reported
    /// instead of dictating: a modifier or modifier combo (reported when released), a key (with
    /// modifiers), or a mouse side button.
    private func capture(_ type: CGEventType, _ event: CGEvent) -> Bool {
        switch type {
        case .flagsChanged:
            let held = heldModifiers
            captureHeld.formUnion(held)
            if held.isEmpty, !captureHeld.isEmpty {
                defer { captureHeld = []; captureTypedKey = false }
                if !captureTypedKey {
                    var keys = captureHeld
                    if keys.contains(.rightOption) { keys.remove(.option) }
                    if keys.contains(.rightCommand) { keys.remove(.command) }
                    finishCapture(.modifierHold(keys: ModifierKey.allCases.filter(keys.contains), mode: .bilingual, holdMilliseconds: 180))
                }
            }
            return true
        case .otherMouseDown:
            let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
            guard button >= 2 else { return false }
            captureHeld = []
            finishCapture(.mouseButton(number: button, mode: .bilingual)); return true
        case .keyDown:
            captureTypedKey = true
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            finishCapture(.key(keyCode: code, modifiers: Self.carbonModifiers(event.flags), mode: .bilingual)); return true
        default: return false
        }
    }

    private func finishCapture(_ trigger: TriggerKind?) {
        captureTimeout?.invalidate(); captureTimeout = nil
        let handler = captureHandler; captureHandler = nil
        gate.reset()
        handler?(trigger)
    }

    private func registerHotkeys(_ triggers: [TriggerKind]) {
        guard lifecycle.isRunning else { return }
        unregisterHotkeys()
        if hotkeyHandler == nil {
            var events = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                          EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
            let opaque = Unmanaged.passUnretained(self).toOpaque()
            InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var hotkey = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hotkey)
                let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
                let at = GetEventTime(event) // seconds since boot, same clock as systemUptime
                let engine = Unmanaged<DictationEngine>.fromOpaque(context).takeUnretainedValue()
                let generation = MainActor.assumeIsolated { engine.lifecycle.generation }
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard engine.lifecycle.accepts(generation) else { return }
                    engine.hotkey(hotkey.id, down: down, at: at > 0 ? at : uptime())
                } }
                return noErr
            }, 2, &events, opaque, &hotkeyHandler)
        }
        var index: UInt32 = 1
        for trigger in triggers {
            guard case .key(let code, let modifiers, let mode) = trigger else { continue }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(code), modifiers, EventHotKeyID(signature: 0x53564F43, id: index), GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { hotkeyRefs.append(ref); hotkeyModes[index] = mode }
            else { Log.input.error("hotkey_failed status=\(status, privacy: .public)") }
            index += 1
        }
    }

    private func unregisterHotkeys() {
        hotkeyRefs.forEach { UnregisterEventHotKey($0) }
        hotkeyRefs = []; hotkeyModes = [:]
    }

    private func hotkey(_ id: UInt32, down: Bool, at: Double) {
        guard lifecycle.isRunning, let mode = hotkeyModes[id] else { return }
        if down {
            guard heldHotkey == nil else { return }
            heldHotkey = id
            if captureHandler != nil { return }
            if canStart { begin(mode: mode, origin: .key(Int(id)), pressAt: at) }
        } else {
            heldHotkey = nil
            if active?.origin == .key(Int(id)) { release() }
        }
    }

    // MARK: dictation

    private var micAllowed: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    private var canStart: Bool {
        guard lifecycle.isRunning, active == nil, pipeline?.isBusy != true else { return false }
        switch state { case .preparing, .listening, .processing: return false; default: return true }
    }

    func beginForTesting(mode: DictationMode, pressAt: Double = uptime()) {
        begin(mode: mode, origin: .manual, pressAt: pressAt)
    }

    func releaseForTesting() { release() }
    func cancelForTesting() { cancelActive() }

    private func begin(mode: DictationMode, origin: Origin, pressAt: Double) {
        guard canStart, let pipeline, let configuration else { return }
        let generation = lifecycle.generation
        let beganAt = uptime()
        if fixtureTarget == nil {
            guard AXIsProcessTrusted() else { fail(.accessibilityMissing); return }
            guard micAllowed else { fail(.microphoneDenied); return }
        }
        // Start warming the microphone before any AX or disk work so cold AVAudioEngine startup overlaps.
        mic.warm(keepAlive: 20)
        let id = UUID().uuidString
        let target = fixtureTarget ?? paster.captureTarget()
        let screenTerms = fixtureTarget == nil ? ScreenContext.capture(target: target, enabled: configuration.useScreenContext) : []
        let isLocal = configuration.localDictationEnabled
        do { try recovery.begin(id: id, mode: mode, appName: target.app?.localizedName, bundleID: target.bundleID) }
        catch { mic.endStreaming(keepAlive: 0); fail(.server("local_storage_unavailable")); return }
        onRecordingNotice?(nil)
        active = Active(id: id, mode: mode, origin: origin, target: target, pressAt: pressAt, beganAt: beganAt,
                        screenTerms: screenTerms, localMode: isLocal)
        if !isLocal {
            pipeline.prepare(id: id, mode: mode, app: target.bundleID, screenTerms: screenTerms)
        }
        let once = Once()
        let since = Self.preRollStart(pressAt: pressAt, lead: configuration.prerollLeadSeconds, endCueAudibleUntil: endCueAudibleUntil)
        let journal = recovery
        let handsFreeTap = origin == .handsFree ? onHandsFreeAudio : nil
        mic.beginStreaming(since: since, maxPreRoll: configuration.prerollMaxSeconds) { [weak self] data in
            do { try journal.append(data, id: id) }
            catch {
                DispatchQueue.main.async { MainActor.assumeIsolated {
                    guard let self, self.active?.id == id else { return }
                    self.release()
                    self.onRecordingNotice?(.saveFailed)
                } }
                return
            }
            handsFreeTap?(data)
            let first = once.first()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.lifecycle.accepts(generation), self.active?.id == id else { return }
                    if isLocal {
                        self.active?.localAudio.append(data)
                    } else {
                        self.pipeline?.audio(data)
                    }
                    if first, let a = self.active {
                        let now = uptime()
                        self.active?.firstAudioAt = now
                        Log.engine.info("press_to_first_audio_ms=\(ms(now - a.pressAt), privacy: .public)")
                    }
                }
            }
        }
        // Record-first: enter active listening immediately while STT connects in parallel and flushes buffered audio.
        announceListening()
        levelTimer?.invalidate()
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lifecycle.accepts(generation), self.active?.id == id else { return }
                self.onLevel?(self.mic.level)
            }
        }
        armRecordingLimit(id: id, generation: generation, configuration: configuration)
        if !isLocal {
            Task { [weak self] in
                guard let self, self.lifecycle.accepts(generation), self.active?.id == id else { return }
                if self.fixtureTarget == nil {
                    // Check in-place corrections asynchronously before prompt/context assembly so AX never stalls listening.
                    self.checkCorrections(onlyPid: target.app?.processIdentifier ?? -1)
                    guard self.lifecycle.accepts(generation), self.active?.id == id else { return }
                }
                await pipeline.start(id: id, mode: mode, app: target.bundleID, screenTerms: screenTerms)
            }
        } else {
            active?.started = true
        }
    }

    private func armRecordingLimit(id: String, generation: UInt64, configuration: EngineConfiguration) {
        let cap = max(1, configuration.maximumRecordingSeconds)
        recordingWarningTimer?.invalidate(); maxRecordingTimer?.invalidate()
        recordingWarningTimer = Timer.scheduledTimer(withTimeInterval: max(0.1, cap - configuration.recordingWarningLeadSeconds), repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lifecycle.accepts(generation), self.active?.id == id, self.active?.released == nil else { return }
                self.onRecordingNotice?(.finishingSoon(seconds: Int(min(cap, configuration.recordingWarningLeadSeconds))))
            }
        }
        maxRecordingTimer = Timer.scheduledTimer(withTimeInterval: cap, repeats: false) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.lifecycle.accepts(generation), self.active?.id == id else { return }
                Log.engine.notice("dictation_cap_reached seconds=\(cap, privacy: .public)")
                self.release()
            }
        }
    }

    public func retryTranscription(id: String) async {
        guard canStart, let pipeline, let r = recoveryRecords.first(where: { $0.id == id }),
              !r.complete, let pcm = try? Data(contentsOf: recovery.audioURL(id)), !pcm.isEmpty else { return }
        // A retry is explicit and copies its result; it never types into a newly focused document.
        active = Active(id: id, mode: r.mode, origin: .manual, target: Paster.Target(app: nil, element: nil), pressAt: uptime())
        onRecordingNotice?(.retrying)
        state = .processing(r.mode)
        await pipeline.start(id: id, mode: r.mode, app: r.bundleID)
        var offset = 0
        while offset < pcm.count, active?.id == id, !Task.isCancelled {
            let end = min(offset + 4800, pcm.count)
            pipeline.audio(pcm.subdata(in: offset..<end)); offset = end
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        guard active?.id == id else { return }
        active?.released = uptime(); pipeline.stop()
    }

    private func announceListening() {
        guard let a = active, a.released == nil, !a.stopping else { return }
        if case .listening = state { return }
        state = .listening(a.mode)
        // Start cue: immediate feedback as microphone capture and bounded pre-roll buffering start.
        if !a.cued, configuration?.soundsEnabled == true, let tick {
            tick.stop(); let played = tick.play(); active?.cued = true
            Log.engine.info("cue_start played=\(played, privacy: .public)")
        }
        let now = uptime()
        Log.engine.info("press_to_listening_ms=\(ms(now - a.pressAt), privacy: .public) begin_to_listening_ms=\(ms(now - a.beganAt), privacy: .public)")
    }

    private func release() {
        guard var a = active, a.released == nil, !a.stopping else { return }
        a.stopping = true; active = a
        mic.endStreaming(keepAlive: 20)
        levelTimer?.invalidate(); maxRecordingTimer?.invalidate(); recordingWarningTimer?.invalidate()
        // Drain audio already queued by the consumer before committing. Otherwise the final
        // syllable could be journaled but omitted from STT when a key-up/cap wins the main queue.
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated {
            guard let self, self.active?.id == a.id else { return }
            self.active?.released = uptime()
            do { try self.recovery.seal(a.id) }
            catch { self.onRecordingNotice?(.saveFailed) }
            self.playEndCue(a.cued)
            self.onRecordingNotice?(nil)
            self.onDiagnostic?(DiagnosticEvent("dictation_stop", turnID: a.id, durationMS: (uptime() - a.pressAt) * 1000))
            self.state = .processing(a.mode)
            if let current = self.active, current.localMode {
                let generation = self.lifecycle.generation
                Task { [weak self] in
                    guard let self, self.lifecycle.accepts(generation) else { return }
                    await self.finishLocalDictation(current)
                }
            } else {
                self.pipeline?.stop(releasedAt: self.active?.released ?? uptime())
            }
        } }
    }

    /// Free Local Mode offline transcription: WhisperKit large-v3-turbo (or pluggable MLX backend)
    /// + local AX screen terms (`promptTokens`) + personal replacement map. Zero external APIs.
    private func finishLocalDictation(_ a: Active) async {
        let released = a.released ?? uptime()
        guard a.localAudio.count >= 4800 else {
            active = nil; fail(.tooShort); return
        }
        guard let transcriber = localTranscriber, transcriber.isReady else {
            active = nil; fail(.server("local_model_missing")); return
        }
        let promptTerms = a.screenTerms + localDictionary.promptTerms()
        do {
            let raw = try await transcriber.transcribe(pcm24kMono: a.localAudio, mode: a.mode, promptTerms: promptTerms)
            guard active?.id == a.id else { return }
            let cleaned = localDictionary.apply(to: raw)
            guard !cleaned.isEmpty else {
                active = nil; fail(.noSpeech); return
            }
            let latencyMs = ms(uptime() - released)
            let audioSeconds = Double(a.localAudio.count) / 48_000
            try? recovery.checkpoint(a.id, raw: raw)
            try? recovery.checkpoint(a.id, final: cleaned, complete: false)
            completeAudio[a.id] = true
            onDiagnostic?(DiagnosticEvent("dictation_success", turnID: a.id, durationMS: audioSeconds * 1000, latencyMS: latencyMs))
            recent.record(id: a.id, transcript: raw, output: cleaned, mode: a.mode, app: a.target.bundleID)
            active = nil
            lastResult = cleaned
            let submit = (a.submit || (a.origin == .handsFree && EndPhrase.endsWithPhrase(cleaned))) && (a.origin != .handsFree || handsFreeSubmitAllowed)
            if let sink = a.sink { sink(EndPhrase.strip(cleaned), latencyMs, submit); state = .idle; return }
            deliver(cleaned, to: a.target, id: a.id, mode: a.mode, handsFree: a.origin == .handsFree, submit: submit)
            Log.engine.info("local_result backend=\(transcriber.backendID, privacy: .public) release_to_ready_ms=\(latencyMs, privacy: .public) audio_s=\(audioSeconds, privacy: .public)")
        } catch {
            guard active?.id == a.id else { return }
            try? recovery.checkpoint(a.id, error: "local_transcription_failed")
            active = nil
            onRecordingNotice?(.recoveryAvailable)
            Log.engine.error("local_dictation_error backend=\(transcriber.backendID, privacy: .public)")
            fail(.server("audio_saved"))
        }
    }

    /// End cue: after the stream to STT is closed, so it is never part of this recording.
    private func playEndCue(_ cued: Bool) {
        guard cued, configuration?.soundsEnabled == true, let endCue else { return }
        endCue.stop(); let played = endCue.play()
        Log.engine.info("cue_end played=\(played, privacy: .public)")
        // Pop is audible for ~0.25 s (the rest of the 1.6 s file is silence); keep a small margin.
        endCueAudibleUntil = uptime() + min(endCue.duration, 0.3)
    }

    /// Pre-roll normally reaches back `lead` seconds before the press; it never reaches back into
    /// the previous dictation's end cue (a quick re-press could otherwise record it).
    nonisolated static func preRollStart(pressAt: Double, lead: Double, endCueAudibleUntil: Double) -> Double {
        max(pressAt - lead, endCueAudibleUntil)
    }

    private func cancelActive() {
        guard lifecycle.isRunning, active != nil else { return }
        let generation = lifecycle.generation
        let id = active!.id
        mic.endStreaming(keepAlive: 20)
        try? recovery.seal(id); try? recovery.checkpoint(id, error: "cancelled")
        active = nil
        levelTimer?.invalidate(); maxRecordingTimer?.invalidate(); recordingWarningTimer?.invalidate()
        state = .idle
        Task { [weak self] in
            guard let self, self.lifecycle.accepts(generation) else { return }
            await self.pipeline?.cancel()
        }
    }

    private func escape() {
        switch state {
        case .preparing, .listening, .processing: cancelActive()
        case .held, .failed: state = .idle
        default: break
        }
    }

    private func pipelineEvent(_ event: TurnPipeline.Event) {
        guard lifecycle.isRunning else { return }
        switch event {
        case .started(let id):
            onDiagnostic?(DiagnosticEvent("dictation_start", turnID: id))
            guard let a = active, a.id == id else { return }
            active?.started = true
            Log.engine.info("press_to_stt_connected_ms=\(ms(uptime() - a.pressAt), privacy: .public)")
        case .checkpoint(let id, let text):
            guard active?.id == id else { return }
            do { try recovery.checkpoint(id, raw: text) }
            catch { onRecordingNotice?(.saveFailed) }
        case .degraded(let id, let code):
            guard active?.id == id else { return }
            try? recovery.checkpoint(id, error: code)
            active?.started = true
            onRecordingNotice?(.recordingLocally)
            Log.engine.error("dictation_recoverable code=\(code, privacy: .public)")
        case .result(let id, let text, let stats):
            guard let a = active, a.id == id else { return }
            try? recovery.seal(id)
            onDiagnostic?(DiagnosticEvent("dictation_success", turnID: id, durationMS: stats.audioSeconds * 1000, latencyMS: stats.releaseToReadyMs))
            completeAudio[id] = stats.audioComplete
            do { try recovery.checkpoint(id, final: text, complete: false) }
            catch { paster.copyToClipboard(text); Log.engine.error("dictation_final_save_failed") }
            active = nil
            lastResult = text
            // The final transcript ending in an end phrase also means "send" (the on-device listener can miss it).
            let submit = (a.submit || (a.origin == .handsFree && EndPhrase.endsWithPhrase(text))) && (a.origin != .handsFree || handsFreeSubmitAllowed)
            if let sink = a.sink { sink(EndPhrase.strip(text), stats.releaseToReadyMs, submit); state = .idle; return }
            deliver(text, to: a.target, id: id, mode: a.mode, handsFree: a.origin == .handsFree, submit: submit)
            Log.engine.info("result mode=\(stats.mode.rawValue, privacy: .public) release_to_ready_ms=\(stats.releaseToReadyMs, privacy: .public) release_to_stt_final_ms=\(stats.releaseToSTTFinalMs, privacy: .public) fallbacks=\(stats.fallbacks, privacy: .public)")
            if !stats.audioComplete {
                after(0.6) { if self.active == nil { self.fail(.server("audio_partial_saved")) } }
            }
            let seconds = stats.audioSeconds
            Task { await self.server?.reportUsage(audioSeconds: seconds, dictations: 1) }
            let generation = lifecycle.generation
            if server != nil {
                Task { [weak self] in
                    guard let self, self.lifecycle.accepts(generation), self.active == nil else { return }
                    await self.pipeline?.maintain()
                }
            }
        case .error(let id, let code):
            onDiagnostic?(DiagnosticEvent("dictation_fail", turnID: id, errorCode: code))
            guard active?.id == id else { return }
            mic.endStreaming(keepAlive: 20)
            try? recovery.seal(id); try? recovery.checkpoint(id, error: code)
            active = nil
            levelTimer?.invalidate(); maxRecordingTimer?.invalidate(); recordingWarningTimer?.invalidate()
            onRecordingNotice?(.recoveryAvailable)
            Log.engine.error("dictation_error code=\(code, privacy: .public)")
            if code == "subscription_required" || code == "STT_subscription_required" {
                fail(.server("subscription_required"))
            } else {
                fail(.server("audio_saved"))
            }
        }
    }

    /// Insert a result. A transcript is never lost: if it can't be pasted, or the paste can't be
    /// confirmed, it stays on the clipboard; a failure also shows the held pill (paste / discard).
    /// Each new dictation is reported through `onDelivery` (the app's local recent list).
    private func deliver(_ raw: String, to target: Paster.Target, id: String? = nil, mode: DictationMode = .bilingual,
                         handsFree: Bool = false, submit: Bool = false) {
        let text = handsFree ? EndPhrase.strip(raw) : raw
        if handsFree, text.isEmpty { state = .idle; Log.engine.info("handsfree_empty_after_end_phrase"); return }
        let started = Date()
        let deliveryStarted = ProcessInfo.processInfo.systemUptime
        let report = { [weak self] (outcome: DeliveryOutcome) in
            guard let self, let id else { return }
            let elapsed = (ProcessInfo.processInfo.systemUptime - deliveryStarted) * 1000
            Log.paste.info("delivery_check_ms=\(elapsed, privacy: .public) outcome=\(outcome.rawValue, privacy: .public)")
            let saved = self.onDelivery?(DeliveryRecord(id: id, text: text, mode: mode, appName: target.app?.localizedName,
                                            bundleID: target.bundleID, at: started, outcome: outcome)) ?? false
            if self.completeAudio[id] == true, saved || outcome == .pasted {
                do {
                    try self.recovery.checkpoint(id, complete: true)
                    try self.recovery.retireCompleted(id)
                    self.completeAudio[id] = nil
                }
                catch { Log.engine.error("dictation_recovery_cleanup_deferred") }
            }
        }
        let heldOnClipboard = { [weak self] in
            guard let self else { return }
            self.paster.copyToClipboard(text); self.state = .held(text); report(.failed)
        }
        // Save before attempting insertion, including AX failures and a crash during paste.
        report(.unconfirmed)
        if handsFree {
            // Typed, not pasted: works when a chat's message list (not its field) has keyboard focus.
            // Re-activate the target and re-focus its field first; focus can move during recording.
            let settle = prepareHandsFreeDelivery?(target.bundleID) ?? 0.25
            after(settle) { [weak self] in
                guard let self else { return }
                guard AXIsProcessTrusted(), let pid = target.app?.processIdentifier,
                      NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else {
                    Log.paste.notice("handsfree_held reason=focus front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public) target=\(target.bundleID ?? "nil", privacy: .public) ax=\(AXIsProcessTrusted(), privacy: .public)")
                    heldOnClipboard(); return
                }
                // Telegram (native) takes typed text even when its list has focus; Electron apps garble typed
                // Hangul under the Korean IME, so they get a Cmd-V into the field we just focused.
                let typed = target.bundleID == "ru.keepcoder.Telegram"
                let text = self.handsFreeInsertPrefix + text; self.handsFreeInsertPrefix = ""
                if typed {
                    if self.paster.keepTranscriptOnClipboard { self.paster.copyToClipboard(text) }
                    Paster.typeUnicode(text)
                } else {
                    self.paster.pasteRaw(text)
                }
                report(.pasted)
                self.onHandsFreeInserted?(target.bundleID, text.trimmingCharacters(in: .whitespaces))
                self.state = .pasted(text); self.after(0.4) { if case .pasted = self.state { self.state = .idle } }
                Log.paste.notice("handsfree_delivered method=\(typed ? "type" : "paste", privacy: .public) chars=\(text.count, privacy: .public) app=\(target.bundleID ?? "nil", privacy: .public)")
                if submit {
                    self.after(typed ? 0.3 : 0.45) {
                        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { Log.engine.notice("handsfree_submit_skipped_focus"); return }
                        for down in [true, false] { CGEvent(keyboardEventSource: nil, virtualKey: 36, keyDown: down)?.post(tap: .cgSessionEventTap) }
                        Log.engine.notice("handsfree_submitted")
                    }
                }
            }
            return
        }
        let outcome = paster.paste(text, into: target) { [weak self] check in
            report(check == .confirmed ? .pasted : check == .unconfirmed ? .unconfirmed : .failed)
            guard let self, check == .failed, self.active == nil else { return }
            switch self.state {
            case .idle, .pasted: self.state = .held(text) // the transcript is already on the clipboard
            default: break
            }
            Log.paste.info("paste_failed_after_check")
        }
        switch outcome {
        case .pasted:
            state = .pasted(text); after(0.4) { if case .pasted = self.state { self.state = .idle } }
            if let id, !id.hasPrefix(DeliveryRecord.diagnosticIDPrefix), recent.enabled, let insertion = paster.lastInsertion {
                watch(id: id, pid: target.app?.processIdentifier, insertion)
            }
        case .held(let reason):
            Log.paste.info("paste_held reason=\(reason, privacy: .public)")
            heldOnClipboard()
        case .secureField:
            Log.paste.info("paste_held reason=secure_field")
            heldOnClipboard()
        case .ownWindow:
            if insertIntoOwnWindow?(text) == true {
                if paster.keepTranscriptOnClipboard { paster.copyToClipboard(text) }
                state = .pasted(text); after(0.4) { if case .pasted = self.state { self.state = .idle } }
                report(.pasted)
            } else {
                heldOnClipboard()
            }
        }
    }

    // MARK: corrections

    private func watch(id: String, pid: pid_t?, _ insertion: Paster.Insertion) {
        watches.append(PasteWatch(id: id, pid: pid, insertion: insertion, at: uptime()))
        if watches.count > 3 { watches.removeFirst(watches.count - 3) }
        if watchTimer == nil {
            let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
                Task { @MainActor in guard let self, self.active == nil else { return }; self.checkCorrections() }
            }
            RunLoop.main.add(timer, forMode: .common); watchTimer = timer
        }
    }

    /// Re-read each recently pasted-into field once in a while for ~2 minutes. An in-place edit of
    /// the inserted words updates the recent context, and a name typed in as a fix twice is added
    /// to My words. Only the edited words are kept; the field's content is not retained or logged.
    private func checkCorrections(onlyPid: pid_t? = nil) {
        guard lifecycle.isRunning, recent.enabled, !watches.isEmpty else { return }
        let now = uptime()
        var keep: [PasteWatch] = []
        for w in watches {
            guard now - w.at >= 2, onlyPid == nil || w.pid == onlyPid else { keep.append(w); continue }
            guard let value = Paster.currentValue(of: w.insertion.element, timeout: onlyPid == nil ? 0.3 : 0.1) else { continue }
            if let c = CorrectionSignal.diff(pasted: w.insertion.text, field: value, start: w.insertion.location) {
                recent.amend(id: w.id, output: c.corrected)
                let corrected = c.corrected, turnID = w.id
                Task { [weak self] in await self?.server?.captureEdit(turnID: turnID, text: corrected) }
                let promoted = learner.observe(CorrectionSignal.terms(c))
                Log.engine.info("correction_seen learned=\(promoted.count, privacy: .public)")
                if !promoted.isEmpty {
                    let generation = learner.generation
                    Task { [weak self] in
                        guard let self, self.learner.generation == generation,
                              self.recent.enabled, let server = self.server else { return }
                        guard await server.addWords(promoted), self.learner.generation == generation else { return }
                        self.learner.confirmAdded(promoted, generation: generation)
                        self.pipeline?.sessionStale = true
                    }
                }
            } else if now - w.at < 120 {
                keep.append(w)
            }
        }
        watches = keep
        if watches.isEmpty { watchTimer?.invalidate(); watchTimer = nil }
    }

    private func fail(_ error: EngineError) {
        state = .failed(error)
        if configuration?.soundsEnabled == true { errorSound?.stop(); errorSound?.play() }
        let shown = state
        after(5) { if self.state == shown { self.state = .idle } }
    }

    private func microphoneFailed(_ code: String) {
        guard active != nil else { return }
        cancelActive(); fail(.microphoneDenied)
        Log.engine.error("mic_failed code=\(code, privacy: .public)")
    }

    private func after(_ seconds: Double, _ body: @escaping @MainActor () -> Void) {
        let generation = lifecycle.generation
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in MainActor.assumeIsolated {
            guard let self, self.lifecycle.accepts(generation) else { return }
            body()
        } }
    }

    // MARK: helpers

    nonisolated static let timebase: mach_timebase_info_data_t = { var t = mach_timebase_info_data_t(); mach_timebase_info(&t); return t }()

    /// Press time of a tapped event on the uptime clock; "now" if the stamp is implausible.
    nonisolated static func eventTime(_ event: CGEvent) -> Double {
        let now = uptime(), raw = Double(event.timestamp)
        for candidate in [raw / 1e9, raw * Double(timebase.numer) / Double(timebase.denom) / 1e9]
        where candidate > 0 && candidate <= now + 0.001 && now - candidate < 1 { return candidate }
        return now
    }

    nonisolated static func carbonModifiers(_ flags: CGEventFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.maskCommand) { mask |= UInt32(cmdKey) }
        if flags.contains(.maskShift) { mask |= UInt32(shiftKey) }
        if flags.contains(.maskAlternate) { mask |= UInt32(optionKey) }
        if flags.contains(.maskControl) { mask |= UInt32(controlKey) }
        return mask
    }
}
