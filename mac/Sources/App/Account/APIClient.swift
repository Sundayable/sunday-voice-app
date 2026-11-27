import Foundation
import DictationEngine
import LocalMeetingEngine

struct VoiceCard: Codable, Equatable { var text: String; var generated_at: String?; var edited_at: String? }
struct Connection: Codable, Equatable { var status: String; var account_label: String? }
struct VoiceSummary: Codable, Equatable {
    var cards: [String: VoiceCard?]
    var connections: [String: Connection]
    var terms: [String]?
}
struct VoiceRefresh: Codable, Equatable {
    struct Stats: Codable, Equatable { var gmail_messages: Int; var slack_messages: Int; var en_samples: Int; var ko_samples: Int; var vocab_terms: Int?; var sources_failed: Int? = nil }
    var cards: [String: VoiceCard?]
    var stats: Stats
    var failed: [String]? = nil
}

enum APIError: Error, Equatable { case notConfigured, http(Int, String) }

struct VocabEntry: Codable, Equatable, Identifiable {
    var term: String; var type: String; var count: Int; var sources: [String]; var enabled: Bool; var manual: Bool; var hint: Bool; var variants: [String]
    var id: String { term.lowercased() }
}
struct VocabList: Codable, Equatable {
    struct Stats: Codable, Equatable { var total: Int; var hints: Int; var replacements: Int }
    var terms: [VocabEntry]; var stats: Stats
}

/// JSON endpoints the app shell uses (the engine has its own client for the hot path).
@MainActor
final class APIClient: WatchRecordingCalendarAPI {
    let auth: AuthService
    let session: URLSession
    init(auth: AuthService, session: URLSession = URLSession(configuration: .ephemeral)) { self.auth = auth; self.session = session }

    private func call<T: Decodable>(_ method: String, _ path: String, body: [String: Any]? = nil, query: [String: String] = [:], as type: T.Type, retried: Bool = false) async throws -> T {
        guard let base = auth.baseURL else { throw APIError.notConfigured }
        var components = URLComponents(url: base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.timeoutInterval = (path == "api/voice/refresh" || path == "api/vocab/import") ? 150 : 20
        let owner = auth.user?.id
        if path.hasPrefix("api/watch/") && !auth.isSignedIn { throw AuthError.signedOut }
        let accessToken = try await auth.accessToken()
        if path.hasPrefix("api/watch/") && (auth.user?.id != owner || !auth.isSignedIn) { throw AuthError.signedOut }
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(AppVersion.header, forHTTPHeaderField: AppVersion.headerName)
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request, delegate: path.hasPrefix("api/watch/") ? RecordingAPIRedirects() : nil)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 && !retried {
            await auth.invalidateAccessToken(accessToken)
            return try await call(method, path, body: body, query: query, as: type, retried: true)
        }
        if status == 428 { await auth.consentReviewRequired() }
        guard (200..<300).contains(status) else {
            let code = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["code"] as? String
            if !path.hasPrefix("api/watch/") && !["api/events", "api/history", "api/reports", "api/consent"].contains(path) { await auth.reportClientError("api_http_\(status)") }
            throw APIError.http(status, code ?? "error")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func watchRecordings(before: String?) async throws -> WatchRecordingPage {
        try await call("GET", "api/watch/recordings", query: before.map { ["before": $0] } ?? [:], as: WatchRecordingPage.self)
    }
    func watchCalendarMatch(id: String) async throws -> RecordingCalendarMatch? {
        guard UUID(uuidString: id) != nil else { throw GoogleCalendarError.invalidResponse }
        return try await call("GET", "api/watch/recordings/\(id)/calendar-match", as: WatchCalendarReply.self).calendar_match
    }
    func saveWatchCalendarMatch(id: String, match: RecordingCalendarMatch) async throws -> RecordingCalendarMatch? {
        guard UUID(uuidString: id) != nil else { throw GoogleCalendarError.invalidResponse }
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(match))
        return try await call("POST", "api/watch/recordings/\(id)/calendar-match", body: ["calendar_match": object], as: WatchCalendarReply.self).calendar_match
    }

    func sendDiagnostic(_ path: String, body: [String: Any]) async throws {
        _ = try await call("POST", path, body: body, as: OK.self)
    }

    struct Link: Decodable { var redirect_url: URL; var connection_id: String }
    struct CardResponse: Decodable { var card: VoiceCard }
    struct Words: Decodable { var words: [String] }
    struct OK: Decodable { var ok: Bool }

    func voice() async throws -> VoiceSummary { try await call("GET", "api/voice", as: VoiceSummary.self) }
    func link(_ toolkit: String) async throws -> URL { try await call("POST", "api/connections/\(toolkit)/link", as: Link.self).redirect_url }
    func disconnect(_ toolkit: String) async throws { _ = try await call("DELETE", "api/connections/\(toolkit)", as: OK.self) }
    func refreshVoice() async throws -> VoiceRefresh { try await call("POST", "api/voice/refresh", as: VoiceRefresh.self) }
    func saveCard(_ lang: String, _ text: String) async throws -> VoiceCard { try await call("PUT", "api/voice/\(lang)", body: ["text": text], as: CardResponse.self).card }
    func vocab() async throws -> VocabList { try await call("GET", "api/vocab", as: VocabList.self) }
    func editVocab(add: [String] = [], remove: [String] = [], enable: [String] = [], disable: [String] = []) async throws {
        _ = try await call("PATCH", "api/vocab", body: ["add": add, "remove": remove, "enable": enable, "disable": disable], as: OK.self)
    }
    struct ImportStats: Decodable { struct S: Decodable { var messages: Int; var candidates: Int; var terms: Int }; var stats: S }
    /// Uploads TERMS and COUNTS extracted on this Mac — never message text.
    func importLocalVocabulary(_ r: LocalHistoryImporter.Result, keep: Set<String>) async throws -> ImportStats {
        let enc = { (c: LocalHistoryImporter.Candidate) -> [String: Any] in
            var o: [String: Any] = ["term": c.term, "count": c.count, "score": c.score, "forms": c.forms]
            if let cap = c.cap_ratio { o["cap_ratio"] = cap }
            return o
        }
        let body: [String: Any] = [
            "source": "ai_history", "messages": r.messages,
            "candidates": ["latin": r.latin.filter { keep.contains($0.term) }.map(enc), "hangul": r.hangul.filter { keep.contains($0.term) }.map(enc)],
            "latin_counts": r.latinCounts, "hangul_counts": r.hangulCounts,
        ]
        return try await call("POST", "api/vocab/import", body: body, as: ImportStats.self)
    }

    func dictionary() async throws -> [String] { try await call("GET", "api/dictionary", as: Words.self).words }
    func saveDictionary(_ words: [String]) async throws -> [String] { try await call("PUT", "api/dictionary", body: ["words": words], as: Words.self).words }
}
