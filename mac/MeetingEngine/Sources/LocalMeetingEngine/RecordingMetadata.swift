import Foundation

/// Owner-local context, never telemetry or an upload. Nil means unavailable, not inferred.
public struct RecordingMeetingContext: Codable, Equatable, Sendable {
    public var appName: String?
    public var bundleID: String?
    public var windowTitle: String?
    enum CodingKeys: String, CodingKey { case appName = "app_name", bundleID = "bundle_id", windowTitle = "window_title" }
    public init(appName: String? = nil, bundleID: String? = nil, windowTitle: String? = nil) {
        self.appName = appName; self.bundleID = bundleID; self.windowTitle = windowTitle
    }
}

public struct RecordingAttendee: Codable, Equatable, Sendable {
    public var email: String?
    public var displayName: String?
    enum CodingKeys: String, CodingKey { case email, displayName = "display_name" }
    public init(email: String?, displayName: String?) { self.email = email; self.displayName = displayName }
}

public struct RecordingCalendarEvent: Codable, Equatable, Sendable {
    public var calendarID: String
    public var eventID: String
    public var title: String
    public var attendees: [RecordingAttendee]
    public var startedAt: String
    public var endedAt: String
    public var overlapSeconds: Double
    enum CodingKeys: String, CodingKey {
        case calendarID = "calendar_id", eventID = "event_id", title, attendees
        case startedAt = "started_at", endedAt = "ended_at", overlapSeconds = "overlap_seconds"
    }
    public init(calendarID: String, eventID: String, title: String, attendees: [RecordingAttendee], startedAt: String, endedAt: String, overlapSeconds: Double = 0) {
        self.calendarID = calendarID; self.eventID = eventID; self.title = title; self.attendees = attendees
        self.startedAt = startedAt; self.endedAt = endedAt; self.overlapSeconds = overlapSeconds
    }
}

public struct RecordingCalendarMatch: Codable, Equatable, Sendable {
    public var status: String
    public var matchedAt: String
    public var method: String
    public var intervalSource: String?
    public var events: [RecordingCalendarEvent]
    enum CodingKeys: String, CodingKey { case status, matchedAt = "matched_at", method, events, intervalSource = "interval_source" }
    public init(status: String, events: [RecordingCalendarEvent] = [], now: Date = Date()) {
        self.status = status; self.events = events; matchedAt = RecordingMetadata.timestamp(now); method = "time_overlap_v1"
    }
}

