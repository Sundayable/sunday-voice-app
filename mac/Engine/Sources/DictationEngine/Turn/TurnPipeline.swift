import Foundation

/// Port of worker.py's turn logic: stream audio to STT, speculatively rewrite partial transcripts
/// while the user is still speaking, and on release paste only a rewrite of the FINAL transcript.
/// Cancelled or superseded turns can never emit a result.
@MainActor
final class TurnPipeline {
    enum Event: Equatable {
        case started(id: String)
        case checkpoint(id: String, text: String)
        case degraded(id: String, code: String)
        case result(id: String, text: String, stats: Stats)
        case error(id: String, code: String)
    }

    struct Stats: Equatable {
        var mode: DictationMode
        var audioSeconds: Double
        var releaseToReadyMs: Double
        var releaseToSTTFinalMs: Double
        var fallbacks: Int
        var finalRewriteStartedBeforeSTTFinal: Bool
        var audioComplete: Bool = true
    }

    @MainActor final class Turn {
        let id: String
        let mode: DictationMode
        let app: String?
        /// Recent dictations sent with this turn's rewrites (fixed at turn start).
        var context: [String] = []
        /// Ephemeral proper-noun/Latin screen terms extracted locally (never logged or stored).
        var screenTerms: [String] = []
        var released: Double?
        var item: String?
        var order: [String] = []
        var committedOrder: [String] = []
        var texts: [String: String] = [:]
        var completed: Set<String> = []
        var commits = 0
        var segmentBytes = 0
        var quietBytes = 0
        var offlineCode: String?
        var audioIncomplete = false
        var finishing = false
        var acceptingAudio = false
        var partial = ""
        var final = ""
        let finalFlag = AsyncFlag()
        var finalAt: Double?
        var translations: [String: Task<String, Error>] = [:]
        var translationIDs: [String: String] = [:]
        var translationProgress: [String: RewriteProgress] = [:]
        var speculator: Task<Void, Never>?
        var lastSpeculation = 0.0
        var bytes = 0
        var fallbacks = 0
        var inFlight = 0
        init(id: String, mode: DictationMode, app: String?) { self.id = id; self.mode = mode; self.app = app }
    }

    struct Tuning {
        var primaryDeadline = 0.7
        var primaryProgressGrace = 0.35
        var speculationInterval = 0.45
        var finalTimeout = 15.0
        var rewriteTimeout = 12.0
        var segmentSeconds = 25.0
        var minimumBytes = 4800 // 0.1 s of PCM16 @ 24 kHz
        /// Bounded in-memory pre-connect buffer (30 s @ 24 kHz Int16 mono = 1.44 MB).
        var maximumPendingAudioBytes = 30 * 48_000
        /// Coalesce buffered pre-connect mic chunks on flush to stay well under relay message rate limits.
        var pendingFlushBatchBytes = 24_000
    }

    let socket: TranscriptionSocket
    let rewriter: Rewriter
    /// Recent dictations used as preceding context (nil = feature off for this pipeline).
    var context: RecentContext?
    var checks: QualityChecks
    var tuning: Tuning
    var onEvent: ((Event) -> Void)?
    private(set) var turn: Turn?
    private var pendingAudio: [Data] = []
    private var pendingAudioBytes = 0
    private let rewriteSlots = AsyncSemaphore(2)
    private(set) var turnCount = 0
    private var isShutdown = false

    init(socket: TranscriptionSocket, rewriter: Rewriter, context: RecentContext? = nil, checks: QualityChecks = QualityChecks(), tuning: Tuning = Tuning()) {
        self.socket = socket; self.rewriter = rewriter; self.context = context; self.checks = checks; self.tuning = tuning
        socket.onEvent = { [weak self] event in self?.received(event) }
    }

    var isBusy: Bool { turn != nil }

    // MARK: commands

    /// Reserve the turn synchronously, before the microphone can deliver its first bytes.
    /// Appended to the STT prompt for the next turn only (hands-free end-phrase hint).
    var turnPromptSuffix = ""

