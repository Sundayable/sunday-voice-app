import Foundation
struct DiagnosticContext {
    struct Turn: Sendable { let id: String; let app: String? }
    @TaskLocal static var turn: Turn?
    struct Rewrite: Sendable { let id: String; let purpose: String }
    @TaskLocal static var rewrite: Rewrite?
    @TaskLocal static var rewriteProgress: RewriteProgress?
}

/// Content-free progress for one existing primary request. Only output needed for a committed
/// or final piece can earn a short grace period; silent/stalled providers keep the old deadline.
final class RewriteProgress: @unchecked Sendable {
    private let lock = NSLock()
    private let now: @Sendable () -> Double
    private var needed: Bool
    private var lastToken: Double?
    init(needed: Bool, now: @escaping @Sendable () -> Double = { uptime() }) {
        self.needed = needed; self.now = now
    }
    func markNeeded() { lock.withLock { needed = true } }
    func receivedToken() { lock.withLock { lastToken = now() } }
    var isNeeded: Bool { lock.withLock { needed } }
    var canExtend: Bool { lock.withLock { needed && lastToken.map { now() - $0 < 0.2 } == true } }
}
