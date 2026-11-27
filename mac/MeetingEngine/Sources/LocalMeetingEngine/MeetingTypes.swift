import Foundation

/// Capture lifecycle only. Transcription runs after capture and has its own state.
public enum MeetingPhase: String, Equatable, Sendable {
    case idle, preparing, recording, recovering, finalizing, failed
}

/// Live progress of the offline transcription pass for the current recording.
public struct MeetingTranscriptionProgress: Equatable, Sendable {
    /// Overall fraction in 0...1 (model load, voice separation, and speech decoding).
    public var fraction: Double
    /// Audio seconds processed so far on the meeting timeline (0...totalAudioSeconds).
    public var processedAudioSeconds: Double
    /// Total meeting audio seconds to transcribe (0 before audio length is known).
    public var totalAudioSeconds: Double
    /// Smoothed estimated seconds remaining; nil until enough decoding throughput is measured.
    public var estimatedRemainingSeconds: Double?

    public init(fraction: Double,
                processedAudioSeconds: Double = 0,
                totalAudioSeconds: Double = 0,
                estimatedRemainingSeconds: Double? = nil) {
        self.fraction = min(1, max(0, fraction))
        self.processedAudioSeconds = max(0, processedAudioSeconds)
        self.totalAudioSeconds = max(0, totalAudioSeconds)
        self.estimatedRemainingSeconds = estimatedRemainingSeconds.map { max(0, $0) }
    }

    public var isAlmostDone: Bool {
        fraction >= 0.94 || (estimatedRemainingSeconds.map { $0 < 8 } ?? false)
    }
}

/// Estimates smoothed remaining transcription time from live measured throughput.
/// Pure and clock-injected so both the engine and unit tests share identical math.
public struct TranscriptionETAEstimator: Sendable {
    private let minimumElapsedSeconds: TimeInterval
    private let minimumFraction: Double
    private var startedAt: TimeInterval?
    private var lastSampleAt: TimeInterval?
    private var lastCompletedWork: Double = 0
    private var smoothedRate: Double?
    private var smoothedETA: Double?

    public init(minimumElapsedSeconds: TimeInterval = 1.5, minimumFraction: Double = 0.03) {
        self.minimumElapsedSeconds = minimumElapsedSeconds
        self.minimumFraction = minimumFraction
    }

    /// Marks the start of the timed decoding phase (excludes one-time model load / diarization overhead).
    public mutating func start(at now: TimeInterval) {
        startedAt = now
        lastSampleAt = now
        lastCompletedWork = 0
        smoothedRate = nil
        smoothedETA = nil
    }

    /// Records progress (`completedWork` out of `totalWork`) at `now` and returns a smoothed ETA in seconds.
    public mutating func update(completedWork: Double, totalWork: Double, now: TimeInterval) -> Double? {
        guard totalWork > 0 else { return nil }
        let clampedDone = min(totalWork, max(0, completedWork))
        let remaining = totalWork - clampedDone
        if remaining <= 0.001 {
            smoothedETA = 0
            return 0
        }
        if startedAt == nil { start(at: now) }
        guard let startedAt else { return nil }
        let elapsed = now - startedAt
        let fraction = clampedDone / totalWork
        guard elapsed >= minimumElapsedSeconds, clampedDone > 0, fraction >= minimumFraction else {
            return nil
        }

        let cumulativeRate = clampedDone / elapsed
        var measuredRate = cumulativeRate
        if let lastSampleAt, now - lastSampleAt >= 0.25, clampedDone > lastCompletedWork {
            let instantRate = (clampedDone - lastCompletedWork) / (now - lastSampleAt)
            // Blend cumulative stability with recent pace so speed shifts reflect smoothly without spikes.
            measuredRate = 0.35 * instantRate + 0.65 * cumulativeRate
        }
        if let previousRate = smoothedRate {
            smoothedRate = 0.35 * measuredRate + 0.65 * previousRate
        } else {
            smoothedRate = measuredRate
        }
        self.lastSampleAt = now
        self.lastCompletedWork = clampedDone

        guard let rate = smoothedRate, rate > 0.001 else { return nil }
        let rawETA = remaining / rate
        if let previousETA = smoothedETA {
            smoothedETA = 0.35 * rawETA + 0.65 * previousETA
        } else {
            smoothedETA = rawETA
        }
        return smoothedETA
    }
}