    func prepare(id: String, mode: DictationMode, app: String?, screenTerms: [String] = []) {
        guard !isShutdown, turn == nil else { return }
        let t = Turn(id: id, mode: mode, app: app)
        t.screenTerms = screenTerms
        turn = t; pendingAudio = []; pendingAudioBytes = 0
    }

    func start(id: String, mode: DictationMode, app: String?, screenTerms: [String] = []) async {
        guard !isShutdown else { return }
        if turn == nil { prepare(id: id, mode: mode, app: app, screenTerms: screenTerms) }
        guard let t = turn, t.id == id else { onEvent?(.error(id: id, code: "busy")); return }
        if !screenTerms.isEmpty { t.screenTerms = screenTerms }
        // A bounded relay must have room for a full ten-minute turn before its function expires.
        if socket.isReady && (uptime() - socket.connectedAt > socket.maximumIdleAge || turnCount >= socket.maximumTurns) { socket.close() }
        if !socket.isReady {
            do { try await socket.connect(); turnCount = 0 } catch {
                guard turn === t else { return }
                degrade(t, (error as? FailureCode)?.code ?? "connection_lost"); return
            }
        }
        guard !isShutdown, turn === t else { return }
        if !socket.keywords.isEmpty { checks.nameAliases = QualityChecks.aliases(fromTerms: socket.keywords) }
        if !socket.replacements.isEmpty {
            // Personal map first (longest first from the server), then the built-in canonical terms.
            checks.canonicalTerms = socket.replacements + QualityChecks.defaultCanonicalTerms
        }
        // Preceding context + local AX screen terms go out before this turn's first audio on the same socket.
        let baseWithRecent = context?.sttPrompt(base: socket.basePrompt, app: app) ?? socket.basePrompt
        let suffixUsed = max(0, baseWithRecent.utf16.count - socket.basePrompt.utf16.count)
        let screenBudget = min(RecentContext.sttPromptLimit - baseWithRecent.utf16.count, max(0, 400 - suffixUsed - turnPromptSuffix.utf16.count))
        let screenSuffix = ScreenContext.sttSuffix(for: t.screenTerms, budget: screenBudget)
        let prompt = baseWithRecent + screenSuffix + turnPromptSuffix
        turnPromptSuffix = ""
        if prompt != socket.prompt { socket.updatePrompt(prompt) }
        t.context = context?.rewriteContext(app: app) ?? []
        socket.setTurnContext(id: id, app: app)
        t.acceptingAudio = true
        flushPendingAudio(for: t)
        onEvent?(.started(id: id))
        if t.released != nil { commitTail(t); launchFinish(t) }
    }

    func audio(_ pcm: Data) {
        guard let t = turn, t.released == nil else { return }
        t.bytes += pcm.count
        guard t.offlineCode == nil else { return } // the engine keeps journaling locally
        if t.acceptingAudio && socket.isReady {
            send(pcm, turn: t)
        } else {
            guard pendingAudioBytes + pcm.count <= tuning.maximumPendingAudioBytes else {
                degrade(t, FailureCode.connectionLost.code); return
            }
            pendingAudio.append(pcm)
            pendingAudioBytes += pcm.count
        }
    }

    private func flushPendingAudio(for t: Turn) {
        guard !pendingAudio.isEmpty else { return }
        let queued = pendingAudio; pendingAudio = []; pendingAudioBytes = 0
        let batchLimit = max(tuning.minimumBytes, tuning.pendingFlushBatchBytes)
        var batch = Data()
        batch.reserveCapacity(min(batchLimit, queued.reduce(0) { $0 + $1.count }))
        for chunk in queued {
            if !batch.isEmpty && batch.count + chunk.count > batchLimit {
                send(batch, turn: t)
                batch.removeAll(keepingCapacity: true)
            }
            batch.append(chunk)
        }
        if !batch.isEmpty { send(batch, turn: t) }
    }

