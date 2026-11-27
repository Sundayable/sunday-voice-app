import AVFoundation
import XCTest
@testable import LocalMeetingEngine

// MARK: - Transcript assembly (pure)

final class MeetingTranscriptBuilderTests: XCTestCase {
    typealias Line = MeetingTranscriptBuilder.Line

    func testEachLineGetsTheVoiceThatSpeaksForMostOfIt() {
        let turns = [SpeakerTurn(speaker: 0, startSeconds: 0, endSeconds: 4), SpeakerTurn(speaker: 1, startSeconds: 4, endSeconds: 10)]
        let lines = [TimedText(startSeconds: 0.2, endSeconds: 3.8, text: "first"), TimedText(startSeconds: 3.5, endSeconds: 9, text: "second"),
                     TimedText(startSeconds: 11, endSeconds: 12, text: "just after a turn"), TimedText(startSeconds: 40, endSeconds: 41, text: "far away")]
        let result = MeetingTranscriptBuilder.attribute(lines, turns: turns, source: .system)
        XCTAssertEqual(result.map(\.voice), [0, 1, 1, nil])
    }

    func testWithoutVoiceTurnsLinesKeepTheirSourceOnly() {
        let result = MeetingTranscriptBuilder.attribute([TimedText(startSeconds: 0, endSeconds: 1, text: "hello")], turns: [], source: .microphone)
        XCTAssertEqual(result.first?.voice, nil)
        let segments = MeetingTranscriptBuilder.segments(microphone: result, system: [])
        XCTAssertEqual(segments.first?.speaker, nil)
        XCTAssertEqual(segments.first?.speakerLabel, "You")
    }

    func testLoudspeakerEchoOnTheMicrophoneIsDroppedButOwnSpeechStays() {
        let system = [Line(source: .system, voice: 0, startSeconds: 10, endSeconds: 14, text: "다음 주 목요일까지 뉴스레터 초안을 보내 드릴게요")]
        let microphone = [Line(source: .microphone, voice: 1, startSeconds: 10.4, endSeconds: 14.2, text: "다음주 목요일까지 뉴스레터 초안을 보내드릴게요."),
                          Line(source: .microphone, voice: 0, startSeconds: 15, endSeconds: 17, text: "좋아요, 그럼 금요일에 리뷰할게요"),
                          Line(source: .microphone, voice: 0, startSeconds: 60, endSeconds: 64, text: "다음 주 목요일까지 뉴스레터 초안을 보내 드릴게요")]
        let kept = MeetingTranscriptBuilder.removeEcho(microphone: microphone, system: system)
        XCTAssertEqual(kept.map(\.startSeconds), [15, 60], "Only the simultaneous copy is an echo; the same words a minute later are real speech")
    }

    func testShortBackchannelIsKeptUnlessTheCallSaysItAtTheSameMoment() {
        let system = [Line(source: .system, voice: 0, startSeconds: 5, endSeconds: 6, text: "네 맞아요")]
        let microphone = [Line(source: .microphone, voice: 0, startSeconds: 5.2, endSeconds: 5.6, text: "네"),
                          Line(source: .microphone, voice: 0, startSeconds: 20, endSeconds: 20.5, text: "네")]
        XCTAssertEqual(MeetingTranscriptBuilder.removeEcho(microphone: microphone, system: system).map(\.startSeconds), [20])
    }

    func testSingleMicrophoneVoiceIsYouAndRemoteVoicesAreNumberedInSpeakingOrder() {
        let microphone = [Line(source: .microphone, voice: 3, startSeconds: 0, endSeconds: 40, text: "opening"),
                          Line(source: .microphone, voice: 5, startSeconds: 41, endSeconds: 43, text: "brief split of the same person")]
        let system = [Line(source: .system, voice: 7, startSeconds: 50, endSeconds: 90, text: "second remote voice heard first"),
                      Line(source: .system, voice: 2, startSeconds: 95, endSeconds: 140, text: "another remote voice"),
                      Line(source: .system, voice: 9, startSeconds: 141, endSeconds: 143, text: "two seconds of an unmatched voice")]
        let segments = MeetingTranscriptBuilder.segments(microphone: microphone, system: system)
        XCTAssertEqual(segments.map(\.speaker), ["You", "Speaker 1", "Speaker 2", "Speaker ?"])
        XCTAssertEqual(segments.first?.text, "opening brief split of the same person", "A minor extra microphone voice merges into You")
    }

    func testSeveralRealMicrophoneVoicesAreRoomSpeakers() {
        let microphone = [Line(source: .microphone, voice: 0, startSeconds: 0, endSeconds: 60, text: "a"),
                          Line(source: .microphone, voice: 1, startSeconds: 61, endSeconds: 120, text: "b")]
        XCTAssertEqual(MeetingTranscriptBuilder.segments(microphone: microphone, system: []).map(\.speaker), ["Room speaker 1", "Room speaker 2"])
    }

    func testConsecutiveLinesByOnePersonBecomeOneParagraphAndSourcesInterleaveByTime() {
        let microphone = [Line(source: .microphone, voice: 0, startSeconds: 0, endSeconds: 3, text: "Hi."),
                          Line(source: .microphone, voice: 0, startSeconds: 3.5, endSeconds: 6, text: "Shall we start?"),
                          Line(source: .microphone, voice: 0, startSeconds: 30, endSeconds: 33, text: "Later remark.")]
        let system = [Line(source: .system, voice: 0, startSeconds: 7, endSeconds: 9, text: "Sure.")]
        let segments = MeetingTranscriptBuilder.segments(microphone: microphone, system: system)
        XCTAssertEqual(segments.map(\.text), ["Hi. Shall we start?", "Sure.", "Later remark."])
        XCTAssertEqual(segments.map(\.source), [.microphone, .system, .microphone])
        XCTAssertEqual(Set(segments.map(\.id)).count, 3)
    }

