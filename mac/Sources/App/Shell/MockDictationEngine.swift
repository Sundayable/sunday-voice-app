import Foundation
import DictationEngine

/// UI-only engine for the screenshot gallery and previews: never opens the mic or an event tap.
@MainActor
final class MockDictationEngine: DictationEngineProtocol {
    var state: EngineState = .idle { didSet { onStateChange?(state) } }
    var onStateChange: ((EngineState) -> Void)?
    var onLevel: LevelHandler?
    var onRecordingNotice: ((DictationNotice?) -> Void)?
    var recoveryRecords: [DictationRecoveryRecord] { [] }
    func retryTranscription(id: String) async {}
    func discardRecoveryAudio() throws {}
    var insertIntoOwnWindow: ((String) -> Bool)?
    var onDelivery: ((DeliveryRecord) -> Bool)?
    var simulatedLevel: Float = 0.3
    private var timer: Timer?
    func start(configuration: EngineConfiguration, tokens: AccessTokenProvider) throws {}
    func stop() { timer?.invalidate() }
    func updateTriggers(_ triggers: [TriggerKind]) {}
    func updateSoundsEnabled(_ enabled: Bool) {}
    func updateKeepTranscriptOnClipboard(_ enabled: Bool) {}
    func updateRecentContextEnabled(_ enabled: Bool) {}
    func clearRecentContext() {}
    func captureNextTrigger(timeout: TimeInterval, _ handler: @escaping (TriggerKind?) -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { handler(.key(keyCode: 79, modifiers: 0, mode: .english)) }
    }
    func pasteLastResult() {}
    func reinstallInputTap() throws {}
    func startMicLevelCheck(_ handler: @escaping LevelHandler) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in handler(Float.random(in: 0...(self?.simulatedLevel ?? 0))) }
        }
    }
    func stopMicLevelCheck() { timer?.invalidate() }
}

/// The one place the real engine is chosen.
@MainActor
enum EngineFactory {
    static func make() -> DictationEngineProtocol {
        if CommandLine.arguments.contains("--gallery") || CommandLine.arguments.contains("--mock-engine") { return MockDictationEngine() }
        return DictationEngine()
    }
}
