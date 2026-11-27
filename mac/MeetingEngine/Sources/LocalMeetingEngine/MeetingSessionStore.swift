import Foundation

/// Kept inside a recording's capture folder from the first second until its transcript is final.
/// It is how an interrupted or not-yet-transcribed recording is found again after a restart.
struct PendingRecording: Codable, Equatable, Sendable {
    var sessionID: UUID
    var sessionFolder: String
    var startedAt: Date
    var attempts: Int = 0
    static let fileName = "Session.json"
}

/// The recording stage: audio files and timing metadata only. No speech model is involved.
actor MeetingSessionStore {
    nonisolated let sessionID: UUID
    nonisolated let sessionDirectory: URL
    nonisolated let captureDirectory: URL
    nonisolated let transcriptURL: URL
    private var document: MeetingDocument
    private var timeline = RecordingAudioTimeline()

    init(root: URL, workRoot: URL, startedAt: Date = Date(), sessionID: UUID = UUID(), context: RecordingMeetingContext? = nil, sourceDevice: String = "mac") throws {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = "\(formatter.string(from: startedAt))_\(sessionID.uuidString.prefix(8))"
        self.sessionID = sessionID
        sessionDirectory = root.appendingPathComponent(folder, isDirectory: true)
        captureDirectory = workRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        transcriptURL = sessionDirectory.appendingPathComponent("Transcript.txt")
        document = MeetingDocument(version: 3, sessionID: sessionID, startedAt: startedAt, finishedAt: nil,
                                   model: "", segments: [], recoveredChunkCount: 0,
                                   incomplete: true, notes: [], recording: RecordingMetadata(recordingID: sessionID.uuidString, sourceDevice: sourceDevice, meeting: context))
        for folder in [root, workRoot, sessionDirectory, captureDirectory] { try Self.privateDirectory(folder) }
        let marker = PendingRecording(sessionID: sessionID, sessionFolder: folder, startedAt: startedAt)
        try Self.writeMarker(marker, in: captureDirectory)
        try Self.writeDocument(document, directory: sessionDirectory)
    }

    /// Timing only. The audio file stays where capture wrote it.
    func observe(_ chunk: MeetingChunk) throws {
        if var recording = document.recording {
            timeline.observe(chunk, metadata: &recording)
            document.recording = recording
            try Self.writeDocument(document, directory: sessionDirectory)
        }
    }

    func recordGap(from start: TimeInterval, to end: TimeInterval) throws {
        document.notes.append(String(format: "Audio capture gap: %.1f–%.1f seconds. Capture resumed automatically.", start, end))
        try Self.writeDocument(document, directory: sessionDirectory)
    }

    /// Capture has ended and every audio file is closed. The transcript is written later, offline.
    func finishRecording(incomplete: Bool, note: String? = nil) throws -> URL {
        // A final buffer may have been closed after the last stream element was delivered.
        for chunk in MeetingAudioAssembler.chunks(in: captureDirectory) { try observe(chunk) }
        document.incomplete = incomplete
        document.recordingEndedAt = Date()
        if let note, !note.isEmpty { document.notes.append(note) }
        try Self.writeDocument(document, directory: sessionDirectory)
        return transcriptURL
    }

    static func privateDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }

    static func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func writeMarker(_ marker: PendingRecording, in captureDirectory: URL) throws {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        try privateWrite(encoder.encode(marker), to: captureDirectory.appendingPathComponent(PendingRecording.fileName))
    }

    static func readMarker(in captureDirectory: URL) -> PendingRecording? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: captureDirectory.appendingPathComponent(PendingRecording.fileName)) else { return nil }
        return try? decoder.decode(PendingRecording.self, from: data)
    }

    static func readDocument(in directory: URL) -> MeetingDocument? {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("Transcript.json")) else { return nil }
        return try? decoder.decode(MeetingDocument.self, from: data)
    }

    static func writeDocument(_ document: MeetingDocument, directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try privateWrite(encoder.encode(document), to: directory.appendingPathComponent("Transcript.json"))
        if let recording = document.recording {
            try privateWrite(encoder.encode(recording), to: directory.appendingPathComponent("RecordingMetadata.json"))
        }
        try privateWrite(Data(MeetingTranscriptBuilder.text(for: document).utf8), to: directory.appendingPathComponent("Transcript.txt"))
    }
}

