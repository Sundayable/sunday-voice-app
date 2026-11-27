import XCTest
@testable import DictationEngine

final class ServerClientAuthTests: XCTestCase {
    func testSTTRetries401WithInvalidatedToken() async throws {
        let fixture = AuthHTTPFixture(); defer { fixture.close() }
        let grant = try await fixture.client.mintSTTSession()
        XCTAssertEqual(grant.client_secret, "test-secret")
        let rejected = await fixture.tokens.rejected
        XCTAssertEqual(rejected, ["old"])
        XCTAssertEqual(fixture.responses.headers, ["Bearer old", "Bearer new"])
    }

    func testSTTStopsAfterSecond401() async throws {
        let fixture = AuthHTTPFixture(alwaysReject: true); defer { fixture.close() }
        do { _ = try await fixture.client.mintSTTSession(); XCTFail("Expected authentication failure") }
        catch { XCTAssertEqual(error as? FailureCode, .notSignedIn) }
        let rejected = await fixture.tokens.rejected
        XCTAssertEqual(rejected, ["old"])
        XCTAssertEqual(fixture.responses.headers, ["Bearer old", "Bearer new"])
    }

    func testStreamingRewriteRetries401WithInvalidatedToken() async throws {
        let fixture = AuthHTTPFixture(); defer { fixture.close() }
        let text = try await fixture.client.rewrite("fixture", mode: .english, tier: .primary, app: nil)
        XCTAssertEqual(text, "rewritten fixture")
        let rejected = await fixture.tokens.rejected
        XCTAssertEqual(rejected, ["old"])
        XCTAssertEqual(fixture.responses.headers, ["Bearer old", "Bearer new"])
    }

    func testStreamingRewriteStopsAfterSecond401() async throws {
        let fixture = AuthHTTPFixture(alwaysReject: true); defer { fixture.close() }
        do { _ = try await fixture.client.rewrite("fixture", mode: .english, tier: .primary, app: nil); XCTFail("Expected authentication failure") }
        catch { XCTAssertEqual(error as? FailureCode, .notSignedIn) }
        let rejected = await fixture.tokens.rejected
        XCTAssertEqual(rejected, ["old"])
        XCTAssertEqual(fixture.responses.headers, ["Bearer old", "Bearer new"])
    }

    func testHTTP200TruncatedRewriteIsNotAccepted() async {
        let fixture = AuthHTTPFixture(rewriteFinish: "length"); defer { fixture.close() }
        do { _ = try await fixture.client.rewrite("fixture", mode: .english, tier: .primary, app: nil); XCTFail("Truncated output must use the raw fallback") }
        catch { XCTAssertEqual(error as? FailureCode, .rewriteIncomplete) }
    }

    func testHTTP200MissingFinalMarkerIsNotAccepted() async {
        let fixture = AuthHTTPFixture(rewriteFinish: nil); defer { fixture.close() }
        do { _ = try await fixture.client.rewrite("fixture", mode: .english, tier: .primary, app: nil); XCTFail("An incomplete stream must use the raw fallback") }
        catch { XCTAssertEqual(error as? FailureCode, .rewriteIncomplete) }
    }
}

private actor RefreshableTestTokens: AccessTokenProvider {
    private var token = "old"
    private(set) var rejected: [String] = []
    func accessToken() async throws -> String { token }
    func invalidateAccessToken(_ rejectedToken: String) async {
        rejected.append(rejectedToken)
        if rejectedToken == token { token = "new" }
    }
}

private final class AuthHTTPFixture {
    let tokens = RefreshableTestTokens()
    let responses: EngineAuthResponses
    let session: URLSession
    let client: ServerClient
    init(alwaysReject: Bool = false, rewriteFinish: String? = "stop") {
        responses = EngineAuthResponses(alwaysReject: alwaysReject, rewriteFinish: rewriteFinish)
        EngineAuthURLProtocol.responses = responses
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [EngineAuthURLProtocol.self]
        session = URLSession(configuration: configuration)
        client = ServerClient(baseURL: URL(string: "https://engine-auth-tests.invalid")!, tokens: tokens, session: session)
    }
    func close() { session.invalidateAndCancel(); EngineAuthURLProtocol.responses = nil }
}

private final class EngineAuthResponses: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedHeaders: [String] = []
    private let alwaysReject: Bool
    private let rewriteFinish: String?
    init(alwaysReject: Bool, rewriteFinish: String?) { self.alwaysReject = alwaysReject; self.rewriteFinish = rewriteFinish }
    var headers: [String] { lock.withLock { recordedHeaders } }
    func response(to request: URLRequest) -> (Int, Data) {
        lock.withLock {
            let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
            recordedHeaders.append(header)
            if alwaysReject || header != "Bearer new" {
                return (401, Data("{\"error\":{\"code\":\"unauthorized\"}}".utf8))
            }
            if request.url?.path == "/api/rewrite" {
                let event: [String: Any] = ["choices": [["delta": ["content": "rewritten fixture"], "finish_reason": rewriteFinish as Any? ?? NSNull()]]]
                let json = String(decoding: try! JSONSerialization.data(withJSONObject: event), as: UTF8.self)
                return (200, Data("data: \(json)\n\ndata: [DONE]\n\n".utf8))
            }
            let grant: [String: Any] = ["client_secret": "test-secret", "expires_at": 12345, "url": "wss://stt.invalid", "model": "fixture",
                                        "session": ["delay": "low", "prompt": "", "keywords": [], "languages": []]]
            return (200, try! JSONSerialization.data(withJSONObject: grant))
        }
    }
}

private final class EngineAuthURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var storedResponses: EngineAuthResponses?
    static var responses: EngineAuthResponses? {
        get { lock.withLock { storedResponses } }
        set { lock.withLock { storedResponses = newValue } }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let responses = Self.responses else { client?.urlProtocol(self, didFailWithError: URLError(.cancelled)); return }
        let (status, data) = responses.response(to: request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
