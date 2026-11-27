import Foundation
import os

/// Seconds since boot (mach uptime). Same clock as CGEvent / Carbon event timestamps.
func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

/// Numeric timings and machine codes only. Never log transcripts, rewrite text or audio.
enum Log {
    static let subsystem = Bundle.main.bundleIdentifier ?? "ca.sundayable.sunday-voice"
    static let engine = Logger(subsystem: subsystem, category: "engine")
    static let stt = Logger(subsystem: subsystem, category: "stt")
    static let rewrite = Logger(subsystem: subsystem, category: "rewrite")
    static let input = Logger(subsystem: subsystem, category: "input")
    static let paste = Logger(subsystem: subsystem, category: "paste")
}

/// Rounds seconds → milliseconds with one decimal, for logs/stats.
func ms(_ seconds: Double) -> Double { (seconds * 10000).rounded() / 10 }

/// Internal failure with a stable machine code (worker.py's error codes). Never carries user text.
struct FailureCode: Error, Equatable, Sendable, CustomStringConvertible {
    var code: String
    init(_ code: String) { self.code = code }
    var description: String { code }

    static let noSpeech = FailureCode("no_speech")
    static let tooShort = FailureCode("recording_too_short")
    static let connectionLost = FailureCode("connection_lost")
    static let transcriptionFailed = FailureCode("transcription_failed")
    static let timeout = FailureCode("timeout")
    static let rewriteIncomplete = FailureCode("rewrite_incomplete")
    static let rewriteDetailsMissing = FailureCode("rewrite_details_missing")
    static let rewriteStreamError = FailureCode("rewrite_stream_error")
    static let notSignedIn = FailureCode("not_signed_in")
    static let quotaExceeded = FailureCode("quota_exceeded")
    static let serverOutdated = FailureCode("server_outdated")

    /// Map to the public error surface.
    var engineError: EngineError {
        switch code {
        case "no_speech": return .noSpeech
        case "recording_too_short": return .tooShort
        case "not_signed_in", "token_expired", "unauthorized": return .notSignedIn
        case "quota_exceeded": return .quotaExceeded
        case "microphone_denied": return .microphoneDenied
        case "accessibility_missing": return .accessibilityMissing
        case "input_monitoring_missing": return .inputMonitoringMissing
        default:
            if code == "connection_lost" || code == "timeout" || code.hasPrefix("network_") { return .network(code) }
            return .server(code)
        }
    }

    /// Classify any thrown error into a code. Cancellation is handled by callers before this.
    static func from(_ error: Error) -> FailureCode {
        if let f = error as? FailureCode { return f }
        if let u = error as? URLError { return FailureCode("network_\(u.code.rawValue)") }
        return FailureCode(String(describing: type(of: error)))
    }
}

/// Small cached NSRegularExpression wrapper so the quality checks read like worker.py.
struct Rx: @unchecked Sendable {
    let re: NSRegularExpression
    init(_ pattern: String, _ options: NSRegularExpression.Options = []) {
        // Patterns are compile-time constants; a bad one is a programming error.
        re = try! NSRegularExpression(pattern: pattern, options: options)
    }
    private func whole(_ s: String) -> NSRange { NSRange(location: 0, length: (s as NSString).length) }
    /// Python `re.search`.
    func search(_ s: String) -> Bool { re.firstMatch(in: s, range: whole(s)) != nil }
    /// Python `re.match` (anchored at the start).
    func matchStart(_ s: String) -> Bool { re.firstMatch(in: s, options: [.anchored], range: whole(s)) != nil }
    /// Python `re.findall` for a pattern without capture groups.
    func findAll(_ s: String) -> [String] {
        let ns = s as NSString
        return re.matches(in: s, range: whole(s)).map { ns.substring(with: $0.range) }
    }
    /// First capture group when the pattern matches the whole string (Python `re.fullmatch(...).group(1)`).
    func firstGroup(_ s: String) -> String? {
        guard let m = re.firstMatch(in: s, options: [.anchored], range: whole(s)), m.range.length == (s as NSString).length,
              m.numberOfRanges > 1, m.range(at: 1).location != NSNotFound else { return nil }
        return (s as NSString).substring(with: m.range(at: 1))
    }
    /// Python `re.sub` with a template (`$1` style).
    func sub(_ s: String, _ template: String) -> String {
        re.stringByReplacingMatches(in: s, range: whole(s), withTemplate: template)
    }
    /// Python `re.sub` with a function; `groups[0]` is the whole match.
    func sub(_ s: String, _ transform: ([String?]) -> String) -> String {
        let ns = s as NSString
        var out = ""; var last = 0
        for m in re.matches(in: s, range: whole(s)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let groups: [String?] = (0..<m.numberOfRanges).map { i in
                let r = m.range(at: i); return r.location == NSNotFound ? nil : ns.substring(with: r)
            }
            out += transform(groups)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }
}

/// FIFO async semaphore (asyncio.Semaphore). Waiting is cancellable. Main-actor isolated.
@MainActor
final class AsyncSemaphore {
    private var available: Int
    private var waiters: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    init(_ value: Int) { available = value }