    func testTranscriptTextExplainsLabelsAndPendingState() {
        var document = MeetingDocument(version: 3, sessionID: UUID(), startedAt: Date(timeIntervalSince1970: 0), finishedAt: nil, model: "",
                                       segments: [], recoveredChunkCount: 0, incomplete: false, notes: [])
        document.recordingEndedAt = Date(timeIntervalSince1970: 60)
        let pending = MeetingTranscriptBuilder.text(for: document)
        XCTAssertTrue(pending.contains("Recording saved on this Mac"))
        XCTAssertTrue(pending.contains("Transcript pending."))
        document.finishedAt = Date(timeIntervalSince1970: 120)
        document.segments = [MeetingSegment(id: "system:0", source: .system, startSeconds: 3725, endSeconds: 3730, text: "Hello", speaker: "Speaker 1")]
        let final = MeetingTranscriptBuilder.text(for: document)
        XCTAssertTrue(final.contains("[01:02:05] Speaker 1: Hello"))
        XCTAssertTrue(final.contains("Names are not identified"))
    }

    func testOlderTranscriptsWithoutSpeakersStillDecode() throws {
        let legacy = #"{"id":"a:0","source":"microphone","startSeconds":0,"endSeconds":1,"text":"old"}"#
        let segment = try JSONDecoder().decode(MeetingSegment.self, from: Data(legacy.utf8))
        XCTAssertNil(segment.speaker)
        XCTAssertEqual(segment.speakerLabel, "You")
    }
}

final class MeetingSpeechRegionsTests: XCTestCase {
    func testOnlySpeechIsPlannedAndEveryRegionHoldsOneVoice() {
        let turns = [SpeakerTurn(speaker: 0, startSeconds: 10, endSeconds: 14), SpeakerTurn(speaker: 0, startSeconds: 14.8, endSeconds: 16),
                     SpeakerTurn(speaker: 1, startSeconds: 16.2, endSeconds: 20), SpeakerTurn(speaker: 1, startSeconds: 20.05, endSeconds: 20.1),
                     SpeakerTurn(speaker: 0, startSeconds: 26, endSeconds: 30), SpeakerTurn(speaker: 0, startSeconds: 300, endSeconds: 305)]
        let regions = MeetingSpeechRegions.plan(turns: turns, totalSeconds: 600)
        XCTAssertEqual(regions.map(\.speaker), [0, 1, 0, 0], "A change of voice always starts a new region; a click is not a turn")
        XCTAssertEqual(regions[0].startSeconds, 10 - MeetingSpeechRegions.paddingSeconds, accuracy: 0.001)
        XCTAssertEqual(regions[0].endSeconds, 16.1, accuracy: 0.001, "Padding stops halfway to the next voice")
        XCTAssertEqual(regions[1].startSeconds, 16.1, accuracy: 0.001)
        for (earlier, later) in zip(regions, regions.dropFirst()) { XCTAssertLessThanOrEqual(earlier.endSeconds, later.startSeconds) }
        let planned = regions.reduce(0) { $0 + $1.endSeconds - $1.startSeconds }
        XCTAssertLessThan(planned, 30, "Almost ten minutes of silence are never decoded")
    }

    func testLongMonologueIsCutAtItsQuietestMomentsIntoSingleWindowPieces() {
        // Ninety seconds of tone with a half-second pause at 25 s and at 50 s.
        var samples = TestAudio.tone(seconds: 90)
        for pause in [25.0, 50.0] { for index in Int(pause * 16_000)..<Int((pause + 0.5) * 16_000) { samples[index] = 0 } }
        let region = MeetingSpeechRegions.Region(startSeconds: 0, endSeconds: 90, speaker: 3)
        let pieces = MeetingSpeechRegions.windows(for: region, samples: samples, sampleRate: 16_000)
        XCTAssertEqual(pieces.first?.startSeconds, 0)
        XCTAssertEqual(pieces.last?.endSeconds, 90)
        XCTAssertTrue(pieces.allSatisfy { $0.speaker == 3 && $0.endSeconds - $0.startSeconds <= MeetingSpeechRegions.maxWindowSeconds })
        for (earlier, later) in zip(pieces, pieces.dropFirst()) { XCTAssertEqual(earlier.endSeconds, later.startSeconds, "No audio is skipped or repeated") }
        XCTAssertEqual(pieces[0].endSeconds, 25.25, accuracy: 0.3, "The first cut lands in the pause, not mid-word")
        XCTAssertEqual(pieces[1].endSeconds, 50.25, accuracy: 0.3)
        let short = MeetingSpeechRegions.Region(startSeconds: 5, endSeconds: 20, speaker: nil)
        XCTAssertEqual(MeetingSpeechRegions.windows(for: short, samples: samples, sampleRate: 16_000), [short])
    }

    func testLinesFromASingleVoiceRegionKeepThatVoice() {
        let turns = [SpeakerTurn(speaker: 4, startSeconds: 0, endSeconds: 9)]
        let line = TimedText(startSeconds: 2, endSeconds: 8, text: "decoded from a region of voice 7", voice: 7)
        XCTAssertEqual(MeetingTranscriptBuilder.attribute([line], turns: turns, source: .system).first?.voice, 7)
    }

    func testWindowsStayUnderTheRecognizerLimitAndALongMonologueStaysWhole() {
        let turns = stride(from: 0.0, to: 120, by: 10).map { SpeakerTurn(speaker: 0, startSeconds: $0, endSeconds: $0 + 6) }
            + [SpeakerTurn(speaker: 1, startSeconds: 200, endSeconds: 290)]
        let regions = MeetingSpeechRegions.plan(turns: turns, totalSeconds: 290)
        for region in regions.dropLast() {
            XCTAssertLessThanOrEqual(region.endSeconds - region.startSeconds, MeetingSpeechRegions.maxWindowSeconds)
        }
        XCTAssertEqual(regions.last!.endSeconds - regions.last!.startSeconds, 90 + MeetingSpeechRegions.paddingSeconds, accuracy: 0.001)
        XCTAssertEqual(regions.last?.endSeconds, 290, "Padding never runs past the end of the audio")
    }
}

// MARK: - Audio files

final class MeetingAudioAssemblerTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-audio-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testChunksBecomeContinuousAudioWithSilenceForRealGaps() throws {
        try TestAudio.chunk(in: root, source: .microphone, start: 0, seconds: 1)
        try TestAudio.chunk(in: root, source: .microphone, start: 1.02, seconds: 1) // jitter: stays contiguous
        try TestAudio.chunk(in: root, source: .microphone, start: 5, seconds: 1)    // a three-second capture gap
        try TestAudio.chunk(in: root, source: .system, start: 0.5, seconds: 2)
        let chunks = MeetingAudioAssembler.chunks(in: root)
        XCTAssertEqual(chunks.count, 4)
        let microphone = MeetingAudioAssembler.samples(for: .microphone, chunks: chunks)
        XCTAssertEqual(microphone.unreadable, 0)
        XCTAssertEqual(microphone.samples.count, 6 * 16_000)
        XCTAssertEqual(MeetingAudioAssembler.rms(Array(microphone.samples[(3 * 16_000)..<(4 * 16_000)])), 0, "The gap is silence")
        XCTAssertGreaterThan(MeetingAudioAssembler.rms(Array(microphone.samples[(5 * 16_000)...])), 0.05)
        let system = MeetingAudioAssembler.samples(for: .system, chunks: chunks)
        XCTAssertEqual(system.samples.count, Int(2.5 * 16_000), "Sources share one clock")
    }

    func testAudioLeftWithoutItsDescriptionByACrashIsStillUsedAndDamagedFilesAreCounted() throws {
        try TestAudio.chunk(in: root, source: .system, start: 0, seconds: 1)
        let orphan = root.appendingPathComponent("\(UUID().uuidString)-system.caf")
        try TestAudio.write(orphan, seconds: 2)
        let damaged = try TestAudio.chunk(in: root, source: .system, start: 10, seconds: 1)
        try Data("not audio".utf8).write(to: damaged.url)
        let chunks = MeetingAudioAssembler.chunks(in: root)
        XCTAssertEqual(chunks.count, 3)
        let result = MeetingAudioAssembler.samples(for: .system, chunks: chunks)
        XCTAssertEqual(result.unreadable, 1)
        XCTAssertEqual(result.samples.count, 13 * 16_000, "The orphan follows the last described audio (10–11 s, unreadable) and keeps its two seconds")
    }

    func testOtherSampleRatesAreConvertedAndLongFilesImportAsCaptureChunks() throws {
        let source = root.appendingPathComponent("import.caf")
        try TestAudio.write(source, seconds: 45, sampleRate: 48_000, channels: 2)
        let capture = root.appendingPathComponent("capture")
        try FileManager.default.createDirectory(at: capture, withIntermediateDirectories: true)
        let seconds = try MeetingAudioAssembler.importFile(source, as: .system, into: capture)
        XCTAssertEqual(seconds, 45, accuracy: 0.1)
        let chunks = MeetingAudioAssembler.chunks(in: capture)
        XCTAssertEqual(chunks.count, 3)
        XCTAssertEqual(Double(MeetingAudioAssembler.samples(for: .system, chunks: chunks).samples.count) / 16_000, 45, accuracy: 0.1)
    }

    func testKeptRecordingIsACompactPrivatePlayableFile() throws {
        let samples = TestAudio.tone(seconds: 10)
        let url = root.appendingPathComponent("microphone.m4a")
        try MeetingAudioAssembler.writeArchive(samples, to: url)
        let file = try AVAudioFile(forReading: url)
        XCTAssertEqual(Double(file.length) / file.fileFormat.sampleRate, 10, accuracy: 0.2)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o600)
        XCTAssertLessThan(attributes[.size] as! Int, samples.count * 4 / 5, "Much smaller than the raw capture")
    }
}

// MARK: - Recording store and offline pass

final class MeetingStoreTests: XCTestCase {
    private var root: URL!
    private var transcripts: URL { root.appendingPathComponent("transcripts") }
    private var work: URL { root.appendingPathComponent("work") }
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-engine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testRecordingIsDurableAndPrivateBeforeAnyTranscription() async throws {
        let store = try MeetingSessionStore(root: transcripts, workRoot: work)
        let chunk = try TestAudio.chunk(in: store.captureDirectory, source: .microphone, start: 0, seconds: 1)
        try await store.observe(chunk)
        let url = try await store.finishRecording(incomplete: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.url.path), "Audio stays until its transcript exists")
        let document = try XCTUnwrap(MeetingSessionStore.readDocument(in: url.deletingLastPathComponent()))
        XCTAssertNotNil(document.recordingEndedAt)
        XCTAssertNil(document.finishedAt)
        XCTAssertFalse(RecordingMetadataStore.isFinalized(url))
        XCTAssertEqual(try permissions(url), 0o600)
        XCTAssertEqual(try permissions(url.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try permissions(store.captureDirectory.appendingPathComponent(PendingRecording.fileName)), 0o600)
        let engine = FakeEngine()
        XCTAssertEqual(MeetingPostProcessor(root: transcripts, workRoot: work, engine: engine).pending().count, 1)
        XCTAssertEqual(MeetingPostProcessor(root: transcripts, workRoot: work, engine: engine).pending(excluding: store.sessionID).count, 0)
    }

