import AppKit
import AVFoundation
import ApplicationServices
import Speech
import os
import DictationEngine

/// Hands-free dictation started by a wake phrase ("헤이 첼로" / "헤이 그룻").
///
/// The phrase itself is spotted on-device by macOS Vocal Shortcuts, which then opens
/// `<scheme>://wake/<target>`. This controller focuses the target chat input, starts a dictation
/// without a held key, and listens on-device (Speech framework, never the network) for the end phrase
/// "입력했어" / "입력완료" (or a final "엔터") → stop, strip the phrase, paste, press Return. A long silence stops without Return.
/// No audio or text is stored or logged here.
@MainActor
final class WakeController {
    enum Target: String {
        case cello, grok, aside
        /// Telegram bot chats (username); nil = Grok Bot desktop app.
        var telegramBot: String? {
            switch self {
            case .cello: return "Cellomello_bot"
            case .aside: return "ANNH4J2XXVO21UNI3HKENB_bot"
            case .grok: return nil
            }
        }
        var bundleID: String { telegramBot == nil ? "com.anysphere.sand" : "ru.keepcoder.Telegram" }
    }
    /// Last text Sunday Voice inserted per app (memory only, never stored or logged).
    private var lastInserted: [String: String] = [:]
    /// The target of the current hands-free session (re-opened right before delivery).
    private var currentTarget: Target?

