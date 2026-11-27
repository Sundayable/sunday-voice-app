import CryptoKit
import XCTest
@testable import DictationEngine

/// Opt-in end-to-end check of the native path against a deployed API (no microphone, no event tap):
/// dev sign-in → ephemeral STT key → OpenAI Realtime socket → streaming rewrite proxy → final text.
/// Runs only with SUNDAY_VOICE_LIVE_BASE, SUNDAY_VOICE_DEV_LOGIN_SECRET and SUNDAY_VOICE_FIXTURE
/// (PCM16 mono 24 kHz WAV) set. Prints timings only; asserts on fixture content.
final class DevTokens: AccessTokenProvider, @unchecked Sendable {
    let base: URL, secret: String
    private var token: String?
    init(base: URL, secret: String) { self.base = base; self.secret = secret }
    func accessToken() async throws -> String {
        if let token { return token }
        let verifier = Data((0..<32).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        func post(_ path: String, _ body: [String: Any], _ headers: [String: String] = [:]) async throws -> [String: Any] {
            var r = URLRequest(url: base.appendingPathComponent(path)); r.httpMethod = "POST"
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            headers.forEach { r.setValue($1, forHTTPHeaderField: $0) }
            r.httpBody = try JSONSerialization.data(withJSONObject: body)
            return try JSONSerialization.jsonObject(with: try await URLSession.shared.data(for: r).0) as! [String: Any]
        }
        let code = try await post("api/auth/dev-login", ["email": "dan@sundayable.com", "code_challenge": challenge, "state": "livetest-state-0001"], ["x-dev-login-secret": secret])["code"] as! String
        token = try await post("api/auth/token", ["grant_type": "authorization_code", "code": code, "code_verifier": verifier])["access_token"] as? String
        return token!
    }
}

@MainActor
final class LiveServerTests: XCTestCase {
    func testFixtureThroughRealServer() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let base = env["SUNDAY_VOICE_LIVE_BASE"].flatMap(URL.init(string:)), let secret = env["SUNDAY_VOICE_DEV_LOGIN_SECRET"],
              let fixture = env["SUNDAY_VOICE_FIXTURE"] else { throw XCTSkip("live env not set") }
        let wav = try Data(contentsOf: URL(fileURLWithPath: fixture))
        let pcm = wav.subdata(in: 44..<wav.count)
        let tokens = DevTokens(base: base, secret: secret)
        let server = ServerClient(baseURL: base, tokens: tokens)
        // Same hints KoEn v4 had in its config, now as the user's dictionary.
        var put = URLRequest(url: base.appendingPathComponent("api/dictionary")); put.httpMethod = "PUT"
        put.setValue("application/json", forHTTPHeaderField: "Content-Type")
        put.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        put.httpBody = try JSONSerialization.data(withJSONObject: ["words": ["Ads report", "Lauren", "Dan", "Sundayable", "Friday"]])
        _ = try await URLSession.shared.data(for: put)
        let socket = RealtimeSTTSocket(server: server)
        let pipeline = TurnPipeline(socket: socket, rewriter: server)
        var outputs: [String: String] = [:]
        for mode in [DictationMode.bilingual, .english] {
            var events: [TurnPipeline.Event] = []
            pipeline.onEvent = { events.append($0) }
            let connectStart = uptime()
            try await socket.connect()
            let connectMs = ms(uptime() - connectStart)
            await pipeline.start(id: mode.rawValue, mode: mode, app: nil)
            let begin = uptime()
            var offset = 0
            while offset < pcm.count { // real-time pacing, 50 ms chunks, no trailing silence
                let end = min(offset + 2400, pcm.count)
                pipeline.audio(pcm.subdata(in: offset..<end))
                offset = end
                let due = begin + Double(offset) / 48000
                if due > uptime() { try await Task.sleep(nanoseconds: UInt64((due - uptime()) * 1e9)) }
            }
            let released = uptime()
            pipeline.stop(releasedAt: released)
            let deadline = uptime() + 15
            while uptime() < deadline, !events.contains(where: { if case .result = $0 { return true }; if case .error = $0 { return true }; return false }) {
                try await Task.sleep(nanoseconds: 2_000_000)
            }
            let readyMs = ms(uptime() - released)
            guard case .result(_, let text, let stats)? = events.last else { return XCTFail("\(mode): \(events)") }
            outputs[mode.rawValue] = text
            if env["SUNDAY_VOICE_LIVE_SHOW_TEXT"] == "1" { print("LIVE_TEXT \(mode.rawValue): \(text)") } // fixture text only
            print("LIVE \(mode.rawValue) socket_connect_ms=\(connectMs) release_to_ready_ms=\(readyMs) stt_final_ms=\(stats.releaseToSTTFinalMs) fallbacks=\(stats.fallbacks) reused_speculation=\(stats.finalRewriteStartedBeforeSTTFinal)")
        }
        // mixed.wav: "음, 이번 Ads report 확인해줘. Lauren에게 Friday 오후 세 시까지 보내줘."
        let bilingual = outputs["bilingual"] ?? "", english = outputs["english"] ?? ""
        XCTAssertTrue(bilingual.contains("Ads report") && bilingual.contains("Lauren") && bilingual.range(of: "[가-힣]", options: .regularExpression) != nil)
        XCTAssertTrue(english.contains("Lauren") && english.contains("3") && english.range(of: "[가-힣]", options: .regularExpression) == nil)
        socket.close()
    }
}
