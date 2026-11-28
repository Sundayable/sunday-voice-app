import XCTest
import AppKit
@testable import DictationEngine

@MainActor
final class DictationRecoveryTests: XCTestCase {
    private func store() -> DictationRecoveryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-recovery-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return DictationRecoveryStore(root: url)
    }

    func testAudioAndPartialSurviveErrorAndRelaunch() throws {
        let journal = store(), pcm = Data(repeating: 17, count: 96_000)
        try journal.begin(id: "a", mode: .bilingual, appName: nil, bundleID: nil)
        XCTAssertEqual(journal.list().count, 1, "Recovery history exists before network/audio")
        try journal.append(pcm, id: "a")
        try journal.checkpoint("a", raw: "Synthetic partial 42", error: "STT_error")
        try journal.seal("a")
        let reopened = DictationRecoveryStore(root: journal.root)
        XCTAssertEqual(try Data(contentsOf: reopened.audioURL("a")), pcm)
        XCTAssertEqual(reopened.list().first?.rawText, "Synthetic partial 42")
        XCTAssertEqual(reopened.list().first?.audioBytes, pcm.count)
        XCTAssertFalse(reopened.list().first!.complete)
        let attrs = try FileManager.default.attributesOfItem(atPath: reopened.audioURL("a").path)
        XCTAssertEqual(attrs[.posixPermissions] as? Int, 0o600)
        // Partial ASR output being saved/pasted never deletes the remaining audio.
        try reopened.checkpoint("a", final: "Synthetic partial 42", complete: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reopened.audioURL("a").path))
        try reopened.checkpoint("a", final: "Synthetic complete 42", complete: true)
        XCTAssertEqual(DictationRecoveryStore(root: journal.root).list().first?.finalText, "Synthetic complete 42")
        XCTAssertFalse(FileManager.default.fileExists(atPath: reopened.audioURL("a").path))
    }

    func testCapFinishesSavesAndCopiesWhenPasteFails() async throws {
        let journal = store(), socket = FakeSocket(), mic = RecoveryMicrophone()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in throw FailureCode("http_502") })
        var config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false)
        config.maximumRecordingSeconds = 0.25; config.recordingWarningLeadSeconds = 0.1
        let engine = DictationEngine(microphone: mic, pipeline: pipeline, recovery: journal, configuration: config)
        let savedBoard = Paster.snapshot(.general)
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedBoard.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            })
            engine.stop()
        }
        var warning = false, deliveries: [DeliveryRecord] = []
        engine.onRecordingNotice = { if case .finishingSoon = $0 { warning = true } }
        engine.onDelivery = { deliveries.append($0); return true }
        let fixture = Task { await engine.runFixture(Data(count: 48_000 * 2), mode: .bilingual) }
        while socket.commits == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        socket.onEvent?(.completed(item: "one", transcript: "Synthetic words 42"))
        _ = await fixture.value
        let end = uptime() + 2
        while deliveries.last?.outcome != .failed, uptime() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(warning)
        XCTAssertEqual(socket.commits, 1, "Cap and key-up cannot commit twice")
        XCTAssertEqual(deliveries.first?.outcome, .unconfirmed, "History is saved before paste")
        XCTAssertEqual(deliveries.last?.outcome, .failed)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "Synthetic words 42")
        XCTAssertEqual(deliveries.last?.text, "Synthetic words 42")
        XCTAssertTrue(journal.list().isEmpty, "Successful history save retires its temporary journal")
        XCTAssertLessThan(socket.appended, 48_000 * 2)
    }

    func testASRFailureKeepsAllAudioThroughReleaseWithoutHistoryText() async throws {
        let journal = store(), socket = FakeSocket()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false)
        let engine = DictationEngine(microphone: RecoveryMicrophone(), pipeline: pipeline, recovery: journal, configuration: config)
        defer { engine.stop() }
        let fixture = Task { await engine.runFixture(Data(count: 12_000), mode: .bilingual) }
        let started = uptime()
        while socket.appended == 0 && uptime() - started < 2 { try await Task.sleep(nanoseconds: 1_000_000) }
        guard socket.appended > 0 else { fixture.cancel(); return XCTFail("Fixture did not start: \(engine.state), records=\(journal.list().count)") }
        socket.onEvent?(.failed)
        while socket.connects == 0 && uptime() - started < 2 { try await Task.sleep(nanoseconds: 1_000_000) } // transparent retry
        socket.onEvent?(.failed)
        _ = await fixture.value
        let end = uptime() + 1
        while case .processing = engine.state, uptime() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        let record = try XCTUnwrap(journal.list().first)
        XCTAssertEqual(record.audioBytes, 12_000, "Keep recording locally after the ASR failure")
        XCTAssertEqual(try Data(contentsOf: journal.audioURL(record.id)).count, 12_000)
        XCTAssertEqual(record.errorCode, "transcription_failed")
        XCTAssertEqual(engine.state, .failed(.server("audio_saved")))
    }

    func testHistoryWriteAndPasteFailureKeepAudioRetryable() async throws {
        let savedBoard = Paster.snapshot(.general)
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedBoard.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            })
        }
        let journal = store(), socket = FakeSocket()
        try journal.begin(id: "saved-audio", mode: .bilingual, appName: nil, bundleID: nil)
        try journal.append(Data(count: 9600), id: "saved-audio"); try journal.seal("saved-audio")
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let engine = DictationEngine(microphone: RecoveryMicrophone(), pipeline: pipeline, recovery: journal,
                                     configuration: EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false))
        defer { engine.stop() }
        engine.onDelivery = { _ in false } // full disk / failed history write
        let retry = Task { await engine.retryTranscription(id: "saved-audio") }
        while socket.commits == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        socket.onEvent?(.completed(item: "a", transcript: "Recover every word 42"))
        await retry.value
        let end = uptime() + 1
        while journal.list().first?.finalText.isEmpty == true, uptime() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(journal.list().first?.finalText, "Recover every word 42")
        XCTAssertFalse(journal.list().first!.complete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.audioURL("saved-audio").path))
    }

    /// 0.3.25: 201 of Dan's 410 saved items were delivered dictations kept forever because a silent tail
    /// segment came back empty. Delivered text now deletes the saved audio and text.
    func testDeliveredTextDeletesRecoveryEvenWhenASilentTailCameBackEmpty() async throws {
        let savedBoard = Paster.snapshot(.general)
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedBoard.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            })
        }
        let journal = store(), socket = FakeSocket()
        try journal.begin(id: "delivered", mode: .bilingual, appName: nil, bundleID: nil)
        try journal.append(Data(count: 9600), id: "delivered"); try journal.seal("delivered")
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let engine = DictationEngine(microphone: RecoveryMicrophone(), pipeline: pipeline, recovery: journal,
                                     configuration: EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false))
        defer { engine.stop() }
        engine.onDelivery = { _ in true } // saved to the recent list
        let retry = Task { await engine.retryTranscription(id: "delivered") }
        while socket.commits == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        socket.onEvent?(.completed(item: "tail", transcript: ""))
        socket.onEvent?(.completed(item: "a", transcript: "Delivered words 7"))
        await retry.value
        let end = uptime() + 2
        while !journal.list().isEmpty, uptime() < end { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertTrue(journal.list().isEmpty, "delivered text must not leave its audio and text behind")
    }

    func testExplicitDiscardRefusesLiveRecordingThenRemovesAudioAndText() throws {
        let journal = store()
        try journal.begin(id: "discard", mode: .bilingual, appName: nil, bundleID: nil)
        try journal.append(Data(count: 9600), id: "discard")
        XCTAssertThrowsError(try journal.discardAll())
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.audioURL("discard").path))
        try journal.seal("discard")
        try journal.checkpoint("discard", raw: "Synthetic private text", error: "ASR_error")
        try journal.discardAll()
        XCTAssertTrue(journal.list().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: journal.root.path))
    }

    func testDefaultLimitIsTenMinutesAndWarningThirtySeconds() {
        let c = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!)
        XCTAssertEqual(c.maximumRecordingSeconds, 600)
        XCTAssertEqual(c.recordingWarningLeadSeconds, 30)
    }

    func testRetiringCompletedNeverRemovesFailedAudio() throws {
        let journal = store()
        try journal.begin(id: "failed", mode: .bilingual, appName: nil, bundleID: nil)
        try journal.append(Data(count: 9600), id: "failed"); try journal.seal("failed")
        try journal.checkpoint("failed", raw: "Saved partial", error: "ASR_error")
        try journal.retireCompleted("failed")
        XCTAssertEqual(journal.list().first?.rawText, "Saved partial")
        XCTAssertTrue(FileManager.default.fileExists(atPath: journal.audioURL("failed").path))
    }

    func testDeadlineDoesNotWaitForUncooperativeProvider() async {
        let provider = SuspendedTestProvider()
        let started = expectation(description: "uncooperative provider started")
        let timedOut = expectation(description: "deadline returns before provider is released")
        let providerFinished = expectation(description: "provider completes after cleanup")
        let request = Task {
            do {
                _ = try await withDeadline(0.02) {
                    started.fulfill()
                    let result = await provider.wait()
                    providerFinished.fulfill()
                    return result
                }
                XCTFail("Must time out")
            } catch { XCTAssertEqual(error as? FailureCode, .timeout) }
            timedOut.fulfill()
        }
        // A structured race that waits for its cancelled provider fails this expectation.
        await fulfillment(of: [started, timedOut], timeout: 2)
        await provider.release()
        await fulfillment(of: [providerFinished], timeout: 2)
        await request.value
    }

    func testSubscription402FallsBackToLocalWhenModelIsReady() async throws {
        let journal = store(), socket = FakeSocket(), mic = RecoveryMicrophone()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false, localDictationEnabled: false)
        let engine = DictationEngine(microphone: mic, pipeline: pipeline, recovery: journal, configuration: config)
        let local = StubLocalTranscriber(ready: true, result: "Local fallback transcript")
        engine.localTranscriber = local
        let savedBoard = Paster.snapshot(.general)
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedBoard.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            })
            engine.stop()
        }
        var fellBack = false
        var delivered: [String] = []
        engine.onSubscriptionFallbackToLocal = { fellBack = true }
        engine.onDelivery = { delivered.append($0.text); return true }

        let fixture = Task { await engine.runFixture(Data(repeating: 1, count: 48_000), mode: .bilingual) }
        while socket.commits == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        socket.onEvent?(.error(code: "subscription_required"))
        _ = await fixture.value

        let deadline = uptime() + 3
        while delivered.isEmpty, uptime() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(fellBack, "402 must notify the app shell to stay in Free Local Mode")
        XCTAssertEqual(delivered.first, "Local fallback transcript", "recorded audio must transcribe locally on the same turn")
    }

    func testSubscription402OffersDownloadOrUpgradeWhenLocalModelIsMissing() async throws {
        let journal = store(), socket = FakeSocket(), mic = RecoveryMicrophone()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false, localDictationEnabled: false)
        let engine = DictationEngine(microphone: mic, pipeline: pipeline, recovery: journal, configuration: config)
        engine.localTranscriber = StubLocalTranscriber(ready: false, result: "")
        defer { engine.stop() }
        var fellBack = false
        var lastError: EngineError?
        engine.onSubscriptionFallbackToLocal = { fellBack = true }
        engine.onStateChange = { if case .failed(let e) = $0 { lastError = e } }

        let fixture = Task { await engine.runFixture(Data(repeating: 1, count: 48_000), mode: .bilingual) }
        while socket.commits == 0 { try await Task.sleep(nanoseconds: 5_000_000) }
        socket.onEvent?(.error(code: "subscription_required"))
        _ = await fixture.value

        let deadline = uptime() + 3
        while lastError == nil, uptime() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(fellBack)
        XCTAssertEqual(lastError, .server("subscription_required_local_missing"))
    }

    func testLocalLongEmptyTranscriptSavesRecoveryAndShowsRetryableHUD() async throws {
        let journal = store(), socket = FakeSocket(), mic = ControllableMicrophone()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false, localDictationEnabled: true)
        let engine = DictationEngine(microphone: mic, pipeline: pipeline, recovery: journal, configuration: config)
        let local = SequenceLocalTranscriber(results: ["", "복구된 로컬 받아쓰기"])
        engine.localTranscriber = local
        let savedBoard = Paster.snapshot(.general)
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedBoard.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            })
            engine.stop()
        }
        var delivered: [String] = []
        engine.onDelivery = { delivered.append($0.text); return true }

        // Reproduce 11.7s local clip returning empty string on first pass.
        engine.beginForTesting(mode: .bilingual)
        mic.emit(Data(repeating: 3, count: 48_000 * 3))
        engine.releaseForTesting()
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.waitForLocalQueueForTesting()

        let record = try XCTUnwrap(journal.list().first, "Substantial audio must stay in DictationRecovery")
        XCTAssertFalse(record.complete)
        XCTAssertEqual(record.errorCode, "local_empty_transcript")
        XCTAssertEqual(record.audioBytes, 48_000 * 3)
        XCTAssertEqual(engine.state, .failed(.server("local_empty_saved")), "HUD must show retryable error instead of plain noSpeech")

        // One-click Retry transcription succeeds and retires recovery cleanly.
        await engine.retryTranscription(id: record.id)
        await engine.waitForLocalQueueForTesting()
        XCTAssertEqual(delivered.last, "복구된 로컬 받아쓰기")
        XCTAssertTrue(journal.list().isEmpty)
    }

    func testLocalQueuedTurnsNeverCancelOrDropPreviousTranscription() async throws {
        let journal = store(), socket = FakeSocket(), mic = ControllableMicrophone()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false, localDictationEnabled: true)
        let engine = DictationEngine(microphone: mic, pipeline: pipeline, recovery: journal, configuration: config)
        let gate = BlockingLocalTranscriber()
        engine.localTranscriber = gate
        let savedBoard = Paster.snapshot(.general)
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedBoard.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            })
            engine.stop()
        }
        var delivered: [String] = []
        engine.onDelivery = { delivered.append($0.text); return true }

        // Turn 1 starts & releases, entering WhisperKit processing.
        engine.beginForTesting(mode: .bilingual)
        mic.emit(Data(repeating: 1, count: 48_000 * 2))
        engine.releaseForTesting()
        await gate.waitForFirstCall()

        // While Turn 1 is STILL transcribing, user immediately starts & releases Turn 2.
        engine.beginForTesting(mode: .bilingual)
        XCTAssertEqual(engine.state, .listening(.bilingual), "New local recording must start while previous turn transcribes")
        mic.emit(Data(repeating: 2, count: 48_000 * 2))

        // Turn 1 finishes while Turn 2 is still listening: must deliver without clobbering Turn 2's listening state.
        await gate.releaseCall(index: 0, text: "First queued turn")
        let wait1 = uptime() + 2
        while !delivered.contains("First queued turn"), uptime() < wait1 { try await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(engine.state, .listening(.bilingual), "Completing Turn 1 must not stomp active Turn 2 HUD")

        engine.releaseForTesting()
        await gate.waitForCall(index: 1)
        await gate.releaseCall(index: 1, text: "Second queued turn")
        await engine.waitForLocalQueueForTesting()

        XCTAssertTrue(delivered.contains("First queued turn"))
        XCTAssertTrue(delivered.contains("Second queued turn"))
        XCTAssertTrue(journal.list().isEmpty)
    }

    func testScrollAndMouseClickDuringActiveModifierHoldDoNotCancelDictation() async throws {
        let journal = store(), socket = FakeSocket(), mic = ControllableMicrophone()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!,
                                         triggers: [.modifierHold(keys: [.fn], mode: .bilingual, holdMilliseconds: 180)],
                                         soundsEnabled: false, localDictationEnabled: true)
        let engine = DictationEngine(microphone: mic, pipeline: pipeline, recovery: journal, configuration: config)
        engine.localTranscriber = StubLocalTranscriber(ready: true, result: "Survived scroll and click")
        let savedBoard = Paster.snapshot(.general)
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedBoard.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            })
            engine.stop()
        }
        var delivered: [String] = []
        engine.onDelivery = { delivered.append($0.text); return true }

        engine.beginModifierForTesting(triggerIndex: 0, mode: .bilingual, beganAgo: 1.5)
        mic.emit(Data(repeating: 5, count: 48_000 * 2))
        engine.handlePointerInterference() // scroll wheel / left click while speaking
        engine.handleTypingKeyDown()       // stray key brush after 0.6s grace window
        XCTAssertEqual(engine.state, .listening(.bilingual), "Pointer/scroll/stray key after grace must never cancel active speech")

        engine.releaseForTesting()
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.waitForLocalQueueForTesting()
        XCTAssertEqual(delivered.last, "Survived scroll and click")
    }

    func testExtraModifierAndTapDisabledFinishInsteadOfCancellingActiveSpeech() async throws {
        let journal = store(), socket = FakeSocket(), mic = ControllableMicrophone()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!,
                                         triggers: [.modifierHold(keys: [.fn], mode: .bilingual, holdMilliseconds: 180)],
                                         soundsEnabled: false, localDictationEnabled: true)
        let engine = DictationEngine(microphone: mic, pipeline: pipeline, recovery: journal, configuration: config)
        engine.localTranscriber = StubLocalTranscriber(ready: true, result: "Finished instead of cancelled")
        let savedBoard = Paster.snapshot(.general)
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedBoard.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            })
            engine.stop()
        }
        var delivered: [String] = []
        engine.onDelivery = { delivered.append($0.text); return true }

        // 1) Extra modifier brushed after 0.6s grace window finishes cleanly instead of cancelling.
        engine.beginModifierForTesting(triggerIndex: 0, mode: .bilingual, beganAgo: 2.0)
        mic.emit(Data(repeating: 6, count: 48_000 * 2))
        engine.simulateActiveModifierChangeForTesting(held: [.fn, .shift])
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.waitForLocalQueueForTesting()
        XCTAssertEqual(delivered.last, "Finished instead of cancelled")

        // 2) Tap disabled while Fn is STILL physically held keeps recording; tap disabled after Fn released finishes cleanly.
        delivered.removeAll()
        engine.beginModifierForTesting(triggerIndex: 0, mode: .bilingual, beganAgo: 2.0)
        mic.emit(Data(repeating: 7, count: 48_000 * 2))
        engine.handleTapDisabled(reason: "timeout", liveFlags: .maskSecondaryFn)
        XCTAssertEqual(engine.state, .listening(.bilingual), "Tap timeout while Fn is still down must not cancel")
        engine.handleTapDisabled(reason: "timeout", liveFlags: [])
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.waitForLocalQueueForTesting()
        XCTAssertEqual(delivered.last, "Finished instead of cancelled")
    }

    func testInvoluntaryCancelOfSubstantialAudioSavesRecoveryAndShowsRetryHUD() async throws {
        let journal = store(), socket = FakeSocket(), mic = ControllableMicrophone()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false, localDictationEnabled: true)
        let engine = DictationEngine(microphone: mic, pipeline: pipeline, recovery: journal, configuration: config)
        engine.localTranscriber = StubLocalTranscriber(ready: true, result: "Recovered after interruption")
        defer { engine.stop() }

        engine.beginForTesting(mode: .bilingual)
        mic.emit(Data(repeating: 9, count: 48_000 * 2)) // 2.0s >= 1.5s threshold
        try await Task.sleep(nanoseconds: 20_000_000)
        engine.cancelForTesting()

        let record = try XCTUnwrap(journal.list().first)
        XCTAssertFalse(record.complete)
        XCTAssertEqual(record.audioBytes, 48_000 * 2)
        XCTAssertEqual(record.errorCode, "cancelled_test")
        XCTAssertEqual(engine.state, .failed(.server("interrupted_saved")))
    }

    func testShortLocalTapRetiresRecoveryWithoutOrphan() async throws {
        let journal = store(), socket = FakeSocket(), mic = ControllableMicrophone()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        let config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false, localDictationEnabled: true)
        let engine = DictationEngine(microphone: mic, pipeline: pipeline, recovery: journal, configuration: config)
        engine.localTranscriber = StubLocalTranscriber(ready: true, result: "unused")
        defer { engine.stop() }

        engine.beginForTesting(mode: .bilingual)
        mic.emit(Data(repeating: 1, count: 496)) // < 4800 bytes
        engine.releaseForTesting()
        try await Task.sleep(nanoseconds: 50_000_000)
        await engine.waitForLocalQueueForTesting()

        XCTAssertEqual(engine.state, .failed(.tooShort))
        XCTAssertTrue(journal.list().isEmpty, "Tiny <0.1s tap must not leave an orphan in DictationRecovery")
    }
}

