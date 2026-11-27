import XCTest
@testable import DictationEngine

@MainActor
final class StoppedLifecycleTests: XCTestCase {
    func testStopInvalidatesQueuedInputEvenAfterRestart() {
        var lifecycle = EngineLifecycle()
        let first = lifecycle.start()
        XCTAssertTrue(lifecycle.accepts(first))
        XCTAssertEqual(lifecycle.start(), first, "Repeated startup must preserve current callbacks")
        lifecycle.stop()
        XCTAssertFalse(lifecycle.accepts(first))
        XCTAssertFalse(lifecycle.allowsMicCheck(first))
        let second = lifecycle.start()
        XCTAssertNotEqual(second, first)
        XCTAssertFalse(lifecycle.accepts(first), "An old hotkey or mic callback must not enter the new run")
        XCTAssertTrue(lifecycle.accepts(second))
    }

    func testFirstRunMicCheckWorksButStopBlocksEveryLaterCheck() {
        let mic = LifecycleMicrophone()
        let engine = DictationEngine(microphone: mic)
        engine.startMicLevelCheck { _ in XCTFail("No timer should fire in this synchronous test") }
        XCTAssertEqual(mic.warms, 1, "Onboarding can test the mic before the first engine start")
        engine.stop()
        engine.startMicLevelCheck { _ in XCTFail("A stopped engine must never deliver levels") }
        engine.stopMicLevelCheck()
        engine.stop()
        XCTAssertEqual(mic.warms, 1)
        XCTAssertEqual(mic.ends, 1)
        XCTAssertEqual(mic.shutdowns, 1, "Repeated stop is idempotent")
        XCTAssertEqual(engine.state, .idle)
    }

    func testStoppedSetupAndFixtureCannotRestartCapture() async throws {
        let mic = LifecycleMicrophone()
        let engine = DictationEngine(microphone: mic)
        engine.stop()
        // These are the calls still possible from an already-open settings/onboarding window.
        try engine.reinstallInputTap()
        engine.updateTriggers([.key(keyCode: 49, modifiers: 0, mode: .bilingual)])
        var captureReplies = 0
        engine.captureNextTrigger(timeout: 0.1) { trigger in
            XCTAssertNil(trigger); captureReplies += 1
        }
        let result = await engine.runFixture(Data(count: 4800), mode: .bilingual)
        XCTAssertNil(result)
        XCTAssertEqual(captureReplies, 1)
        XCTAssertEqual(mic.warms, 0)
        XCTAssertEqual(mic.streams, 0)
        XCTAssertEqual(engine.state, .idle)
    }

    func testShutdownDiscardsAudioWaitingForConnect() async {
        let socket = SuspendedLifecycleSocket()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        var events: [TurnPipeline.Event] = []
        pipeline.onEvent = { events.append($0) }
        let start = Task { await pipeline.start(id: "pending", mode: .bilingual, app: nil) }
        await socket.waitForConnect()
        pipeline.audio(Data(count: 9600))
        pipeline.shutdown()
        socket.finishConnect()
        await start.value
        await pipeline.maintain()
        await pipeline.cancel()
        await pipeline.start(id: "late", mode: .english, app: nil)
        pipeline.audio(Data(count: 4800))
        pipeline.stop()
        XCTAssertEqual(socket.appended, 0, "Stopped pending audio must never flush to the cloud")
        XCTAssertEqual(socket.connects, 1)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(pipeline.isBusy)
    }

    func testQueuedShortTurnCancelCannotReconnectAfterShutdown() async {
        let socket = FakeSocket()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        await pipeline.start(id: "short", mode: .bilingual, app: nil)
        pipeline.audio(Data(count: 10))
        pipeline.stop() // Queues normal cancellation/recovery on the actor.
        pipeline.shutdown()
        pipeline.shutdown()
        await Task.yield()
        XCTAssertEqual(socket.connects, 0)
        XCTAssertEqual(socket.closes, 1)
        XCTAssertFalse(pipeline.isBusy)
    }

    func testNormalCancelStillReconnects() async {
        let socket = FakeSocket()
        let pipeline = TurnPipeline(socket: socket, rewriter: FakeRewriter { text, _ in text })
        await pipeline.start(id: "cancel", mode: .bilingual, app: nil)
        await pipeline.cancel()
        XCTAssertEqual(socket.connects, 1)
        XCTAssertTrue(socket.isReady)
        XCTAssertFalse(pipeline.isBusy)
        pipeline.shutdown()
    }

