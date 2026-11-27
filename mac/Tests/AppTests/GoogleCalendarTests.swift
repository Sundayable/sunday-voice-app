import Foundation
import LocalMeetingEngine
import XCTest
@testable import Sunday_Voice

@MainActor
final class FakeGoogleCalendarAuth: GoogleCalendarAuthorizing {
    var user: GoogleCalendarAccount? = GoogleCalendarAccount(id: "one", email: "me@example.com")
    var restores = 0
    var forced: [Bool] = []
    var error: Error?
    var connectAction: (() async throws -> GoogleCalendarAccount)?
    func restore() async throws -> GoogleCalendarAccount? { restores += 1; if let error { throw error }; return user }
    func connect(hint: String?) async throws -> GoogleCalendarAccount {
        if let connectAction { return try await connectAction() }
        if let error { throw error }; return user!
    }
    func accessToken(forceRefresh: Bool) async throws -> String {
        forced.append(forceRefresh)
        if let error { throw error }
        return forceRefresh ? "new-test-token" : "test-token"
    }
    func disconnect() { user = nil }
}

private let calendarNow = Date(timeIntervalSince1970: 1_800_000_000)
private func calendarQuery(_ request: URLRequest) -> [String: String] {
    Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? [])
        .map { ($0.name, $0.value ?? "") })
}
private func calendarReply(_ request: URLRequest, _ object: [String: Any], status: Int = 200) throws -> (Data, URLResponse) {
    (try JSONSerialization.data(withJSONObject: object), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
}
private func calendarEvent(_ id: String = "meeting", start: Date = calendarNow.addingTimeInterval(120)) -> [String: Any] {
    let format = ISO8601DateFormatter()
    return ["id": id, "summary": "Synthetic meeting", "status": "confirmed",
            "start": ["dateTime": format.string(from: start)], "end": ["dateTime": format.string(from: start.addingTimeInterval(3600))],
            "hangoutLink": "https://meet.google.com/abc-defg-hij",
            "attendees": [["email": "me@example.com", "self": true, "responseStatus": "accepted"],
                          ["displayName": "Synthetic guest", "responseStatus": "tentative"]]]
}
private let calendarChoices: [[String: Any]] = [
    ["id": "primary@example.com", "summary": "Primary", "primary": true, "accessRole": "owner"],
    ["id": "shared@example.com", "summary": "Shared", "accessRole": "reader"],
    ["id": "busy@example.com", "summary": "Busy only", "accessRole": "freeBusyReader"]
]

final class GoogleCalendarParsingTests: XCTestCase {
    private func decode(_ object: [String: Any]) throws -> CalendarMeeting? {
        try JSONDecoder().decode(GoogleCalendarEvent.self, from: JSONSerialization.data(withJSONObject: object))
            .meeting(calendarID: "calendar", email: "ME@example.com")
    }

    func testTimedEventPrefillsTitleAttendeesAndOffsetTime() throws {
        var event = calendarEvent()
        event["start"] = ["dateTime": "2026-10-14T12:55:00.123-07:00"]
        event["end"] = ["dateTime": "2026-10-14T13:55:00-07:00"]
        let meeting = try XCTUnwrap(decode(event))
        XCTAssertEqual(meeting.title, "Synthetic meeting")
        XCTAssertEqual(meeting.attendees.count, 2)
        XCTAssertEqual(meeting.startsAt, GoogleCalendarEvent.date("2026-10-14T19:55:00.123Z"))
    }

    func testCancelledAllDayDeclinedAndMissingLinkAreExcluded() throws {
        var cancelled = calendarEvent(); cancelled["status"] = "cancelled"
        var allDay = calendarEvent(); allDay["start"] = ["date": "2026-10-14"]
        var declined = calendarEvent(); declined["attendees"] = [["email": "me@example.com", "responseStatus": "declined"]]
        var missing = calendarEvent(); missing.removeValue(forKey: "hangoutLink")
        for event in [cancelled, allDay, declined, missing] { XCTAssertNil(try decode(event)) }
    }

    func testConferenceLocationDescriptionAndDomainSpoof() throws {
        var event = calendarEvent(); event.removeValue(forKey: "hangoutLink")
        event["conferenceData"] = ["entryPoints": [["entryPointType": "video", "uri": "https://meet.google.com/abc-defg-hij"]]]
        XCTAssertNotNil(try decode(event))
        event.removeValue(forKey: "conferenceData")
        event["location"] = "https://us02web.zoom.us/j/123456789?pwd=test"
        XCTAssertNotNil(try decode(event))
        event.removeValue(forKey: "location")
        event["description"] = "Join <a href=\"https://teams.microsoft.com/l/meetup-join/123?x=1&amp;y=2\">meeting</a>"
        XCTAssertNotNil(try decode(event))
        event["description"] = "https://meet.google.com.attacker.example/abc-defg-hij"
        XCTAssertNil(try decode(event))
    }

    func testCrossSourceDuplicateStaysDismissedAndRecurringOccurrenceReturns() throws {
        let google = try XCTUnwrap(decode(calendarEvent()))
        let local = CalendarMeeting(id: "eventkit", title: google.title, attendees: [], startsAt: google.startsAt,
                                    endsAt: google.endsAt, videoURL: google.videoURL)
        var policy = CalendarMeetingPolicy()
        XCTAssertNotNil(policy.next([google], now: calendarNow))
        policy.dismiss(google)
        XCTAssertNil(policy.next([local], now: calendarNow))
        let tomorrow = try XCTUnwrap(decode(calendarEvent(start: google.startsAt.addingTimeInterval(86400))))
        XCTAssertNotNil(policy.next([tomorrow], now: calendarNow.addingTimeInterval(86400)))
    }
}

@MainActor
final class GoogleCalendarAPITests: XCTestCase {
    func testPaginationAndIncrementalQueryDoNotMixTimeBounds() async throws {
        let auth = FakeGoogleCalendarAuth()
        var requests: [URLRequest] = []
        let api = GoogleCalendarAPI(auth: auth) { request in
            requests.append(request)
            if requests.count == 1 { return try calendarReply(request, ["items": [calendarEvent()], "nextPageToken": "page2"]) }
            return try calendarReply(request, ["items": [], "nextSyncToken": "sync2"])
        }
        let result = try await api.events(calendarID: "test/#@example.com", syncToken: "sync1", now: calendarNow)
        XCTAssertEqual(result.items?.count, 1)
        XCTAssertEqual(result.nextSyncToken, "sync2")
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.host, "www.googleapis.com")
            XCTAssertNil(request.httpBody)
            XCTAssertEqual(calendarQuery(request)["syncToken"], "sync1")
            XCTAssertNil(calendarQuery(request)["timeMin"])
            XCTAssertNil(calendarQuery(request)["timeMax"])
            XCTAssertNil(calendarQuery(request)["orderBy"])
            XCTAssertTrue(request.url!.absoluteString.contains("test%2F%23%40example.com"))
        }
        XCTAssertEqual(calendarQuery(requests[1])["pageToken"], "page2")
    }

    func testUnauthorizedForcesRefreshExactlyOnce() async throws {
        let auth = FakeGoogleCalendarAuth()
        var calls = 0
        let api = GoogleCalendarAPI(auth: auth) { request in
            calls += 1
            return try calendarReply(request, calls == 1 ? [:] : ["nextSyncToken": "new"], status: calls == 1 ? 401 : 200)
        }
        _ = try await api.calendars(syncToken: nil)
        XCTAssertEqual(auth.forced, [false, true])
        XCTAssertEqual(calls, 2)
    }

    func testRepeatedUnauthorizedStopsWithoutAnInfiniteLoop() async throws {
        let auth = FakeGoogleCalendarAuth()
        let api = GoogleCalendarAPI(auth: auth) { try calendarReply($0, [:], status: 401) }
        do { _ = try await api.calendars(syncToken: nil); XCTFail("Expected authorization failure") }
        catch { XCTAssertEqual(error as? GoogleCalendarError, .unauthorized) }
        XCTAssertEqual(auth.forced, [false, true])
    }

    func testExpiredSyncAndDisabledAPIAreDistinctFromOffline() async throws {
        for (status, body, expected) in [(410, "", GoogleCalendarError.expiredSync), (403, "SERVICE_DISABLED", .apiDisabled)] {
            let api = GoogleCalendarAPI(auth: FakeGoogleCalendarAuth()) { try calendarReply($0, ["error": body], status: status) }
            do { _ = try await api.calendars(syncToken: "old"); XCTFail("Expected error") }
            catch { XCTAssertEqual(error as? GoogleCalendarError, expected) }
        }
    }

    func testRepeatedPaginationTokenDoesNotLoopOrCommitPartialData() async throws {
        var calls = 0
        let api = GoogleCalendarAPI(auth: FakeGoogleCalendarAuth()) { request in
            calls += 1
            return try calendarReply(request, ["items": calendarChoices, "nextPageToken": "same"])
        }
        do { _ = try await api.calendars(syncToken: nil); XCTFail("Expected invalid pagination") }
        catch { XCTAssertEqual(error as? GoogleCalendarError, .invalidResponse) }
        XCTAssertEqual(calls, 2)
    }
}