/// Shared field names with the Watch/iPhone metadata API. UTC instants plus IANA zone and
/// offsets preserve both exact ordering and the device's local wall time, including DST.
public struct RecordingMetadata: Codable, Equatable, Sendable {
    public var version = 1
    public var recordingID: String
    public var sourceDevice: String
    public var recordedAt: String?
    public var endedAt: String?
    public var timeZone: String?
    public var utcOffsetMinutes: Int?
    public var endedUTCOffsetMinutes: Int?
    public var durationSeconds: Double?
    public var elapsedSeconds: Double?
    public var timestampProvenance: [String: String?]
    public var meeting: RecordingMeetingContext?
    public var calendarMatch: RecordingCalendarMatch?
    enum CodingKeys: String, CodingKey {
        case version, recordingID = "recording_id", sourceDevice = "source_device"
        case recordedAt = "recorded_at", endedAt = "ended_at", timeZone = "time_zone"
        case utcOffsetMinutes = "utc_offset_minutes", endedUTCOffsetMinutes = "ended_utc_offset_minutes"
        case durationSeconds = "duration_seconds", elapsedSeconds = "elapsed_seconds"
        case timestampProvenance = "timestamp_provenance", meeting, calendarMatch = "calendar_match"
    }
    public init(recordingID: String, sourceDevice: String = "mac", timeZone: String? = TimeZone.current.identifier,
                meeting: RecordingMeetingContext? = nil) {
        self.recordingID = recordingID; self.sourceDevice = sourceDevice; self.timeZone = timeZone; self.meeting = meeting
        timestampProvenance = ["start": "unknown", "end": "unknown", "duration": "unknown"]
    }
    public static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.string(from: date)
    }
    public static func date(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions.insert(.withFractionalSeconds)
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions.remove(.withFractionalSeconds)
        return formatter.date(from: value)
    }
    public var textFooter: String {
        var lines = ["", "", "--- Recording metadata ---", "Source device: \(sourceDevice)",
                     "Start: \(recordedAt ?? "unknown")", "End: \(endedAt ?? "unknown")",
                     "Time zone: \(timeZone ?? "unknown") (start UTC offset minutes: \(utcOffsetMinutes.map(String.init) ?? "unknown"))",
                     "Audio duration seconds: \(durationSeconds.map { String(format: "%.3f", $0) } ?? "unknown")"]
        if let meeting {
            lines += ["Meeting app: \(meeting.appName ?? "unknown")", "Meeting window: \(meeting.windowTitle ?? "unknown")"]
        }
        lines.append("Timestamp provenance: \(timestampProvenance.keys.sorted().map { "\($0)=\((timestampProvenance[$0] ?? nil) ?? "unknown")" }.joined(separator: "; "))")
        lines.append("Calendar: \(calendarMatch?.status ?? "pending") (\(calendarMatch?.intervalSource ?? "pending"); attendees are invitees, not verified speakers)")
        for event in calendarMatch?.events ?? [] {
            lines.append("\(event.startedAt) – \(event.endedAt): \(event.title); invitees: \(event.attendees.compactMap { $0.displayName ?? $0.email }.joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Keep sample duration separate from elapsed time: gaps and concurrent sources do not inflate it.
struct RecordingAudioTimeline {
    private var chunks: [UUID: MeetingChunk] = [:]
    mutating func observe(_ chunk: MeetingChunk, metadata: inout RecordingMetadata) {
        guard let start = chunk.recordedAt, chunk.durationSeconds.isFinite, chunk.durationSeconds > 0,
              (chunk.endedAt ?? start.addingTimeInterval(chunk.durationSeconds)) >= start else { return }
        chunks[chunk.id] = chunk
        let first = chunks.values.compactMap(\.recordedAt).min()!
        let end = chunks.values.map { $0.endedAt ?? $0.recordedAt!.addingTimeInterval($0.durationSeconds) }.max()!
        let duration = MeetingAudioSource.allCases.map { source in
            chunks.values.filter { $0.source == source }.reduce(0) { $0 + $1.durationSeconds }
        }.max() ?? 0
        let zone = metadata.timeZone.flatMap(TimeZone.init(identifier:))
        metadata.recordedAt = RecordingMetadata.timestamp(first); metadata.endedAt = RecordingMetadata.timestamp(end)
        metadata.utcOffsetMinutes = zone.map { $0.secondsFromGMT(for: first) / 60 }
        metadata.endedUTCOffsetMinutes = zone.map { $0.secondsFromGMT(for: end) / 60 }
        metadata.durationSeconds = duration; metadata.elapsedSeconds = end.timeIntervalSince(first)
        metadata.timestampProvenance = ["start": "audio_sample_clock", "end": "audio_sample_clock", "duration": "longest_source_audio_samples"]
    }
}

public enum RecordingCalendarMatcher {
    public static func interval(_ recording: RecordingMetadata) -> DateInterval? {
        guard let start = RecordingMetadata.date(recording.recordedAt) else { return nil }
        let end = RecordingMetadata.date(recording.endedAt) ?? recording.durationSeconds.flatMap {
            $0.isFinite && $0 > 0 ? start.addingTimeInterval($0) : nil
        }
        guard let end, end > start else { return nil }
        return DateInterval(start: start, end: end)
    }
    /// Only positive overlap qualifies. Multiple events remain ambiguous, including a recording
    /// spanning successive calls. This is a calendar association, never proof of attendance.
    public static func match(_ recording: RecordingMetadata, events: [RecordingCalendarEvent], now: Date = Date()) -> RecordingCalendarMatch {
        guard let interval = interval(recording) else {
            return RecordingCalendarMatch(status: "unknown_time", now: now)
        }
        let start = interval.start, end = interval.end
        var seen = Set<String>()
        let overlaps = events.compactMap { event -> RecordingCalendarEvent? in
            guard let eventStart = RecordingMetadata.date(event.startedAt), let eventEnd = RecordingMetadata.date(event.endedAt), eventEnd > eventStart else { return nil }
            let overlap = min(end, eventEnd).timeIntervalSince(max(start, eventStart))
            guard overlap > 0, seen.insert("\(event.calendarID)|\(event.eventID)|\(event.startedAt)").inserted else { return nil }
            var event = event; event.overlapSeconds = overlap; return event
        }.sorted {
            if $0.overlapSeconds != $1.overlapSeconds { return $0.overlapSeconds > $1.overlapSeconds }
            return "\($0.calendarID)|\($0.eventID)" < "\($1.calendarID)|\($1.eventID)"
        }
        var match = RecordingCalendarMatch(status: overlaps.isEmpty ? "unmatched" : (overlaps.count == 1 ? "matched" : "ambiguous"), events: overlaps, now: now)
        match.intervalSource = recording.endedAt == nil ? "estimated_end_from_audio_duration" :
            (recording.timestampProvenance.values.contains(where: { $0?.hasPrefix("legacy_") == true }) ? "recorded_timestamps_see_provenance" : "capture_timestamps")
        return match
    }
}

public enum RecordingMetadataStore {
    public static func isFinalized(_ transcript: URL) -> Bool {
        let url = transcript.deletingPathExtension().appendingPathExtension("json")
        guard let data = try? Data(contentsOf: url), let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        return document["finishedAt"] is String
    }
    public static func read(beside transcript: URL) throws -> RecordingMetadata {
        let data = try Data(contentsOf: transcript.deletingLastPathComponent().appendingPathComponent("RecordingMetadata.json"))
        return try JSONDecoder().decode(RecordingMetadata.self, from: data)
    }
    /// Finalized files only. Preserve existing fields and transcript text. Calendar outages can
    /// never prevent audio/transcript finalization; this optional enrichment is retried later.
    public static func save(match: RecordingCalendarMatch, beside transcript: URL) throws {
        let jsonURL = transcript.deletingPathExtension().appendingPathExtension("json")
        var document = try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)) as? [String: Any] ?? [:]
        guard document["finishedAt"] is String, let object = document["recording"] else { return }
        let old = try JSONDecoder().decode(RecordingMetadata.self, from: JSONSerialization.data(withJSONObject: object))
        var metadata = old; metadata.calendarMatch = match
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(metadata)
        document["recording"] = try JSONSerialization.jsonObject(with: data)
        try MeetingSessionStore.privateWrite(JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys]), to: jsonURL)
        try MeetingSessionStore.privateWrite(data, to: transcript.deletingLastPathComponent().appendingPathComponent("RecordingMetadata.json"))
        var text = try String(contentsOf: transcript, encoding: .utf8)
        if text.hasSuffix(old.textFooter) { text.removeLast(old.textFooter.count) }
        text += metadata.textFooter
        try MeetingSessionStore.privateWrite(Data(text.utf8), to: transcript)
    }
}
