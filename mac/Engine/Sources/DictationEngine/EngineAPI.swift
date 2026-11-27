import Foundation

// Public surface shared by the app shell (mac/Sources/App) and the engine. Keep this file stable;
// both sides code against it. Change it only together with docs/ARCHITECTURE.md.

public enum DictationMode: String, Codable, Sendable { case bilingual, english }

/// Modifier keys that can be held (alone or together) as a dictation trigger.
public enum ModifierKey: String, Codable, Hashable, Sendable, CaseIterable {
    case fn, control, option, command, shift, rightOption, rightCommand
}

/// What starts a dictation. Several can be active at once.
public enum TriggerKind: Codable, Hashable, Sendable {
    /// Hold Control alone for `holdMilliseconds` (default 180). Any other key/click cancels.
    /// Kept for stored settings from KoEn-era builds; equivalent to `.modifierHold([.control], …)`.
    case controlHold(mode: DictationMode, holdMilliseconds: Int)
    /// Hold exactly these modifiers (no other key) for `holdMilliseconds`; any other key/click cancels.
    case modifierHold(keys: [ModifierKey], mode: DictationMode, holdMilliseconds: Int)
    /// Zero-based mouse button number (4 = "Mouse 5" side button).
    case mouseButton(number: Int, mode: DictationMode)
    /// Virtual key code + Carbon modifier mask (0 = none), e.g. 79 = F18.
    case key(keyCode: UInt16, modifiers: UInt32, mode: DictationMode)
}

public enum EngineState: Equatable, Sendable {
    case idle
    case connecting                 // STT socket (re)connecting; audio is buffered
    case preparing(DictationMode)   // trigger down, mic warming
    case listening(DictationMode)   // first audio reached STT
    case processing(DictationMode)  // released, waiting for final text
    case pasted(String)             // final text that was pasted (never logged)
    case held(String)               // focus changed / secure field: kept for "paste last result"
    case failed(EngineError)
}

public enum EngineError: Error, Equatable, Sendable {
    case notSignedIn
    case microphoneDenied
    case accessibilityMissing
    case inputMonitoringMissing
    case noSpeech
    case tooShort
    case network(String)
    case quotaExceeded
    case server(String)
}

/// How a finished dictation reached the user: pasted and confirmed, pasted but not confirmable (it
/// also stays on the clipboard), or not pasted (left on the clipboard, held pill shown).
public enum DeliveryOutcome: String, Codable, Sendable { case pasted, unconfirmed, failed }

/// One finished dictation, reported once and again if a later paste check changes its outcome (same `id`).
public struct DeliveryRecord: Codable, Equatable, Sendable {
    public static let diagnosticIDPrefix = "diagnostic:"
    public var isDiagnostic: Bool { id.hasPrefix(Self.diagnosticIDPrefix) }
    public var id: String
    public var text: String
    public var mode: DictationMode
    public var appName: String?
    public var bundleID: String?
    public var at: Date
    public var outcome: DeliveryOutcome
    public init(id: String, text: String, mode: DictationMode, appName: String?, bundleID: String?, at: Date, outcome: DeliveryOutcome) {
        self.id = id; self.text = text; self.mode = mode; self.appName = appName; self.bundleID = bundleID; self.at = at; self.outcome = outcome
    }
}

public enum DictationNotice: Equatable, Sendable {
    case finishingSoon(seconds: Int), recordingLocally, retrying, saveFailed, recoveryAvailable
}

/// Audio level 0…1 for the HUD waveform, ~20 Hz while listening.
public typealias LevelHandler = @Sendable (Float) -> Void

/// The app gives the engine a way to get a fresh access token (refreshing if needed).
public protocol AccessTokenProvider: AnyObject, Sendable {
    func accessToken() async throws -> String
    /// A 401 can arrive before the token's local expiry. Invalidate only that rejected token;
    /// concurrent callers must share a refresh and late failures must preserve a newer token.
    func reportClientError(_ code: String) async
    func consentReviewRequired() async
    func invalidateAccessToken(_ rejectedToken: String) async
}

public extension AccessTokenProvider {
    func reportClientError(_ code: String) async {}
    func consentReviewRequired() async {}
    /// Providers without a token cache can keep supplying a fresh token on every call.
    func invalidateAccessToken(_ rejectedToken: String) async {}
}

public struct EngineConfiguration: Sendable {
    public var apiBaseURL: URL
    public var triggers: [TriggerKind]
    public var soundsEnabled: Bool
    public var prerollLeadSeconds: Double
    public var prerollMaxSeconds: Double
    /// Send the last few dictations (kept in memory on this Mac only) as context with the next one.
    public var useRecentContext: Bool
    /// Extract proper-noun / Latin terms from the frontmost window title and caret ±300 chars (opt-in, never logged).
    public var useScreenContext: Bool
    /// Run dictation 100% locally on this Mac using WhisperKit + local replacements (zero external APIs).
    public var localDictationEnabled: Bool
    /// Leave the latest transcript on the clipboard after every dictation (default on).
    public var maximumRecordingSeconds: Double = DictationLimits.maximumRecordingSeconds
    public var recordingWarningLeadSeconds: Double = DictationLimits.warningLeadSeconds
    public var keepTranscriptOnClipboard: Bool
    public init(apiBaseURL: URL,
                triggers: [TriggerKind] = [.controlHold(mode: .bilingual, holdMilliseconds: 180),
                                           .mouseButton(number: 4, mode: .bilingual),
                                           .key(keyCode: 79, modifiers: 0, mode: .english)],
                soundsEnabled: Bool = true, prerollLeadSeconds: Double = 0.1, prerollMaxSeconds: Double = 1.0,
                useRecentContext: Bool = true, useScreenContext: Bool = false, localDictationEnabled: Bool = false,
                keepTranscriptOnClipboard: Bool = true) {
        self.apiBaseURL = apiBaseURL; self.triggers = triggers; self.soundsEnabled = soundsEnabled
        self.useRecentContext = useRecentContext
        self.useScreenContext = useScreenContext
        self.localDictationEnabled = localDictationEnabled
        self.keepTranscriptOnClipboard = keepTranscriptOnClipboard
        self.prerollLeadSeconds = prerollLeadSeconds; self.prerollMaxSeconds = prerollMaxSeconds
    }
}

