import Foundation

enum RewriteTier: String, Sendable { case primary, fallback }

/// What the server hands back for opening the OpenAI Realtime transcription socket.
struct STTSessionGrant: Decodable, Sendable {
    struct Session: Decodable, Sendable {
        var delay: String
        var prompt: String
        var keywords: [String]
        var languages: [String]
    }
    struct Replacement: Decodable, Sendable { var from: String; var to: String }
    var client_secret: String
    var expires_at: Double
    var url: URL
    var model: String
    var session: Session
    /// Personal vocabulary: safe mis-hearing → canonical spellings, longest first.
    var replacements: [Replacement]?
    var transport: String?
}

/// Rewrites a transcript through the server proxy. Separated so the turn pipeline can be tested offline.
protocol Rewriter: AnyObject, Sendable {
    /// `context`: the user's recent dictations (oldest first), retained in consented encrypted history.
    func rewrite(_ text: String, mode: DictationMode, tier: RewriteTier, app: String?, context: [String]) async throws -> String
    /// `screenTerms`: ephemeral proper-noun/Latin tokens from the active window, never logged or stored.
    func rewrite(_ text: String, mode: DictationMode, tier: RewriteTier, app: String?, context: [String], screenTerms: [String]) async throws -> String
}

extension Rewriter {
    func rewrite(_ text: String, mode: DictationMode, tier: RewriteTier, app: String?, context: [String], screenTerms: [String]) async throws -> String {
        try await rewrite(text, mode: mode, tier: tier, app: app, context: context)
    }
    func rewrite(_ text: String, mode: DictationMode, tier: RewriteTier, app: String?) async throws -> String {
        try await rewrite(text, mode: mode, tier: tier, app: app, context: [])
    }
}

/// `X-Sunday-Voice-Version: 0.2.14 (16)` on every API request (admin dashboard shows each person's version).
public enum AppVersion {
    public static let headerName = "X-Sunday-Voice-Version"
    public static var header: String {
        let info = Bundle.main.infoDictionary ?? [:]
        return "\(info["CFBundleShortVersionString"] as? String ?? "0") (\(info["CFBundleVersion"] as? String ?? "0"))"
    }
}

/// Talks to the Sunday Voice API with the signed-in user's access token. No API keys live here.
final class ServerClient: Rewriter, @unchecked Sendable {
    let baseURL: URL
    let tokens: AccessTokenProvider
    let session: URLSession

    init(baseURL: URL, tokens: AccessTokenProvider, session: URLSession? = nil) {
        self.baseURL = baseURL; self.tokens = tokens
        let config = URLSessionConfiguration.ephemeral
        config.httpMaximumConnectionsPerHost = 4
        config.timeoutIntervalForRequest = 20
        config.urlCache = nil
        self.session = session ?? URLSession(configuration: config)
    }

