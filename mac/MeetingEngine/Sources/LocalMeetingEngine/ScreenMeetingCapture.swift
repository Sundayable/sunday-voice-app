import AVFoundation
import CoreMedia
import ScreenCaptureKit
import OSLog

@available(macOS 15.0, *)
@MainActor
final class ScreenMeetingCapture: MeetingCapturing {
    private var stream: SCStream?
    private var output: MeetingCaptureOutput?

    func start(directory: URL, startOffset: TimeInterval, onFailure: @escaping @Sendable (MeetingEngineError) -> Void) async throws -> AsyncThrowingStream<MeetingChunk, Error> {
        try Task.checkCancellation()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: break
        case .notDetermined:
            guard await AVCaptureDevice.requestAccess(for: .audio) else { throw MeetingEngineError.microphoneDenied }
        default: throw MeetingEngineError.microphoneDenied
        }
        // Permission responses may arrive after Stop; never turn a cancelled request into capture.
        try Task.checkCancellation()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
            throw MeetingEngineError.noDisplay
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.captureMicrophone = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16_000
        config.channelCount = 1
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false
        config.queueDepth = 3
        // Register audio outputs only. No screen output, screenshot, or video is read or stored.
        let pair = AsyncThrowingStream<MeetingChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(12))
        let output = MeetingCaptureOutput(directory: directory, startOffset: startOffset, continuation: pair.continuation, onFailure: onFailure)
        self.output = output
        let stream = SCStream(filter: filter, configuration: config, delegate: output)
        self.stream = stream
        try stream.addStreamOutput(output, type: .audio, sampleHandlerQueue: output.queue)
        try stream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: output.queue)
        do {
            try Task.checkCancellation()
            try await stream.startCapture()
            try Task.checkCancellation()
        } catch {
            try? await stream.stopCapture()
            await output.finish()
            self.stream = nil
            self.output = nil
            throw error
        }
        output.startWatchdog()
        return pair.stream
    }

    func stop() async {
        if let stream { try? await stream.stopCapture() }
        if let output { await output.finish() }
        stream = nil
        output = nil
    }
}

@available(macOS 15.0, *)
private final class MeetingCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "ca.sundayable.meetings.audio", qos: .userInitiated)
    private let directory: URL
    private let continuation: AsyncThrowingStream<MeetingChunk, Error>.Continuation
    private let onFailure: @Sendable (MeetingEngineError) -> Void
    private let startOffset: TimeInterval
    private var watchdog: DispatchSourceTimer?
    private var lastBuffer: [MeetingAudioSource: TimeInterval] = [:]
    private let log = Logger(subsystem: "ca.sundayable.sunday-voice", category: "meeting-capture")
    private let hostStart = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
    private let wallStart = Date()
    private var writers: [MeetingAudioSource: ChunkWriter] = [:]
    private var accepting = true

    init(directory: URL, startOffset: TimeInterval, continuation: AsyncThrowingStream<MeetingChunk, Error>.Continuation, onFailure: @escaping @Sendable (MeetingEngineError) -> Void) {
        self.directory = directory
        self.startOffset = startOffset
        self.continuation = continuation
        self.onFailure = onFailure
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard accepting, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let source: MeetingAudioSource
        switch type {
        case .microphone: source = .microphone
        case .audio: source = .system
        default: return
        }
        lastBuffer[source] = ProcessInfo.processInfo.systemUptime
        do {
            guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(description),
                  let format = AVAudioFormat(streamDescription: streamDescription),
                  format.commonFormat == .pcmFormatFloat32 || format.commonFormat == .pcmFormatInt16 else {
                throw MeetingEngineError.audioFormat
            }
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
            buffer.frameLength = AVAudioFrameCount(frames)
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sampleBuffer, at: 0, frameCount: Int32(frames), into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw MeetingEngineError.audioFormat }
            if let writer = writers[source], !writer.format.isEqual(format) { try close(source: source, emit: true) }
            let timestamp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) - hostStart
            if writers[source] == nil {
                writers[source] = try ChunkWriter(source: source, startSeconds: startOffset + max(0, timestamp.isFinite ? timestamp : 0),
                                                  directory: directory, format: format,
                                                  recordedAt: timestamp.isFinite ? wallStart.addingTimeInterval(timestamp) : nil)
            }
            try writers[source]?.append(buffer, endedAt: timestamp.isFinite ? wallStart.addingTimeInterval(timestamp + Double(frames) / format.sampleRate) : nil)
            if let writer = writers[source], writer.durationSeconds >= 20 { try close(source: source, emit: true) }
        } catch {
            fail(error)
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        queue.async {
            self.log.error("stream_stopped code=\(code, privacy: .public)")
            self.fail(code == -3817 ? MeetingEngineError.captureStoppedByUser : MeetingEngineError.streamInterrupted(code))
        }
    }

    func finish() async {
        await withCheckedContinuation { continuation in
            queue.async {
                self.watchdog?.cancel(); self.watchdog = nil
                do {
                    for source in Array(self.writers.keys) { try self.close(source: source, emit: self.accepting) }
                    self.accepting = false
                    self.continuation.finish()
                } catch { self.fail(error) }
                continuation.resume()
            }
        }
    }

    func startWatchdog() {
        queue.async {
            guard self.accepting else { return }
            let started = ProcessInfo.processInfo.systemUptime
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + 5, repeating: 5)
            timer.setEventHandler { [weak self] in
                guard let self, self.accepting else { return }
                let now = ProcessInfo.processInfo.systemUptime
                for source in MeetingAudioSource.allCases {
                    // Buffer arrival, not volume: quiet or muted speech is not a failure.
                    if now - (self.lastBuffer[source] ?? started) > 20 {
                        self.log.error("capture_stalled source=\(source.rawValue, privacy: .public)")
                        self.fail(MeetingEngineError.captureStalled)
                        return
                    }
                }
            }
            self.watchdog = timer
            timer.resume()
        }
    }

    private func close(source: MeetingAudioSource, emit: Bool) throws {
        guard let writer = writers.removeValue(forKey: source) else { return }
        let chunk = try writer.finish()
        log.notice("capture_chunk source=\(source.rawValue, privacy: .public) start=\(chunk.startSeconds, privacy: .public) duration=\(chunk.durationSeconds, privacy: .public)")
        guard emit else { return }
        if case .dropped = continuation.yield(chunk) { fail(MeetingEngineError.backlogFull) }
    }

    private func fail(_ error: Error) {
        guard accepting else { return }
        accepting = false
        watchdog?.cancel(); watchdog = nil
        let reason = error as? MeetingEngineError ?? .captureFailed
        onFailure(reason) // Alert immediately, without waiting for transcription to drain.
        // Flush accepted speech before the error. A rejected chunk still remains on disk.
        for source in Array(writers.keys) { try? close(source: source, emit: true) }
        continuation.finish(throwing: reason)
    }
}

