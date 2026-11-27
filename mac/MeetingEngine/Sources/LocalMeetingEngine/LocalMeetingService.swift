import AVFoundation
import Combine
import Foundation

@MainActor
public final class LocalMeetingService: ObservableObject {
    @Published public private(set) var phase: MeetingPhase = .idle
    @Published public private(set) var statusMessage = "Meeting audio stays on this Mac."
    @Published public private(set) var segments: [MeetingSegment] = []
    @Published public private(set) var elapsedSeconds: TimeInterval = 0
    @Published public private(set) var modelReady: Bool
    @Published public private(set) var setupProgress: Double = 0
    @Published public private(set) var lastSavedURL: URL?
    @Published public private(set) var captureWarning: String?
    /// Offline transcript work for saved recordings. Independent of `phase`: a new meeting can be recorded meanwhile.
    @Published public private(set) var transcription: MeetingTranscriptionState = .idle
    @Published public private(set) var speakerModelReady: Bool
    /// The most recently completed transcript. `lastSavedURL` is set as soon as a recording is safe on disk.
    @Published public private(set) var lastTranscriptURL: URL?
    public var recordingContext: RecordingMeetingContext?
    /// Keep a compact copy of each source beside the transcript after it is written.
    public var keepsAudio = false
    public var audioRetentionDays = 30
    public let transcriptDirectory: URL
    public let modelDirectory: URL