    private func request(_ path: String, method: String = "POST", body: [String: Any]? = nil) async throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        if let id = DiagnosticContext.turn?.id { request.setValue(id, forHTTPHeaderField: "X-Dictation-ID") }
        if let app = DiagnosticContext.turn?.app { request.setValue(app, forHTTPHeaderField: "X-Dictation-App") }
        if let attempt = DiagnosticContext.rewrite {
            request.setValue(attempt.id, forHTTPHeaderField: "X-Rewrite-Attempt")
            request.setValue(attempt.purpose, forHTTPHeaderField: "X-Rewrite-Purpose")
        }
        request.setValue(AppVersion.header, forHTTPHeaderField: AppVersion.headerName)
        request.setValue("relay-v1,bounded-pcm-v1", forHTTPHeaderField: "X-Sunday-Voice-Transport")
        request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    private static func check(_ response: URLResponse, body: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw FailureCode("network_invalid_response") }
        guard (200..<300).contains(http.statusCode) else {
            let code = body.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                .flatMap { ($0["error"] as? [String: Any])?["code"] as? String }
            switch http.statusCode {
            case 401: throw FailureCode.notSignedIn
            case 402: throw FailureCode(code ?? "subscription_required")
            case 429: throw code == "quota_exceeded" ? FailureCode.quotaExceeded : FailureCode("rate_limited")
            default: throw FailureCode(code ?? "http_\(http.statusCode)")
            }
        }
    }

    private func invalidateToken(in request: URLRequest) async {
        if let header = request.value(forHTTPHeaderField: "Authorization"), header.hasPrefix("Bearer ") {
            await tokens.invalidateAccessToken(String(header.dropFirst(7)))
        }
    }

    /// One retry on 401, including a token the server rejected before its local expiry.
    private func data(_ make: () async throws -> URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            let request = try await make()
            let (data, response) = try await session.data(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 428 { await tokens.consentReviewRequired() }
            do { try Self.check(response, body: data); return data }
            catch let failure as FailureCode where failure == .notSignedIn && attempt == 0 {
                await invalidateToken(in: request)
                attempt += 1
            }
        }
    }

    func mintSTTSession() async throws -> STTSessionGrant {
        let data = try await data { try await request("api/stt/session", body: ["languages": SpeechLanguagePolicy.allowedLanguages]) }
        return try JSONDecoder().decode(STTSessionGrant.self, from: data)
    }

    /// PCM format is fixed by MicEngine; the server measures and reserves its actual duration.
    func transcribePCM(_ pcm: Data, onDelta: @escaping @Sendable (String) -> Void = { _ in }) async throws -> String {
        var attempt = 0
        while true {
            var request = try await request("api/stt/transcribe")
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            request.httpBody = pcm
            request.timeoutInterval = 50
            let (bytes, response) = try await session.bytes(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 428 { await tokens.consentReviewRequired() }
            if (response as? HTTPURLResponse)?.statusCode == 401 && attempt == 0 {
                bytes.task.cancel(); await invalidateToken(in: request); attempt += 1; continue
            }
            return try await withTaskCancellationHandler {
                defer { bytes.task.cancel() }
                // Compatibility with 0.3.8 servers and structured 4xx errors. Never retry paid work.
                guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("text/event-stream") == true else {
                    var data = Data()
                    for try await byte in bytes {
                        guard data.count < 128_000 else { throw FailureCode("stt_incomplete") }
                        data.append(byte)
                    }
                    try Self.check(response, body: data)
                    struct Transcript: Decodable { let text: String }
                    return try JSONDecoder().decode(Transcript.self, from: data).text
                }
                try Self.check(response)
                var characters = 0
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard line.hasPrefix("data:"),
                          let event = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(5).utf8)) as? [String: Any] else { continue }
                    if event["type"] as? String == "error" { throw FailureCode(event["code"] as? String ?? "stt_unavailable") }
                    if event["type"] as? String == "delta", let delta = event["delta"] as? String {
                        characters += delta.count
                        guard characters <= 16000 else { throw FailureCode("stt_incomplete") }
                        onDelta(delta)
                    }
                    if event["type"] as? String == "completed", let text = event["text"] as? String, text.count <= 16000 { return text }
                }
                throw FailureCode("stt_incomplete")
            } onCancel: { bytes.task.cancel() }
        }
    }

    func captureEdit(turnID: String, text: String) async {
        _ = try? await data { try await request("api/history", body: ["id": UUID().uuidString, "turn_id": turnID, "kind": "edit", "text": text]) }
    }

    /// Adds words to the user's vocabulary (My words), e.g. names learned from the user's corrections.
    func addWords(_ words: [String]) async -> Bool {
        guard !words.isEmpty else { return true }
        do {
            _ = try await data { try await request("api/vocab", method: "PATCH", body: ["add": words]) }
            return true
        } catch { return false }
    }

    func reportUsage(audioSeconds: Double, dictations: Int) async {
        _ = try? await data { try await request("api/usage", body: ["audio_seconds": (audioSeconds * 1000).rounded() / 1000, "dictations": dictations]) }
    }

    /// Keeps TLS to the API and the cached access token warm without a billable call.
    func warm() async {
        async let health: Void = { _ = try? await self.session.data(from: self.baseURL.appendingPathComponent("api/health")) }()
        async let token: Void = { _ = try? await self.tokens.accessToken() }()
        _ = await (health, token)
    }

    func rewrite(_ text: String, mode: DictationMode, tier: RewriteTier, app: String?, context: [String]) async throws -> String {
        try await rewrite(text, mode: mode, tier: tier, app: app, context: context, screenTerms: [])
    }

    /// Streams OpenAI-compatible chunks; succeeds only on `finish_reason == "stop"` with text.
    func rewrite(_ text: String, mode: DictationMode, tier: RewriteTier, app: String?, context: [String], screenTerms: [String]) async throws -> String {
        var body: [String: Any] = ["mode": mode.rawValue, "text": text, "tier": tier.rawValue, "final": true]
        if let id = DiagnosticContext.turn?.id { body["turn_id"] = id }
        if let app { body["app"] = app }
        if !context.isEmpty { body["context"] = context }
        if !screenTerms.isEmpty { body["screen_terms"] = screenTerms }
        return try await stream(body, expectMode: nil)
    }

    /// "Tidy clipboard": same streaming proxy, `mode: tidy`. A server without tidy support answers as a
    /// dictation cleanup without the `X-Rewrite-Mode: tidy` header; that is refused, never used.
    func tidy(_ text: String, tier: RewriteTier) async throws -> String {
        try await stream(["mode": "tidy", "output_language": "english", "text": text, "tier": tier.rawValue, "final": true], expectMode: "tidy")
    }

    private func stream(_ body: [String: Any], expectMode: String?) async throws -> String {
        var attempt = 0
        while true {
            let request = try await request("api/rewrite", body: body)
            let (bytes, response) = try await session.bytes(for: request)
            if (response as? HTTPURLResponse)?.statusCode == 428 { await tokens.consentReviewRequired() }
            do { try Self.check(response) }
            catch {
                bytes.task.cancel()
                guard let failure = error as? FailureCode, failure == .notSignedIn, attempt == 0 else { throw error }
                await invalidateToken(in: request)
                attempt += 1
                continue
            }
            if let expectMode, (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "X-Rewrite-Mode") != expectMode {
                bytes.task.cancel(); throw FailureCode.serverOutdated
            }
            return try await withTaskCancellationHandler {
                defer { bytes.task.cancel() }
                var out = ""
                for try await line in bytes.lines {
                    try Task.checkCancellation()
                    guard line.hasPrefix("data: "), line != "data: [DONE]" else { continue }
                    guard let object = try? JSONSerialization.jsonObject(with: Data(line.dropFirst(6).utf8)) as? [String: Any] else { continue }
                    if object["error"] != nil { throw FailureCode.rewriteStreamError }
                    for choice in object["choices"] as? [[String: Any]] ?? [] {
                        let delta = ((choice["delta"] as? [String: Any])?["content"] as? String) ?? ""
                        out += delta
                        if !delta.isEmpty { DiagnosticContext.rewriteProgress?.receivedToken() }
                        if let reason = choice["finish_reason"] as? String {
                            let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard reason == "stop", !trimmed.isEmpty else { throw FailureCode.rewriteIncomplete }
                            return trimmed
                        }
                    }
                }
                throw FailureCode.rewriteIncomplete
            } onCancel: { bytes.task.cancel() }
        }
    }
}
