/// A fake provider that ignores cancellation until the test explicitly releases it.
/// This checks completion ordering without depending on subsecond scheduler latency.
actor SuspendedTestProvider {
    private var continuation: CheckedContinuation<String, Never>?
    private var released = false

    func wait() async -> String {
        guard !released else { return "late provider response" }
        return await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume(returning: "late provider response")
        continuation = nil
    }
}