private final class SequenceLocalTranscriber: LocalDictationTranscriber, @unchecked Sendable {
    let backendID = "sequence-local"
    let isReady = true
    private let lock = NSLock()
    private var results: [String]
    init(results: [String]) { self.results = results }
    func transcribe(pcm24kMono: Data, mode: DictationMode, promptTerms: [String]) async throws -> String {
        lock.withLock { results.isEmpty ? "" : results.removeFirst() }
    }
}

private actor BlockingLocalTranscriber: LocalDictationTranscriber {
    nonisolated let backendID = "blocking-local"
    nonisolated let isReady = true
    private var continuations: [Int: CheckedContinuation<String, Error>] = [:]
    private var arrivedWaiters: [Int: CheckedContinuation<Void, Never>] = [:]
    private var count = 0

    func transcribe(pcm24kMono: Data, mode: DictationMode, promptTerms: [String]) async throws -> String {
        let idx = count
        count += 1
        return try await withCheckedThrowingContinuation { cont in
            continuations[idx] = cont
            arrivedWaiters.removeValue(forKey: idx)?.resume()
        }
    }

    func waitForFirstCall() async { await waitForCall(index: 0) }
    func waitForCall(index: Int) async {
        if continuations[index] != nil { return }
        await withCheckedContinuation { cont in arrivedWaiters[index] = cont }
    }

    func releaseCall(index: Int, text: String) {
        continuations.removeValue(forKey: index)?.resume(returning: text)
    }
}

