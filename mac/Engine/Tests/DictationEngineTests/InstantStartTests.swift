import AppKit
import XCTest
@testable import DictationEngine

@MainActor
final class InstantStartTests: XCTestCase {
    private func store() -> DictationRecoveryStore {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("instant-start-test-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return DictationRecoveryStore(root: url)
    }

    private func makeEngine(socket: TranscriptionSocket,
                            mic: InstantTestMicrophone = InstantTestMicrophone(),
                            rewriter: Rewriter = FakeRewriter { text, _ in text },
                            tuning: TurnPipeline.Tuning = TurnPipeline.Tuning(),
                            recovery: DictationRecoveryStore? = nil) -> (DictationEngine, TurnPipeline, InstantTestMicrophone, DictationRecoveryStore) {
        let journal = recovery ?? store()
        let pipeline = TurnPipeline(socket: socket, rewriter: rewriter, tuning: tuning)
        let config = EngineConfiguration(apiBaseURL: URL(string: "https://tests.invalid")!, soundsEnabled: false)
        let engine = DictationEngine(microphone: mic, pipeline: pipeline, recovery: journal, configuration: config)
        return (engine, pipeline, mic, journal)
    }

    private func waitFor(_ condition: @autoclosure @escaping () -> Bool, timeout: Double = 2) async {
        let end = uptime() + timeout
        while !condition() && uptime() < end { try? await Task.sleep(nanoseconds: 2_000_000) }
    }

    func testInstantListeningBeforeSocketConnectCompletesAndFlushesPreRollInOrder() async throws {
        let socket = DelayedConnectSocket()
        let (engine, _, mic, _) = makeEngine(socket: socket)
        defer { engine.stop() }
        var seenStates: [EngineState] = []
        engine.onStateChange = { seenStates.append($0) }

        let t0 = uptime()
        engine.beginForTesting(mode: .bilingual, pressAt: t0)
        let listeningMs = (uptime() - t0) * 1000

        XCTAssertEqual(engine.state, .listening(.bilingual), "HUD must enter listening immediately without blocking on STT connect")
        XCTAssertFalse(seenStates.contains { if case .preparing = $0 { return true }; return false }, "No preparing spinner state should block dictation start")
        XCTAssertLessThan(listeningMs, 100, "Start-to-listening must be immediate (measured \(listeningMs) ms)")
        XCTAssertEqual(mic.warms, 1)
        XCTAssertEqual(mic.streams, 1)

        await socket.waitForConnectStart()
        XCTAssertFalse(socket.isReady, "Socket is still mid-handshake while user is already speaking")

        // Speak three distinct chunks before the socket finishes connecting.
        let c1 = Data(repeating: 1, count: 4800)
        let c2 = Data(repeating: 2, count: 4800)
        let c3 = Data(repeating: 3, count: 4800)
        mic.emit(c1); mic.emit(c2); mic.emit(c3)
        await waitFor(engine.recoveryRecords.first?.audioBytes == 14_400)
        XCTAssertEqual(socket.appendedData.count, 0, "Audio stays buffered until socket connects")

        // Complete the slow handshake -> every pre-roll byte must flush in exact order.
        socket.succeedConnect()
        await waitFor(socket.appendedData.count == 14_400)
        XCTAssertEqual(socket.appendedData, c1 + c2 + c3, "Zero clipped first syllables; exact byte order preserved")
    }

    func testShortUtteranceFinishingBeforeSocketConnectStillTranscribes() async throws {
        let savedBoard = Paster.snapshot(.general)
        defer {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.writeObjects(savedBoard.map { values in
                let item = NSPasteboardItem(); for (type, data) in values { item.setData(data, forType: type) }; return item
            })
        }
        let socket = DelayedConnectSocket()
        let (engine, _, mic, _) = makeEngine(socket: socket)
        defer { engine.stop() }
        var delivered: [DeliveryRecord] = []
        engine.onDelivery = { delivered.append($0); return true }

        engine.beginForTesting(mode: .bilingual)
        XCTAssertEqual(engine.state, .listening(.bilingual))
        await socket.waitForConnectStart()

        // User speaks a short phrase and releases BEFORE the socket finishes connecting.
        let utterance = Data(repeating: 42, count: 14_400)
        mic.emit(utterance)
        engine.releaseForTesting()
        await waitFor({ if case .processing = engine.state { return true }; return false }())
        XCTAssertEqual(socket.commits, 0, "Cannot commit until socket finishes connecting")

        socket.succeedConnect()
        await waitFor(socket.commits == 1)
        XCTAssertEqual(socket.appendedData, utterance)

        socket.onEvent?(.committed(item: "short-1", previous: nil))
        socket.onEvent?(.completed(item: "short-1", transcript: "Quick note"))
        await waitFor(delivered.contains { $0.text == "Quick note" })
        XCTAssertEqual(delivered.last?.text, "Quick note")
    }

    func testFastCancelWhileSocketConnectingDropsBufferedAudioAndReturnsIdle() async throws {
        let socket = DelayedConnectSocket()
        let (engine, _, mic, _) = makeEngine(socket: socket)
        defer { engine.stop() }

        engine.beginForTesting(mode: .bilingual)
        XCTAssertEqual(engine.state, .listening(.bilingual))
        await socket.waitForConnectStart()

        mic.emit(Data(repeating: 7, count: 9600))
        engine.cancelForTesting()
        XCTAssertEqual(engine.state, .idle)
        XCTAssertEqual(mic.ends, 1)

        socket.succeedConnect()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(socket.appendedData.count, 0, "Cancelled pre-roll audio must never flush to STT")
        XCTAssertEqual(socket.commits, 0)
    }

    func testConnectionFailureWhileSpeakingKeepsLocalAudioAndRecoversCleanly() async throws {
        let socket = DelayedConnectSocket()
        let (engine, _, mic, journal) = makeEngine(socket: socket)
        defer { engine.stop() }
        var notices: [DictationNotice?] = []
        engine.onRecordingNotice = { notices.append($0) }

        engine.beginForTesting(mode: .bilingual)
        XCTAssertEqual(engine.state, .listening(.bilingual))
        await socket.waitForConnectStart()

        mic.emit(Data(repeating: 9, count: 9600))
        socket.failConnect(FailureCode("network_offline"))
        await socket.waitForConnectStart() // one transparent retry on a fresh session
        XCTAssertEqual(socket.connects, 2)
        socket.failConnect(FailureCode("network_offline"))
        await waitFor(notices.contains(.recordingLocally))
        XCTAssertEqual(engine.state, .listening(.bilingual), "Recording continues locally without interrupting speech")

        // User keeps speaking after connection failed; local journal must still capture it.
        mic.emit(Data(repeating: 10, count: 9600))
        engine.releaseForTesting()
        await waitFor(engine.state == .failed(.server("audio_saved")))

        let record = try XCTUnwrap(journal.list().first)
        XCTAssertEqual(record.audioBytes, 19_200, "Every spoken byte before and after connect failure is preserved on disk")
        XCTAssertEqual(record.errorCode, "network_offline")
        XCTAssertTrue(notices.contains(.recoveryAvailable))
    }

    func testPendingAudioBufferEnforcesMemoryBoundAndDegradesSafely() async throws {
        let socket = DelayedConnectSocket()
        var tuning = TurnPipeline.Tuning()
        tuning.maximumPendingAudioBytes = 9600
        let (engine, _, mic, journal) = makeEngine(socket: socket, tuning: tuning)
        defer { engine.stop() }
        var notices: [DictationNotice?] = []
        engine.onRecordingNotice = { notices.append($0) }

        engine.beginForTesting(mode: .bilingual)
        await socket.waitForConnectStart()

        mic.emit(Data(repeating: 1, count: 4800))
        mic.emit(Data(repeating: 2, count: 4800))
        mic.emit(Data(repeating: 3, count: 4800)) // exceeds 9600-byte pre-connect bound -> degrades cleanly
        await waitFor(notices.contains(.recordingLocally))

        engine.releaseForTesting()
        await waitFor(engine.state == .failed(.server("audio_saved")))
        XCTAssertEqual(journal.list().first?.audioBytes, 14_400, "Disk recovery keeps all bytes even when in-memory pre-connect buffer caps out")
    }

    func testPendingFlushCoalescesSmallChunksUnderRelayRateLimit() async {
        let socket = DelayedConnectSocket()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        defer { pipeline.shutdown() }

        pipeline.prepare(id: "burst", mode: .bilingual, app: nil)
        let start = Task { await pipeline.start(id: "burst", mode: .bilingual, app: nil) }
        await socket.waitForConnectStart()

        var expected = Data()
        for i in 0..<250 {
            let chunk = Data(repeating: UInt8(i % 251), count: 1920) // 40 ms @ 24 kHz
            expected.append(chunk)
            pipeline.audio(chunk)
        }
        socket.succeedConnect()
        await start.value

        XCTAssertEqual(socket.appendedData, expected)
        XCTAssertLessThanOrEqual(socket.appendCalls, 25, "Coalesced flush must stay far below relay 200 msg/s limit (got \(socket.appendCalls))")
    }

    func testServerWarmProactivelyRefreshesAccessToken() async {
        let tokens = CountingTokenProvider()
        WarmProtocol.healthHits = 0
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [WarmProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let client = ServerClient(baseURL: URL(string: "https://warm.invalid")!, tokens: tokens, session: session)

        await client.warm()
        let tokenHits = await tokens.calls
        XCTAssertEqual(WarmProtocol.healthHits, 1)
        XCTAssertEqual(tokenHits, 1)
    }

    func testStartToListeningLatencyBenchmark() async {
        var samplesMs: [Double] = []
        for i in 0..<10 {
            let socket = DelayedConnectSocket()
            let (engine, _, _, _) = makeEngine(socket: socket)
            let t0 = uptime()
            engine.beginForTesting(mode: .bilingual, pressAt: t0)
            let dt = (uptime() - t0) * 1000
            XCTAssertEqual(engine.state, .listening(.bilingual))
            samplesMs.append(dt)
            engine.cancelForTesting()
            engine.stop()
            if i == 0 { XCTAssertLessThan(dt, 100) }
        }
        let cold = samplesMs.first ?? 0
        let warm = samplesMs.dropFirst().sorted()
        let warmMedian = warm[warm.count / 2]
        print(String(format: "INSTANT_START_BENCH cold_ms=%.2f warm_median_ms=%.2f max_ms=%.2f", cold, warmMedian, samplesMs.max() ?? 0))
        XCTAssertLessThan(warmMedian, 25)
    }
}

private final class InstantTestMicrophone: EngineMicrophone {
    var onFailure: ((String) -> Void)?
    var level: Float = 0.25
    var warms = 0, streams = 0, ends = 0, shutdowns = 0
    private var sink: ((Data) -> Void)?
    func prepare() {}
    func warm(keepAlive: Double) { warms += 1 }
    @discardableResult func beginStreaming(since: Double, maxPreRoll: Double, sink: @escaping (Data) -> Void) -> Double {
        streams += 1; self.sink = sink; return 0
    }
    func emit(_ data: Data) { sink?(data) }
    func endStreaming(keepAlive: Double) { ends += 1; sink = nil }
    func shutdown() { shutdowns += 1; sink = nil }
}

@MainActor
private final class DelayedConnectSocket: TranscriptionSocket {
    var isReady = false
    var onEvent: ((STTEvent) -> Void)?
    var connectedAt = 0.0
    var keywords: [String] = []
    var replacements: [(String, String)] = []
    var basePrompt = "Base."
    var prompt = "Base."
    var appendedData = Data()
    var appendCalls = 0
    var commits = 0
    var connects = 0
    private var connectContinuation: CheckedContinuation<Void, Error>?
    private var startWaiter: CheckedContinuation<Void, Never>?

    func connect() async throws {
        connects += 1
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            connectContinuation = c
            startWaiter?.resume(); startWaiter = nil
        }
        isReady = true
        connectedAt = uptime()
        prompt = basePrompt
    }

    func waitForConnectStart() async {
        if connectContinuation != nil { return }
        await withCheckedContinuation { startWaiter = $0 }
    }

    func succeedConnect() {
        let c = connectContinuation; connectContinuation = nil
        c?.resume()
    }

    func failConnect(_ error: Error) {
        let c = connectContinuation; connectContinuation = nil
        c?.resume(throwing: error)
    }

    func append(_ pcm: Data) { appendedData.append(pcm); appendCalls += 1 }
    func commit() { commits += 1 }
    func close() {
        isReady = false
        let c = connectContinuation; connectContinuation = nil
        c?.resume(throwing: CancellationError())
    }
    func updatePrompt(_ prompt: String) { self.prompt = prompt }
}

private actor CountingTokenProvider: AccessTokenProvider {
    private(set) var calls = 0
    func accessToken() async throws -> String { calls += 1; return "warm-token" }
}

private final class WarmProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var healthHits = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/api/health" { Self.healthHits += 1 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("{\"ok\":true}".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
