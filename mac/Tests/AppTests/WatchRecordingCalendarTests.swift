import Foundation
import LocalMeetingEngine
import XCTest
@testable import Sunday_Voice

@MainActor
private final class FakeWatchCalendarAPI: WatchRecordingCalendarAPI {
    var records: [WatchRecordingMetadata] = []
    var canonical: [String: RecordingCalendarMatch] = [:]
    var listError: Error?
    var loseWriteResponse = false
    var writes = 0, reads = 0, lists = 0
    func watchRecordings(before: String?) async throws -> WatchRecordingPage {
        lists += 1
        if let listError { throw listError }
        return WatchRecordingPage(recordings: records, next_before: nil)
    }
    func watchCalendarMatch(id: String) async throws -> RecordingCalendarMatch? { reads += 1; return canonical[id] }
    func saveWatchCalendarMatch(id: String, match: RecordingCalendarMatch) async throws -> RecordingCalendarMatch? {
        writes += 1; canonical[id] = match
        if loseWriteResponse { throw URLError(.networkConnectionLost) }
        return match
    }
}

@MainActor
final class WatchRecordingCalendarTests: XCTestCase {
    private func record(_ id: String = UUID().uuidString, complete: Bool = true) -> WatchRecordingMetadata {
        WatchRecordingMetadata(id: id, source_device: "apple_watch", recorded_at: "2026-10-23T17:00:00Z",
            ended_at: nil, time_zone: nil, utc_offset_minutes: nil, ended_utc_offset_minutes: nil,
            timestamp_provenance: ["start": "device_clock_seconds", "end": nil, "duration": "pcm_sample_count"],
            duration_seconds: 7.895, status: complete ? "ready" : "uploading", created_at: RecordingMetadata.timestamp(Date()), chunk_count: complete ? 1 : nil)
    }

    func testCompleteWatchNoteMatchesOnceAndPartialUploadNeverWrites() async {
        let api = FakeWatchCalendarAPI(); api.records = [record(), record(complete: false)]
        var matched = 0
        let sync = WatchRecordingCalendarSync(api: api, identity: { "same-origin|owner" }) { metadata in
            matched += 1
            XCTAssertNil(metadata.endedAt)
            XCTAssertNil(metadata.timeZone)
            XCTAssertEqual(metadata.sourceDevice, "apple_watch")
            return RecordingCalendarMatch(status: "matched")
        }
        await sync.sync(); await sync.sync()
        XCTAssertEqual(matched, 1)
        XCTAssertEqual(api.writes, 1)
    }

    func testUncertainPostIsReconciledWithoutASecondWrite() async {
        let api = FakeWatchCalendarAPI(); api.records = [record()]; api.loseWriteResponse = true
        let sync = WatchRecordingCalendarSync(api: api, identity: { "same-origin|owner" }) { _ in RecordingCalendarMatch(status: "matched") }
        await sync.sync(); await sync.sync()
        XCTAssertEqual(api.writes, 1)
        XCTAssertEqual(api.reads, 2)
    }

    func testExistingCanonicalMatchPreventsReplayAfterRelaunch() async {
        let api = FakeWatchCalendarAPI(); let value = record(); api.records = [value]
        api.canonical[value.id] = RecordingCalendarMatch(status: "matched")
        let sync = WatchRecordingCalendarSync(api: api, identity: { "same-origin|owner" }) { _ in
            XCTFail("Existing match needs no second calendar query")
            return RecordingCalendarMatch(status: "unmatched")
        }
        await sync.sync()
        XCTAssertEqual(api.writes, 0)
    }

    func testAccountChangeDuringCalendarReadPreventsWriteAndMissingIdentityDoesNotRead() async {
        let api = FakeWatchCalendarAPI(); api.records = [record()]
        var identity: String? = nil
        let sync = WatchRecordingCalendarSync(api: api, identity: { identity }) { _ in
            identity = "other-origin|other-owner"
            return RecordingCalendarMatch(status: "matched")
        }
        await sync.sync(); XCTAssertEqual(api.lists, 0)
        identity = "same-origin|owner"
        await sync.sync()
        XCTAssertEqual(api.writes, 0)
    }

    func testUnavailableConfiguredOriginDoesNotProbeAnotherOrigin() async {
        let api = FakeWatchCalendarAPI(); api.listError = APIError.http(404, "not_found")
        let sync = WatchRecordingCalendarSync(api: api, identity: { "production|owner" }) { _ in
            XCTFail("An unavailable API cannot supply recording data")
            return RecordingCalendarMatch(status: "unmatched")
        }
        await sync.sync()
        XCTAssertEqual(api.lists, 1)
        XCTAssertEqual(api.writes, 0)
        XCTAssertTrue(sync.status.contains("configured server"))
    }
}
