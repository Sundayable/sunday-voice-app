import Foundation
import LocalMeetingEngine

struct GoogleCalendarAccount: Equatable {
    let id: String
    let email: String
}

struct GoogleCalendarChoice: Decodable, Equatable, Identifiable {
    let id: String
    var summary: String?
    var primary: Bool?
    var accessRole: String?
    var deleted: Bool?
    var readable: Bool { deleted != true && ["owner", "writer", "reader"].contains(accessRole ?? "") }
    var name: String { summary?.isEmpty == false ? summary! : (primary == true ? "Primary calendar" : id) }
}

struct GoogleCalendarEvent: Decodable {
    struct Moment: Decodable { var dateTime: String?; var date: String? }
    struct Attendee: Decodable {
        var email: String?; var displayName: String?; var responseStatus: String?; var isSelf: Bool?
        enum CodingKeys: String, CodingKey { case email, displayName, responseStatus; case isSelf = "self" }
    }
    struct Conference: Decodable {
        struct Entry: Decodable { var entryPointType: String?; var uri: String? }
        var entryPoints: [Entry]?
    }
    let id: String
    var status: String?
    var summary: String?
    var start: Moment?
    var end: Moment?
    var hangoutLink: String?
    var conferenceData: Conference?
    var location: String?
    var description: String?
    var attendees: [Attendee]?

    func meeting(calendarID: String, email: String) -> CalendarMeeting? {
        guard status != "cancelled", start?.date == nil, end?.date == nil,
              let start = Self.date(start?.dateTime), let end = Self.date(end?.dateTime), end > start,
              !(attendees ?? []).contains(where: {
                  ($0.isSelf == true || $0.email?.lowercased() == email.lowercased()) && $0.responseStatus == "declined"
              }) else { return nil }
        let conferenceLinks = (conferenceData?.entryPoints ?? []).filter { $0.entryPointType == "video" }.compactMap(\.uri)
        let text = ([hangoutLink, location, description].compactMap { $0 } + conferenceLinks).joined(separator: "\n")
        guard let video = CalendarMeeting.videoLink(in: text.replacingOccurrences(of: "&amp;", with: "&")) else { return nil }
        return CalendarMeeting(id: "google:\(calendarID):\(id)",
            title: summary?.isEmpty == false ? summary! : "Scheduled meeting",
            attendees: (attendees ?? []).filter { $0.responseStatus != "declined" }
                .compactMap { $0.displayName ?? $0.email }, startsAt: start, endsAt: end, videoURL: video)
    }

    /// Matching also includes in-person events without a video URL.
    func recordingEvent(calendarID: String, email: String) -> RecordingCalendarEvent? {
        guard status != "cancelled", start?.date == nil, end?.date == nil,
              let start = Self.date(start?.dateTime), let end = Self.date(end?.dateTime), end > start,
              !(attendees ?? []).contains(where: {
                  ($0.isSelf == true || $0.email?.lowercased() == email.lowercased()) && $0.responseStatus == "declined"
              }) else { return nil }
        return RecordingCalendarEvent(calendarID: calendarID, eventID: id,
            title: summary?.isEmpty == false ? summary! : "Scheduled meeting",
            attendees: (attendees ?? []).filter { $0.responseStatus != "declined" }.map {
                RecordingAttendee(email: $0.email, displayName: $0.displayName)
            }, startedAt: RecordingMetadata.timestamp(start), endedAt: RecordingMetadata.timestamp(end))
    }

    static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }
}

struct GoogleCalendarPage<Item: Decodable>: Decodable {
    var items: [Item]?
    var nextPageToken: String?
    var nextSyncToken: String?
}

enum GoogleCalendarError: Error, Equatable {
    case notConfigured, consentRequired, unauthorized, apiDisabled, expiredSync, invalidResponse, unavailable, signInTimedOut
}

@MainActor
protocol GoogleCalendarAuthorizing: AnyObject {
    func restore() async throws -> GoogleCalendarAccount?
    func connect(hint: String?) async throws -> GoogleCalendarAccount
    func accessToken(forceRefresh: Bool) async throws -> String
    func disconnect()
}

/// No persistent HTTP cache/cookies; a redirect cannot forward a bearer token to another host.
private final class GoogleCalendarRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class GoogleCalendarAPI {
    typealias Request = (URLRequest) async throws -> (Data, URLResponse)
    private let auth: any GoogleCalendarAuthorizing
    private let request: Request

