import Foundation
import XCTest
@testable import DictationEngine

/// Controlled outage at the test rewriter boundary, real production fallback transport.
/// A server OpenRouter 402 becomes HTTP 502; ServerClient exposes FailureCode("http_502").
/// No production code, provider configuration, installed app or microphone is changed.
@MainActor
final class LiveFallbackTests: XCTestCase {
    func testOutOfCreditPrimaryUsesProductionOpenAI() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SV_NATIVE_FAULT_PROXY"] == "1", let file = env["SV_NATIVE_TOKEN_FILE"],
              let base = env["SV_NATIVE_BASE"].flatMap(URL.init(string:)) else { throw XCTSkip("controlled live fallback not configured") }
        let token = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let server = ServerClient(baseURL: base, tokens: FallbackFixtureToken(token))
        let rewriter = CreditFailureRewriter(server: server)
        let pipeline = TurnPipeline(socket: RealtimeSTTSocket(server: server), rewriter: rewriter)
        let source = "내일 오후 세 시에 예약 확인 부탁드려요."
        let start = uptime()
        let output = try await pipeline.translate(source, mode: .english, app: nil, turn: nil)
        XCTAssertGreaterThan(output.count, 10)
        XCTAssertNil(output.range(of: "[가-힣]", options: .regularExpression))
        let timePreserved = output.contains("3") || output.lowercased().contains("three")
        XCTAssertTrue(timePreserved)
        let attempts = await rewriter.attempts
        XCTAssertEqual(attempts, ["primary:http_502:simulated_openrouter_402", "fallback:production_openai"])
        if let path = env["SV_NATIVE_FAULT_REPORT"] {
            let data = try JSONSerialization.data(withJSONObject: ["base": base.absoluteString, "at": ISO8601DateFormatter().string(from: Date()), "faultInjectedOnlyInTest": true,
                "attempts": attempts, "englishResultPreservesTime": timePreserved, "outputCharacters": output.count, "latencyMs": ms(uptime()-start)], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
}
private actor CreditFailureRewriter: Rewriter {
    let server: ServerClient
    var attempts: [String] = []
    init(server: ServerClient) { self.server = server }
    func rewrite(_ text: String, mode: DictationMode, tier: RewriteTier, app: String?, context: [String]) async throws -> String {
        if tier == .primary { attempts.append("primary:http_502:simulated_openrouter_402"); throw FailureCode("http_502") }
        attempts.append("fallback:production_openai")
        return try await server.rewrite(text, mode: mode, tier: tier, app: app, context: context)
    }
}
private final class FallbackFixtureToken: AccessTokenProvider, @unchecked Sendable {
    let token: String
    init(_ token: String) { self.token = token }
    func accessToken() async throws -> String { token }
}