    func testOfflinePassWritesSpeakerLabelledTranscriptThenRemovesRawAudio() async throws {
        let store = try MeetingSessionStore(root: transcripts, workRoot: work)
        try TestAudio.chunk(in: store.captureDirectory, source: .microphone, start: 0, seconds: 2)
        try TestAudio.chunk(in: store.captureDirectory, source: .system, start: 2, seconds: 2)
        _ = try await store.finishRecording(incomplete: false)
        let engine = FakeEngine()
        let processor = MeetingPostProcessor(root: transcripts, workRoot: work, engine: engine)
        let progress = ProgressLog()
        let url = try await processor.process(store.captureDirectory, keepAudio: false) { progress.add($0) }
        let document = try XCTUnwrap(MeetingSessionStore.readDocument(in: url.deletingLastPathComponent()))
        XCTAssertEqual(document.segments.map(\.speaker), ["You", "Speaker 1"])
        XCTAssertEqual(document.segments.map(\.source), [.microphone, .system])
        XCTAssertEqual(document.segments[1].startSeconds, 2, accuracy: 0.01, "Times are on the meeting clock, not the source's")
        XCTAssertNotNil(document.finishedAt)
        XCTAssertFalse(document.incomplete)
        XCTAssertEqual(document.model, engine.speechModelName)
        XCTAssertEqual(document.transcription?.speakerCount, 2)
        XCTAssertEqual(document.transcription?.languages, ["ko"])
        XCTAssertNil(document.audioFiles)
        XCTAssertTrue(RecordingMetadataStore.isFinalized(url))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.captureDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent("Audio").path))
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[00:00:00] You: Synthetic meeting fixture"))
        XCTAssertTrue(text.contains("[00:00:02] Speaker 1: Quarterly budget review tomorrow"))
        XCTAssertEqual(progress.values.last, 1)
        XCTAssertEqual(engine.recognizeCalls, 2)
    }

    func testKeepingAudioStoresOneCompactFilePerSourceAndPruningRemovesOnlyOldAudio() async throws {
        let store = try MeetingSessionStore(root: transcripts, workRoot: work)
        try TestAudio.chunk(in: store.captureDirectory, source: .microphone, start: 0, seconds: 2)
        try TestAudio.chunk(in: store.captureDirectory, source: .system, start: 0, seconds: 2)
        _ = try await store.finishRecording(incomplete: false)
        let processor = MeetingPostProcessor(root: transcripts, workRoot: work, engine: FakeEngine())
        let url = try await processor.process(store.captureDirectory, keepAudio: true) { _ in }
        let folder = url.deletingLastPathComponent()
        XCTAssertEqual(MeetingSessionStore.readDocument(in: folder)?.audioFiles, ["microphone.m4a", "system.m4a"])
        XCTAssertEqual(try permissions(folder.appendingPathComponent("Audio/system.m4a")), 0o600)
        processor.pruneAudio(olderThan: 30)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Audio/system.m4a").path))
        processor.pruneAudio(olderThan: 30, now: Date().addingTimeInterval(31 * 86_400))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("Audio").path))
        XCTAssertNil(MeetingSessionStore.readDocument(in: folder)?.audioFiles)
        XCTAssertEqual(MeetingSessionStore.readDocument(in: folder)?.segments.count, 2, "Pruning never touches the transcript")
    }

    func testSilentSourceIsNotDecodedAndMeetingWithNoSpeechStillFinishes() async throws {
        let store = try MeetingSessionStore(root: transcripts, workRoot: work)
        try TestAudio.chunk(in: store.captureDirectory, source: .microphone, start: 0, seconds: 2, amplitude: 0)
        _ = try await store.finishRecording(incomplete: false)
        let engine = FakeEngine()
        let url = try await MeetingPostProcessor(root: transcripts, workRoot: work, engine: engine).process(store.captureDirectory, keepAudio: false) { _ in }
        XCTAssertEqual(engine.recognizeCalls, 0)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("No speech was detected."))
    }

    func testFailedPassKeepsAudioAndAfterThreeAttemptsParksItBesideTheTranscript() async throws {
        let store = try MeetingSessionStore(root: transcripts, workRoot: work)
        let chunk = try TestAudio.chunk(in: store.captureDirectory, source: .system, start: 0, seconds: 2)
        let transcript = try await store.finishRecording(incomplete: false)
        let engine = FakeEngine(failures: 3)
        let processor = MeetingPostProcessor(root: transcripts, workRoot: work, engine: engine)
        for attempt in 1...3 {
            do { _ = try await processor.process(store.captureDirectory, keepAudio: false) { _ in }; XCTFail("Injected failure expected") }
            catch { XCTAssertEqual(error as? MeetingEngineError, .transcriptionFailed) }
            if attempt < 3 {
                XCTAssertTrue(FileManager.default.fileExists(atPath: chunk.url.path))
                XCTAssertEqual(MeetingSessionStore.readMarker(in: store.captureDirectory)?.attempts, attempt)
                XCTAssertEqual(processor.pending().count, 1)
            }
        }
        XCTAssertEqual(processor.pending().count, 0)
        let recovery = transcript.deletingLastPathComponent().appendingPathComponent("Recovery Audio")
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovery.appendingPathComponent(chunk.url.lastPathComponent).path))
        XCTAssertEqual(try permissions(recovery.appendingPathComponent(chunk.url.lastPathComponent)), 0o600)
        let text = try String(contentsOf: transcript, encoding: .utf8)
        XCTAssertTrue(text.contains("1 audio chunks remain in Recovery Audio"))
        XCTAssertTrue(text.contains("could not be transcribed after 3 attempts"))
    }

    func testARecordingIsNeverProcessedTwiceAtOnceAndAFinishedTranscriptIsNeverOverwritten() async throws {
        let store = try MeetingSessionStore(root: transcripts, workRoot: work)
        try TestAudio.chunk(in: store.captureDirectory, source: .system, start: 0, seconds: 2)
        _ = try await store.finishRecording(incomplete: false)
        let marker = try Data(contentsOf: store.captureDirectory.appendingPathComponent(PendingRecording.fileName))
        let engine = FakeEngine(holdRecognize: true)
        let processor = MeetingPostProcessor(root: transcripts, workRoot: work, engine: engine)
        let directory = store.captureDirectory
        let first = Task { try await processor.process(directory, keepAudio: false) { _ in } }
        for _ in 0..<400 where !engine.recognizeWaiting { try await Task.sleep(nanoseconds: 5_000_000) }
        do { _ = try await processor.process(directory, keepAudio: false) { _ in }; XCTFail("Same recording is already in flight") }
        catch { XCTAssertEqual(error as? MeetingEngineError, .busy) }
        engine.resumeRecognize()
        let url = try await first.value
        XCTAssertEqual(engine.recognizeCalls, 1)
        // A stale marker for the finished recording must not turn its transcript into "no speech".
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try marker.write(to: directory.appendingPathComponent(PendingRecording.fileName))
        let again = try await processor.process(directory, keepAudio: false) { _ in }
        XCTAssertEqual(again, url)
        XCTAssertEqual(MeetingSessionStore.readDocument(in: url.deletingLastPathComponent())?.segments.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testMissingModelIsNotCountedAsAFailedAttempt() async throws {
        let store = try MeetingSessionStore(root: transcripts, workRoot: work)
        try TestAudio.chunk(in: store.captureDirectory, source: .system, start: 0, seconds: 2)
        _ = try await store.finishRecording(incomplete: false)
        let processor = MeetingPostProcessor(root: transcripts, workRoot: work, engine: FakeEngine(ready: false))
        do { _ = try await processor.process(store.captureDirectory, keepAudio: false) { _ in }; XCTFail("Model is missing") }
        catch { XCTAssertEqual(error as? MeetingEngineError, .modelMissing) }
        XCTAssertEqual(MeetingSessionStore.readMarker(in: store.captureDirectory)?.attempts, 0)
    }

    func testRecordingCutShortByAQuitIsTranscribedAndMarkedIncomplete() async throws {
        let store = try MeetingSessionStore(root: transcripts, workRoot: work)
        try TestAudio.chunk(in: store.captureDirectory, source: .microphone, start: 0, seconds: 2)
        // No finishRecording: the app went away mid-meeting.
        let processor = MeetingPostProcessor(root: transcripts, workRoot: work, engine: FakeEngine())
        let url = try await processor.process(try XCTUnwrap(processor.pending().first), keepAudio: false) { _ in }
        let document = try XCTUnwrap(MeetingSessionStore.readDocument(in: url.deletingLastPathComponent()))
        XCTAssertTrue(document.incomplete)
        XCTAssertEqual(document.segments.count, 1)
        XCTAssertTrue(document.notes.contains { $0.contains("closed before this recording was stopped") })
    }

    func testETAEstimatorWarmsUpSmoothlyAndConvergesToZero() {
        var estimator = TranscriptionETAEstimator(minimumElapsedSeconds: 1.5, minimumFraction: 0.05)
        estimator.start(at: 100)
        // Too early / too little progress: stay unknown instead of flashing a wild estimate.
        XCTAssertNil(estimator.update(completedWork: 5, totalWork: 600, now: 100.5))
        XCTAssertNil(estimator.update(completedWork: 20, totalWork: 600, now: 102))
        // Steady 10x realtime: 60s of audio in 6s -> 540s remaining -> ~54s ETA.
        let first = estimator.update(completedWork: 60, totalWork: 600, now: 106)
        XCTAssertEqual(try XCTUnwrap(first), 54, accuracy: 0.5)
        // Continues at 10x: 300s done in 30s -> 300s left -> smoothly moves toward 30s.
        let mid = estimator.update(completedWork: 300, totalWork: 600, now: 130)
        XCTAssertLessThan(try XCTUnwrap(mid), first!)
        XCTAssertGreaterThan(try XCTUnwrap(mid), 25)
        // Completion reports exact 0.
        XCTAssertEqual(estimator.update(completedWork: 600, totalWork: 600, now: 160), 0)
    }

    func testStructuredProgressReportsAudioSecondsAcrossSources() async throws {
        let store = try MeetingSessionStore(root: transcripts, workRoot: work)
        try TestAudio.chunk(in: store.captureDirectory, source: .microphone, start: 0, seconds: 4)
        try TestAudio.chunk(in: store.captureDirectory, source: .system, start: 0, seconds: 6)
        _ = try await store.finishRecording(incomplete: false)
        let processor = MeetingPostProcessor(root: transcripts, workRoot: work, engine: FakeEngine())
        final class DetailBox: @unchecked Sendable {
            private let lock = NSLock()
            private var items: [MeetingTranscriptionProgress] = []
            func append(_ item: MeetingTranscriptionProgress) { lock.withLock { items.append(item) } }
            var values: [MeetingTranscriptionProgress] { lock.withLock { items } }
        }
        let box = DetailBox()
        _ = try await processor.processDetailed(store.captureDirectory, keepAudio: false) { box.append($0) }
        let details = box.values
        XCTAssertGreaterThanOrEqual(details.count, 3)
        XCTAssertEqual(details.first?.totalAudioSeconds ?? 0, 6, accuracy: 0.1)
        XCTAssertEqual(details.last?.fraction, 1)
        XCTAssertEqual(details.last?.processedAudioSeconds ?? 0, 6, accuracy: 0.1)
    }

    private func permissions(_ url: URL) throws -> Int { try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as! Int }
}

// MARK: - Service lifecycle

@MainActor
final class LocalMeetingServiceTests: XCTestCase {
    private var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("meeting-service-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { if let root { try? FileManager.default.removeItem(at: root) } }

    func testInitDoesNotStartCaptureDownloadOrLoadAnything() async throws {
        let engine = FakeEngine(ready: false)
        let capture = FakeCapture()
        let service = makeService(engine, capture)
        XCTAssertFalse(service.modelReady)
        XCTAssertTrue(service.needsModelSetup)
        XCTAssertEqual(capture.startCalls, 0)
        XCTAssertEqual(engine.prepareCalls, 0)
        XCTAssertEqual(engine.loadCalls, 0)
        XCTAssertEqual(service.transcription, .idle)
    }

    func testRecordingWorksWithoutTheSpeechModelAndIsTranscribedOnceItIsSetUp() async throws {
        let engine = FakeEngine(ready: false)
        let capture = FakeCapture()
        let service = makeService(engine, capture)
        try await service.start()
        XCTAssertEqual(service.phase, .recording, "Recording must never wait for a model")
        try capture.emit(.microphone)
        await service.stop()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.transcription, .waitingForModel(pending: 1))
        let saved = try XCTUnwrap(service.lastSavedURL)
        XCTAssertTrue(try String(contentsOf: saved, encoding: .utf8).contains("Transcript pending."))
        XCTAssertEqual(engine.recognizeCalls, 0)
        try await service.prepareModel()
        await service.waitForTranscription()
        XCTAssertTrue(service.modelReady)
        XCTAssertEqual(service.transcription, .idle)
        XCTAssertEqual(service.segments.map(\.speaker), ["You"])
        XCTAssertEqual(service.lastTranscriptURL, saved)
        XCTAssertEqual(service.pendingTranscriptionCount, 0)
    }

    func testNothingIsDecodedDuringTheMeetingAndStopReturnsBeforeTheTranscriptIsWritten() async throws {
        let engine = FakeEngine(holdRecognize: true)
        let capture = FakeCapture()
        capture.flushSources = [.microphone, .system]
        let service = makeService(engine, capture)
        try await service.start()
        for count in 1...40 { // More than the old 12-file inference backlog.
            try capture.emit(.system)
            try await waitUntil { capture.recordedSeconds >= Double(count) - 0.01 }
        }
        XCTAssertEqual(service.phase, .recording, "A long meeting can no longer outrun transcription")
        XCTAssertEqual(engine.loadCalls, 0)
        XCTAssertEqual(engine.recognizeCalls, 0)
        async let first: Void = service.stop()
        async let second: Void = service.stop()
        _ = await (first, second)
        XCTAssertEqual(capture.stopCalls, 1)
        XCTAssertEqual(service.phase, .idle, "The microphone is free as soon as the recording is saved")
        XCTAssertNotNil(service.lastSavedURL)
        try await waitUntil { engine.recognizeWaiting }
        if case .running = service.transcription {} else { XCTFail("Transcription should be running after capture") }
        // A second meeting can start while the first is still being transcribed.
        try await service.start()
        XCTAssertEqual(service.phase, .recording)
        try capture.emit(.microphone)
        await service.stop()
        engine.resumeRecognize()
        await service.waitForTranscription()
        XCTAssertEqual(service.transcription, .idle)
        XCTAssertEqual(service.pendingTranscriptionCount, 0)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("transcripts").path).count, 2)
        XCTAssertEqual(engine.unloadCalls, 1, "Models are released once every recording has its transcript")
        let first42 = try transcripts().first { $0.segments.count == 2 }
        XCTAssertEqual(first42?.segments.map(\.speaker), ["Speaker 1", "You"], "Forty seconds of call audio, then the final microphone file")
        XCTAssertEqual(first42?.recording?.durationSeconds ?? 0, 41, accuracy: 0.5)
    }

    func testRecordingsLeftByAQuitAreTranscribedAtTheNextLaunch() async throws {
        let store = try MeetingSessionStore(root: root.appendingPathComponent("transcripts"), workRoot: root.appendingPathComponent("work"))
        try TestAudio.chunk(in: store.captureDirectory, source: .system, start: 0, seconds: 2)
        let engine = FakeEngine()
        let service = makeService(engine, FakeCapture())
        XCTAssertEqual(service.pendingTranscriptionCount, 1)
        service.resumePendingTranscriptions()
        await service.waitForTranscription()
        XCTAssertEqual(service.pendingTranscriptionCount, 0)
        let document = try XCTUnwrap(transcripts().first)
        XCTAssertTrue(document.incomplete)
        XCTAssertEqual(document.segments.map(\.speaker), ["Speaker 1"])
    }

    func testFailedTranscriptionKeepsTheRecordingAndDoesNotRetryInALoop() async throws {
        let engine = FakeEngine(failures: 10)
        let capture = FakeCapture()
        let service = makeService(engine, capture)
        try await service.start()
        try capture.emit(.system)
        await service.stop()
        await service.waitForTranscription()
        XCTAssertEqual(service.transcription, .failed(pending: 1))
        XCTAssertEqual(engine.recognizeCalls, 1)
        XCTAssertEqual(service.pendingTranscriptionCount, 1, "The audio is still there for the next launch")
        XCTAssertEqual(service.phase, .idle)
    }

    func testKeepAudioPreferenceReachesTheOfflinePass() async throws {
        let capture = FakeCapture()
        let service = makeService(FakeEngine(), capture)
        service.keepsAudio = true
        try await service.start()
        try capture.emit(.system)
        await service.stop()
        await service.waitForTranscription()
        let transcript = try XCTUnwrap(service.lastTranscriptURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transcript.deletingLastPathComponent().appendingPathComponent("Audio/system.m4a").path))
    }

    func testImportedFilesGoThroughTheSameOfflinePass() async throws {
        let microphone = root.appendingPathComponent("mic.caf"), system = root.appendingPathComponent("sys.caf")
        try TestAudio.write(microphone, seconds: 3)
        try TestAudio.write(system, seconds: 25)
        let engine = FakeEngine()
        let service = makeService(engine, FakeCapture())
        let url = try await service.transcribeRecording(microphone: microphone, system: system)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(service.elapsedSeconds, 25, accuracy: 0.1)
        XCTAssertEqual(Set(service.segments.map(\.speakerLabel)), ["You", "Speaker 1"])
        XCTAssertEqual(engine.sampleCounts.sorted(), [3 * 16_000, 25 * 16_000])
        XCTAssertTrue(RecordingMetadataStore.isFinalized(url))
        XCTAssertEqual(MeetingSessionStore.readDocument(in: url.deletingLastPathComponent())?.recording?.sourceDevice, "imported_file")
    }

    func testStoppingSetupBlocksRecordingUntilAllSetupWorkReturns() async throws {
        let engine = FakeEngine(ready: false, holdPrepare: true)
        let capture = FakeCapture()
        let service = makeService(engine, capture)
        let setup = Task { try await service.prepareModel() }
        try await waitUntil { engine.prepareWaiting }
        let stop = Task { await service.stop() }
        try await waitUntil { service.phase == .finalizing }
        do { try await service.start(); XCTFail("Recording must wait for cancelled setup networking") }
        catch { XCTAssertEqual(error as? MeetingEngineError, .busy) }
        engine.resumePrepare()
        await stop.value
        _ = try? await setup.value
        XCTAssertEqual(capture.startCalls, 0)
        XCTAssertEqual(service.phase, .idle)
    }

    func testStopDuringCaptureStartupWaitsUntilCaptureIsStopped() async throws {
        let capture = FakeCapture()
        capture.holdStart = true
        let service = makeService(FakeEngine(), capture)
        let start = Task { try await service.start() }
        try await waitUntil { capture.startWaiting }
        let stop = Task { await service.stop() }
        await Task.yield()
        XCTAssertEqual(capture.stopCalls, 0)
        capture.resumeStart()
        await stop.value
        _ = try? await start.value
        XCTAssertEqual(capture.stopCalls, 1)
        XCTAssertEqual(service.phase, .idle)
    }

    func testStopCancelsPendingPermissionRequestBeforeItCanCapture() async throws {
        let capture = FakeCapture()
        capture.holdStart = true
        capture.honorsStartCancellation = true
        let service = makeService(FakeEngine(), capture)
        let start = Task { try await service.start() }
        try await waitUntil { capture.startWaiting }
        let stop = Task { await service.stop() }
        try await waitUntil { service.phase == .finalizing }
        capture.resumeStart()
        await stop.value
        _ = try? await start.value
        await service.waitForTranscription()
        XCTAssertTrue(capture.cancelledBeforeCapture)
        XCTAssertEqual(capture.stopCalls, 1)
        XCTAssertTrue(service.segments.isEmpty)
        XCTAssertEqual(service.phase, .idle)
    }

    func testSystemPurgeAutomaticallyResumesSameMeetingAndMarksTheGap() async throws {
        let capture = FakeCapture()
        let service = makeService(FakeEngine(), capture)
        try await service.start()
        try capture.emit(.microphone)
        capture.fail(.streamInterrupted(-3821)) // replayd high-urgency cache purge, observed Oct 14
        try await waitUntil { capture.startCalls == 2 && service.phase == .recording }
        XCTAssertNil(service.lastSavedURL, "Interruption must not end the meeting")
        try capture.emit(.system)
        await service.stop()
        await service.waitForTranscription()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(Set(service.segments.map(\.source)), Set(MeetingAudioSource.allCases))
        let document = try XCTUnwrap(transcripts().first)
        XCTAssertTrue(document.incomplete, "A gap must never be presented as a complete recording")
        XCTAssertTrue(document.notes.contains { $0.contains("automatically resumed") })
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("transcripts").path).count, 1)
    }

    func testUserSystemStopIsNeverAutomaticallyRestartedAndWhatWasRecordedIsTranscribed() async throws {
        let capture = FakeCapture()
        let service = makeService(FakeEngine(), capture)
        try await service.start()
        try capture.emit(.system)
        try await waitUntil { capture.recordedSeconds >= 0.99 }
        capture.fail(.captureStoppedByUser)
        try await waitUntil { service.phase == .failed }
        await service.waitForTranscription()
        XCTAssertEqual(capture.startCalls, 1)
        XCTAssertNotNil(service.lastSavedURL)
        XCTAssertEqual(try transcripts().first?.segments.count, 1)
    }

    func testStopDuringReconnectCancelsRetries() async throws {
        let capture = FakeCapture()
        let service = LocalMeetingService(transcriber: FakeEngine(), transcriptDirectory: root.appendingPathComponent("transcripts"),
            modelDirectory: root, workRoot: root.appendingPathComponent("work"), captureFactory: { capture }, retryDelay: 10)
        try await service.start()
        capture.fail(.streamInterrupted(-3821))
        try await waitUntil { service.phase == .recovering }
        await service.stop()
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(capture.startCalls, 1)
    }

    func testStopDuringRetryStartupWaitsAndNeverLeavesCaptureRunning() async throws {
        let capture = FakeCapture()
        let service = makeService(FakeEngine(), capture)
        try await service.start()
        capture.holdStart = true
        capture.honorsStartCancellation = true
        capture.fail(.streamInterrupted(-3821))
        try await waitUntil { capture.startWaiting }
        let stop = Task { await service.stop() }
        try await waitUntil { service.phase == .finalizing }
        capture.resumeStart()
        await stop.value
        XCTAssertTrue(capture.cancelledBeforeCapture)
        XCTAssertEqual(service.phase, .idle)
        XCTAssertEqual(capture.startCalls, 2)
    }

    func testPermissionAndUserStopsAreNotRetryable() {
        XCTAssertFalse(MeetingEngineError.streamInterrupted(-3801).canResumeCapture)
        XCTAssertFalse(MeetingEngineError.streamInterrupted(-3803).canResumeCapture)
        XCTAssertFalse(MeetingEngineError.captureStoppedByUser.canResumeCapture)
        XCTAssertTrue(MeetingEngineError.captureError(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3821)).canResumeCapture)
    }

    private func makeService(_ engine: FakeEngine, _ capture: FakeCapture) -> LocalMeetingService {
        LocalMeetingService(transcriber: engine, transcriptDirectory: root.appendingPathComponent("transcripts"),
                            modelDirectory: root.appendingPathComponent("models"), workRoot: root.appendingPathComponent("work"),
                            captureFactory: { capture }, retryDelay: 0.005)
    }
    private func transcripts() throws -> [MeetingDocument] {
        let folder = root.appendingPathComponent("transcripts")
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .compactMap { MeetingSessionStore.readDocument(in: $0) }.sorted { $0.startedAt < $1.startedAt }
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Timed out waiting for controlled test state")
    }
}

