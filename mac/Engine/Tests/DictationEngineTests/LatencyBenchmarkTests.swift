import AppKit
import Foundation
import XCTest
@testable import DictationEngine

/// Explicit opt-in, synthetic PCM only. No microphone, installed app, focus, general clipboard,
/// keyboard events or Keychain. Runs unchanged in the 0.3.6 and 0.3.8 source trees.
@MainActor
final class LatencyBenchmarkTests: XCTestCase {
    func testSyntheticLatencyMatrix() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["SV_LATENCY_APPROVED"] == "1", let directory = env["SV_LATENCY_DIR"],
              let endpoint = env["SV_LATENCY_BASE"], let label = env["SV_LATENCY_LABEL"] else { throw XCTSkip("explicit benchmark only") }
        let token = try String(contentsOfFile: env["SV_LATENCY_TOKEN_FILE"] ?? directory + "/token", encoding: .utf8)
        let metrics = LatencyMetrics()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = 4; configuration.timeoutIntervalForRequest = 50; configuration.urlCache = nil
        if let path = env["SV_PREVIEW_AUTH_FILE"] {
            guard URL(string: endpoint)?.host?.hasSuffix("-sundayable.vercel.app") == true else { throw FailureCode("invalid_preview_host") }
            configuration.httpAdditionalHeaders = ["x-vercel-protection-bypass": try String(contentsOfFile: path, encoding: .utf8)]
        }
        let session = URLSession(configuration: configuration, delegate: metrics, delegateQueue: nil)
        let server = ServerClient(baseURL: try XCTUnwrap(URL(string: endpoint)), tokens: LatencyToken(token), session: session)
        let socket = RealtimeSTTSocket(server: server)
        let pipeline = TurnPipeline(socket: socket, rewriter: server)
        defer { pipeline.shutdown(); session.invalidateAndCancel() }
        var rows: [[String: Any]] = []
        let report = directory + "/" + label + ".json"
        let samples = min(10, max(1, Int(env["SV_LATENCY_N"] ?? "5") ?? 5))
        let lengths = (env["SV_LATENCY_LENGTHS"] ?? "short,long").split(separator: ",").map(String.init)
        guard !lengths.isEmpty, lengths.allSatisfy({ ["short", "long"].contains($0) }) else { throw FailureCode("invalid_benchmark_lengths") }
        // Interleave conditions, retaining the normal warm session across turns.
        for run in 0..<samples {
            for (language, mode) in [("ko", DictationMode.bilingual), ("en", .english)] {
                for length in lengths {
                    let pcm = try Data(contentsOf: URL(fileURLWithPath: directory + "/" + language + "-" + length + ".pcm"))
                    let id = UUID().uuidString
                    var result: (String, TurnPipeline.Stats)?, failures: [String] = []
                    var firstTextAt: Double?
                    let turnBegan = uptime()
                    pipeline.onEvent = {
                        if case .checkpoint(_, let text) = $0, !text.isEmpty, firstTextAt == nil { firstTextAt = uptime() }
                        if case .result(_, let text, let stats) = $0 { result = (text, stats) }
                        if case .error(_, let code) = $0 { failures.append(code) }
                    }
                    try await socket.connect()
                    let connectMS = ms(uptime() - turnBegan)
                    metrics.reset()
                    await pipeline.start(id: id, mode: mode, app: nil)
                    let began = uptime()
                    for at in stride(from: 0, to: pcm.count, by: 2400) {
                        pipeline.audio(pcm.subdata(in: at..<min(at + 2400, pcm.count)))
                        let remaining = began + Double(min(at + 2400, pcm.count)) / 48_000 - uptime()
                        if remaining > 0 { try await Task.sleep(nanoseconds: UInt64(remaining * 1e9)) }
                    }
                    let released = uptime(); pipeline.stop(releasedAt: released)
                    while result == nil && failures.isEmpty && uptime() - released < 45 { try await Task.sleep(nanoseconds: 2_000_000) }
                    var row: [String: Any] = ["run": run, "id": id, "language": language, "length": length, "audioSeconds": Double(pcm.count)/48_000, "errors": failures, "at": ISO8601DateFormatter().string(from: Date())]
                    row["connectMs"] = connectMS
                    row["startToFirstTextMs"] = firstTextAt.map { ms($0 - turnBegan) } ?? -1
                    if let (text, stats) = result {
                        row["releaseToReadyMs"] = stats.releaseToReadyMs
                        row["releaseToSTTFinalMs"] = stats.releaseToSTTFinalMs
                        row["rewriteTailMs"] = stats.releaseToReadyMs - stats.releaseToSTTFinalMs
                        row["fallbacks"] = stats.fallbacks; row["audioComplete"] = stats.audioComplete
                        row["characters"] = text.count
                        row["languageOK"] = (text.range(of: "[가-힣]", options: .regularExpression) != nil) == (language == "ko")
                        let lower = text.lowercased()
                        let detailsOK = language == "ko"
                            ? lower.contains("내일") && (lower.contains("세 시") || lower.contains("세시") || lower.contains("3"))
                            : lower.contains("tomorrow") && (lower.contains("three") || lower.contains("3"))
                        row["detailsOK"] = detailsOK
                        // Keep gold-word recognition separate from the transport/latency verdict.
                        // A provider homophone error must stay visible; never silently correct the fixture.
                        XCTAssertTrue(row["languageOK"] as? Bool == true)
                        // Private pasteboard + NSTextView's real paste implementation. Does not send
                        // Command-V or touch Dan's clipboard; external AX latency remains separate.
                        let pasteStart = uptime(), board = NSPasteboard(name: NSPasteboard.Name("SVLatency-" + id))
                        board.clearContents(); board.setString(text, forType: .string)
                        let field = NSTextView(); field.readSelection(from: board)
                        row["isolatedPasteMs"] = ms(uptime() - pasteStart)
                        row["releaseToIsolatedPasteMs"] = ms(uptime() - released)
                        row["pasteVerified"] = field.string == text
                        board.releaseGlobally()
                    }
                    row["requests"] = metrics.snapshot()
                    rows.append(row)
                    let data = try JSONSerialization.data(withJSONObject: ["label": label, "base": endpoint, "nPerCell": samples, "pasteMethod": "private pasteboard into isolated NSTextView; excludes external AX/keyboard", "results": rows], options: [.prettyPrinted, .sortedKeys])
                    try data.write(to: URL(fileURLWithPath: report), options: .atomic)
                    print("LATENCY \(label) \(language) \(length) run=\(run) ready_ms=\(result?.1.releaseToReadyMs ?? -1) stt_ms=\(result?.1.releaseToSTTFinalMs ?? -1) fallbacks=\(result?.1.fallbacks ?? -1)")
                    XCTAssertNotNil(result, "no result: \(failures)")
                    XCTAssertTrue(result?.1.audioComplete ?? false)
                    if result == nil { return } // Never replay a paid uncertain turn.
                    try await Task.sleep(nanoseconds: 500_000_000)
                }
            }
        }
    }
}
private final class LatencyToken: AccessTokenProvider, @unchecked Sendable {
    let token: String
    init(_ token: String) { self.token = token }
    func accessToken() async throws -> String { token }
}
private final class LatencyMetrics: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let lock = NSLock()
    private var rows: [[String: Any]] = []
    func reset() { lock.lock(); rows = []; lock.unlock() }
    func snapshot() -> [[String: Any]] { lock.lock(); defer { lock.unlock() }; return rows }
    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        let values: [[String: Any]] = metrics.transactionMetrics.map { m in
            func milliseconds(_ start: Date?, _ end: Date?) -> Double { guard let start, let end else { return -1 }; return (end.timeIntervalSince(start) * 1000).rounded() }
            return ["path": m.request.url?.path ?? "", "uploadMs": milliseconds(m.requestStartDate, m.requestEndDate),
                    "attempt": m.request.value(forHTTPHeaderField: "X-Rewrite-Attempt") ?? "", "purpose": m.request.value(forHTTPHeaderField: "X-Rewrite-Purpose") ?? "",
                    "waitMs": milliseconds(m.requestEndDate, m.responseStartDate), "downloadMs": milliseconds(m.responseStartDate, m.responseEndDate),
                    "status": (m.response as? HTTPURLResponse)?.statusCode ?? 0,
                    "serverTiming": (m.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Server-Timing") ?? ""]
        }
        lock.lock(); rows += values; lock.unlock()
    }
}