    func testClosingDuringUncooperativeGrantCannotCreateWebSocket() async {
        let grants = SuspendedLifecycleGrants()
        var socketCreations = 0
        let socket = RealtimeSTTSocket(mintSession: { await grants.request() }, makeWebSocket: { _ in
            socketCreations += 1
            throw FixtureError.socketForbidden
        })
        let connecting = Task { try await socket.connect() }
        await grants.waitForRequests(1)
        socket.close()
        await grants.release(1)
        do { try await connecting.value; XCTFail("Closed connect must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(socketCreations, 0)
        XCTAssertFalse(socket.isReady)
    }

    func testClosedConnectionCanBeExplicitlyStartedAgain() async {
        let grants = SuspendedLifecycleGrants()
        var socketCreations = 0
        let socket = RealtimeSTTSocket(mintSession: { await grants.request() }, makeWebSocket: { _ in
            socketCreations += 1
            throw FixtureError.socketForbidden
        })
        let old = Task { try await socket.connect() }
        await grants.waitForRequests(1)
        socket.close()
        let fresh = Task { try await socket.connect() }
        await grants.waitForRequests(2)
        await grants.release(1)
        do { try await old.value; XCTFail("Old generation must remain closed") } catch {}
        await grants.release(2)
        do { try await fresh.value; XCTFail("Fixture never opens a real WebSocket") }
        catch { XCTAssertEqual(error as? FixtureError, .socketForbidden) }
        XCTAssertEqual(socketCreations, 1, "Only the fresh generation may reach transport creation")
        socket.close()
    }
}

private enum FixtureError: Error { case socketForbidden }

private final class LifecycleMicrophone: EngineMicrophone {
    var onFailure: ((String) -> Void)?
    var level: Float = 0
    var warms = 0, streams = 0, ends = 0, shutdowns = 0
    func prepare() {}
    func warm(keepAlive: Double) { warms += 1 }
    func beginStreaming(since: Double, maxPreRoll: Double, sink: @escaping (Data) -> Void) -> Double {
        streams += 1; return 0
    }
    func endStreaming(keepAlive: Double) { ends += 1 }
    func shutdown() { shutdowns += 1 }
}

@MainActor
private final class SuspendedLifecycleSocket: TranscriptionSocket {
    var isReady = false
    var onEvent: ((STTEvent) -> Void)?
    var connectedAt = 0.0
    var keywords: [String] = []
    var replacements: [(String, String)] = []
    var basePrompt = "", prompt = ""
    var appended = 0, connects = 0
    private var connection: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    func connect() async throws {
        connects += 1
        await withCheckedContinuation { connection = $0; waiter?.resume(); waiter = nil }
        isReady = true
    }
    func waitForConnect() async {
        if connection != nil { return }
        await withCheckedContinuation { waiter = $0 }
    }
    func finishConnect() { connection?.resume(); connection = nil }
    func append(_ pcm: Data) { appended += pcm.count }
    func commit() {}
    func close() { isReady = false }
    func updatePrompt(_ prompt: String) { self.prompt = prompt }
}

/// Deliberately ignores task cancellation to exercise the generation check after an await.
private actor SuspendedLifecycleGrants {
    private var count = 0
    private var pending: [Int: CheckedContinuation<STTSessionGrant, Never>] = [:]
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []
    func request() async -> STTSessionGrant {
        count += 1
        let id = count
        return await withCheckedContinuation { continuation in
            pending[id] = continuation
            let ready = waiters.filter { $0.0 <= count }
            waiters.removeAll { $0.0 <= count }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitForRequests(_ expected: Int) async {
        if count >= expected { return }
        await withCheckedContinuation { waiters.append((expected, $0)) }
    }
    func release(_ id: Int) {
        pending.removeValue(forKey: id)?.resume(returning: STTSessionGrant(
            client_secret: "offline-fixture", expires_at: 0, url: URL(string: "wss://fixture.invalid")!,
            model: "offline", session: .init(delay: "low", prompt: "", keywords: [], languages: [])))
    }
}