private final class ControllableMicrophone: EngineMicrophone {
    var onFailure: ((String) -> Void)?
    var level: Float = 0.3
    private var sink: ((Data) -> Void)?
    func prepare() {}
    func warm(keepAlive: Double) {}
    func beginStreaming(since: Double, maxPreRoll: Double, sink: @escaping (Data) -> Void) -> Double {
        self.sink = sink; return 0
    }
    func endStreaming(keepAlive: Double) { sink = nil }
    func shutdown() { sink = nil }
    func emit(_ data: Data) { sink?(data) }
}

private final class StubLocalTranscriber: LocalDictationTranscriber, @unchecked Sendable {
    let backendID = "stub-local"
    let isReady: Bool
    let result: String
    init(ready: Bool, result: String) { self.isReady = ready; self.result = result }
    func prewarm() async {}
    func transcribe(pcm24kMono: Data, mode: DictationMode, promptTerms: [String]) async throws -> String { result }
}

private final class RecoveryMicrophone: EngineMicrophone {
    var onFailure: ((String) -> Void)?
    var level: Float = 0
    func prepare() {}
    func warm(keepAlive: Double) {}
    func beginStreaming(since: Double, maxPreRoll: Double, sink: @escaping (Data) -> Void) -> Double { 0 }
    func endStreaming(keepAlive: Double) {}
    func shutdown() {}

