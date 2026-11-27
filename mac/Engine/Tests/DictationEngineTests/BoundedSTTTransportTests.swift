import XCTest
@testable import DictationEngine

@MainActor
final class BoundedSTTTransportTests: XCTestCase {
    func testPartialTranscriptArrivesBeforeCompletionAndCloseFencesIt() async {
        let gate = BoundedReplyGate(), partial = expectation(description: "partial before final")
        let transport = BoundedSTTTransport(streaming: { _, delta in delta("대표님 "); return await gate.wait() })
        var completed = false
        transport.onEvent = { event in
            if case .delta(_, let text) = event { XCTAssertEqual(text, "대표님 "); partial.fulfill() }
            if case .completed = event { completed = true }
        }
        transport.append(Data(count: 4800)); transport.commit()
        await fulfillment(of: [partial], timeout: 2)
        XCTAssertFalse(completed)
        transport.close(); await gate.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(completed)
    }
    func testCommittedItemsKeepOrderAndCompleteWithServerText() async {
        let completed = expectation(description: "two bounded responses")
        completed.expectedFulfillmentCount = 2
        let transport = BoundedSTTTransport { pcm in "bytes=\(pcm.count)" }
        var commits: [(String, String?)] = [], texts: [String] = []
        transport.onEvent = { event in
            if case .committed(let id, let previous) = event { commits.append((id, previous)) }
            if case .completed(_, let text) = event { texts.append(text); completed.fulfill() }
        }
        transport.append(Data(count: 4800)); transport.commit()
        transport.append(Data(count: 9600)); transport.commit()
        await fulfillment(of: [completed], timeout: 2)
        XCTAssertEqual(commits.count, 2)
        XCTAssertNil(commits[0].1)
        XCTAssertEqual(commits[1].1, commits[0].0)
        XCTAssertEqual(Set(texts), Set(["bytes=4800", "bytes=9600"]))
        transport.close()
    }

    func testEachCommitCapturesItsOwnHistoryContext() async {
        let done = expectation(description: "correlated chunks"); done.expectedFulfillmentCount = 2
        var results: Set<String> = []
        let transport = BoundedSTTTransport { _ in DiagnosticContext.turn?.id ?? "missing" }
        transport.onEvent = { event in if case .completed(_, let text) = event { results.insert(text); done.fulfill() } }
        transport.context = .init(id: "first", app: "one")
        transport.append(Data(count: 4800)); transport.commit()
        transport.context = .init(id: "second", app: "two")
        transport.append(Data(count: 4800)); transport.commit()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(results, Set(["first", "second"]))
        transport.close()
    }

    func testOverflowNeverReachesProvider() {
        let transport = BoundedSTTTransport { _ in XCTFail("Oversized PCM must remain local"); return "" }
        var events: [STTEvent] = []
        transport.onEvent = { events.append($0) }
        transport.append(Data(count: BoundedSTTTransport.maximumBytes + 2)); transport.commit()
        XCTAssertEqual(events, [.error(code: "audio_too_long")])
        transport.close()
    }

    func testCloseFencesLateServerCompletion() async {
        let gate = BoundedReplyGate()
        let transport = BoundedSTTTransport { _ in await gate.wait() }
        var events: [STTEvent] = []
        transport.onEvent = { events.append($0) }
        transport.append(Data(count: 4800)); transport.commit()
        while !(await gate.waiting) { await Task.yield() }
        transport.close()
        await gate.finish()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(events.count, 1, "Only the initial commit, never a late transcript")
    }

    func testGuestGrantDoesNotOpenProviderWebSocket() async throws {
        let grant = STTSessionGrant(client_secret: "", expires_at: 0,
            url: URL(string: "https://example.test/api/stt/transcribe")!, model: "gpt-live-transcribe",
            session: .init(delay: "minimal", prompt: "", keywords: [], languages: ["ko", "en"]),
            transport: "bounded-pcm-v1")
        let socket = RealtimeSTTSocket(mintSession: { grant }, makeWebSocket: { _ in
            XCTFail("An external tester must not receive or use a provider credential")
            throw FailureCode("unexpected_websocket")
        }, transcribePCM: { _ in "안녕하세요" })
        try await socket.connect()
        XCTAssertTrue(socket.isReady)
        socket.close()
        XCTAssertFalse(socket.isReady)
    }
}

private actor BoundedReplyGate {
    var waiting = false
    private var reply: CheckedContinuation<String, Never>?
    func wait() async -> String {
        await withCheckedContinuation { reply = $0; waiting = true }
    }
    func finish() { reply?.resume(returning: "late"); reply = nil }
}