public extension TriggerKind {
    var mode: DictationMode {
        switch self {
        case .controlHold(let m, _), .modifierHold(_, let m, _), .mouseButton(_, let m), .key(_, _, let m): return m
        }
    }
    /// Same physical input regardless of mode (used for conflict detection).
    var inputKey: String {
        switch self {
        case .controlHold: return "mod:control"
        case .modifierHold(let keys, _, _): return "mod:" + keys.map(\.rawValue).sorted().joined(separator: "+")
        case .mouseButton(let n, _): return "mouse:\(n)"
        case .key(let c, let m, _): return "key:\(c):\(m)"
        }
    }
    func with(mode: DictationMode) -> TriggerKind {
        switch self {
        case .controlHold(_, let ms): return .controlHold(mode: mode, holdMilliseconds: ms)
        case .modifierHold(let k, _, let ms): return .modifierHold(keys: k, mode: mode, holdMilliseconds: ms)
        case .mouseButton(let n, _): return .mouseButton(number: n, mode: mode)
        case .key(let c, let m, _): return .key(keyCode: c, modifiers: m, mode: mode)
        }
    }
}

/// Implemented by the real engine and by `MockDictationEngine` (app target) for UI work.
@MainActor
public protocol DictationEngineProtocol: AnyObject {
    var state: EngineState { get }
    var onStateChange: ((EngineState) -> Void)? { get set }
    var onLevel: LevelHandler? { get set }
    var onRecordingNotice: ((DictationNotice?) -> Void)? { get set }
    var recoveryRecords: [DictationRecoveryRecord] { get }
    func retryTranscription(id: String) async
    /// Explicit user action only; refuses while dictation is active.
    func discardRecoveryAudio() throws
    /// Called instead of a clipboard paste when our own window is frontmost. Return false to hold the text.
    var insertIntoOwnWindow: ((String) -> Bool)? { get set }
    /// Persist a finished dictation before paste (then update its outcome). Return true only after durable save.
    var onDelivery: ((DeliveryRecord) -> Bool)? { get set }
    var onDiagnostic: ((DiagnosticEvent) -> Void)? { get set }
    /// Install the input tap and pre-warm STT. Requires the three permissions; throws the missing one.
    func start(configuration: EngineConfiguration, tokens: AccessTokenProvider) throws
    func stop()
    func updateTriggers(_ triggers: [TriggerKind])
    /// Apply the sound preference without restarting the microphone or a current dictation.
    func updateSoundsEnabled(_ enabled: Bool)
    /// Turn recent-dictation context (and learning from corrections) on or off; off clears it.
    func updateRecentContextEnabled(_ enabled: Bool)
    /// Turn local Accessibility screen-term extraction on or off (opt-in, never logged).
    func updateScreenContextEnabled(_ enabled: Bool)
    /// Switch between Free Local Mode (on-device WhisperKit, zero APIs) and Cloud Fast Path.
    func updateLocalDictationEnabled(_ enabled: Bool)
    /// Pluggable on-device STT backend for Free Local Mode (WhisperKit today, MLX Qwen3-ASR future).
    var localTranscriber: LocalDictationTranscriber? { get set }
    /// Forget recent dictations and learned-correction counts (sign-out).
    func clearRecentContext()
    /// Leave each transcript on the clipboard (on) or restore the previous clipboard after a confirmed paste (off).
    func updateKeepTranscriptOnClipboard(_ enabled: Bool)
    /// Onboarding "press your key now" test: reports the next trigger press without dictating.
    func captureNextTrigger(timeout: TimeInterval, _ handler: @escaping (TriggerKind?) -> Void)
    /// Re-paste the last held/pasted result into the focused field.
    func pasteLastResult()
    /// Recreate the event tap right after Accessibility flips to granted (no relaunch).
    /// Throws `.inputMonitoringMissing` if the tap still cannot be created while AX is trusted.
    func reinstallInputTap() throws
    /// Onboarding microphone check: runs the mic without STT and reports levels (~20 Hz).
    func startMicLevelCheck(_ handler: @escaping LevelHandler)
    func stopMicLevelCheck()
}

public struct DiagnosticEvent: Sendable {
    public var name: String
    public var turnID: String?
    public var durationMS: Double?
    public var latencyMS: Double?
    public var errorCode: String?
    public init(_ name: String, turnID: String? = nil, durationMS: Double? = nil, latencyMS: Double? = nil, errorCode: String? = nil) {
        self.name = name; self.turnID = turnID; self.durationMS = durationMS; self.latencyMS = latencyMS; self.errorCode = errorCode
    }
}
public extension DictationEngineProtocol {
    var onDiagnostic: ((DiagnosticEvent) -> Void)? { get { nil } set {} }
    var localTranscriber: LocalDictationTranscriber? { get { nil } set {} }
    func updateScreenContextEnabled(_ enabled: Bool) {}
    func updateLocalDictationEnabled(_ enabled: Bool) {}
}