/// Turns saved recordings into speaker-labelled transcripts, one at a time, after capture.
/// A recording is removed from the capture folder only once its transcript is safely written.
actor MeetingPostProcessor {
    static let maxAttempts = 3
    private let root: URL
    private let workRoot: URL
    private let engine: any MeetingTranscribing
    /// Recordings being processed right now. An actor still interleaves at every `await`,
    /// so a second request for the same recording must be refused, not run alongside the first.
    private var inFlight: Set<String> = []

    init(root: URL, workRoot: URL, engine: any MeetingTranscribing) {
        self.root = root
        self.workRoot = workRoot
        self.engine = engine
    }

    /// Recordings waiting for a transcript, oldest first. The one still being captured is excluded.
    nonisolated func pending(excluding active: UUID? = nil) -> [URL] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: workRoot, includingPropertiesForKeys: nil)) ?? []
        return folders.compactMap { folder -> (URL, Date)? in
            guard let marker = MeetingSessionStore.readMarker(in: folder), marker.sessionID != active,
                  marker.attempts < Self.maxAttempts else { return nil }
            return (folder, marker.startedAt)
        }.sorted { $0.1 < $1.1 }.map(\.0)
    }

    /// Writes the final transcript for one recording and returns its location.
    func process(_ captureDirectory: URL, keepAudio: Bool, progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        try await processDetailed(captureDirectory, keepAudio: keepAudio) { detail in progress(detail.fraction) }
    }

    /// Writes the final transcript for one recording, reporting structured audio progress and live ETA.
    func processDetailed(_ captureDirectory: URL, keepAudio: Bool, progress: @escaping @Sendable (MeetingTranscriptionProgress) -> Void) async throws -> URL {
        guard var marker = MeetingSessionStore.readMarker(in: captureDirectory) else { throw MeetingEngineError.invalidFile }
        guard inFlight.insert(captureDirectory.lastPathComponent).inserted else { throw MeetingEngineError.busy }
        defer { inFlight.remove(captureDirectory.lastPathComponent) }
        let sessionDirectory = root.appendingPathComponent(marker.sessionFolder, isDirectory: true)
        try MeetingSessionStore.privateDirectory(sessionDirectory)
        var document = MeetingSessionStore.readDocument(in: sessionDirectory)
            ?? MeetingDocument(version: 3, sessionID: marker.sessionID, startedAt: marker.startedAt, finishedAt: nil, model: "",
                               segments: [], recoveredChunkCount: 0, incomplete: true, notes: [],
                               recording: RecordingMetadata(recordingID: marker.sessionID.uuidString))
        let chunks = MeetingAudioAssembler.chunks(in: captureDirectory)
        // Already transcribed and only the empty capture folder was left behind: never overwrite a finished transcript.
        if document.finishedAt != nil, chunks.isEmpty {
            try? FileManager.default.removeItem(at: captureDirectory)
            return sessionDirectory.appendingPathComponent("Transcript.txt")
        }
        let began = Date()
        do {
            // Assemble audio first so total audio duration is known while models load.
            let sources = MeetingAudioSource.allCases.filter { source in chunks.contains { $0.source == source } }
            var audibleTracks: [(source: MeetingAudioSource, samples: [Float])] = []
            var audioSeconds = 0.0
            var unreadable = 0
            for source in sources {
                try Task.checkCancellation()
                let assembled = MeetingAudioAssembler.samples(for: source, chunks: chunks)
                unreadable += assembled.unreadable
                audioSeconds = max(audioSeconds, Double(assembled.samples.count) / MeetingAudioAssembler.sampleRate)
                // A source that never rose above the noise floor (muted microphone, silent Mac) is not decoded.
                let audible = chunks.contains { $0.source == source && $0.rms >= 0.0015 }
                if audible, assembled.samples.count >= Int(MeetingAudioAssembler.sampleRate / 4) {
                    audibleTracks.append((source, assembled.samples))
                }
            }
            progress(MeetingTranscriptionProgress(fraction: 0, processedAudioSeconds: 0, totalAudioSeconds: audioSeconds, estimatedRemainingSeconds: nil))
            try await engine.load()
            var lines: [MeetingAudioSource: [MeetingTranscriptBuilder.Line]] = [:]
            var languages = Set<String>()
            var voices = 0
            var archives: [String] = []
            if !audibleTracks.isEmpty {
                let recognized = try await engine.recognizeTracks(audibleTracks, meetingAudioSeconds: audioSeconds, progress: progress)
                for track in audibleTracks {
                    if let recognition = recognized[track.source] {
                        lines[track.source] = MeetingTranscriptBuilder.attribute(recognition.lines, turns: recognition.turns, source: track.source)
                        languages.formUnion(recognition.languages)
                        voices += Set(recognition.turns.map(\.speaker)).count
                    }
                    if keepAudio {
                        let folder = sessionDirectory.appendingPathComponent("Audio", isDirectory: true)
                        try MeetingSessionStore.privateDirectory(folder)
                        try MeetingAudioAssembler.writeArchive(track.samples, to: folder.appendingPathComponent("\(track.source.rawValue).m4a"))
                        archives.append("\(track.source.rawValue).m4a")
                    }
                }
            } else {
                progress(MeetingTranscriptionProgress(fraction: 1, processedAudioSeconds: audioSeconds, totalAudioSeconds: audioSeconds, estimatedRemainingSeconds: 0))
            }
            try Task.checkCancellation()
            document.segments = MeetingTranscriptBuilder.segments(microphone: lines[.microphone] ?? [], system: lines[.system] ?? [])
            document.transcription = MeetingTranscriptionInfo(
                speechModel: engine.speechModelName, speakerModel: voices > 0 ? engine.speakerModelName : nil,
                languages: languages.sorted(), audioSeconds: audioSeconds, processingSeconds: Date().timeIntervalSince(began),
                speakerCount: Set(document.segments.compactMap(\.speaker)).count)
            document.model = engine.speechModelName
            document.finishedAt = Date()
            document.recoveredChunkCount = 0
            document.audioFiles = archives.isEmpty ? nil : archives
            if document.recordingEndedAt == nil {
                document.incomplete = true
                document.notes.append("Sunday Voice closed before this recording was stopped. Everything captured up to that moment was transcribed.")
            }
            if unreadable > 0 {
                document.incomplete = true
                document.notes.append("\(unreadable) audio file(s) could not be read and are missing from this transcript.")
            }
            // Text is durable before the only copy of the audio is removed.
            try MeetingSessionStore.writeDocument(document, directory: sessionDirectory)
            try? FileManager.default.removeItem(at: captureDirectory)
            return sessionDirectory.appendingPathComponent("Transcript.txt")
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            // A missing model is a setup state, not a failed attempt.
            if (error as? MeetingEngineError) == .modelMissing { throw error }
            marker.attempts += 1
            try? MeetingSessionStore.writeMarker(marker, in: captureDirectory)
            if marker.attempts >= Self.maxAttempts { try? park(captureDirectory, document: &document, sessionDirectory: sessionDirectory) }
            throw error
        }
    }

    /// After repeated failures the audio moves beside the transcript so nothing is lost or retried forever.
    private func park(_ captureDirectory: URL, document: inout MeetingDocument, sessionDirectory: URL) throws {
        let recovery = sessionDirectory.appendingPathComponent("Recovery Audio", isDirectory: true)
        try MeetingSessionStore.privateDirectory(recovery)
        let files = (try? FileManager.default.contentsOfDirectory(at: captureDirectory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent != PendingRecording.fileName {
            let target = recovery.appendingPathComponent(file.lastPathComponent)
            if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.moveItem(at: file, to: target) }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
        }
        let kept = (try? FileManager.default.contentsOfDirectory(at: recovery, includingPropertiesForKeys: nil)) ?? []
        document.recoveredChunkCount = kept.filter { $0.pathExtension == "caf" }.count
        document.incomplete = true
        document.finishedAt = Date()
        document.notes.append("This recording could not be transcribed after \(Self.maxAttempts) attempts. Its audio is kept in Recovery Audio.")
        try MeetingSessionStore.writeDocument(document, directory: sessionDirectory)
        try? FileManager.default.removeItem(at: captureDirectory)
    }

    /// Removes kept audio older than the retention window. Transcripts are never touched.
    nonisolated func pruneAudio(olderThan days: Int, now: Date = Date()) {
        let folders = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        for folder in folders {
            let audio = folder.appendingPathComponent("Audio", isDirectory: true)
            guard let document = MeetingSessionStore.readDocument(in: folder), let finished = document.finishedAt,
                  now.timeIntervalSince(finished) > Double(days) * 86_400,
                  FileManager.default.fileExists(atPath: audio.path) else { continue }
            try? FileManager.default.removeItem(at: audio)
            var updated = document
            updated.audioFiles = nil
            try? MeetingSessionStore.writeDocument(updated, directory: folder)
        }
    }

    func unload() async { await engine.unload() }
}
