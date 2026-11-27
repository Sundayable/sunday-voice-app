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
}

private final class RecoveryMicrophone: EngineMicrophone {
    var onFailure: ((String) -> Void)?
    var level: Float = 0
    func prepare() {}
    func warm(keepAlive: Double) {}
    func beginStreaming(since: Double, maxPreRoll: Double, sink: @escaping (Data) -> Void) -> Double { 0 }
    func endStreaming(keepAlive: Double) {}
    func shutdown() {}
}