// MARK: - Fixtures

enum TestAudio {
    static func tone(seconds: Double, amplitude: Float = 0.2, sampleRate: Double = 16_000) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / Float(sampleRate)) }
    }

    static func write(_ url: URL, seconds: Double, amplitude: Float = 0.2, sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let samples = tone(seconds: seconds, amplitude: amplitude, sampleRate: sampleRate)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count))!
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for channel in 0..<Int(channels) { samples.withUnsafeBufferPointer { buffer.floatChannelData![channel].update(from: $0.baseAddress!, count: samples.count) } }
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file?.write(from: buffer)
        file = nil
    }

    /// A capture file exactly as the recorder leaves it: audio plus its description.
    @discardableResult
    static func chunk(in directory: URL, source: MeetingAudioSource, start: Double, seconds: Double, amplitude: Float = 0.2) throws -> MeetingChunk {
        let id = UUID()
        let url = directory.appendingPathComponent("\(id.uuidString)-\(source.rawValue).caf")
        try write(url, seconds: seconds, amplitude: amplitude)
        let chunk = MeetingChunk(id: id, source: source, startSeconds: start, durationSeconds: seconds, url: url,
                                 rms: amplitude / Float(2).squareRoot(), recordedAt: Date(timeIntervalSince1970: 1_800_000_000 + start),
                                 endedAt: Date(timeIntervalSince1970: 1_800_000_000 + start + seconds))
        try JSONEncoder().encode(chunk).write(to: url.appendingPathExtension("json"))
        return chunk
    }
}