    private func send(_ pcm: Data, turn t: Turn) {
        // Bound each ASR item, while keeping one session for the entire ten-minute dictation.
        var offset = 0
        let cap = max(tuning.minimumBytes, Int(tuning.segmentSeconds * 48_000))
        let pauseAfter = min(cap * 4 / 5, Int((socket.preferredPauseSeconds ?? tuning.segmentSeconds) * 48_000))
        while offset < pcm.count {
            let count = min(pcm.count - offset, cap - t.segmentBytes)
            socket.append(pcm.subdata(in: offset..<(offset + count)))
            let part = pcm.subdata(in: offset..<(offset + count))
            let quiet = part.withUnsafeBytes { bytes -> Bool in
                let samples = bytes.bindMemory(to: Int16.self)
                guard !samples.isEmpty else { return true }
                return samples.reduce(0.0) { $0 + Double(abs(Int($1))) } / Double(samples.count) < 180
            }
            t.quietBytes = quiet ? t.quietBytes + count : 0
            t.segmentBytes += count; offset += count
            // Bounded uploads start at a natural pause after six seconds, so transcription and
            // rewriting overlap speech. Keep the 25-second hard cap without chopping short words.
            if t.segmentBytes >= cap || (t.segmentBytes >= pauseAfter && t.quietBytes >= 5760) {
                t.commits += 1; t.segmentBytes = 0; t.quietBytes = 0; socket.commit()
            }
        }
    }

    private func commitTail(_ t: Turn) {
        guard t.offlineCode == nil, socket.isReady else { return }
        if t.segmentBytes > 0 {
            if t.segmentBytes < tuning.minimumBytes { socket.append(Data(count: tuning.minimumBytes - t.segmentBytes)) }
            t.commits += 1; t.segmentBytes = 0; socket.commit()
        }
        updateFinal(t)
    }

    private func launchFinish(_ t: Turn) {
        guard !t.finishing else { return }
        t.finishing = true
        Task { await self.finish(t) }
    }

    func stop(releasedAt: Double = uptime()) {
        guard let t = turn, t.released == nil else { return }
        t.released = releasedAt
        if t.bytes < tuning.minimumBytes {
            Task { await self.cancel() }
            onEvent?(.error(id: t.id, code: FailureCode.tooShort.code)); return
        }
        guard t.acceptingAudio || t.offlineCode != nil else { return }
        if !pendingAudio.isEmpty, socket.isReady { flushPendingAudio(for: t) }
        commitTail(t)
        if socket.isReady || t.offlineCode != nil { launchFinish(t) }
        // Otherwise start() owns the queued audio and commits it after the connection opens.
    }

    /// Drop the turn and reconnect, so late events from it cannot attach to the next one.
    func cancel() async {
        guard !isShutdown else { return }
        if let t = turn { clear(t) }
        socket.close(); turnCount = 0
        try? await socket.connect()
    }

    /// Permanent engine stop: discard pending audio and work without opening another session.
    /// A fresh engine start constructs a fresh pipeline; queued commands cannot revive this one.
    func shutdown() {
        guard !isShutdown else { return }
        isShutdown = true
        if let t = turn { clear(t) }
        pendingAudio = []; pendingAudioBytes = 0
        onEvent = nil; socket.onEvent = nil
        socket.close()
    }

    /// Set when the user's vocabulary changed: the next idle maintenance mints a fresh session.
    var sessionStale = false

    /// Reconnect an idle socket that is old or has served many turns (worker maintenance).
    func maintain(maxAge: Double = 600, maxTurns: Int = 20) async {
        guard !isShutdown, turn == nil else { return }
        if !socket.isReady || uptime() - socket.connectedAt > min(maxAge, socket.maximumIdleAge) || turnCount >= min(maxTurns, socket.maximumTurns) || sessionStale {
            socket.close(); turnCount = 0; sessionStale = false
            try? await socket.connect()
        }
    }

    // MARK: STT events