    func testPurgeExpiredDeletesOldItemsOnlyAndToleratesAMissingFolder() throws {
        let missing = DictationRecoveryStore(root: FileManager.default.temporaryDirectory.appendingPathComponent("sv-missing-\(UUID().uuidString)"))
        XCTAssertEqual(missing.purgeExpired(olderThan: 60), 0)
        XCTAssertEqual(missing.list(), [])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sv-purge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = DictationRecoveryStore(root: root)
        try store.begin(id: "old", mode: .bilingual, appName: nil, bundleID: nil)
        try store.append(Data(count: 4800), id: "old"); try store.seal("old")
        try store.begin(id: "live", mode: .bilingual, appName: nil, bundleID: nil)
        try store.append(Data(count: 4800), id: "live")
        try store.begin(id: "kept", mode: .bilingual, appName: nil, bundleID: nil); try store.seal("kept")
        let later = Date().addingTimeInterval(8 * 86_400)
        XCTAssertEqual(store.purgeExpired(olderThan: 7 * 86_400, keep: ["kept"], now: later), 1, "only the sealed, unkept item expires")
        XCTAssertEqual(Set(store.list().map(\.id)), ["live", "kept"])
        XCTAssertEqual(store.purgeExpired(olderThan: 7 * 86_400, now: Date()), 0, "nothing is younger than a week yet")
        try store.seal("live")
    }
}
