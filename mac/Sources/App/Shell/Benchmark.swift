import AppKit
import ApplicationServices
import DictationEngine

/// Local diagnostics (enabled only with `defaults write <bundle id> diagnostics -bool true`):
/// `<scheme>://diagnostic/benchmark?mode=bilingual|english&n=10&fixture=mixed`
/// Plays a bundled recording through the real path (STT → rewrite → paste) into the frontmost
/// TextEdit document (or explicitly selected Slack/browser QA field) and measures release → text visible (AX read-back). Writes
/// ~/Library/Application Support/SundayVoice/benchmark.json. Fixture text only; no user speech.
@MainActor
enum Benchmark {
    /// Fixed 1,500-word synthetic input only. Never reads the clipboard or user documents.
    /// Uses the signed-in app's normal Tidy path and writes counts/timing, not text.
    static func runTidyFixture(apiBaseURL: URL, tokens: AccessTokenProvider) async {
        let source = (1000..<1075).map {
            "Please review item \($0) and confirm the schedule before Friday. The team needs this update for the next planning meeting."
        }.joined(separator: "\n\n")
        let started = uptime()
        var row: [String: Any] = ["source_words": source.split(whereSeparator: \.isWhitespace).count,
                                   "source_chars": source.count, "version": Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? ""]
        do {
            let result = try await Tidier(apiBaseURL: apiBaseURL, tokens: tokens).tidy(source)
            row["ok"] = true; row["result_chars"] = result.text.count; row["changed"] = result.changed
            row["all_75_item_numbers_preserved"] = (1000..<1075).allSatisfy { result.text.contains(String($0)) }
        } catch {
            row["ok"] = false; row["error"] = String(describing: error)
        }
        row["elapsed_ms"] = ((uptime() - started) * 10000).rounded() / 10
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SundayVoice")
        let file = dir.appendingPathComponent("tidy-benchmark.json")
        if let data = try? JSONSerialization.data(withJSONObject: row, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }

    static func run(_ url: URL, engine: DictationEngineProtocol) async {
        guard let real = engine as? DictationEngine else { return }
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ k: String) -> String? { q.first { $0.name == k }?.value }
        let modes: [DictationMode] = (value("mode") ?? "bilingual,english").split(separator: ",").compactMap { DictationMode(rawValue: String($0)) }
        let n = min(20, max(1, Int(value("n") ?? "10") ?? 10))
        let fixture = value("fixture") ?? "mixed"
        guard let wav = Bundle.main.url(forResource: fixture, withExtension: "wav"), let data = try? Data(contentsOf: wav) else { return }
        let clip = data.subdata(in: 44..<data.count)
        let seconds = min(600, max(0, Double(value("seconds") ?? "0") ?? 0))
        var pcm = clip
        if seconds > 0 {
            let wanted = Int(seconds * 48_000)
            pcm = Data(); pcm.reserveCapacity(wanted)
            while pcm.count < wanted { pcm.append(clip.prefix(min(clip.count, wanted - pcm.count))) }
        }
        // Only these explicitly selected QA apps are supported. The caller prepares and
        // focuses a disposable document/draft first; this never sends a Return key.
        let target = value("target") ?? "textedit"
        let bundles = ["textedit": "com.apple.TextEdit", "slack": "com.tinyspeck.slackmacgap", "browser": "at.studio.AsideBrowser"]
        guard let bundle = bundles[target],
              let edit = NSRunningApplication.runningApplications(withBundleIdentifier: bundle).first else { return }
        var rows: [[String: Any]] = []
        for mode in modes {
            for i in 0..<n {
                edit.activate()
                try? await Task.sleep(nanoseconds: 600_000_000)
                let before = focusedValue(edit) ?? ""
                guard let released = await real.runFixture(pcm, mode: mode) else { rows.append(["mode": mode.rawValue, "run": i, "error": "start"]); continue }
                var text: String?
                let deadline = uptime() + 45
                while uptime() < deadline {
                    if case .pasted(let t) = real.state { text = t }
                    if case .failed(let e) = real.state { rows.append(["mode": mode.rawValue, "run": i, "error": "\(e)"]); break }
                    if let t = text, let now = focusedValue(edit), now.count >= before.count + t.count, now.contains(t) {
                        rows.append(["target": target, "mode": mode.rawValue, "run": i, "release_to_visible_ms": ((uptime() - released) * 10000).rounded() / 10, "text": t, "verified": true, "source_audio_seconds": Double(pcm.count) / 48_000,
                                     "final_chars": t.count, "clipboard_match": NSPasteboard.general.string(forType: .string) == t])
                        break
                    }
                    try? await Task.sleep(nanoseconds: 3_000_000)
                }
                if uptime() >= deadline { rows.append(["mode": mode.rawValue, "run": i, "error": "timeout"]) }
                try? await Task.sleep(nanoseconds: 700_000_000)
            }
        }
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/SundayVoice")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let out = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) {
            try? out.write(to: dir.appendingPathComponent("benchmark.json"))
        }
    }

    static func focusedValue(_ app: NSRunningApplication) -> String? {
        var focused: CFTypeRef?, value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(app.processIdentifier), kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let element = focused, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        _ = AXUIElementCopyAttributeValue(element as! AXUIElement, kAXValueAttribute as CFString, &value)
        return value as? String
    }
}