@MainActor
final class GoogleMeetingCalendarTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!
    override func setUp() {
        super.setUp()
        suite = "SundayVoice.GoogleCalendarTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() { defaults.removePersistentDomain(forName: suite); super.tearDown() }

    private func provider(auth: FakeGoogleCalendarAuth? = nil,
                          request: GoogleCalendarAPI.Request? = nil) -> GoogleMeetingCalendar {
        GoogleMeetingCalendar(auth: auth ?? FakeGoogleCalendarAuth(), defaults: defaults, request: request ?? { request in
            try calendarReply(request, ["items": request.url!.path.hasSuffix("calendarList") ? calendarChoices : [calendarEvent()],
                                        "nextSyncToken": "next"])
        })
    }

    func testPrimaryOnlyByDefaultAndMultipleCalendarSelectionPersists() async {
        let calendar = provider()
        await calendar.refresh(now: calendarNow)
        XCTAssertEqual(calendar.calendars.count, 2) // excludes free/busy-only calendars
        XCTAssertEqual(calendar.selectedIDs, ["primary@example.com"])
        calendar.select("shared@example.com", enabled: true)
        let restored = provider()
        await restored.refresh(now: calendarNow)
        XCTAssertEqual(restored.selectedIDs, ["primary@example.com", "shared@example.com"])
    }

    func testAnExplicitEmptySelectionIsNotResetToPrimary() async {
        let calendar = provider()
        await calendar.refresh(now: calendarNow)
        calendar.select("primary@example.com", enabled: false)
        let restored = provider()
        var events: [CalendarMeeting] = []
        restored.onEvents = { events = $0 }
        await restored.refresh(now: calendarNow)
        XCTAssertTrue(restored.selectedIDs.isEmpty)
        XCTAssertTrue(events.isEmpty)
    }

    func testSelectionsAreIsolatedBetweenAccounts() async {
        let calendar = provider()
        await calendar.refresh(now: calendarNow)
        calendar.select("shared@example.com", enabled: true)
        let other = FakeGoogleCalendarAuth()
        other.user = GoogleCalendarAccount(id: "two", email: "second@example.com")
        let restored = provider(auth: other)
        await restored.refresh(now: calendarNow)
        XCTAssertEqual(restored.selectedIDs, ["primary@example.com"])
    }

    func testIncrementalCancellationRemovesCachedSuggestion() async {
        var eventCalls = 0, requests: [URLRequest] = [], events: [CalendarMeeting] = []
        let calendar = provider { request in
            requests.append(request)
            if request.url!.path.hasSuffix("calendarList") { return try calendarReply(request, ["items": calendarChoices, "nextSyncToken": "list"]) }
            eventCalls += 1
            return try calendarReply(request, ["items": eventCalls == 1 ? [calendarEvent()] : [["id": "meeting", "status": "cancelled"]], "nextSyncToken": "events"])
        }
        calendar.onEvents = { events = $0 }
        await calendar.refresh(now: calendarNow)
        XCTAssertEqual(events.count, 1)
        await calendar.refresh(now: calendarNow.addingTimeInterval(300))
        XCTAssertTrue(events.isEmpty)
        XCTAssertEqual(calendarQuery(requests[3])["syncToken"], "events")
    }

    func testExpiredSyncResetsOnlyAffectedResourceAndRebasesHorizon() async {
        var requests: [URLRequest] = []
        let calendar = provider { request in
            requests.append(request)
            if calendarQuery(request)["syncToken"] != nil { return try calendarReply(request, [:], status: 410) }
            return try calendarReply(request, ["items": request.url!.path.hasSuffix("calendarList") ? calendarChoices : [calendarEvent()], "nextSyncToken": "token"])
        }
        await calendar.refresh(now: calendarNow)
        await calendar.refresh(now: calendarNow.addingTimeInterval(300))
        XCTAssertEqual(requests.count, 6)
        XCTAssertNil(calendarQuery(requests[5])["syncToken"])
        XCTAssertNotNil(calendarQuery(requests[5])["timeMin"])
        XCTAssertNotNil(calendar.lastSynced)
    }

    func testRollingWindowRefreshFindsUnchangedEventsEnteringHorizon() async {
        var eventQueries: [[String: String]] = []
        let calendar = provider { request in
            if !request.url!.path.hasSuffix("calendarList") { eventQueries.append(calendarQuery(request)) }
            return try calendarReply(request, ["items": request.url!.path.hasSuffix("calendarList") ? calendarChoices : [], "nextSyncToken": "token"])
        }
        await calendar.refresh(now: calendarNow)
        await calendar.refresh(now: calendarNow.addingTimeInterval(6 * 3600))
        XCTAssertEqual(eventQueries.count, 2)
        XCTAssertNil(eventQueries[1]["syncToken"])
        XCTAssertNotEqual(eventQueries[0]["timeMax"], eventQueries[1]["timeMax"])
    }

    func testOfflineKeepsRecentMeetingsAndExpiredCacheIsNotSuggested() async {
        var offline = false, events: [CalendarMeeting] = []
        let calendar = provider { request in
            if offline { throw URLError(.notConnectedToInternet) }
            return try calendarReply(request, ["items": request.url!.path.hasSuffix("calendarList") ? calendarChoices : [calendarEvent()], "nextSyncToken": "token"])
        }
        calendar.onEvents = { events = $0 }
        await calendar.refresh(now: calendarNow)
        offline = true
        await calendar.refresh(now: calendarNow.addingTimeInterval(300))
        XCTAssertEqual(events.count, 1)
        XCTAssertFalse(calendar.needsConsent)
        XCTAssertTrue(calendar.status.contains("retry automatically"))
        await calendar.refresh(now: calendarNow.addingTimeInterval(86401))
        XCTAssertTrue(events.isEmpty)
    }

    func testRevokedAccessRemovesSuggestionsAndAsksForReconnect() async {
        let auth = FakeGoogleCalendarAuth(), calendar = provider()
        await calendar.refresh(now: calendarNow)
        let revoked = provider(auth: auth)
        auth.error = NSError(domain: "org.openid.appauth.oauth_token", code: -3)
        await revoked.refresh(now: calendarNow)
        XCTAssertTrue(revoked.needsConsent)
        XCTAssertTrue(revoked.status.hasPrefix("Reconnect"))
    }

    func testDisconnectFencesLateResponsesAndClearsInMemoryDetails() async {
        var gate: CheckedContinuation<Void, Never>?
        let calendar = provider { request in
            await withCheckedContinuation { gate = $0 }
            return try calendarReply(request, ["items": calendarChoices, "nextSyncToken": "late"])
        }
        let task = Task { await calendar.refresh(now: calendarNow) }
        while gate == nil { await Task.yield() }
        calendar.disconnect()
        gate?.resume()
        await task.value
        XCTAssertNil(calendar.account)
        XCTAssertTrue(calendar.calendars.isEmpty)
        XCTAssertNil(calendar.lastSynced)
    }

    func testDisablingDuringConsentDoesNotLeaveConnectButtonStuck() async {
        let auth = FakeGoogleCalendarAuth()
        var gate: CheckedContinuation<GoogleCalendarAccount, Never>?
        auth.connectAction = { await withCheckedContinuation { gate = $0 } }
        let calendar = provider(auth: auth)
        let task = Task { await calendar.connect() }
        while gate == nil { await Task.yield() }
        XCTAssertTrue(calendar.connecting)
        calendar.enabled = false
        gate?.resume(returning: auth.user!)
        await task.value
        XCTAssertFalse(calendar.connecting)
        XCTAssertFalse(calendar.enabled)
        XCTAssertNil(calendar.account)
        XCTAssertNil(calendar.lastSynced)
    }

    func testSelectionPreferencesContainNoEventTitleOrAttendees() async {
        let calendar = provider()
        await calendar.refresh(now: calendarNow)
        let saved = defaults.persistentDomain(forName: suite) ?? [:]
        XCTAssertEqual(Set(saved.keys), ["googleMeetingCalendars.one"])
        XCTAssertEqual(saved.values.first as? [String], ["primary@example.com"])
    }

    func testTwoMinuteReminderUsesCacheWithoutWaitingForFiveMinutePoll() async {
        var requests = 0, offered: CalendarMeeting?, clock = calendarNow
        var policy = CalendarMeetingPolicy()
        let calendar = provider { request in
            requests += 1
            return try calendarReply(request, ["items": request.url!.path.hasSuffix("calendarList") ? calendarChoices :
                [calendarEvent(start: calendarNow.addingTimeInterval(240))], "nextSyncToken": "token"])
        }
        calendar.onEvents = { offered = policy.next($0, now: clock) }
        await calendar.refresh(now: calendarNow)
        XCTAssertNil(offered)
        calendar.start()
        clock = calendarNow.addingTimeInterval(120)
        calendar.tick(now: clock)
        XCTAssertNotNil(offered)
        XCTAssertEqual(requests, 2)
        calendar.stop()
    }
}