/// What the offline pass is doing with saved recordings. Never blocks a new recording.
public enum MeetingTranscriptionState: Equatable, Sendable {
    case idle
    /// Recordings are saved; the speech models have not been set up on this Mac yet.
    case waitingForModel(pending: Int)
    case running(progress: Double, pending: Int, detail: MeetingTranscriptionProgress? = nil)
    case failed(pending: Int)
}

/// Independent audio sources. Speakers inside one source are separated after the meeting.
public enum MeetingAudioSource: String, Codable, CaseIterable, Sendable {
    case microphone, system
    public var label: String { self == .microphone ? "You" : "Meeting audio" }
}

public struct MeetingSegment: Identifiable, Codable, Equatable, Sendable {
    public let id: String
    public let source: MeetingAudioSource
    public let startSeconds: TimeInterval
    public let endSeconds: TimeInterval
    public let text: String
    /// Display label for the person speaking ("You", "Speaker 2"). Nil in transcripts made before
    /// speaker separation, where only the source is known.
    public var speaker: String?

    public init(id: String, source: MeetingAudioSource, startSeconds: TimeInterval, endSeconds: TimeInterval, text: String, speaker: String? = nil) {
        self.id = id
        self.source = source
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
        self.text = text
        self.speaker = speaker
    }

    public var speakerLabel: String { speaker ?? source.label }
}

/// One uninterrupted stretch of a single voice inside one audio source.
struct SpeakerTurn: Equatable, Sendable {
    let speaker: Int
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
}

/// Recognized text with times relative to the start of the audio it was decoded from.
struct TimedText: Equatable, Sendable {
    let startSeconds: TimeInterval
    let endSeconds: TimeInterval
    let text: String
    /// Set when the audio this line was decoded from held a single known voice.
    var voice: Int? = nil
}

struct MeetingChunk: Codable, Sendable {
    let id: UUID
    let source: MeetingAudioSource
    let startSeconds: TimeInterval
    let durationSeconds: TimeInterval
    let url: URL
    let rms: Float
    var recordedAt: Date? = nil
    var endedAt: Date? = nil
}

/// How a finished transcript was produced. All of it happened on this Mac.
struct MeetingTranscriptionInfo: Codable, Equatable, Sendable {
    var speechModel: String
    var speakerModel: String?
    var languages: [String]
    var audioSeconds: Double
    var processingSeconds: Double
    var speakerCount: Int
}

struct MeetingDocument: Codable, Sendable {
    let version: Int
    let sessionID: UUID
    let startedAt: Date
    var finishedAt: Date?
    var model: String
    var segments: [MeetingSegment]
    var recoveredChunkCount: Int
    var incomplete: Bool
    var notes: [String]
    var recording: RecordingMetadata? = nil
    /// Set when capture has ended and the audio is safely on disk, before any transcription.
    var recordingEndedAt: Date? = nil
    var transcription: MeetingTranscriptionInfo? = nil
    /// File names under `Audio/` kept beside the transcript when the user chose to keep recordings.
    var audioFiles: [String]? = nil
}

enum MeetingEngineError: LocalizedError, Equatable {
    case busy, modelMissing, invalidModel, unsupportedOS, noDisplay, microphoneDenied
    case audioFormat, captureFailed, backlogFull, fileTooLong, invalidFile
    case modelDownload, saveFailed, transcriptionFailed
    case streamInterrupted(Int), captureStalled, captureStoppedByUser

    var errorDescription: String? {
        switch self {
        case .busy: return "A meeting operation is already in progress."
        case .modelMissing: return "Set up the local speech model to transcribe your saved recordings."
        case .invalidModel: return "The local model files are incomplete. Run model setup again."
        case .unsupportedOS: return "Meeting audio capture requires macOS 15 or later."
        case .noDisplay: return "No display is available for system audio capture."
        case .microphoneDenied: return "Allow Microphone access in System Settings to record your voice."
        case .audioFormat: return "The audio device changed to an unsupported format. Your partial transcript has been kept."
        case .captureFailed: return "Audio capture stopped. Your partial transcript has been kept."
        case .backlogFull: return "The recording could not be written fast enough. Recording stopped and the saved audio was kept."
        case .fileTooLong: return "The audio file is too long to import."
        case .invalidFile: return "The audio file could not be read."
        case .modelDownload: return "The local model download did not finish. Run setup again when connected."
        case .saveFailed: return "The meeting could not be saved. Captured audio remains in the local recovery folder."
        case .transcriptionFailed: return "The recording is saved, but the transcript could not be written. It will be tried again."
        case .streamInterrupted(let code): return "macOS interrupted audio capture (\(code))."
        case .captureStalled: return "Audio stopped arriving from a recording source."
        case .captureStoppedByUser: return "Recording was stopped in macOS. Choose Start to record again."
        }
    }