    private func received(_ event: STTEvent) {
        guard let t = turn else { return }
        switch event {
        case .committed(let item, let previous):
            if !t.order.contains(item) { t.order.append(item) }
            if !t.committedOrder.contains(item) {
                if let previous, let i = t.committedOrder.firstIndex(of: previous) { t.committedOrder.insert(item, at: i + 1) }
                else { t.committedOrder.append(item) }
            }
            updateFinal(t)
        case .delta(let item, let text):
            if !t.order.contains(item) { t.order.append(item) }
            t.texts[item, default: ""] += text
            updateFinal(t)
            // Speculation stays bounded for short utterances. Long turns rewrite committed pieces.
            guard t.bytes < 15 * 48_000, t.completed.isEmpty else { return }
            let current = t.partial
            let key = QualityChecks.normalized(current)
            if QualityChecks.length(key) >= 5, QualityChecks.endsSentence(current), t.translations[key] == nil {
                for old in Array(t.translations.keys) where old != key {
                    t.translations.removeValue(forKey: old)?.cancel()
                }
                _ = translation(for: t, current); t.lastSpeculation = uptime()
            }
            if t.speculator == nil { t.speculator = Task { await self.speculate(t) } }
        case .completed(let item, let transcript):
            if !t.order.contains(item) { t.order.append(item) }
            // An empty final must not erase already received partial words.
            let final = checks.canonicalTranscript(transcript.trimmingCharacters(in: .whitespacesAndNewlines))
            if !final.isEmpty { t.texts[item] = final }
            else { t.audioIncomplete = true }
            t.completed.insert(item); t.finalAt = uptime()
            updateFinal(t)
            // A natural pause can finalize the first piece before 15 seconds. Rewrite that
            // stable piece immediately and stop repeatedly rewriting the growing whole turn.
            t.speculator?.cancel()
            for piece in Self.rewritePieces(t.texts[item] ?? "") { _ = translation(for: t, piece, committed: true) }
            for key in Array(t.translations.keys) where t.translationProgress[key]?.isNeeded != true {
                t.translations.removeValue(forKey: key)?.cancel()
            }
        case .failed: degrade(t, FailureCode.transcriptionFailed.code)
        case .error(let code): degrade(t, "STT_\(code)")
        case .disconnected: degrade(t, FailureCode.connectionLost.code)
        }
    }

    private func updateFinal(_ t: Turn) {
        let order = t.committedOrder + t.order.filter { !t.committedOrder.contains($0) }
        t.partial = checks.canonicalTranscript(order.compactMap { t.texts[$0] }.filter { !$0.isEmpty }.joined(separator: " "))
        t.final = t.partial
        onEvent?(.checkpoint(id: t.id, text: t.partial))
        if t.released != nil, t.commits > 0, t.completed.count >= t.commits { t.finalFlag.set() }
    }

    private func degrade(_ t: Turn, _ code: String) {
        guard turn === t else { return }
        t.offlineCode = code; pendingAudio = []; pendingAudioBytes = 0
        socket.close() // fence late callbacks; continue recording to the local journal
        onEvent?(.degraded(id: t.id, code: code))
        if t.released != nil { t.finalFlag.set(); launchFinish(t) }
    }

    /// Compatible with the currently deployed 4,000-character / 256-output-token endpoint.
    /// Prefer sentence/word boundaries; count UTF-16 units so non-ASCII inputs stay bounded too.
    static func rewritePieces(_ text: String) -> [String] {
        let cap = text.unicodeScalars.contains { $0.value > 127 } ? 120 : 600
        guard text.utf16.count > cap else { return text.isEmpty ? [] : [text] }
        var result: [String] = [], rest = text[...]
        while !rest.isEmpty {
            var end = rest.startIndex, units = 0, boundary: String.Index?
            while end < rest.endIndex {
                let next = rest.index(after: end), cost = rest[end..<next].utf16.count
                if units + cost > cap { break }
                units += cost
                if rest[end].isWhitespace || ".!?。！？".contains(rest[end]) { boundary = next }
                end = next
            }
            if end == rest.startIndex { end = rest.index(after: end) }
            if end != rest.endIndex, let boundary, rest.distance(from: rest.startIndex, to: boundary) > cap / 3 { end = boundary }
            result.append(String(rest[..<end])); rest = rest[end...]
        }
        return result
    }

    // MARK: speculation and rewrite

