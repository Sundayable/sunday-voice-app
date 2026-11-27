import XCTest
@testable import DictationEngine

final class TranscriptionStreamTests: XCTestCase {
    func testFinalTranscriptDoesNotWaitForHTTPClosureOrHistoryAcknowledgement() async throws {
        let fixture = TranscriptionFixture(body: "data: {\"type\":\"delta\",\"delta\":\"대표님 \"}\r\n\r\ndata: {\"type\":\"completed\",\"text\":\"대표님 안녕하세요.\"}\n\n", finish: false)
        defer { fixture.close() }
        let received = TranscriptionDeltas()
        let text = try await withDeadline(2) { try await fixture.client.transcribePCM(Data(count: 4800), onDelta: { received.append($0) }) }
        XCTAssertEqual(text, "대표님 안녕하세요.")
        XCTAssertEqual(received.values, ["대표님 "])
        XCTAssertEqual(TranscriptionProtocol.calls, 1)
    }
    func testOldServerJSONResponseStillWorks() async throws {
        let fixture = TranscriptionFixture(body: "{\"text\":\"legacy result\"}", type: "application/json", finish: true)
        defer { fixture.close() }
        let text = try await fixture.client.transcribePCM(Data(count: 4800))
        XCTAssertEqual(text, "legacy result")
    }
    func testIncompleteStreamNeverProducesFinalOrRetries() async {
        let fixture = TranscriptionFixture(body: "data: {\"type\":\"delta\",\"delta\":\"partial\"}\n\n", finish: true)
        defer { fixture.close() }
        do { _ = try await fixture.client.transcribePCM(Data(count: 4800)); XCTFail("Missing completion") }
        catch { XCTAssertEqual(error as? FailureCode, FailureCode("stt_incomplete")) }
        XCTAssertEqual(TranscriptionProtocol.calls, 1)
    }
    func testQuotaDenialIsNotRetried() async {
        let fixture = TranscriptionFixture(body: "{\"error\":{\"code\":\"quota_exceeded\"}}", type: "application/json", status: 429, finish: true)
        defer { fixture.close() }
        do { _ = try await fixture.client.transcribePCM(Data(count: 4800)); XCTFail("Expected quota denial") }
        catch { XCTAssertEqual(error as? FailureCode, .quotaExceeded) }
        XCTAssertEqual(TranscriptionProtocol.calls, 1)
    }
}
private final class TranscriptionDeltas: @unchecked Sendable {
    let lock = NSLock(); private var collected: [String] = []
    func append(_ value: String) { lock.withLock { collected.append(value) } }
    var values: [String] { lock.withLock { collected } }
}
private actor TranscriptionToken: AccessTokenProvider {
    func accessToken() async throws -> String { "fixture-token" }
}
private final class TranscriptionFixture: @unchecked Sendable {
    let session: URLSession, client: ServerClient
    init(body: String, type: String = "text/event-stream", status: Int = 200, finish: Bool) {
        TranscriptionProtocol.body = body; TranscriptionProtocol.type = type; TranscriptionProtocol.status = status
        TranscriptionProtocol.finish = finish; TranscriptionProtocol.calls = 0
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [TranscriptionProtocol.self]
        session = URLSession(configuration: config)
        client = ServerClient(baseURL: URL(string: "https://transcription.invalid")!, tokens: TranscriptionToken(), session: session)
    }
    func close() { session.invalidateAndCancel() }
}
private final class TranscriptionProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = "", type = "text/event-stream", status = 200, finish = true, calls = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls += 1
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": Self.type])!, cacheStoragePolicy: .notAllowed)
        let bytes = Data(Self.body.utf8)
        for at in stride(from: 0, to: bytes.count, by: 7) { client?.urlProtocol(self, didLoad: bytes.subdata(in: at..<min(at + 7, bytes.count))) }
        if Self.finish { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