    var canResumeCapture: Bool {
        switch self {
        case .captureFailed, .captureStalled, .audioFormat: return true
        case .streamInterrupted(let code): return [-3802, -3804, -3805, -3811, -3814, -3815, -3818, -3820, -3821].contains(code)
        default: return false
        }
    }

    static func captureError(_ error: Error) -> Self {
        if let known = error as? Self { return known }
        let ns = error as NSError
        if ns.domain == "com.apple.ScreenCaptureKit.SCStreamErrorDomain" {
            return ns.code == -3817 ? .captureStoppedByUser : .streamInterrupted(ns.code)
        }
        return .captureFailed
    }
}

/// What the offline pass found in one audio source.
struct MeetingRecognition: Sendable {
    var lines: [TimedText]
    /// Empty when voices could not be separated; the transcript is still written.
    var turns: [SpeakerTurn]
    var languages: [String]
}

/// The speech models. Used only after a recording has ended; capture never touches them.
protocol MeetingTranscribing: Sendable {
    var assetsAvailable: Bool { get }
    var speakerAssetsAvailable: Bool { get }
    var speechModelName: String { get }
    var speakerModelName: String { get }
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws
    func load() async throws
    func unload() async
    /// One whole source (16 kHz mono) on the meeting clock.
    func recognize(_ samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingRecognition
    /// Multi-source offline pass sharing one progress & ETA timeline across all audible tracks.
    func recognizeTracks(_ tracks: [(source: MeetingAudioSource, samples: [Float])],
                         meetingAudioSeconds: Double,
                         progress: @escaping @Sendable (MeetingTranscriptionProgress) -> Void) async throws -> [MeetingAudioSource: MeetingRecognition]
}

extension MeetingTranscribing {
    func recognizeTracks(_ tracks: [(source: MeetingAudioSource, samples: [Float])],
                         meetingAudioSeconds: Double,
                         progress: @escaping @Sendable (MeetingTranscriptionProgress) -> Void) async throws -> [MeetingAudioSource: MeetingRecognition] {
        guard !tracks.isEmpty else {
            progress(MeetingTranscriptionProgress(fraction: 1, processedAudioSeconds: meetingAudioSeconds, totalAudioSeconds: meetingAudioSeconds, estimatedRemainingSeconds: 0))
            return [:]
        }
        var results: [MeetingAudioSource: MeetingRecognition] = [:]
        let totalTracks = Double(tracks.count)
        let tracker = DefaultTrackProgressTracker(totalAudioSeconds: meetingAudioSeconds, totalTracks: totalTracks, progress: progress)
        for (index, track) in tracks.enumerated() {
            try Task.checkCancellation()
            results[track.source] = try await recognize(track.samples) { value in
                tracker.update(trackIndex: index, trackFraction: value)
            }
            tracker.update(trackIndex: index, trackFraction: 1)
        }
        return results
    }
}

private final class DefaultTrackProgressTracker: @unchecked Sendable {
    private let lock = NSLock()
    private let totalAudioSeconds: Double
    private let totalTracks: Double
    private let progress: @Sendable (MeetingTranscriptionProgress) -> Void
    private var estimator = TranscriptionETAEstimator()

    init(totalAudioSeconds: Double, totalTracks: Double, progress: @escaping @Sendable (MeetingTranscriptionProgress) -> Void) {
        self.totalAudioSeconds = totalAudioSeconds
        self.totalTracks = totalTracks
        self.progress = progress
        estimator.start(at: ProcessInfo.processInfo.systemUptime)
    }

    func update(trackIndex: Int, trackFraction: Double) {
        let clamped = min(1, max(0, trackFraction))
        let overall = (Double(trackIndex) + clamped) / totalTracks
        let processed = totalAudioSeconds * overall
        let eta: Double? = lock.withLock {
            estimator.update(completedWork: processed, totalWork: max(totalAudioSeconds, 1), now: ProcessInfo.processInfo.systemUptime)
        }
        progress(MeetingTranscriptionProgress(fraction: overall,
                                              processedAudioSeconds: processed,
                                              totalAudioSeconds: totalAudioSeconds,
                                              estimatedRemainingSeconds: eta))
    }
}

@MainActor
protocol MeetingCapturing: AnyObject {
    func start(directory: URL, startOffset: TimeInterval, onFailure: @escaping @Sendable (MeetingEngineError) -> Void) async throws -> AsyncThrowingStream<MeetingChunk, Error>
    func stop() async
}