    private func speculate(_ t: Turn) async {
        while turn === t, t.bytes < 15 * 48_000, t.completed.isEmpty, !t.finalFlag.isSet, !Task.isCancelled {
            let delta = uptime() - t.lastSpeculation
            if delta < tuning.speculationInterval {
                try? await Task.sleep(nanoseconds: UInt64((tuning.speculationInterval - delta) * 1e9))
            }
            guard turn === t, t.completed.isEmpty, !t.finalFlag.isSet, !Task.isCancelled else { return }
            let text = checks.canonicalTranscript(t.partial.trimmingCharacters(in: .whitespacesAndNewlines))
            let key = QualityChecks.normalized(text)
            if QualityChecks.length(key) >= 5, t.translations[key] == nil {
                // At most two speculative requests in flight; superseded ones are dropped before they cost tokens.
                if t.inFlight < 2 {
                    _ = translation(for: t, text); t.lastSpeculation = uptime()
                }
            }
            try? await Task.sleep(nanoseconds: 35_000_000)
        }
    }

    private func translation(for t: Turn, _ text: String, committed: Bool = false) -> Task<String, Error> {
        let key = QualityChecks.normalized(text)
        if let existing = t.translations[key] {
            if committed { t.translationProgress[key]?.markNeeded() }
            return existing
        }
        t.inFlight += 1
        let diagnostic = DiagnosticContext.Rewrite(id: UUID().uuidString, purpose: t.finalFlag.isSet ? "final" : "speculative")
        t.translationIDs[key] = diagnostic.id
        let progress = RewriteProgress(needed: committed || t.finalFlag.isSet)
        t.translationProgress[key] = progress
        let task = Task { @MainActor in
            defer { t.inFlight -= 1 }
            return try await DiagnosticContext.$rewrite.withValue(diagnostic) {
                try await DiagnosticContext.$rewriteProgress.withValue(progress) {
                    try await self.translate(text, mode: t.mode, app: t.app, context: t.context, screenTerms: t.screenTerms, turn: t)
                }
            }
        }
        t.translations[key] = task
        return task
    }

    /// Primary (Groq) within the deadline, else fallback. Cancellation never triggers a fallback.
    func translate(_ text: String, mode: DictationMode, app: String?, context: [String] = [], screenTerms: [String] = [], turn t: Turn?) async throws -> String {
        let slotBegan = uptime()
        try await rewriteSlots.acquire()
        defer { rewriteSlots.release() }
        try Task.checkCancellation()
        let rewriter = self.rewriter, checks = self.checks
        let diagnostic = DiagnosticContext.rewrite ?? .init(id: UUID().uuidString, purpose: "final")
        let progress = DiagnosticContext.rewriteProgress ?? RewriteProgress(needed: true)
        Log.rewrite.info("rewrite_slot job=\(diagnostic.id, privacy: .public) purpose=\(diagnostic.purpose, privacy: .public) wait_ms=\(ms(uptime() - slotBegan), privacy: .public)")
        let turnContext = t.map { DiagnosticContext.Turn(id: $0.id, app: $0.app) }
        let attempt: @Sendable (RewriteTier) async throws -> String = { tier in
            let started = uptime(), id = diagnostic.id + ":" + tier.rawValue
            var outcome = "cancelled_or_failed"
            defer { Log.rewrite.info("rewrite_attempt id=\(id, privacy: .public) purpose=\(diagnostic.purpose, privacy: .public) outcome=\(outcome, privacy: .public) elapsed_ms=\(ms(uptime() - started), privacy: .public)") }
            let out = try await DiagnosticContext.$rewriteProgress.withValue(progress) {
                try await DiagnosticContext.$rewrite.withValue(.init(id: id, purpose: diagnostic.purpose)) {
                    try await DiagnosticContext.$turn.withValue(turnContext) {
                        try await rewriter.rewrite(text, mode: mode, tier: tier, app: app, context: context, screenTerms: screenTerms)
                    }
                }
            }
            if mode == .english && !checks.englishPreservesDetails(source: text, output: out) { throw FailureCode.rewriteDetailsMissing }
            outcome = "success"
            return mode == .bilingual ? QualityChecks.preserveBilingual(source: text, cleaned: out) : out
        }
        do {
            return try await withDeadline(tuning.primaryDeadline, grace: tuning.primaryProgressGrace,
                                          shouldExtend: { progress.canExtend }) { try await attempt(.primary) }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            t?.fallbacks += 1
            Log.rewrite.info("rewrite_fallback job=\(diagnostic.id, privacy: .public) reason=\((error as? FailureCode)?.code ?? "error", privacy: .public)")
            return try await attempt(.fallback)
        }
    }