final class ProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []
    func add(_ value: Double) { lock.lock(); stored.append(value); lock.unlock() }
    var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
}

/// Stands in for the speech models: one line and one voice per source, with controllable timing and failures.
final class FakeEngine: MeetingTranscribing, @unchecked Sendable {
    private let lock = NSLock()
    private var ready: Bool
    private var failures: Int
    private var holdPrepare: Bool
    private var holdRecognize: Bool
    private var prepareContinuation: CheckedContinuation<Void, Never>?
    private var recognizeContinuation: CheckedContinuation<Void, Never>?
    private var counters = (prepare: 0, load: 0, unload: 0, recognize: 0)
    private var samples: [Int] = []

    init(ready: Bool = true, failures: Int = 0, holdPrepare: Bool = false, holdRecognize: Bool = false) {
        self.ready = ready; self.failures = failures; self.holdPrepare = holdPrepare; self.holdRecognize = holdRecognize
    }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var assetsAvailable: Bool { locked { ready } }
    var speakerAssetsAvailable: Bool { locked { ready } }
    static let sentences = ["Synthetic meeting fixture", "Quarterly budget review tomorrow", "Please upload the draft", "Nothing else from me"]
    let speechModelName = "fake-speech"
    let speakerModelName = "fake-voices"
    var prepareCalls: Int { locked { counters.prepare } }
    var loadCalls: Int { locked { counters.load } }
    var unloadCalls: Int { locked { counters.unload } }
    var recognizeCalls: Int { locked { counters.recognize } }
    var sampleCounts: [Int] { locked { samples } }
    var prepareWaiting: Bool { locked { prepareContinuation != nil } }
    var recognizeWaiting: Bool { locked { recognizeContinuation != nil } }

    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        let hold = locked { () -> Bool in counters.prepare += 1; return holdPrepare }
        if hold { await withCheckedContinuation { continuation in locked { prepareContinuation = continuation } } }
        try Task.checkCancellation()
        locked { ready = true }
        progress(1)
    }
    func resumePrepare() {
        let continuation = locked { () -> CheckedContinuation<Void, Never>? in holdPrepare = false; defer { prepareContinuation = nil }; return prepareContinuation }
        continuation?.resume()
    }
    func load() async throws {
        let available = locked { () -> Bool in counters.load += 1; return ready }
        if !available { throw MeetingEngineError.modelMissing }
    }
    func unload() async { locked { counters.unload += 1 } }
    func recognize(_ audio: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingRecognition {
        let state = locked { () -> (hold: Bool, fail: Bool, text: String) in
            // Each source says something different, as real people do; identical words at the same
            // moment on both sources would rightly be treated as loudspeaker echo.
            let text = Self.sentences[counters.recognize % Self.sentences.count]
            counters.recognize += 1
            samples.append(audio.count)
            let fail = failures > 0
            if fail { failures -= 1 }
            return (holdRecognize, fail, text)
        }
        if state.hold { await withCheckedContinuation { continuation in locked { recognizeContinuation = continuation } } }
        if state.fail { throw MeetingEngineError.transcriptionFailed }
        progress(1)
        // Speech starts where the audio does: leading silence is the capture offset of this source.
        let first = Double(audio.firstIndex { $0 != 0 } ?? 0) / 16_000
        let end = Double(audio.count) / 16_000
        return MeetingRecognition(lines: [TimedText(startSeconds: first, endSeconds: end, text: state.text)],
                                  turns: [SpeakerTurn(speaker: 0, startSeconds: first, endSeconds: end)], languages: ["ko"])
    }
    func resumeRecognize() {
        let continuation = locked { () -> CheckedContinuation<Void, Never>? in holdRecognize = false; defer { recognizeContinuation = nil }; return recognizeContinuation }
        continuation?.resume()
    }
}

