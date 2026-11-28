import XCTest
@testable import DictationEngine

@MainActor
final class FakeSocket: TranscriptionSocket {
    var isReady = true
    var onEvent: ((STTEvent) -> Void)?
    var connectedAt = uptime()
    var keywords: [String] = ["Lauren", "Sundayable"]
    var replacements: [(String, String)] = [("파세오", "Paseo")]
    var appended = 0, commits = 0, closes = 0, connects = 0
    var basePrompt = "Base."
    var prompt = "Base."
    var preferredPauseSeconds: Double?
    var maximumIdleAge: Double = .infinity
    var maximumTurns: Int = .max
    /// Prompt updates and appends in the order they reached the socket.
    var log: [String] = []
    var connectError: Error?
    func updatePrompt(_ prompt: String) { self.prompt = prompt; log.append("prompt:" + prompt) }
    func connect() async throws {
        connects += 1
        if let connectError { throw connectError }
        isReady = true; connectedAt = uptime(); prompt = basePrompt
    }
    func append(_ pcm: Data) { appended += pcm.count; log.append("audio") }
    func commit() { commits += 1 }
    func close() { closes += 1; isReady = false }
}

final class FakeRewriter: Rewriter, @unchecked Sendable {
    let lock = NSLock()
    var calls: [(text: String, tier: RewriteTier, mode: DictationMode)] = []
    var contexts: [[String]] = []
    var respond: @Sendable (String, RewriteTier) async throws -> String
    init(_ respond: @escaping @Sendable (String, RewriteTier) async throws -> String) { self.respond = respond }
    func rewrite(_ text: String, mode: DictationMode, tier: RewriteTier, app: String?, context: [String]) async throws -> String {
        lock.withLock { calls.append((text, tier, mode)); contexts.append(context) }
        return try await respond(text, tier)
    }
    var tiers: [RewriteTier] { lock.withLock { calls.map(\.tier) } }
}

@MainActor
final class TurnPipelineTests: XCTestCase {
    func testRewriteProgressRequiresNeededRecentTokens() {
        let clock = Locked(0.0)
        let progress = RewriteProgress(needed: false, now: { clock.get })
        XCTAssertFalse(RewriteProgress(needed: true, now: { clock.get }).canExtend)
        progress.receivedToken()
        XCTAssertFalse(progress.canExtend)
        progress.markNeeded()
        XCTAssertTrue(progress.canExtend)
        clock.withValue { $0 = 0.19 }
        XCTAssertTrue(progress.canExtend)
        clock.withValue { $0 = 0.2 }
        XCTAssertFalse(progress.canExtend)
        progress.receivedToken()
        XCTAssertTrue(progress.canExtend)
    }

