import Foundation
import OSLog

enum MeetingCaptureRecovery: Equatable {
    case interrupted, resumed
}

/// Keeps a single meeting stream open across macOS capture-daemon/device interruptions.
/// This pump never runs inference, so reconnection and alerts cannot wait behind the decoder.
@MainActor
final class ResilientMeetingCapture: MeetingCapturing {
    private let factory: @MainActor () -> any MeetingCapturing
    private let onRecovery: @MainActor (MeetingCaptureRecovery) -> Void
    private let retryDelay: TimeInterval
    private let retryLimit: Int
    private let log = Logger(subsystem: "ca.sundayable.sunday-voice", category: "meeting-recovery")
    private var capture: (any MeetingCapturing)?
    private var runner: Task<Void, Never>?
    private var stopped = false
    private var waiting = false
    private var announced = false
    private var generation = UUID()
    private var terminalFailure: (@Sendable (MeetingEngineError) -> Void)?
    private var opening: Task<AsyncThrowingStream<MeetingChunk, Error>, Error>?
    private var closing: Task<Void, Never>?

    init(factory: @escaping @MainActor () -> any MeetingCapturing, retryDelay: TimeInterval = 1,
         retryLimit: Int = 5, onRecovery: @escaping @MainActor (MeetingCaptureRecovery) -> Void) {
        self.factory = factory; self.retryDelay = retryDelay; self.retryLimit = retryLimit
        self.onRecovery = onRecovery
    }

    func start(directory: URL, startOffset: TimeInterval,
               onFailure: @escaping @Sendable (MeetingEngineError) -> Void) async throws -> AsyncThrowingStream<MeetingChunk, Error> {
        stopped = false
        terminalFailure = onFailure
        let began = ProcessInfo.processInfo.systemUptime
        var stream = try await open(directory: directory, offset: startOffset)
        let pair = AsyncThrowingStream<MeetingChunk, Error>.makeStream(bufferingPolicy: .bufferingOldest(12))
        runner = Task { [self] in
            var attempts = 0
            var healthySince = ProcessInfo.processInfo.systemUptime
            while true {
                var reason: MeetingEngineError = .captureFailed
                do {
                    for try await chunk in stream {
                        if case .dropped = pair.continuation.yield(chunk) { throw MeetingEngineError.backlogFull }
                    }
                    if stopped { break }
                } catch { reason = .captureError(error) }
                if stopped { break }
                if !reason.canResumeCapture { fail(reason, continuation: pair.continuation); return }
                announceInterruption()
                generation = UUID() // Late callbacks from the retired stream cannot affect the new one.
                await closeCapture()
                if ProcessInfo.processInfo.systemUptime - healthySince >= 60 { attempts = 0 }
                var opened = false
                while !stopped && attempts < retryLimit {
                    attempts += 1
                    log.notice("capture_retry attempt=\(attempts, privacy: .public)")
                    waiting = true
                    do { try await Task.sleep(for: .seconds(min(15, retryDelay * pow(2, Double(attempts - 1))))) }
                    catch { waiting = false; break }
                    waiting = false
                    guard !stopped else { break }
                    do {
                        stream = try await open(directory: directory, offset: startOffset + ProcessInfo.processInfo.systemUptime - began)
                        guard !stopped else { await closeCapture(); break }
                        announced = false
                        healthySince = ProcessInfo.processInfo.systemUptime
                        onRecovery(.resumed)
                        log.notice("capture_resumed")
                        opened = true
                        break
                    } catch {
                        reason = .captureError(error)
                        await closeCapture()
                        if !reason.canResumeCapture { break }
                    }
                }
                if stopped { break }
                if !opened { fail(reason, continuation: pair.continuation); return }
            }
            pair.continuation.finish()
        }
        return pair.stream
    }

    private func open(directory: URL, offset: TimeInterval) async throws -> AsyncThrowingStream<MeetingChunk, Error> {
        let token = UUID(); generation = token
        let next = factory(); capture = next
        let task = Task {
            try await next.start(directory: directory, startOffset: offset) { [weak self] reason in
                Task { @MainActor in
                    guard let self, !self.stopped, self.generation == token else { return }
                    if reason.canResumeCapture { self.announceInterruption() }
                    else { self.terminalFailure?(reason) }
                }
            }
        }
        opening = task
        defer { opening = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func announceInterruption() {
        guard !announced else { return }
        announced = true
        onRecovery(.interrupted)
    }

    private func fail(_ reason: MeetingEngineError, continuation: AsyncThrowingStream<MeetingChunk, Error>.Continuation) {
        continuation.finish(throwing: reason)
        terminalFailure?(reason)
    }

    func stop() async {
        stopped = true
        generation = UUID()
        if waiting { runner?.cancel() }
        if let opening { opening.cancel(); _ = try? await opening.value }
        await closeCapture()
        await runner?.value
        runner = nil; capture = nil
    }

    private func closeCapture() async {
        if let closing { await closing.value; return }
        guard let current = capture else { return }
        let task = Task { await current.stop() }
        closing = task
        await task.value
        capture = nil; closing = nil
    }
}
