import Foundation
import XCTest
@testable import DictationEngine

/// Opt-in product transport QA. A dedicated test invitation supplies the token; no Keychain,
/// installed app, microphone, event tap, paste, or personal account is touched.
@MainActor
final class LiveGuestServerTests: XCTestCase {
    func testGuestFixtureThroughNativePipeline() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SV_NATIVE_BASE"].flatMap(URL.init(string:)), let file = env["SV_NATIVE_TOKEN_FILE"],
              let fixture = env["SV_NATIVE_FIXTURE"] else { throw XCTSkip("dedicated guest live QA not configured") }
        let token = try String(contentsOfFile: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let pcm = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let server = ServerClient(baseURL: base, tokens: GuestFixtureToken(token))
        let socket = RealtimeSTTSocket(server: server)
        defer { socket.close() }
        let pipeline = TurnPipeline(socket: socket, rewriter: server)
        var evidence: [[String: Any]] = []
        for mode in [DictationMode.bilingual, .english] {
            var results: [String] = [], failures: [String] = []
            var fallbackCount = 0, audioComplete = false
            pipeline.onEvent = {
                if case .result(_, let text, let stats) = $0 {
                    results.append(text); fallbackCount = stats.fallbacks; audioComplete = stats.audioComplete
                }
                if case .error(_, let code) = $0 { failures.append(code) }
            }
            try await socket.connect()
            await pipeline.start(id: UUID().uuidString, mode: mode, app: nil)
            let began = uptime()
            for at in stride(from: 0, to: pcm.count, by: 2400) {
                pipeline.audio(pcm.subdata(in: at..<min(at + 2400, pcm.count)))
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let released = uptime(); pipeline.stop(releasedAt: released)
            let deadline = uptime() + 25
            while results.isEmpty && failures.isEmpty && uptime() < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
            XCTAssertTrue(failures.isEmpty, "Native guest pipeline failure: \(failures)")
            let output = try XCTUnwrap(results.last, "Native guest pipeline produced no result")
            XCTAssertGreaterThan(output.count, 10)
            let languageOK = (output.range(of: "[가-힣]", options: .regularExpression) != nil) == (mode == .bilingual)
            XCTAssertTrue(languageOK)
            XCTAssertTrue(audioComplete)
            if env["SV_NATIVE_REQUIRE_FALLBACK"] == "1" { XCTAssertGreaterThan(fallbackCount, 0) }
            let readyMs = ms(uptime()-released)
            evidence.append(["mode": mode.rawValue, "audioSeconds": Double(pcm.count)/48000, "releaseToReadyMs": readyMs,
                             "fallbacks": fallbackCount, "audioComplete": audioComplete, "outputCharacters": output.count, "languageCheck": languageOK])
            print("GUEST_NATIVE_RESULT mode=\(mode.rawValue) audio_seconds=\(Double(pcm.count)/48000) release_to_ready_ms=\(readyMs) fallbacks=\(fallbackCount) total_ms=\(ms(uptime()-began))")
        }
        if let report = env["SV_NATIVE_REPORT"] {
            let data = try JSONSerialization.data(withJSONObject: ["base": base.absoluteString, "at": ISO8601DateFormatter().string(from: Date()), "results": evidence], options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: report), options: .atomic)
        }
    }
}
private final class GuestFixtureToken: AccessTokenProvider, @unchecked Sendable {
    private let token: String
    init(_ token: String) { self.token = token }
    func accessToken() async throws -> String { token }
}