    public static var defaultTranscriptDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SundayVoice/Meetings", isDirectory: true)
    }
    public static var defaultModelDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SundayVoice/MeetingModels", isDirectory: true)
    }

    private let transcriber: any MeetingTranscribing
    private let captureFactory: @MainActor () -> any MeetingCapturing
    private let workRoot: URL
    private var capture: (any MeetingCapturing)?
    private var store: MeetingSessionStore?
    private var activeSession: UUID?
    private let processor: MeetingPostProcessor
    private var transcriptionTask: Task<Void, Never>?
    private var transcriptionRun = UUID()
    private var deferred: Set<URL> = []
    private var consumer: Task<Void, Never>?
    private var startup: Task<AsyncThrowingStream<MeetingChunk, Error>, Error>?
    private var modelSetup: Task<Void, Error>?
    private var stopping: Task<Void, Never>?
    private var clock: Task<Void, Never>?
    private var operation = UUID()
    private var failure: String?
    private var interruptions = 0
    private var gapStartedAt: TimeInterval?
    private let retryDelay: TimeInterval

    public convenience init(transcriptDirectory: URL? = nil, modelDirectory: URL? = nil, workDirectory: URL? = nil) {
        let modelDirectory = modelDirectory ?? Self.defaultModelDirectory
        self.init(transcriber: WhisperMeetingTranscriber(directory: modelDirectory), transcriptDirectory: transcriptDirectory ?? Self.defaultTranscriptDirectory,
                  modelDirectory: modelDirectory,
                  workRoot: workDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SundayVoice/MeetingCapture"),
                  captureFactory: {
                      if #available(macOS 15.0, *) { return ScreenMeetingCapture() }
                      return UnavailableMeetingCapture()
                  })
    }

    init(transcriber: any MeetingTranscribing, transcriptDirectory: URL, modelDirectory: URL, workRoot: URL,
         captureFactory: @escaping @MainActor () -> any MeetingCapturing, retryDelay: TimeInterval = 1) {
        self.transcriber = transcriber
        self.transcriptDirectory = transcriptDirectory
        self.modelDirectory = modelDirectory
        self.workRoot = workRoot
        self.captureFactory = captureFactory
        self.retryDelay = retryDelay
        self.modelReady = transcriber.assetsAvailable
        self.speakerModelReady = transcriber.speakerAssetsAvailable
        self.processor = MeetingPostProcessor(root: transcriptDirectory, workRoot: workRoot, engine: transcriber)
    }

    /// True when a model download would add something: the speech model or voice separation is missing.
    public var needsModelSetup: Bool { !modelReady || !speakerModelReady }

    /// Explicit setup action only. Initialization and meeting detection never download a model.
    public func prepareModel() async throws {
        guard phase == .idle || phase == .failed else { throw MeetingEngineError.busy }
        let token = UUID()
        operation = token
        phase = .preparing
        setupProgress = 0
        statusMessage = "Downloading the local speech models…"
        do {
            let modelSetup = Task { [transcriber, weak self] in
                try await transcriber.prepare { [weak self] progress in
                    Task { @MainActor in
                        guard let self, self.operation == token else { return }
                        self.setupProgress = progress
                        self.statusMessage = progress < 0.94 ? "Downloading local model — \(Int(progress * 100))%" : "Preparing the model on this Mac…"
                    }
                }
            }
            self.modelSetup = modelSetup
            try await modelSetup.value
            guard operation == token else { throw CancellationError() }
            self.modelSetup = nil
            modelReady = transcriber.assetsAvailable
            speakerModelReady = transcriber.speakerAssetsAvailable
            phase = .idle
            setupProgress = 1
            statusMessage = "Speech models ready. Recordings are transcribed on this Mac."
            startTranscription()
        } catch {
            if operation == token {
                modelSetup = nil
                modelReady = transcriber.assetsAvailable
                speakerModelReady = transcriber.speakerAssetsAvailable
                phase = .failed
                statusMessage = Self.safeMessage(error, fallback: "Local model setup did not finish. Try setup again.")
            }
            throw error
        }
    }

    /// The only live-capture entry point; the caller must obtain an explicit action or the enabled automatic-start preference.
    /// Recording needs no speech model: audio goes straight to disk and is transcribed after the meeting.
    public func start() async throws {
        guard phase == .idle || phase == .failed, stopping == nil else { throw MeetingEngineError.busy }
        let token = UUID()
        operation = token
        phase = .preparing
        failure = nil
        interruptions = 0
        captureWarning = nil
        lastSavedURL = nil
        segments = []
        elapsedSeconds = 0
        statusMessage = "Starting the recording…"
        do {
            let store = try MeetingSessionStore(root: transcriptDirectory, workRoot: workRoot, context: recordingContext)
            self.store = store
            activeSession = store.sessionID
            let capture = ResilientMeetingCapture(factory: captureFactory, retryDelay: retryDelay) { [weak self] state in
                guard let self, self.operation == token else { return }
                switch state {
                case .interrupted:
                    self.interruptions += 1
                    self.gapStartedAt = self.elapsedSeconds
                    self.phase = .recovering
                    self.statusMessage = "Audio interrupted — reconnecting automatically. Keep this meeting open."
                    self.captureWarning = self.statusMessage
                case .resumed:
                    if let start = self.gapStartedAt {
                        let end = self.elapsedSeconds
                        Task { try? await store.recordGap(from: start, to: end) }
                    }
                    self.gapStartedAt = nil
                    self.phase = .recording
                    self.statusMessage = "Recording resumed — the gap is marked in your transcript."
                    self.captureWarning = nil
                }
            }
            self.capture = capture
            let directory = store.captureDirectory
            let startup = Task {
                try await capture.start(directory: directory, startOffset: 0) { [weak self] reason in
                    Task { @MainActor in
                        guard let self, self.operation == token else { return }
                        self.failure = reason.localizedDescription
                        self.captureWarning = reason.localizedDescription
                        await self.stop()
                    }
                }
            }
            self.startup = startup
            let chunks = try await startup.value
            guard operation == token else { throw CancellationError() }
            self.startup = nil
            phase = captureWarning == nil ? .recording : .recovering
            statusMessage = captureWarning ?? "Recording on this Mac — microphone + Mac audio"
            let startedAt = Date()
            clock = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    guard !Task.isCancelled else { return }
                    self?.elapsedSeconds = Date().timeIntervalSince(startedAt)
                }
            }
            // Each element is a finished audio file. Only its timing is noted here; nothing is decoded during the meeting.
            consumer = Task { [weak self] in
                do {
                    for try await chunk in chunks { try await store.observe(chunk) }
                } catch {
                    self?.failure = Self.safeMessage(error, fallback: MeetingEngineError.captureFailed.localizedDescription)
                    if self?.phase == .recording || self?.phase == .recovering {
                        Task { [weak self] in await self?.stop() }
                    }
                }
            }
        } catch {
            // A concurrent stop owns cleanup after it invalidates this start token.
            if operation == token {
                failure = Self.safeMessage(error, fallback: "Meeting capture could not start. Check Microphone and Screen & System Audio permissions in System Settings.")
                await stop()
            }
            throw error
        }
    }

    /// Idempotent, including during capture startup. Returns once capture has ended and the recording is safe on disk.
    /// The transcript is written afterwards without holding the microphone.
    public func stop() async {
        if let stopping { await stopping.value; return }
        let stopping = Task<Void, Never> { [weak self] in
            guard let self else { return }
            await self.performStop()
        }
        self.stopping = stopping
        await stopping.value
        self.stopping = nil
    }

    private func performStop() async {
        operation = UUID() // An awaiting startup cannot later start capture.
        let hadSession = store != nil || capture != nil
        if hadSession || modelSetup != nil { phase = .finalizing; statusMessage = "Saving the recording…" }
        // A new recording cannot start while cancelled setup still has network work in flight.
        if let modelSetup {
            modelSetup.cancel()
            _ = try? await modelSetup.value
            self.modelSetup = nil
            modelReady = transcriber.assetsAvailable
            speakerModelReady = transcriber.speakerAssetsAvailable
        }
        clock?.cancel()
        clock = nil
        if let startup {
            startup.cancel()
            _ = try? await startup.value
        }
        startup = nil
        await capture?.stop()
        await consumer?.value
        consumer = nil
        var saved = false
        if let store {
            do {
                lastSavedURL = try await store.finishRecording(incomplete: failure != nil || interruptions > 0,
                    note: failure ?? (interruptions > 0 ? "Audio capture was interrupted \(interruptions) time(s) and automatically resumed. Gaps may be missing from this transcript." : nil))
                saved = true
            } catch { failure = MeetingEngineError.saveFailed.localizedDescription }
        }
        capture = nil
        store = nil
        activeSession = nil
        phase = failure == nil ? .idle : .failed
        statusMessage = failure ?? (hadSession ? (transcriber.assetsAvailable ? "Recording saved. The transcript is being written on this Mac."
                                                                             : "Recording saved. Set up the speech model to get the transcript.")
                                               : "Meeting audio stays on this Mac.")
        if saved { startTranscription() }
    }

    // MARK: - After the meeting

    /// Picks up every saved recording that has no transcript yet, including ones left by a quit or crash.
    /// Call at launch; it is also run after each recording and after model setup.
    public func resumePendingTranscriptions() { startTranscription() }

    public var pendingTranscriptionCount: Int { processor.pending(excluding: activeSession).count }

    private func startTranscription() {
        guard transcriptionTask == nil else { return }
        let waiting = processor.pending(excluding: activeSession).filter { !deferred.contains($0) }
        guard !waiting.isEmpty else {
            if case .running = transcription { transcription = .idle }
            if case .waitingForModel = transcription { transcription = .idle }
            return
        }
        guard transcriber.assetsAvailable else { transcription = .waitingForModel(pending: waiting.count); return }
        let run = UUID()
        transcriptionRun = run
        transcription = .running(progress: 0, pending: waiting.count)
        transcriptionTask = Task { [weak self] in await self?.drain(run) }
    }

    private func drain(_ run: UUID) async {
        var failed = 0
        while !Task.isCancelled, transcriptionRun == run {
            let waiting = processor.pending(excluding: activeSession).filter { !deferred.contains($0) }
            guard let next = waiting.first else { break }
            let count = waiting.count
            transcription = .running(progress: 0, pending: count, detail: MeetingTranscriptionProgress(fraction: 0))
            do {
                let keep = keepsAudio
                let url = try await processor.processDetailed(next, keepAudio: keep) { [weak self] detail in
                    Task { @MainActor in
                        guard let self, self.transcriptionRun == run, case .running = self.transcription else { return }
                        self.transcription = .running(progress: detail.fraction, pending: count, detail: detail)
                    }
                }
                lastTranscriptURL = url
                if phase == .idle || phase == .failed {
                    lastSavedURL = url
                    segments = MeetingSessionStore.readDocument(in: url.deletingLastPathComponent())?.segments ?? []
                    if phase == .idle { statusMessage = segments.isEmpty ? "Transcript saved. No speech was detected." : "Transcript ready on this Mac." }
                }
            } catch is CancellationError {
                break
            } catch {
                if (error as? MeetingEngineError) == .modelMissing {
                    modelReady = transcriber.assetsAvailable
                    transcription = .waitingForModel(pending: count)
                    transcriptionTask = nil
                    return
                }
                failed += 1
                deferred.insert(next) // Tried again at the next launch, at most three times in total.
            }
        }
        // Models are needed only between meetings; holding them would cost memory all day.
        await processor.unload()
        if keepsAudio { processor.pruneAudio(olderThan: audioRetentionDays) }
        guard transcriptionRun == run else { return }
        transcriptionTask = nil
        let left = processor.pending(excluding: activeSession).filter { !deferred.contains($0) }
        if !left.isEmpty && !Task.isCancelled { startTranscription(); return }
        transcription = failed > 0 ? .failed(pending: failed) : .idle
        if failed > 0, phase == .idle { statusMessage = MeetingEngineError.transcriptionFailed.localizedDescription }
    }

    /// Stops offline work without touching saved audio; it resumes at the next launch.
    public func cancelTranscription() {
        transcriptionRun = UUID()
        transcriptionTask?.cancel()
        transcriptionTask = nil
        if case .running = transcription { transcription = .idle }
    }

    /// Waits for the current offline pass. For tests and the command-line check.
    public func waitForTranscription() async {
        while let task = transcriptionTask { await task.value }
    }

    /// Imports local audio files as one recording and runs the same offline pass a meeting gets.
    /// Never opens a microphone or a network connection.
    @discardableResult
    public func transcribeRecording(microphone: URL? = nil, system: URL? = nil) async throws -> URL {
        guard phase == .idle || phase == .failed, stopping == nil, transcriptionTask == nil else { throw MeetingEngineError.busy }
        var files: [(MeetingAudioSource, URL)] = []
        if let microphone { files.append((.microphone, microphone)) }
        if let system { files.append((.system, system)) }
        guard !files.isEmpty, files.allSatisfy({ $0.1.isFileURL }) else { throw MeetingEngineError.invalidFile }
        guard transcriber.assetsAvailable else { throw MeetingEngineError.modelMissing }
        let token = UUID()
        operation = token
        phase = .preparing
        failure = nil
        interruptions = 0
        lastSavedURL = nil
        segments = []
        statusMessage = "Transcribing the local audio file…"
        do {
            let store = try MeetingSessionStore(root: transcriptDirectory, workRoot: workRoot, sourceDevice: "imported_file")
            let directory = store.captureDirectory
            var seconds = 0.0
            for (source, url) in files {
                let length = try await Task.detached { try MeetingAudioAssembler.importFile(url, as: source, into: directory) }.value
                seconds = max(seconds, length)
            }
            guard operation == token else { throw CancellationError() }
            elapsedSeconds = seconds
            _ = try await store.finishRecording(incomplete: false)
            let run = UUID()
            transcriptionRun = run
            transcription = .running(progress: 0, pending: 1, detail: MeetingTranscriptionProgress(fraction: 0, totalAudioSeconds: seconds))
            let keep = keepsAudio
            let url = try await processor.processDetailed(directory, keepAudio: keep) { [weak self] detail in
                Task { @MainActor in
                    guard let self, self.transcriptionRun == run, case .running = self.transcription else { return }
                    self.transcription = .running(progress: detail.fraction, pending: 1, detail: detail)
                }
            }
            await processor.unload()
            transcription = .idle
            lastSavedURL = url
            lastTranscriptURL = url
            segments = MeetingSessionStore.readDocument(in: url.deletingLastPathComponent())?.segments ?? []
            phase = .idle
            statusMessage = "Local file transcript saved."
            return url
        } catch {
            transcription = .idle
            if operation == token {
                phase = .failed
                statusMessage = Self.safeMessage(error, fallback: "Local file transcription failed. No audio was sent anywhere.")
            }
            throw error
        }
    }

    private static func safeMessage(_ error: Error, fallback: String) -> String {
        (error as? MeetingEngineError)?.localizedDescription ?? fallback
    }
}