private final class ChunkWriter {
    let id = UUID()
    let source: MeetingAudioSource
    let startSeconds: TimeInterval
    let format: AVAudioFormat
    private let url: URL
    private var file: AVAudioFile?
    private var frames: AVAudioFrameCount = 0
    private var squares: Double = 0
    private var count = 0
    private let recordedAt: Date?
    private var endedAt: Date?
    var durationSeconds: TimeInterval { Double(frames) / format.sampleRate }

    init(source: MeetingAudioSource, startSeconds: TimeInterval, directory: URL, format: AVAudioFormat, recordedAt: Date?) throws {
        self.source = source
        self.startSeconds = startSeconds
        self.format = format
        self.recordedAt = recordedAt
        self.url = directory.appendingPathComponent("\(id.uuidString)-\(source.rawValue).caf")
        file = try AVAudioFile(forWriting: url, settings: format.settings, commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func append(_ buffer: AVAudioPCMBuffer, endedAt: Date?) throws {
        self.endedAt = endedAt
        try file?.write(from: buffer)
        frames += buffer.frameLength
        let metrics = MeetingAudioMetrics.energy(buffer)
        squares += metrics.squares
        count += metrics.count
    }

    func finish() throws -> MeetingChunk {
        file = nil
        let chunk = MeetingChunk(id: id, source: source, startSeconds: startSeconds, durationSeconds: durationSeconds,
                                 url: url, rms: count > 0 ? Float(sqrt(squares / Double(count))) : 0, recordedAt: recordedAt, endedAt: endedAt)
        try MeetingSessionStore.privateWrite(JSONEncoder().encode(chunk), to: url.appendingPathExtension("json"))
        return chunk
    }
}

enum MeetingAudioMetrics {
    static func energy(_ buffer: AVAudioPCMBuffer) -> (squares: Double, count: Int) {
        let channels = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let lanes = buffer.format.isInterleaved ? 1 : channels
        let laneSamples = buffer.format.isInterleaved ? frameCount * channels : frameCount
        var total: Double = 0
        if let samples = buffer.floatChannelData {
            for lane in 0..<lanes { for index in 0..<laneSamples { let value = Double(samples[lane][index]); total += value * value } }
        } else if let samples = buffer.int16ChannelData {
            for lane in 0..<lanes { for index in 0..<laneSamples { let value = Double(samples[lane][index]) / 32768; total += value * value } }
        }
        return (total, frameCount * channels)
    }
}

@MainActor
final class UnavailableMeetingCapture: MeetingCapturing {
    func start(directory: URL, startOffset: TimeInterval, onFailure: @escaping @Sendable (MeetingEngineError) -> Void) async throws -> AsyncThrowingStream<MeetingChunk, Error> {
        throw MeetingEngineError.unsupportedOS
    }
    func stop() async {}
}