@MainActor
final class RecordingCalendarAPITests: XCTestCase {
    func testRecordingLookupPaginatesWithoutSyncTokenAndNeverWrites() async throws {
        var requests: [URLRequest] = []
        let api = GoogleCalendarAPI(auth: FakeGoogleCalendarAuth()) { request in
            requests.append(request)
            return try calendarReply(request, requests.count == 1 ? ["items": [calendarEvent()], "nextPageToken": "second"] : ["items": []])
        }
        let events = try await api.recordingEvents(calendarID: "test/#@example.com", start: calendarNow, end: calendarNow.addingTimeInterval(300))
        XCTAssertEqual(events.count, 1)
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(calendarQuery(request)["syncToken"])
            XCTAssertEqual(calendarQuery(request)["singleEvents"], "true")
            XCTAssertTrue(request.url!.absoluteString.contains("test%2F%23%40example.com"))
            XCTAssertFalse(calendarQuery(request)["fields"]!.contains("description"))
        }
        XCTAssertEqual(calendarQuery(requests[1])["pageToken"], "second")
    }

    func testInPersonEventMatchesButCancelledDeclinedAllDayDoNot() throws {
        var object = calendarEvent(); object.removeValue(forKey: "hangoutLink")
        func decode(_ object: [String: Any]) throws -> RecordingCalendarEvent? {
            try JSONDecoder().decode(GoogleCalendarEvent.self, from: JSONSerialization.data(withJSONObject: object))
                .recordingEvent(calendarID: "synthetic", email: "me@example.com")
        }
        XCTAssertEqual(try decode(object)?.title, "Synthetic meeting")
        var cancelled = object; cancelled["status"] = "cancelled"
        var allDay = object; allDay["start"] = ["date": "2026-10-23"]
        var declined = object; declined["attendees"] = [["self": true, "responseStatus": "declined"]]
        for excluded in [cancelled, allDay, declined] { XCTAssertNil(try decode(excluded)) }
    }

    func testDisabledCalendarCannotEnrichRecording() async throws {
        let suite = "SundayVoice.RecordingCalendarTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let calendar = GoogleMeetingCalendar(auth: FakeGoogleCalendarAuth(), defaults: defaults) { _ in
            XCTFail("Disabled matching must not make a network request")
            throw GoogleCalendarError.unavailable
        }
        calendar.enabled = false
        do { _ = try await calendar.matchRecording(RecordingMetadata(recordingID: "synthetic")); XCTFail("Expected disabled") }
        catch { XCTAssertEqual(error as? GoogleCalendarError, .consentRequired) }
    }
}