    func testProgressingFinalPrimaryGetsBoundedGraceWithoutStartingFallback() async throws {
        // Keep token freshness independent of this machine's scheduling delay. The
        // recency boundary is exercised separately with an advancing injected clock.
        let progress = RewriteProgress(needed: true, now: { 0 })
        progress.receivedToken()
        let rewriter = FakeRewriter { text, tier in
            if tier == .primary {
                DiagnosticContext.rewriteProgress?.receivedToken()
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            return text
        }
        let (pipeline, _) = make(rewriter, deadline: 0.02)
        pipeline.tuning.primaryProgressGrace = 1
        let output = try await DiagnosticContext.$rewriteProgress.withValue(progress) {
            try await pipeline.translate("A completed sentence.", mode: .bilingual, app: nil, turn: nil)
        }
        XCTAssertEqual(output, "A completed sentence.")
        XCTAssertEqual(rewriter.tiers, [.primary])
    }
    func testProgressGraceStillTimesOutAndFallsBackIfProviderStalls() async throws {
        let provider = SuspendedTestProvider()
        let fallbackStarted = expectation(description: "fallback starts while primary is still blocked")
        let primaryFinished = expectation(description: "primary completes after cleanup")
        let rewriter = FakeRewriter { text, tier in
            if tier == .primary {
                DiagnosticContext.rewriteProgress?.receivedToken()
                let result = await provider.wait()
                primaryFinished.fulfill()
                return result
            }
            fallbackStarted.fulfill()
            return text
        }
        let (pipeline, _) = make(rewriter, deadline: 0.035)
        pipeline.tuning.primaryProgressGrace = 0.04
        let request = Task {
            try await pipeline.translate("A completed sentence.", mode: .bilingual, app: nil, turn: nil)
        }
        await fulfillment(of: [fallbackStarted], timeout: 2)
        XCTAssertEqual(rewriter.tiers, [.primary, .fallback])
        await provider.release()
        await fulfillment(of: [primaryFinished], timeout: 2)
        let output = try await request.value
        XCTAssertEqual(output, "A completed sentence.")
    }
    func testEarlyCommittedPieceIsRewrittenDuringSpeechAndSurvivesLaterDeltas() async {
        let rewriter = FakeRewriter { text, _ in
            try await Task.sleep(nanoseconds: 30_000_000)
            return text
        }
        let (pipeline, socket) = make(rewriter)
        socket.preferredPauseSeconds = 6
        await pipeline.start(id: "early-pause", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 7 * 48000))
        socket.onEvent?(.committed(item: "one", previous: nil))
        socket.onEvent?(.completed(item: "one", transcript: "First sentence."))
        socket.onEvent?(.delta(item: "two", text: "Second sentence."))
        try? await Task.sleep(nanoseconds: 80_000_000)
        // Both the committed first piece and the active tail segment rewrite independently during
        // speech without ever re-rewriting the combined turn.
        XCTAssertEqual(rewriter.calls.map(\.text), ["First sentence.", "Second sentence."])
        pipeline.audio(Data(count: 4800)); pipeline.stop()
        socket.onEvent?(.committed(item: "two", previous: "one"))
        socket.onEvent?(.completed(item: "two", transcript: "Second sentence."))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "First sentence. Second sentence.")
        XCTAssertEqual(rewriter.calls.map(\.text), ["First sentence.", "Second sentence."])
        guard case .result(_, _, let stats)? = events.last else { return XCTFail() }
        XCTAssertTrue(stats.finalRewriteStartedBeforeSTTFinal, "Tail segment must reuse speculative rewrite on release")
    }
    func testUsedRelayReconnectsBeforeNextTurnSoItsFullAudioBudgetIsAvailable() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        socket.maximumTurns = 1
        await pipeline.start(id: "first", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 4800)); pipeline.stop()
        socket.onEvent?(.committed(item: "one", previous: nil))
        socket.onEvent?(.completed(item: "one", transcript: "First turn."))
        await waitFor(self.result != nil)
        XCTAssertEqual(pipeline.turnCount, 1)
        await pipeline.start(id: "second", mode: .bilingual, app: nil)
        XCTAssertEqual(socket.connects, 1); XCTAssertEqual(socket.closes, 1)
        XCTAssertEqual(pipeline.turnCount, 1, "the fresh session is counted as used by the second turn")
        pipeline.shutdown()
    }

    /// Dan 2026-11-27 15:40: "no speech" then "stt_busy" twice. A turn that ends without text has still
    /// opened a turn on the relay; reusing that session made the next dictation fail.
    func testNoSpeechTurnRetiresTheRelaySessionSoTheNextTurnGetsAFreshOne() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        socket.maximumTurns = 1
        await pipeline.start(id: "quiet", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600)); pipeline.stop()
        socket.onEvent?(.completed(item: "i", transcript: "  "))
        await waitFor(self.errorCode != nil)
        XCTAssertEqual(errorCode, "no_speech")
        XCTAssertEqual(socket.closes, 1, "the used session is closed right away")
        events = []
        await pipeline.start(id: "next", mode: .bilingual, app: nil)
        XCTAssertEqual(socket.connects, 1, "the next turn opens a fresh session instead of reusing the used one")
        pipeline.audio(Data(count: 4800)); pipeline.stop()
        socket.onEvent?(.committed(item: "n", previous: nil))
        socket.onEvent?(.completed(item: "n", transcript: "Next turn works."))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "Next turn works.")
    }

    func testBusySessionMidTurnIsReplacedOnceAndTheAudioReplayed() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        socket.maximumTurns = 1
        await pipeline.start(id: "busy", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600))
        XCTAssertEqual(socket.appended, 9600)
        socket.onEvent?(.error(code: "stt_busy"))
        await waitFor(socket.connects == 1)
        await waitFor(socket.appended == 19_200)
        XCTAssertEqual(socket.appended, 19_200, "everything captured so far is replayed on the fresh session")
        pipeline.audio(Data(count: 4800))
        XCTAssertEqual(socket.appended, 24_000, "live audio continues on the fresh session")
        pipeline.stop()
        socket.onEvent?(.committed(item: "r", previous: nil))
        socket.onEvent?(.completed(item: "r", transcript: "Recovered without a retry button."))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "Recovered without a retry button.")
        XCTAssertTrue(events.contains { if case .retrying = $0 { return true }; return false })
        XCTAssertFalse(events.contains { if case .degraded = $0 { return true }; return false }, "no 'recording on this Mac' notice")
    }

    func testSecondSessionFailureFallsBackToLocalRecording() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        await pipeline.start(id: "twice", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600))
        socket.onEvent?(.error(code: "stt_busy"))
        await waitFor(socket.connects == 1)
        socket.onEvent?(.disconnected)
        XCTAssertTrue(events.contains { if case .degraded = $0 { return true }; return false })
        pipeline.stop()
        await waitFor(self.errorCode != nil)
        XCTAssertEqual(errorCode, "connection_lost")
    }

    func testAccountErrorsAreNotRetried() {
        XCTAssertFalse(TurnPipeline.isRetryable("STT_quota_exceeded"))
        XCTAssertFalse(TurnPipeline.isRetryable("STT_consent_required"))
        XCTAssertFalse(TurnPipeline.isRetryable("STT_audio_too_long"))
        XCTAssertTrue(TurnPipeline.isRetryable("STT_stt_busy"))
        XCTAssertTrue(TurnPipeline.isRetryable("connection_lost"))
        XCTAssertTrue(TurnPipeline.isRetryable("STT_relay_not_ready"))
    }
    func testAgedRelayReconnectsBeforeAFullLengthTurnCanStart() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        socket.maximumIdleAge = 60; socket.connectedAt = uptime() - 61
        await pipeline.start(id: "aged-relay", mode: .bilingual, app: nil)
        XCTAssertEqual(socket.connects, 1); XCTAssertEqual(socket.closes, 1)
        pipeline.shutdown()
    }
    func testBoundedAudioCommitsAtAnEarlyNaturalPauseWithoutDroppingSamples() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        socket.preferredPauseSeconds = 6
        await pipeline.start(id: "bounded", mode: .bilingual, app: nil)
        let speech = Data(repeating: 20, count: 6 * 48_000)
        pipeline.audio(speech)
        XCTAssertEqual(socket.commits, 0, "Do not cut active speech at the preferred pause threshold")
        pipeline.audio(Data(count: 5760))
        XCTAssertEqual(socket.commits, 1, "Start ASR while the user continues the long turn")
        XCTAssertEqual(socket.appended, speech.count + 5760)
        pipeline.shutdown()
    }
    var events: [TurnPipeline.Event] = []

    func make(_ rewriter: FakeRewriter, deadline: Double = 0.7, context: RecentContext? = nil) -> (TurnPipeline, FakeSocket) {
        let socket = FakeSocket()
        var tuning = TurnPipeline.Tuning(); tuning.primaryDeadline = deadline; tuning.speculationInterval = 0.05
        let pipeline = TurnPipeline(socket: socket, rewriter: rewriter, context: context, tuning: tuning)
        events = []
        pipeline.onEvent = { [weak self] in self?.events.append($0) }
        return (pipeline, socket)
    }

    func waitFor(_ condition: @autoclosure @escaping () -> Bool, timeout: Double = 3) async {
        let end = uptime() + timeout
        while !condition() && uptime() < end { try? await Task.sleep(nanoseconds: 5_000_000) }
    }

    var result: String? {
        for case .result(_, let text, _) in events { return text }
        return nil
    }
    var errorCode: String? {
        for case .error(_, let code) in events { return code }
        return nil
    }

    func testFinalTranscriptIsRewrittenAndPasted() async {
        let rewriter = FakeRewriter { text, _ in "EN(\(text))" }
        let (pipeline, socket) = make(rewriter)
        await pipeline.start(id: "a", mode: .english, app: nil)
        XCTAssertEqual(events.first, .started(id: "a"))
        pipeline.audio(Data(count: 9600))
        socket.onEvent?(.delta(item: "i1", text: "내일 보내 "))
        socket.onEvent?(.delta(item: "i1", text: "주세요"))
        pipeline.stop()
        socket.onEvent?(.completed(item: "i1", transcript: "내일 보내 주세요"))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "EN(내일 보내 주세요)")
        XCTAssertEqual(socket.commits, 1)
        // The sentence-ending speculation is reused: exactly one rewrite of that text.
        XCTAssertEqual(rewriter.calls.filter { $0.text == "내일 보내 주세요" }.count, 1)
        XCTAssertFalse(pipeline.isBusy)
    }

    func testChangedNumberRequiresFinalRewrite() async {
        let rewriter = FakeRewriter { text, _ in text.contains("네") ? "Meet Lauren at 4 PM." : "Meet Lauren at 3 PM." }
        let (pipeline, socket) = make(rewriter)
        await pipeline.start(id: "b", mode: .english, app: nil)
        pipeline.audio(Data(count: 9600))
        socket.onEvent?(.delta(item: "i", text: "로렌과 오후 세 시에 만나요."))
        await waitFor(rewriter.calls.count >= 1)
        pipeline.stop()
        socket.onEvent?(.completed(item: "i", transcript: "로렌과 오후 네 시에 만나요."))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "Meet Lauren at 4 PM.")
    }

    func testFinalTranscriptCancelsObsoleteSpeculationBeforeWaitingForSlots() async {
        let finalText = "Final corrected words"
        let rewriter = FakeRewriter { text, _ in
            if text != finalText { try await Task.sleep(nanoseconds: 2_000_000_000) }
            return text
        }
        let (pipeline, socket) = make(rewriter, deadline: 5)
        defer { pipeline.shutdown() }
        await pipeline.start(id: "stale-slots", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600))
        socket.onEvent?(.delta(item: "i", text: "An unfinished draft"))
        await waitFor(rewriter.calls.count == 1)
        socket.onEvent?(.delta(item: "i", text: " that changed"))
        await waitFor(rewriter.calls.count == 2)
        XCTAssertEqual(rewriter.calls.count, 2, "Both rewrite slots hold obsolete drafts")
        pipeline.stop()
        socket.onEvent?(.completed(item: "i", transcript: finalText))
        await waitFor(self.result != nil, timeout: 0.25)
        XCTAssertEqual(result, finalText, "The final rewrite must not queue behind stale drafts")
        XCTAssertFalse(rewriter.tiers.contains(.fallback), "Cancellation must not launch paid fallbacks")
    }

    func testPrimaryTimeoutFallsBackInSameMode() async {
        let rewriter = FakeRewriter { _, tier in
            if tier == .primary { try await Task.sleep(nanoseconds: 2_000_000_000) }
            return "이번 Ads report 확인해줘."
        }
        let (pipeline, socket) = make(rewriter, deadline: 0.1)
        await pipeline.start(id: "c", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600)); pipeline.stop()
        socket.onEvent?(.completed(item: "i", transcript: "음 이번 Ads report 확인해줘."))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "이번 Ads report 확인해줘.")
        XCTAssertEqual(rewriter.tiers, [.primary, .fallback])
        XCTAssertTrue(rewriter.calls.allSatisfy { $0.mode == .bilingual })
    }

    func testEnglishDetailCheckRejectsPrimaryAndUsesFallback() async {
        let rewriter = FakeRewriter { _, tier in tier == .primary ? "Send it to Lauren by Friday afternoon." : "Send it to Lauren by Friday at 3 PM." }
        let (pipeline, socket) = make(rewriter)
        await pipeline.start(id: "d", mode: .english, app: nil)
        pipeline.audio(Data(count: 9600)); pipeline.stop()
        socket.onEvent?(.completed(item: "i", transcript: "Lauren에게 Friday 오후 세시까지 보내줘."))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "Send it to Lauren by Friday at 3 PM.")
    }

    func testCancelledTurnNeverPastesLateResult() async {
        let rewriter = FakeRewriter { _, _ in try await Task.sleep(nanoseconds: 300_000_000); return "late" }
        let (pipeline, socket) = make(rewriter)
        await pipeline.start(id: "e", mode: .english, app: nil)
        pipeline.audio(Data(count: 9600)); pipeline.stop()
        socket.onEvent?(.completed(item: "i", transcript: "내일 보내 주세요."))
        try? await Task.sleep(nanoseconds: 50_000_000)
        await pipeline.cancel()
        try? await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertNil(result)
        XCTAssertFalse(pipeline.isBusy)
        XCTAssertGreaterThanOrEqual(socket.closes, 1) // reconnect so late deltas cannot attach to the next turn
    }

    func testTooShortRecording() async {
        let (pipeline, _) = make(FakeRewriter { _, _ in "x" })
        await pipeline.start(id: "f", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 1000)); pipeline.stop()
        await waitFor(self.errorCode != nil)
        XCTAssertEqual(errorCode, "recording_too_short")
    }

    func testEmptyFinalIsNoSpeechAndDisconnectFails() async {
        let (pipeline, socket) = make(FakeRewriter { _, _ in "x" })
        await pipeline.start(id: "g", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600)); pipeline.stop()
        socket.onEvent?(.completed(item: "i", transcript: "  "))
        await waitFor(self.errorCode != nil)
        XCTAssertEqual(errorCode, "no_speech")
        events = []
        await pipeline.start(id: "h", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600))
        socket.onEvent?(.disconnected)
        await waitFor(socket.connects >= 2) // one transparent retry on a fresh session
        socket.onEvent?(.disconnected)      // that one drops too
        XCTAssertTrue(pipeline.isBusy, "Offline capture continues locally until release")
        pipeline.stop()
        await waitFor(self.errorCode != nil)
        XCTAssertEqual(errorCode, "connection_lost")
    }

    func testPersonalReplacementMapIsAppliedBeforeRewrite() async {
        let rewriter = FakeRewriter { text, _ in text }
        let (pipeline, socket) = make(rewriter)
        await pipeline.start(id: "r", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600)); pipeline.stop()
        socket.onEvent?(.completed(item: "i", transcript: "파세오에서 열어 줘"))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "Paseo에서 열어 줘")
    }

    func testRecentDictationReachesNextTurnsPromptAndRewrite() async {
        let rewriter = FakeRewriter { text, _ in text }
        let context = RecentContext()
        let (pipeline, socket) = make(rewriter, context: context)
        await pipeline.start(id: "c1", mode: .bilingual, app: "com.apple.dt.Xcode")
        XCTAssertEqual(socket.prompt, "Base.", "no history yet: base prompt, no update sent")
        XCTAssertTrue(socket.log.isEmpty)
        pipeline.audio(Data(count: 9600)); pipeline.stop()
        socket.onEvent?(.completed(item: "i1", transcript: "Xcode에서 Developer ID 확인해줘"))
        await waitFor(self.result != nil)
        XCTAssertEqual(rewriter.contexts.last, [])
        XCTAssertEqual(context.entries.map(\.transcript), ["Xcode에서 Developer ID 확인해줘"])

        events = []; socket.log = []
        await pipeline.start(id: "c2", mode: .bilingual, app: "com.apple.dt.Xcode")
        pipeline.audio(Data(count: 9600))
        XCTAssertEqual(socket.log.first, "prompt:Base." + RecentContext.sttHeader + "Xcode에서 Developer ID 확인해줘")
        XCTAssertEqual(socket.log.dropFirst().first, "audio", "the context update precedes this turn's audio")
        pipeline.stop()
        socket.onEvent?(.completed(item: "i2", transcript: "육백 해놨어"))
        await waitFor(self.result != nil)
        XCTAssertEqual(rewriter.contexts.last, ["Xcode에서 Developer ID 확인해줘"])
    }

    func testContextOffSendsNothingExtra() async {
        let rewriter = FakeRewriter { text, _ in text }
        let context = RecentContext()
        context.record(id: "old", transcript: "Paseo 열어줘", output: "Paseo 열어줘", mode: .bilingual, app: nil)
        context.enabled = false
        let (pipeline, socket) = make(rewriter, context: context)
        await pipeline.start(id: "x", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600)); pipeline.stop()
        socket.onEvent?(.completed(item: "i", transcript: "확인해줘"))
        await waitFor(self.result != nil)
        XCTAssertEqual(socket.prompt, "Base.")
        XCTAssertEqual(rewriter.contexts, [[]])
        XCTAssertTrue(context.entries.isEmpty, "turning it off forgets and stops recording")
    }

    func testAudioIsBufferedWhileConnecting() async {
        let (pipeline, socket) = make(FakeRewriter { _, _ in "x" })
        socket.isReady = false
        pipeline.audio(Data(count: 100)) // no turn yet: dropped
        await pipeline.start(id: "i", mode: .bilingual, app: nil)
        XCTAssertEqual(socket.connects, 1)
        pipeline.audio(Data(count: 4800))
        XCTAssertEqual(socket.appended, 4800)
    }
    func testASRErrorKeepsPartialAndCaptureAliveUntilRelease() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        await pipeline.start(id: "loss", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600))
        socket.onEvent?(.delta(item: "one", text: "Keep these words 42"))
        socket.onEvent?(.error(code: "server_error"))
        await waitFor(socket.connects == 1) // transparent retry
        socket.onEvent?(.error(code: "server_error")) // the retry fails too: keep the first session's words
        XCTAssertTrue(pipeline.isBusy)
        pipeline.audio(Data(count: 9600))
        pipeline.stop()
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "Keep these words 42")
        guard case .result(_, _, let stats)? = events.last else { return XCTFail() }
        XCTAssertFalse(stats.audioComplete, "The missing tail must remain retryable on disk")
        XCTAssertEqual(stats.audioSeconds, 0.4)
    }

    func testRewrite5xxAndTimeoutDeliverRawInsteadOfError() async {
        for timeout in [false, true] {
            let (pipeline, socket) = make(FakeRewriter { _, _ in
                if timeout { try await Task.sleep(nanoseconds: 3_000_000_000) }
                throw FailureCode("http_502")
            })
            pipeline.tuning.rewriteTimeout = 0.04
            await pipeline.start(id: "rewrite-loss", mode: .english, app: nil)
            pipeline.audio(Data(count: 9600)); pipeline.stop()
            socket.onEvent?(.completed(item: "one", transcript: "원문을 보존해 주세요 42"))
            await waitFor(self.result != nil)
            XCTAssertEqual(result, "원문을 보존해 주세요 42")
            XCTAssertNil(errorCode)
        }
    }

    func testLongAudioCommitsAllSegmentsAndOrdersOutOfOrderFinals() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        pipeline.tuning.segmentSeconds = 0.2
        await pipeline.start(id: "long", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 24_000)) // 0.5 seconds: two full items and one tail
        XCTAssertEqual(socket.commits, 2)
        socket.onEvent?(.committed(item: "a", previous: nil))
        socket.onEvent?(.committed(item: "b", previous: "a"))
        socket.onEvent?(.completed(item: "b", transcript: "Second 2."))
        pipeline.stop()
        XCTAssertEqual(socket.commits, 3)
        socket.onEvent?(.committed(item: "c", previous: "b"))
        socket.onEvent?(.completed(item: "c", transcript: "Last 3."))
        XCTAssertNil(result)
        socket.onEvent?(.completed(item: "a", transcript: "First 1."))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "First 1. Second 2. Last 3.")
    }

    func testEmptyFinalNeverErasesPartialWords() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        await pipeline.start(id: "empty", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600))
        socket.onEvent?(.delta(item: "a", text: "Already heard 42"))
        pipeline.stop(); socket.onEvent?(.completed(item: "a", transcript: ""))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "Already heard 42")
    }

    func testLongRewritePiecesPreserveEveryCharacterWithinLiveServerLimit() {
        for source in [String(repeating: "Keep item 42 and https://example.com safe. ", count: 200),
                       String(repeating: "이 문장과 숫자 42, 이모지 👨‍👩‍👧‍👦를 보존해 주세요. ", count: 200)] {
            let pieces = TurnPipeline.rewritePieces(source)
            XCTAssertEqual(pieces.joined(), source)
            XCTAssertTrue(pieces.allSatisfy { $0.utf16.count <= 600 })
        }
    }

    func testPreRollAndImmediateReleaseWaitForTurnPreparation() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        pipeline.prepare(id: "early", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 9600))
        pipeline.stop()
        XCTAssertEqual(socket.appended, 0)
        XCTAssertEqual(socket.commits, 0)
        await pipeline.start(id: "early", mode: .bilingual, app: nil)
        XCTAssertEqual(socket.appended, 9600)
        XCTAssertEqual(socket.commits, 1)
        socket.onEvent?(.completed(item: "a", transcript: "Do not lose the first word"))
        await waitFor(self.result != nil)
        XCTAssertEqual(result, "Do not lose the first word")
    }

    func testSubscriptionRequiredFailsImmediatelyWithoutDegrading() async {
        let (pipeline, socket) = make(FakeRewriter { text, _ in text })
        socket.isReady = false
        socket.connectError = FailureCode.subscriptionRequired
        var events: [TurnPipeline.Event] = []
        pipeline.onEvent = { events.append($0) }
        await pipeline.start(id: "sub-1", mode: .bilingual, app: nil)
        XCTAssertEqual(events, [.error(id: "sub-1", code: "subscription_required")])
        XCTAssertFalse(pipeline.isBusy)

        // Mid-turn STT subscription_required error also fails immediately instead of recording locally.
        socket.connectError = nil
        events = []
        await pipeline.start(id: "sub-2", mode: .bilingual, app: nil)
        socket.onEvent?(.error(code: "subscription_required"))
        XCTAssertTrue(events.contains(.error(id: "sub-2", code: "STT_subscription_required")))
        XCTAssertFalse(events.contains(where: { if case .degraded = $0 { return true }; return false }))
        XCTAssertFalse(pipeline.isBusy)
    }

}
