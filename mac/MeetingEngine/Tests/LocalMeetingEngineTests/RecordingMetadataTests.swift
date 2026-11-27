import Foundation
import XCTest
@testable import LocalMeetingEngine

final class RecordingMetadataTests: XCTestCase {
    private func recording(start: String = "2026-10-23T17:00:58.123Z", end: String? = "2026-10-23T17:01:05.123Z") -> RecordingMetadata {
        var value = RecordingMetadata(recordingID: "synthetic", timeZone: "America/Vancouver")
        value.recordedAt = start; value.endedAt = end
        return value
    }
    private func event(_ id: String = "one", start: String = "2026-10-23T10:00:00-07:00", end: String = "2026-10-23T11:00:00-07:00") -> RecordingCalendarEvent {
        RecordingCalendarEvent(calendarID: "synthetic@example.com", eventID: id, title: "Synthetic meeting",
            attendees: [RecordingAttendee(email: "guest@example.com", displayName: "Guest")], startedAt: start, endedAt: end)
    }

    func testOffsetMatchAndExclusiveBoundaries() {
        let value = recording()
        let matched = RecordingCalendarMatcher.match(value, events: [event()])
        XCTAssertEqual(matched.status, "matched")
        XCTAssertEqual(matched.events.first?.overlapSeconds, 7)
        XCTAssertEqual(matched.events.first?.attendees.first?.email, "guest@example.com")
        XCTAssertEqual(RecordingCalendarMatcher.match(value, events: [event(end: value.recordedAt!)]).status, "unmatched")
        XCTAssertEqual(RecordingCalendarMatcher.match(value, events: [event(start: value.endedAt!)]).status, "unmatched")
    }

    func testMultipleOverlapsAreAmbiguousAndDuplicatePagesAreIdempotent() {
        let match = RecordingCalendarMatcher.match(recording(), events: [event(), event(), event("two")])
        XCTAssertEqual(match.status, "ambiguous")
        XCTAssertEqual(match.events.count, 2)
        XCTAssertEqual(match.events.map(\.eventID), ["one", "two"])
    }

    func testWatchMissingEndUsesExplicitEstimateWithoutInventingCaptureEnd() {
        var value = recording(end: nil); value.durationSeconds = 0.793375
        let match = RecordingCalendarMatcher.match(value, events: [event()])
        XCTAssertEqual(match.status, "matched")
        XCTAssertEqual(match.intervalSource, "estimated_end_from_audio_duration")
        XCTAssertNil(value.endedAt)
        value.durationSeconds = .infinity
        XCTAssertEqual(RecordingCalendarMatcher.match(value, events: [event()]).status, "unknown_time")
    }

    func testMidnightAndDSTOffsetTransitionsUseInstants() {
        let value = recording(start: "2026-11-01T01:55:00-07:00", end: "2026-11-01T01:05:00-08:00")
        let match = RecordingCalendarMatcher.match(value, events: [event(start: "2026-11-01T08:00:00Z", end: "2026-11-01T10:00:00Z")])
        XCTAssertEqual(match.events.first?.overlapSeconds, 600)
        let midnight = recording(start: "2026-10-23T23:59:59-07:00", end: "2026-10-24T00:00:05-07:00")
        XCTAssertEqual(RecordingCalendarMatcher.match(midnight, events: [event(start: "2026-10-24T06:59:00Z", end: "2026-10-24T07:01:00Z")]).status, "matched")
    }

    func testAudioSamplesPreserveExactEndsAndDurationDoesNotDoubleCountSourcesOrGaps() {
        var timeline = RecordingAudioTimeline()
        var metadata = RecordingMetadata(recordingID: "synthetic", timeZone: "America/Vancouver")
        let start = RecordingMetadata.date("2025-11-02T08:59:55.125Z")!
        let mic = MeetingChunk(id: UUID(), source: .microphone, startSeconds: 0, durationSeconds: 5,
            url: URL(fileURLWithPath: "/synthetic"), rms: 0, recordedAt: start, endedAt: start.addingTimeInterval(5))
        let system = MeetingChunk(id: UUID(), source: .system, startSeconds: 0, durationSeconds: 5,
            url: mic.url, rms: 0, recordedAt: start, endedAt: start.addingTimeInterval(5))
        let resumed = MeetingChunk(id: UUID(), source: .microphone, startSeconds: 20, durationSeconds: 2,
            url: mic.url, rms: 0, recordedAt: start.addingTimeInterval(20), endedAt: start.addingTimeInterval(23))
        for chunk in [resumed, mic, system, mic] { timeline.observe(chunk, metadata: &metadata) }
        XCTAssertEqual(metadata.recordedAt, "2025-11-02T08:59:55.125Z")
        XCTAssertEqual(metadata.endedAt, "2025-11-02T09:00:18.125Z")
        XCTAssertEqual(metadata.durationSeconds, 7)
        XCTAssertEqual(metadata.elapsedSeconds, 23)
        XCTAssertEqual(metadata.utcOffsetMinutes, -420)
        XCTAssertEqual(metadata.endedUTCOffsetMinutes, -480)
    }