    private let log = Logger(subsystem: "ca.sundayable.sunday-voice", category: "wake")
    private let engine: DictationEngine
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    /// Same request, appended to straight from the audio queue (append is thread-safe).
    nonisolated(unsafe) private var liveRequest: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var watchdog: Timer?
    private var startedAt = 0.0, lastChangeAt = 0.0, lastPartial = ""
    private var finishing = false
    private var enterTimer: Timer?
    /// Wait this long after a trailing "엔터" for more words before sending.
    var enterPause = 0.8

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "wakeEnabled") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "wakeEnabled") }
    }
    /// End-phrase hints for the on-device recognizer and the STT prompt (default on; `wakeHints` = false to compare).
    static var hints: Bool { UserDefaults.standard.object(forKey: "wakeHints") as? Bool ?? true }
    static let endPhraseWords = ["입력완료", "입력 완료", "입력했어", "엔터"]
    /// Testing: do everything except pressing Return.
    static var dryRun: Bool { UserDefaults.standard.bool(forKey: "wakeDryRun") }

    /// Stop without Return after this much silence (no new partial words).
    var silenceSeconds = 3.5
    /// Give up if nothing at all was recognized this long after the start.
    var noSpeechSeconds = 12.0

    init?(engine: DictationEngineProtocol) {
        guard let engine = engine as? DictationEngine else { return nil }
        self.engine = engine
        engine.onHandsFreeAudio = { [weak self] data in self?.feed(data) }
        engine.onHandsFreeInserted = { [weak self] bundleID, text in if let bundleID { self?.lastInserted[bundleID] = text } }
        engine.prepareHandsFreeDelivery = { [weak self] bundleID in self?.refocus(bundleID) ?? 0.25 }
    }

    func handle(_ url: URL) {
        guard url.host == "wake", let target = Target(rawValue: url.lastPathComponent) else { return }
        guard Self.enabled else { log.info("wake_ignored_disabled"); return }
        let t0 = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in await self.run(target, t0: t0) }
    }

    /// Diagnostics (`defaults write … diagnostics -bool true`): focus the target like a wake, then send a
    /// fixed transcript through the same hands-free delivery. Deterministic test without a microphone.
    func debugDeliver(_ url: URL) {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard let target = Target(rawValue: value("target") ?? "cello"), let text = value("text"), !text.isEmpty else { return }
        let submit = value("submit") == "1"
        Task { @MainActor in
            self.currentTarget = target
            let focused = await self.focus(target)
            let bundleID = target.bundleID
            self.log.notice("debug_handsfree focused=\(focused, privacy: .public) front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "nil", privacy: .public)")
            guard focused, NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID else { return }
            self.engine.debugDeliverHandsFree(text, submit: submit)
            if !submit, value("cleanup") == "1" {
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID {
                    Self.postKey(0, flags: .maskCommand); Self.postKey(51)
                    self.lastInserted[bundleID] = nil
                    self.log.notice("debug_handsfree_cleaned")
                }
            }
        }
    }

    /// Diagnostics: `<scheme>://diagnostic/handsfreebench?dir=/path` — for each `*.wav` (24 kHz mono 16-bit)
    /// with a sidecar `<name>.json` {"speech_end": seconds}, stream it as a hands-free turn and record
    /// end-phrase detection lag, release-to-ready and the stripped text into `<dir>/results.json`.
    func bench(_ url: URL) {
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let dirPath = q.first(where: { $0.name == "dir" })?.value else { return }
        let dir = URL(fileURLWithPath: dirPath)
        Task { @MainActor in
            var rows: [[String: Any]] = []
            let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "wav" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for wav in files {
                guard let data = try? Data(contentsOf: wav), let r = data.range(of: Data("data".utf8)) else { continue }
                let pcm = data.subdata(in: (r.upperBound + 4)..<data.count)
                let meta = (try? JSONSerialization.jsonObject(with: Data(contentsOf: wav.deletingPathExtension().appendingPathExtension("json")))) as? [String: Any] ?? [:]
                let speechEnd = meta["speech_end"] as? Double ?? 0
                self.startRecognizer(); self.finishing = false; self.endPhraseSeenAt = nil
                var out: (String, Double, Bool)?
                let start = await self.engine.runHandsFreeFixture(pcm) { text, ready, submit in out = (text, ready, submit) }
                let stopAt = ProcessInfo.processInfo.systemUptime
                let deadline = stopAt + 15
                while out == nil, ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(nanoseconds: 50_000_000) }
                self.stopRecognizer()
                var row: [String: Any] = ["file": wav.lastPathComponent, "hints": Self.hints]
                if let start {
                    if let seen = self.endPhraseSeenAt { row["end_phrase_detect_lag_ms"] = Int((seen - start - speechEnd) * 1000) }
                    else { row["end_phrase_detect_lag_ms"] = NSNull() }
                    row["stop_after_speech_end_ms"] = Int((stopAt - start - speechEnd) * 1000)
                }
                if let out { row["text"] = out.0; row["release_to_ready_ms"] = Int(out.1); row["would_submit"] = out.2 } else { row["text"] = NSNull() }
                rows.append(row)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            let json = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try? json?.write(to: dir.appendingPathComponent(Self.hints ? "results-hints.json" : "results-nohints.json"))
            self.log.notice("wake_bench_done n=\(rows.count, privacy: .public)")
        }
    }

    private func run(_ target: Target, t0: Double) async {
        if engine.isHandsFreeActive { finish(submit: false, reason: "retrigger"); return }
        let focused: Bool
        currentTarget = target
        focused = await focus(target)
        let t1 = ProcessInfo.processInfo.systemUptime
        log.notice("wake_focus target=\(target.rawValue, privacy: .public) ok=\(focused, privacy: .public) ms=\(Int((t1 - t0) * 1000), privacy: .public)")
        guard focused else { return }
        let bundleID = target.bundleID
        // Another app can take focus back right after ours (e.g. a window on another display).
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier != bundleID {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate()
            guard await waitFront(bundleID, seconds: 1) else { log.notice("wake_focus_lost"); return }
        }
        startRecognizer()
        finishing = false
        guard engine.beginHandsFree(mode: .bilingual, expectedBundleID: bundleID) else { stopRecognizer(); log.notice("wake_engine_refused"); return }
        log.info("wake_begin_ms=\(Int((ProcessInfo.processInfo.systemUptime - t0) * 1000), privacy: .public)")
    }

    // MARK: targets

    /// Right before typing: bring the target back to front and put the caret in its field again.
    /// Telegram: re-open the Cello chat (the user or Telegram may have navigated away while recording).
    /// Returns the settle time before typing.
    private func refocus(_ bundleID: String?) -> Double {
        guard let bundleID, let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return 0.25 }
        var settle = 0.25
        if bundleID == "ru.keepcoder.Telegram", let bot = currentTarget?.telegramBot, let url = URL(string: "tg://resolve?domain=\(bot)") {
            NSWorkspace.shared.open(url); settle = 0.6
        }
        app.activate()
        if bundleID == "com.anysphere.sand" {
            let root = AXUIElementCreateApplication(app.processIdentifier)
            if let prompt = Self.find(in: root, role: "AXTextArea", description: "Prompt") {
                AXUIElementSetAttributeValue(prompt, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(prompt, kAXValueAttribute as CFString, &value)
                let current = ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !current.isEmpty {
                    if let last = lastInserted[bundleID], !last.isEmpty, last.hasPrefix(current) || current.hasPrefix(last) {
                        // Our own leftover from an earlier attempt: clear it.
                        Self.postKey(0, flags: .maskCommand); Self.postKey(51)
                        log.notice("wake_cleared_own_leftover")
                    } else {
                        // The user's own draft: keep it and append after a space.
                        Self.postKey(125, flags: .maskCommand)
                        engine.handsFreeInsertPrefix = " "
                        log.notice("wake_append_after_user_draft")
                    }
                    settle = max(settle, 0.35)
                }
            }
        }
        log.notice("wake_refocus target=\(bundleID, privacy: .public)")
        return settle
    }

    private func waitFront(_ bundleID: String, seconds: Double) async -> Bool {
        let end = ProcessInfo.processInfo.systemUptime + seconds
        while ProcessInfo.processInfo.systemUptime < end {
            if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID { return true }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        return false
    }

    private func focus(_ target: Target) async -> Bool {
        if let bot = target.telegramBot { return await focusTelegram(bot: bot) }
        return await focusGrokPrompt()
    }

    private func focusTelegram(bot: String) async -> Bool {
        guard let url = URL(string: "tg://resolve?domain=\(bot)") else { return false }
        NSWorkspace.shared.open(url)
        NSRunningApplication.runningApplications(withBundleIdentifier: "ru.keepcoder.Telegram").first?.activate()
        guard await waitFront("ru.keepcoder.Telegram", seconds: 3) else { return false }
        // Telegram focuses the message field once the chat is shown.
        try? await Task.sleep(nanoseconds: 250_000_000)
        return true
    }

    private func focusGrokPrompt() async -> Bool {
        let bundleID = "com.anysphere.sand"
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        app.activate()
        guard await waitFront(bundleID, seconds: 3) else { return false }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let prompt = Self.find(in: root, role: "AXTextArea", description: "Prompt") else { return false }
        return AXUIElementSetAttributeValue(prompt, kAXFocusedAttribute as CFString, kCFBooleanTrue) == .success
    }

    private static func postKey(_ code: CGKeyCode, flags: CGEventFlags = []) {
        for down in [true, false] {
            let e = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            e?.flags = flags
            e?.post(tap: .cgSessionEventTap)
        }
    }

    private static func find(in root: AXUIElement, role: String, description: String) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(root, 0)], visited = 0
        while !queue.isEmpty, visited < 4000 {
            let (el, depth) = queue.removeFirst(); visited += 1
            var r: CFTypeRef?, d: CFTypeRef?
            AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &r)
            if (r as? String) == role {
                AXUIElementCopyAttributeValue(el, kAXDescriptionAttribute as CFString, &d)
                if (d as? String) == description { return el }
            }
            guard depth < 40 else { continue }
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &kids) == .success, let list = kids as? [AXUIElement] {
                queue.append(contentsOf: list.map { ($0, depth + 1) })
            }
        }
        return nil
    }

    // MARK: on-device end-phrase listener

    nonisolated private static let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)!

    private func startRecognizer() {
        stopRecognizer()
        engine.handsFreeSubmitAllowed = !Self.dryRun
        engine.handsFreePromptHint = Self.hints ? " 끝맺음 말: 입력완료, 입력했어, 엔터." : ""
        startedAt = ProcessInfo.processInfo.systemUptime; lastChangeAt = startedAt; lastPartial = ""
        armWatchdog()
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            if SFSpeechRecognizer.authorizationStatus() == .notDetermined { SFSpeechRecognizer.requestAuthorization { _ in } }
            log.error("wake_speech_not_authorized"); return
        }
        guard let rec = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR")), rec.isAvailable, rec.supportsOnDeviceRecognition else {
            log.error("wake_speech_on_device_unavailable"); return
        }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.requiresOnDeviceRecognition = true   // never leaves the Mac
        req.shouldReportPartialResults = true
        req.taskHint = .dictation
        req.addsPunctuation = false
        if Self.hints { req.contextualStrings = Self.endPhraseWords }
        recognizer = rec; request = req; liveRequest = req
        task = rec.recognitionTask(with: req) { [weak self] result, _ in
            guard let text = result?.bestTranscription.formattedString else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.partial(text) } }
        }
    }

    /// Audio queue → convert Int16 24 kHz mono to Float32 for the recognizer.
    nonisolated private func feed(_ data: Data) {
        let frames = data.count / 2
        guard frames > 0, let buffer = AVAudioPCMBuffer(pcmFormat: Self.pcmFormat, frameCapacity: AVAudioFrameCount(frames)) else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        let out = buffer.floatChannelData![0]
        data.withUnsafeBytes { raw in
            let src = raw.bindMemory(to: Int16.self)
            for i in 0..<frames { out[i] = Float(src[i]) / 32768 }
        }
        liveRequest?.append(buffer)
    }

    /// Benchmark: when the end phrase was first seen (uptime).
    private var endPhraseSeenAt: Double?

    private func partial(_ text: String) {
        guard engine.isHandsFreeActive, !finishing else { return }
        if text != lastPartial { lastPartial = text; lastChangeAt = ProcessInfo.processInfo.systemUptime }
        if EndPhrase.heard(in: text) { endPhraseSeenAt = ProcessInfo.processInfo.systemUptime; finish(submit: true, reason: "end_phrase"); return }
        // "엔터" only as the final word: send if no further words follow within a short pause.
        enterTimer?.invalidate(); enterTimer = nil
        if EndPhrase.endsWithEnter(text) {
            enterTimer = Timer.scheduledTimer(withTimeInterval: enterPause, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.lastPartial == text, EndPhrase.endsWithEnter(text) else { return }
                    self.endPhraseSeenAt = ProcessInfo.processInfo.systemUptime
                    self.finish(submit: true, reason: "enter")
                }
            }
        }
    }

    private func armWatchdog() {
        watchdog?.invalidate()
        watchdog = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let now = ProcessInfo.processInfo.systemUptime
                if !self.engine.isHandsFreeActive, now - self.startedAt > 2 { self.stopRecognizer(); return }
                if self.lastPartial.isEmpty, now - self.startedAt > self.noSpeechSeconds { self.finish(submit: false, reason: "no_speech") }
                else if !self.lastPartial.isEmpty, now - self.lastChangeAt > self.silenceSeconds { self.finish(submit: false, reason: "silence") }
            }
        }
    }

    private func finish(submit: Bool, reason: String) {
        guard !finishing else { return }
        finishing = true
        let send = submit && !Self.dryRun
        if submit && Self.dryRun { log.info("wake_dryrun_would_submit") }
        log.notice("wake_finish reason=\(reason, privacy: .public) submit=\(send, privacy: .public) seconds=\(Int(ProcessInfo.processInfo.systemUptime - self.startedAt), privacy: .public)")
        if reason == "no_speech" { engine.cancelHandsFree() } else { engine.finishHandsFree(submit: send) }
        stopRecognizer()
    }

    private func stopRecognizer() {
        watchdog?.invalidate(); watchdog = nil
        enterTimer?.invalidate(); enterTimer = nil
        liveRequest = nil
        request?.endAudio(); task?.cancel()
        request = nil; task = nil; recognizer = nil
    }
}
