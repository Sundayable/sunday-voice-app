import Foundation

/// Consent-gated transport. TurnPipeline commits at pauses / 25 seconds; the server accepts <=30 s.
/// Buffers contain synthetic/live PCM only in memory (the engine owns its local recovery journal).
@MainActor
final class BoundedSTTTransport {
    static let maximumBytes = 30 * 48_000
    private let transcribe: @Sendable (Data, @escaping @Sendable (String) -> Void) async throws -> String
    private var buffer = Data()
    private var pending: [String: Task<Void, Never>] = [:]
    private var previous: String?
    private var generation: UInt64 = 0
    private var failed = false
    var context: DiagnosticContext.Turn?
    var onEvent: ((STTEvent) -> Void)?

    init(transcribe: @escaping @Sendable (Data) async throws -> String) { self.transcribe = { pcm, _ in try await transcribe(pcm) } }
    init(streaming: @escaping @Sendable (Data, @escaping @Sendable (String) -> Void) async throws -> String) { self.transcribe = streaming }

    func append(_ pcm: Data) {
        guard !failed else { return }
        guard buffer.count + pcm.count <= Self.maximumBytes else {
            failed = true; buffer.removeAll(); onEvent?(.error(code: "audio_too_long")); return
        }
        buffer.append(pcm)
    }

    func commit() {
        guard !failed, !buffer.isEmpty else { return }
        // Keep at most two in-flight requests. Congestion preserves the engine's recovery audio.
        guard pending.count < 2 else { failed = true; buffer.removeAll(); onEvent?(.error(code: "stt_busy")); return }
        let pcm = buffer; buffer.removeAll(keepingCapacity: true)
        let item = UUID().uuidString, before = previous, current = generation
        previous = item
        onEvent?(.committed(item: item, previous: before))
        let turnContext = context
        pending[item] = Task { [weak self, transcribe] in
            do {
                let text = try await DiagnosticContext.$turn.withValue(turnContext) {
                    try await transcribe(pcm) { [weak self] delta in
                        Task { @MainActor in
                            guard let self, self.generation == current, self.pending[item] != nil else { return }
                            self.onEvent?(.delta(item: item, text: delta))
                        }
                    }
                }
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.pending[item] = nil
                self.onEvent?(.completed(item: item, transcript: text))
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.pending[item] = nil
                self.onEvent?(.error(code: (error as? FailureCode)?.code ?? "stt_unavailable"))
            }
        }
    }

    func close() {
        generation &+= 1
        for task in pending.values { task.cancel() }
        pending.removeAll(); buffer.removeAll(); previous = nil; failed = false
        onEvent = nil
    }
}