    private func finish(_ t: Turn) async {
        if t.offlineCode == nil {
            do { try await t.finalFlag.wait(timeout: tuning.finalTimeout) }
            catch { t.offlineCode = "stt_final_timeout"; socket.close() }
        }
        guard turn === t else { return }
        guard !t.final.isEmpty else { fail(t, t.offlineCode ?? FailureCode.noSpeech.code); return }
        // Every raw checkpoint has reached durable storage before any final rewrite starts.
        onEvent?(.checkpoint(id: t.id, text: t.final))
        let order = t.committedOrder + t.order.filter { !t.committedOrder.contains($0) }
        let pieces = order.flatMap { Self.rewritePieces(t.texts[$0] ?? "") }
        // A final correction can make both speculative requests obsolete. Release their slots
        // before scheduling the required final pieces; keep matching work so it can be reused.
        t.speculator?.cancel()
        let needed = Set(pieces.map(QualityChecks.normalized))
        for key in Array(t.translations.keys) where !needed.contains(key) {
            t.translations.removeValue(forKey: key)?.cancel()
        }
        for key in needed { t.translationProgress[key]?.markNeeded() }
        let cached = pieces.allSatisfy { t.translations[QualityChecks.normalized($0)] != nil }
        let jobs = pieces.map { piece -> Task<String, Error> in
            let key = QualityChecks.normalized(piece)
            if t.translations[key]?.isCancelled == true { t.translations[key] = nil }
            return translation(for: t, piece)
        }
        var outputs: [String] = []
        // One bounded wait for the whole result, not a timeout multiplied by every piece.
        let deadline = uptime() + tuning.rewriteTimeout
        for (piece, job) in zip(pieces, jobs) {
            do {
                let left = deadline - uptime()
                guard left > 0 else { throw FailureCode("rewrite_timeout") }
                let out = try await withDeadline(left) { try await job.value }
                let jobID = t.translationIDs[QualityChecks.normalized(piece)] ?? "unknown"
                Log.rewrite.info("rewrite_adopt job=\(jobID, privacy: .public)")
                outputs.append(out.isEmpty ? piece : out)
            } catch { outputs.append(piece); job.cancel(); t.fallbacks += 1 }
            guard turn === t else { return }
        }
        let out = outputs.joined(separator: pieces.count > 1 ? " " : "")
        let now = uptime(), released = t.released ?? now
        let stats = Stats(mode: t.mode, audioSeconds: Double(t.bytes) / 48000,
                          releaseToReadyMs: ms(now - released), releaseToSTTFinalMs: ms(max(0, (t.finalAt ?? now) - released)),
                          fallbacks: t.fallbacks, finalRewriteStartedBeforeSTTFinal: cached, audioComplete: t.offlineCode == nil && !t.audioIncomplete)
        clear(t); turnCount += 1
        if turnCount >= socket.maximumTurns, socket.isReady { socket.close() }
        context?.record(id: t.id, transcript: t.final, output: out, mode: t.mode, app: t.app)
        onEvent?(.result(id: t.id, text: out, stats: stats))
    }

    private func clear(_ t: Turn) {
        t.speculator?.cancel()
        for task in t.translations.values { task.cancel() }
        if turn === t { turn = nil; pendingAudio = []; pendingAudioBytes = 0 }
    }

    private func fail(_ t: Turn, _ code: String) {
        guard turn === t else { return }
        clear(t)
        onEvent?(.error(id: t.id, code: code))
    }
}