@MainActor
private final class FakeCapture: MeetingCapturing {
    var startCalls = 0
    var stopCalls = 0
    var flushSources: [MeetingAudioSource] = []
    var holdStart = false
    var startWaiting: Bool { startContinuation != nil }
    private var startContinuation: CheckedContinuation<Void, Never>?
    private var directory: URL!
    var honorsStartCancellation = false
    var cancelledBeforeCapture = false
    private var emittedChunks = 0
    private var offset: TimeInterval = 0
    private var continuation: AsyncThrowingStream<MeetingChunk, Error>.Continuation?
    private var onFailure: (@Sendable (MeetingEngineError) -> Void)?
    private(set) var sessionFolder: URL?
    /// Seconds of audio whose timing the service has durably recorded for the current meeting.
    var recordedSeconds: Double {
        guard let sessionFolder else { return 0 }
        return MeetingSessionStore.readDocument(in: sessionFolder)?.recording?.durationSeconds ?? 0
    }

    func start(directory: URL, startOffset: TimeInterval, onFailure: @escaping @Sendable (MeetingEngineError) -> Void) async throws -> AsyncThrowingStream<MeetingChunk, Error> {
        startCalls += 1
        self.directory = directory
        self.offset = max(startOffset, Double(emittedChunks))
        self.onFailure = onFailure
        if let marker = MeetingSessionStore.readMarker(in: directory) {
            sessionFolder = directory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("transcripts").appendingPathComponent(marker.sessionFolder)
        }
        let pair = AsyncThrowingStream<MeetingChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(12))
        continuation = pair.continuation
        if holdStart { await withCheckedContinuation { startContinuation = $0 } }
        if honorsStartCancellation && Task.isCancelled {
            cancelledBeforeCapture = true
            throw CancellationError()
        }
        return pair.stream
    }
    func resumeStart() { holdStart = false; startContinuation?.resume(); startContinuation = nil }
    func emit(_ source: MeetingAudioSource) throws {
        let chunk = try TestAudio.chunk(in: directory, source: source, start: Double(emittedChunks), seconds: 1)
        emittedChunks += 1
        if let continuation, case .dropped = continuation.yield(chunk) {
            continuation.finish(throwing: MeetingEngineError.backlogFull)
            onFailure?(.backlogFull)
        }
    }
    func fail(_ reason: MeetingEngineError = .captureFailed) { continuation?.finish(throwing: reason); onFailure?(reason) }
    func stop() async {
        stopCalls += 1
        for source in flushSources { try? emit(source) }
        continuation?.finish()
        continuation = nil
    }
}
