import Foundation
import LocalMeetingEngine

struct WatchRecordingMetadata: Decodable {
    var id: String
    var source_device: String
    var recorded_at: String?
    var ended_at: String?
    var time_zone: String?
    var utc_offset_minutes: Int?
    var ended_utc_offset_minutes: Int?
    var timestamp_provenance: [String: String?]?
    var duration_seconds: Double?
    var status: String
    var created_at: String?
    var chunk_count: Int?

    var metadata: RecordingMetadata {
        var value = RecordingMetadata(recordingID: id, sourceDevice: source_device, timeZone: time_zone)
        value.recordedAt = recorded_at; value.endedAt = ended_at
        value.utcOffsetMinutes = utc_offset_minutes; value.endedUTCOffsetMinutes = ended_utc_offset_minutes
        value.durationSeconds = duration_seconds
        value.timestampProvenance = timestamp_provenance ?? [:]
        return value
    }
    var completeCapture: Bool {
        chunk_count != nil && chunk_count! > 0 && status != "uploading" &&
            duration_seconds.map { $0.isFinite && $0 > 0 } == true
    }
    var fingerprint: String { "\(id)|\(recorded_at ?? "")|\(ended_at ?? "")|\(duration_seconds ?? 0)|\(chunk_count ?? 0)" }
}

struct WatchRecordingPage: Decodable {
    var recordings: [WatchRecordingMetadata]
    var next_before: String?
}
struct WatchCalendarReply: Decodable { var calendar_match: RecordingCalendarMatch? }

@MainActor
protocol WatchRecordingCalendarAPI: AnyObject {
    func watchRecordings(before: String?) async throws -> WatchRecordingPage
    func watchCalendarMatch(id: String) async throws -> RecordingCalendarMatch?
    func saveWatchCalendarMatch(id: String, match: RecordingCalendarMatch) async throws -> RecordingCalendarMatch?
}

/// No redirects for owner metadata or bearer tokens, including production -> preview.
final class RecordingAPIRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Runs with the app's existing session only. A missing same-origin endpoint is unavailable,
/// never a reason to forward a bearer to a preview or extract/rotate a token with an external CLI.
@MainActor
final class WatchRecordingCalendarSync {
    private let api: any WatchRecordingCalendarAPI
    private let identity: () -> String?
    private let match: (RecordingMetadata) async throws -> RecordingCalendarMatch
    private var task: Task<Void, Never>?
    private var completed = Set<String>()
    private var currentIdentity: String?
    private(set) var status = "Waiting for the connected account and calendar."

    convenience init(api: APIClient, calendar: GoogleMeetingCalendar) {
        self.init(api: api, identity: { [weak api, weak calendar] in
            guard let api, let calendar, api.auth.isSignedIn, let user = api.auth.user, user.guest != true,
                  calendar.enabled, !calendar.needsConsent,
                  calendar.account?.email.lowercased() == user.email.lowercased(),
                  let origin = api.auth.baseURL, origin.scheme == "https" else { return nil }
            return "\(origin.absoluteString)|\(user.id)|\(calendar.selectedIDs.sorted().joined(separator: ","))"
        }, match: { [weak calendar] recording in
            guard let calendar else { throw CancellationError() }
            return try await calendar.matchRecording(recording)
        })
    }

    init(api: any WatchRecordingCalendarAPI, identity: @escaping () -> String?,
         match: @escaping (RecordingMetadata) async throws -> RecordingCalendarMatch) {
        self.api = api; self.identity = identity; self.match = match
    }

    func tick() {
        guard task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            defer { self.task = nil }
            await self.sync()
        }
    }

    func sync(now: Date = Date()) async {
        guard let owner = identity() else { return }
        if owner != currentIdentity { currentIdentity = owner; completed = [] }
        var cursor: String?, cursors = Set<String>()
        do {
            for _ in 0..<100 {
                let page = try await api.watchRecordings(before: cursor)
                try check(owner)
                for recording in page.recordings where recording.completeCapture {
                    guard !completed.contains(recording.fingerprint) else { continue }
                    // Recent uploads include delayed offline recordings regardless of their capture date.
                    if let created = RecordingMetadata.date(recording.created_at), now.timeIntervalSince(created) > 7 * 86400 { continue }
                    let existing = try await api.watchCalendarMatch(id: recording.id)
                    try check(owner)
                    if let existing, existing.status != "unmatched" || now.timeIntervalSince(RecordingMetadata.date(existing.matchedAt) ?? .distantPast) < 1800 {
                        if existing.status != "unmatched" { completed.insert(recording.fingerprint) }
                        continue
                    }
                    let candidate = try await match(recording.metadata)
                    try check(owner)
                    do {
                        let saved = try await api.saveWatchCalendarMatch(id: recording.id, match: candidate)
                        try check(owner)
                        guard saved == candidate else { throw GoogleCalendarError.invalidResponse }
                        if saved?.status != "unmatched" { completed.insert(recording.fingerprint) }
                    } catch {
                        try check(owner)
                        // Reconcile the canonical owner record after an uncertain POST. A new
                        // attempt always GETs first, so a successful write is never blindly replayed.
                        if let saved = try? await api.watchCalendarMatch(id: recording.id), saved == candidate {
                            if saved.status != "unmatched" { completed.insert(recording.fingerprint) }
                        } else { throw error }
                    }
                }
                guard let next = page.next_before else { status = "Voice-note calendar matches are up to date."; return }
                guard cursors.insert(next).inserted else { throw GoogleCalendarError.invalidResponse }
                if !page.recordings.isEmpty && page.recordings.allSatisfy({
                    RecordingMetadata.date($0.created_at).map { now.timeIntervalSince($0) > 7 * 86400 } == true
                }) { return }
                cursor = next
            }
            throw GoogleCalendarError.invalidResponse
        } catch APIError.http(404, _), APIError.http(503, _) {
            status = "Voice-note metadata is not available on this app’s configured server."
        } catch {
            status = "Voice-note calendar matching will retry after the next calendar sync."
        }
    }

    private func check(_ expected: String) throws {
        guard identity() == expected, !Task.isCancelled else { throw CancellationError() }
    }
}