    init(auth: any GoogleCalendarAuthorizing, request: Request? = nil) {
        self.auth = auth
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 25
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: GoogleCalendarRedirects(), delegateQueue: nil)
        self.request = request ?? { try await session.data(for: $0) }
    }

    func calendars(syncToken: String?) async throws -> GoogleCalendarPage<GoogleCalendarChoice> {
        var query = ["maxResults": "250", "showHidden": "true", "showDeleted": "true",
                     "fields": "items(id,summary,primary,accessRole,deleted),nextPageToken,nextSyncToken"]
        query["syncToken"] = syncToken
        return try await pages(path: "users/me/calendarList", query: query)
    }

    func events(calendarID: String, syncToken: String?, now: Date) async throws -> GoogleCalendarPage<GoogleCalendarEvent> {
        var query = ["maxResults": "250", "singleEvents": "true", "showDeleted": "true",
                     "fields": "items(id,status,summary,start,end,hangoutLink,conferenceData,location,description,attendees(email,displayName,self,responseStatus)),nextPageToken,nextSyncToken"]
        if let syncToken { query["syncToken"] = syncToken }
        else {
            let formatter = ISO8601DateFormatter()
            query["timeMin"] = formatter.string(from: now.addingTimeInterval(-120))
            query["timeMax"] = formatter.string(from: now.addingTimeInterval(7 * 86400))
        }
        // Encode the ID as one path segment (calendar IDs can contain @, # and /).
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let id = calendarID.addingPercentEncoding(withAllowedCharacters: safe) else { throw GoogleCalendarError.invalidResponse }
        return try await pages(path: "calendars/\(id)/events", query: query)
    }

    /// Read-only bounded lookup. No event writes, descriptions, video links or transcript uploads.
    func recordingEvents(calendarID: String, start: Date, end: Date) async throws -> [GoogleCalendarEvent] {
        guard end > start else { return [] }
        let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let id = calendarID.addingPercentEncoding(withAllowedCharacters: safe) else { throw GoogleCalendarError.invalidResponse }
        let query = ["maxResults": "250", "singleEvents": "true", "showDeleted": "false",
                     "timeMin": RecordingMetadata.timestamp(start.addingTimeInterval(-1)),
                     "timeMax": RecordingMetadata.timestamp(end.addingTimeInterval(1)),
                     "fields": "items(id,status,summary,start,end,attendees(email,displayName,self,responseStatus)),nextPageToken"]
        let page: GoogleCalendarPage<GoogleCalendarEvent> = try await pages(path: "calendars/\(id)/events", query: query, requiresSyncToken: false)
        return page.items ?? []
    }

    private func pages<Item: Decodable>(path: String, query: [String: String], requiresSyncToken: Bool = true) async throws -> GoogleCalendarPage<Item> {
        var query = query, items: [Item] = [], seen = Set<String>()
        for _ in 0..<100 {
            try Task.checkCancellation()
            let page: GoogleCalendarPage<Item> = try await get(path: path, query: query)
            items.append(contentsOf: page.items ?? [])
            guard let next = page.nextPageToken else {
                guard !requiresSyncToken || page.nextSyncToken != nil else { throw GoogleCalendarError.invalidResponse }
                return GoogleCalendarPage(items: items, nextSyncToken: page.nextSyncToken)
            }
            guard seen.insert(next).inserted else { throw GoogleCalendarError.invalidResponse }
            query["pageToken"] = next
        }
        throw GoogleCalendarError.invalidResponse
    }

    private func get<Item: Decodable>(path: String, query: [String: String]) async throws -> GoogleCalendarPage<Item> {
        var url = URLComponents(string: "https://www.googleapis.com/calendar/v3/\(path)")!
        url.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        for attempt in 0...1 {
            let token = try await auth.accessToken(forceRefresh: attempt == 1)
            try Task.checkCancellation()
            var req = URLRequest(url: url.url!)
            req.httpMethod = "GET"
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, response) = try await request(req)
            try Task.checkCancellation()
            guard let response = response as? HTTPURLResponse else { throw GoogleCalendarError.invalidResponse }
            switch response.statusCode {
            case 200: return try JSONDecoder().decode(GoogleCalendarPage<Item>.self, from: data)
            case 401 where attempt == 0: continue
            case 401: throw GoogleCalendarError.unauthorized
            case 410: throw GoogleCalendarError.expiredSync
            case 403:
                let raw = String(data: data, encoding: .utf8) ?? ""
                if raw.contains("accessNotConfigured") || raw.contains("SERVICE_DISABLED") { throw GoogleCalendarError.apiDisabled }
                if raw.contains("rateLimitExceeded") || raw.contains("userRateLimitExceeded") { throw GoogleCalendarError.unavailable }
                throw GoogleCalendarError.consentRequired
            default: throw GoogleCalendarError.unavailable
            }
        }
        throw GoogleCalendarError.unauthorized
    }
}
