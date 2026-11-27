import XCTest
@testable import DictationEngine

// Server 2026-10-14 reads tidy answers whole (email length guard) and sends them as one SSE content event + stop.
// These bytes are exactly what `server/lib/tidy.ts` `sse()` writes; installed apps must read them unchanged.
final class TidyServerStreamTests: XCTestCase {
    static let body =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"Hi Mike,\\n\\nDave and I moved the launch to Nov 12.\\n\\n감사합니다!\\nDan\"},\"finish_reason\":null}]}\n\n" +
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" +
        "data: [DONE]\n\n"

    func testOneEventTidyStreamIsReadWhole() async throws {
        TidyStreamURLProtocol.body = Self.body
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TidyStreamURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = ServerClient(baseURL: URL(string: "https://tidy-stream-tests.invalid")!, tokens: StaticTokens(), session: session)
        let text = try await client.tidy("source", tier: .primary)
        XCTAssertEqual(text, "Hi Mike,\n\nDave and I moved the launch to Nov 12.\n\n감사합니다!\nDan")
    }
}

private actor StaticTokens: AccessTokenProvider {
    func accessToken() async throws -> String { "token" }
    func invalidateAccessToken(_ rejectedToken: String) async {}
}

private final class TidyStreamURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var body = ""
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let headers = ["Content-Type": "text/event-stream", "X-Rewrite-Mode": "tidy", "X-Rewrite-Tier": "primary"]
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