    func acquire() async throws {
        try Task.checkCancellation()
        if available > 0 { available -= 1; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                waiters.append((id, c))
            }
        } onCancel: {
            Task { @MainActor in self.cancelWaiter(id) }
        }
    }

    func release() {
        if !waiters.isEmpty { waiters.removeFirst().continuation.resume() } else { available += 1 }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// asyncio.Event with an optional timeout on wait. Main-actor isolated.
@MainActor
final class AsyncFlag {
    private(set) var isSet = false
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func set() {
        guard !isSet else { return }
        isSet = true
        let all = waiters; waiters.removeAll()
        for c in all.values { c.resume() }
    }

    /// Waits until set; throws `FailureCode.timeout` after `timeout` seconds, or CancellationError.
    func wait(timeout: Double) async throws {
        if isSet { return }
        let id = UUID()
        let timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9))
            if !Task.isCancelled { self?.resolve(id, FailureCode.timeout) }
        }
        defer { timer.cancel() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                if isSet { c.resume() } else { waiters[id] = c }
            }
        } onCancel: {
            Task { @MainActor in self.resolve(id, CancellationError()) }
        }
    }

    private func resolve(_ id: UUID, _ error: Error) {
        waiters.removeValue(forKey: id)?.resume(throwing: error)
    }
}

/// Runs `operation`, throwing `FailureCode.timeout` if it does not finish in `seconds`.
/// An optional, one-time grace keeps an already-progressing required request alive; no retry.
/// The operation is cancelled on timeout (asyncio.wait_for semantics).
func withDeadline<T: Sendable>(_ seconds: Double, grace: Double = 0,
                             shouldExtend: @escaping @Sendable () -> Bool = { false },
                             _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    let race = DeadlineRace<T>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            race.add(Task {
                do { race.resolve(.success(try await operation())) }
                catch { race.resolve(.failure(error)) }
            })
            race.add(Task {
                do { try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1e9)) }
                catch { return }
                if grace > 0 && shouldExtend() {
                    do { try await Task.sleep(nanoseconds: UInt64(grace * 1e9)) }
                    catch { return }
                }
                race.resolve(.failure(FailureCode.timeout))
            })
        }
    } onCancel: { race.resolve(.failure(CancellationError())) }
}

/// Unlike a task group, a deadline must not wait for an uncooperative provider/Task.value to exit.
/// First resolution wins; late results cannot paste or resume the continuation again.
private final class DeadlineRace<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<T, Error>?
    private var continuation: CheckedContinuation<T, Error>?
    private var tasks: [Task<Void, Never>] = []
    func install(_ value: CheckedContinuation<T, Error>) {
        let ready = lock.withLock { () -> Result<T, Error>? in
            if let result { return result }
            continuation = value; return nil
        }
        if let ready { value.resume(with: ready) }
    }
    func add(_ task: Task<Void, Never>) {
        let done = lock.withLock { if result != nil { return true }; tasks.append(task); return false }
        if done { task.cancel() }
    }
    func resolve(_ value: Result<T, Error>) {
        let resolved = lock.withLock { () -> (CheckedContinuation<T, Error>?, [Task<Void, Never>]) in
            guard result == nil else { return (nil, []) }
            result = value
            let c = continuation, t = tasks; continuation = nil; tasks = []
            return (c, t)
        }
        resolved.1.forEach { $0.cancel() }; resolved.0?.resume(with: value)
    }
}

/// Thread-safe "first time only" flag (from main.swift).
final class Once: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func first() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// Lock-protected value box for cross-thread counters.
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock(); private var value: Value
    init(_ value: Value) { self.value = value }
    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.lock(); defer { lock.unlock() }; return body(&value) }
    var get: Value { withValue { $0 } }
}