    func testLegacyDocumentStillDecodesAndNullableProvenanceSurvives() throws {
        let object: [String: Any] = ["version": 1, "sessionID": UUID().uuidString, "startedAt": "2026-10-23T17:00:00Z",
            "model": "synthetic", "segments": [], "recoveredChunkCount": 0, "incomplete": false, "notes": []]
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let document = try decoder.decode(MeetingDocument.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(document.recording)
        var value = recording(end: nil); value.timestampProvenance["end"] = .some(nil)
        XCTAssertEqual(try JSONDecoder().decode(RecordingMetadata.self, from: JSONEncoder().encode(value)), value)
    }

    func testStorePersistsSampleTimesWhileRecordingAndCalendarEnrichmentKeepsTranscript() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let context = RecordingMeetingContext(appName: "Synthetic browser", bundleID: "test.browser", windowTitle: "Meet - Synthetic")
        let store = try MeetingSessionStore(root: root.appendingPathComponent("meetings"), workRoot: root.appendingPathComponent("work"), context: context)
        let url = store.captureDirectory.appendingPathComponent("\(UUID().uuidString)-microphone.caf")
        try TestAudio.write(url, seconds: 7)
        let start = RecordingMetadata.date("2026-10-23T17:00:58.123Z")!
        let chunk = MeetingChunk(id: UUID(), source: .microphone, startSeconds: 0, durationSeconds: 7, url: url, rms: 0.1,
            recordedAt: start, endedAt: start.addingTimeInterval(7))
        try JSONEncoder().encode(chunk).write(to: url.appendingPathExtension("json"))
        try await store.observe(chunk)
        let transcript = store.transcriptURL
        let during = try RecordingMetadataStore.read(beside: transcript)
        XCTAssertEqual(during.recordedAt, "2026-10-23T17:00:58.123Z")
        // An enrichment job cannot write into an active session.
        try RecordingMetadataStore.save(match: RecordingCalendarMatch(status: "unmatched"), beside: transcript)
        XCTAssertNil(try RecordingMetadataStore.read(beside: transcript).calendarMatch)
        _ = try await store.finishRecording(incomplete: false)
        // A saved recording without its transcript is still not open to enrichment.
        try RecordingMetadataStore.save(match: RecordingCalendarMatch(status: "unmatched"), beside: transcript)
        XCTAssertNil(try RecordingMetadataStore.read(beside: transcript).calendarMatch)
        let processor = MeetingPostProcessor(root: root.appendingPathComponent("meetings"), workRoot: root.appendingPathComponent("work"), engine: FakeEngine())
        _ = try await processor.process(store.captureDirectory, keepAudio: false) { _ in }
        let metadata = try RecordingMetadataStore.read(beside: transcript)
        XCTAssertEqual(metadata.endedAt, "2026-10-23T17:01:05.123Z") // Not the much later processing/finish date.
        XCTAssertEqual(metadata.meeting, context)
        let match = RecordingCalendarMatcher.match(metadata, events: [event()])
        try RecordingMetadataStore.save(match: match, beside: transcript)
        try RecordingMetadataStore.save(match: match, beside: transcript)
        let text = try String(contentsOf: transcript)
        XCTAssertTrue(text.contains("You: Synthetic meeting fixture"))
        XCTAssertTrue(text.contains("Guest"))
        XCTAssertEqual(text.components(separatedBy: "--- Recording metadata ---").count, 2)
        XCTAssertEqual(try RecordingMetadataStore.read(beside: transcript).calendarMatch, match)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: transcript.path)[.posixPermissions] as? Int, 0o600)
    }
}
