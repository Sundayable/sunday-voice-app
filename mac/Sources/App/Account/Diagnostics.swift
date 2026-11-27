import AppKit
import CryptoKit
import DictationEngine
import SwiftUI

/// Content-free breadcrumbs. Audio, clipboard text, document contents, tokens and OS-wide logs
/// never enter this log. Content history has a separate consent-gated server endpoint.
@MainActor
final class Diagnostics: ObservableObject {
    let auth: AuthService
    let api: APIClient
    private var owner: String?
    private var lines: [String] = []
    private var ids: [String] = []
    private var directory: URL?
    private var observer: NSObjectProtocol?
    private var settings: [String: String] = [:]
    private var delivered: Set<String> = []
    private let breadcrumbWriter = DispatchQueue(label: "SundayVoice.diagnostic-storage", qos: .utility)
    private let settingKeys = ["soundsEnabled", "useRecentContext", "keepTranscriptOnClipboard", "openAtLogin", "tidyShortcuts", "triggers", "uiLanguage"]
    init(auth: AuthService, api: APIClient) { self.auth = auth; self.api = api }
    var metadata: [String: Any] { ["app_version": AppVersion.header, "os_version": ProcessInfo.processInfo.operatingSystemVersionString] }

    func begin() {
        guard auth.isSignedIn, let user = auth.user, owner != user.id else { return }
        reset(); owner = user.id
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SundayVoice/Diagnostics/\(user.id)", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        directory = root
        if let data = try? Data(contentsOf: root.appendingPathComponent("breadcrumbs.jsonl")), data.count <= 128_000,
           let text = String(data: data, encoding: .utf8) {
            lines = text.split(separator: "\n").map(String.init).filter { line in
                guard let data = line.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let at = object["at"] as? Double else { return false }
                return at > Date().timeIntervalSince1970 - 7 * 86400
            }.suffix(150).map { $0 }
        }
        settings = settingSnapshot()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.changedSettings() }
        }
        event(DiagnosticEvent("app_launch"))
        Task { await captureCrashes() }
    }
    func reset() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil; owner = nil; lines = []; ids = []; delivered = []; directory = nil
    }
    private func settingSnapshot() -> [String: String] {
        Dictionary(uniqueKeysWithValues: settingKeys.map { ($0, String(describing: UserDefaults.standard.object(forKey: $0))) })
    }
    private func changedSettings() {
        let next = settingSnapshot()
        for key in settingKeys where next[key] != settings[key] { event(DiagnosticEvent("settings_change"), extra: ["setting": key]) }
        settings = next
    }
    func event(_ event: DiagnosticEvent, extra: [String: Any] = [:]) {
        guard auth.isSignedIn, owner == auth.user?.id else { return }
        var meta = metadata.merging(extra) { _, new in new }
        if let value = event.durationMS { meta["duration_ms"] = value }
        if let value = event.latencyMS { meta["latency_ms"] = value }
        if let value = event.errorCode { meta["error_code"] = String(value.prefix(100)) }
        var body: [String: Any] = ["id": UUID().uuidString, "name": event.name, "metadata": meta]
        if let id = event.turnID {
            body["turn_id"] = id
            if !ids.contains(id) { ids.append(id); ids = Array(ids.suffix(20)) }
        }
        breadcrumb(body)
        let owner = self.owner
        Task {
            guard self.owner == owner, auth.isSignedIn else { return }
            try? await api.sendDiagnostic("api/events", body: body)
            if event.name == "dictation_fail" || event.name == "client_error" {
                try? await submit(id: UUID().uuidString, kind: "error", description: event.errorCode ?? "dictation_failed")
            }
        }
    }
    func delivery(_ record: DeliveryRecord) {
        guard auth.isSignedIn, owner == auth.user?.id, !record.isDiagnostic else { return }
        let meta = metadata.merging(["mode": record.mode.rawValue, "app_bundle_id": record.bundleID ?? "unknown", "outcome": record.outcome.rawValue]) { _, new in new }
        let owner = self.owner
        Task {
            guard self.owner == owner else { return }
            try? await api.sendDiagnostic("api/history", body: ["id": record.id, "turn_id": record.id, "kind": "delivery", "text": record.text, "metadata": meta])
        }
        delivered.insert(record.id)
        if delivered.count > 200 { delivered = Set(ids) }
    }
    private func breadcrumb(_ body: [String: Any]) {
        guard let directory else { return }
        var object = body; object["at"] = Date().timeIntervalSince1970
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let line = String(data: data, encoding: .utf8) else { return }
        lines.append(line); lines = Array(lines.suffix(150))
        let file = directory.appendingPathComponent("breadcrumbs.jsonl")
        let snapshot = Data(lines.joined(separator: "\n").suffix(64_000).utf8)
        breadcrumbWriter.async {
            try? snapshot.write(to: file, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        }
    }
    func submit(id: String, kind: String = "bug", description: String, logs: String? = nil) async throws {
        guard auth.isSignedIn, owner == auth.user?.id else { throw AuthError.signedOut }
        try await api.sendDiagnostic("api/reports", body: ["id": id, "kind": kind, "description": description,
            "logs": logs ?? lines.joined(separator: "\n"), "dictation_ids": ids, "metadata": metadata])
    }
    private func captureCrashes() async {
        guard let owner, let directory else { return }
        let marker = directory.appendingPathComponent("crash-since")
        // First consent never uploads older sessions or any other app's crash reports.
        guard let value = try? String(contentsOf: marker, encoding: .utf8), let since = Double(value) else {
            try? String(Date().timeIntervalSince1970).write(to: marker, atomically: true, encoding: .utf8); return
        }
        let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])) ?? []
        var latest = since
        for file in files.filter({ $0.pathExtension == "ips" && $0.lastPathComponent.hasPrefix(AppIdentity.name) }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }).suffix(10) {
            guard self.owner == owner, auth.isSignedIn, let attrs = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let date = attrs.contentModificationDate, date.timeIntervalSince1970 > since, date > Date().addingTimeInterval(-7 * 86400),
                  (attrs.fileSize ?? 0) < 2_000_000, let data = try? Data(contentsOf: file),
                  let summary = CrashSummary.extract(data, bundleID: Bundle.main.bundleIdentifier ?? "") else { continue }
            do {
                try await submit(id: CrashSummary.identifier(data), kind: "crash", description: "macOS crash report", logs: summary)
                latest = max(latest, date.timeIntervalSince1970)
            } catch { return }
        }
        try? String(latest).write(to: marker, atomically: true, encoding: .utf8)
    }
}

enum CrashSummary {
    static func identifier(_ data: Data) -> String {
        let bytes = Array(SHA256.hash(data: data).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15])).uuidString
    }
    static func extract(_ data: Data, bundleID: String) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let body = text.firstIndex(of: "\n").map { String(text[text.index(after: $0)...]) } ?? text
        guard let bytes = body.data(using: .utf8), let report = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let bundle = report["bundleInfo"] as? [String: Any], bundle["CFBundleIdentifier"] as? String == bundleID else { return nil }
        let exception = report["exception"] as? [String: Any] ?? [:]
        var result: [String] = []
        for key in ["type", "signal"] { if let value = exception[key] as? String, value.range(of: "^[A-Z0-9_]+$", options: .regularExpression) != nil { result.append("\(key)=\(value)") } }
        for thread in (report["threads"] as? [[String: Any]] ?? []).filter({ $0["triggered"] as? Bool == true }) {
            for frame in (thread["frames"] as? [[String: Any]] ?? []).prefix(40) {
                if let symbol = frame["symbol"] as? String, symbol.count < 250, symbol.range(of: "^[A-Za-z0-9_.$:() <>+,-]+$", options: .regularExpression) != nil { result.append(symbol) }
            }
        }
        return result.isEmpty ? "crash_no_symbols" : result.joined(separator: "\n")
    }
}

struct BugReportView: View {
    @ObservedObject var diagnostics: Diagnostics
    @State private var description = ""
    @State private var sending = false
    @State private var sent = false
    @State private var failure = false
    @State private var id = UUID().uuidString
    private var ko: Bool { UILanguage.isKorean }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(ko ? "문제 신고" : "Report a bug").font(Theme.display(25))
            Text(ko ? "어떤 작업 중에 문제가 생겼는지 알려 주세요. 앱·macOS 버전, 최근 진단 로그와 받아쓰기 번호가 함께 전송돼요. 로그에는 음성이나 글 본문이 들어가지 않습니다." : "Tell us what happened. App/macOS version, recent diagnostic logs and dictation IDs are attached automatically. Logs do not contain audio or text content.").font(Theme.text(14))
            TextEditor(text: $description).frame(minHeight: 180).border(.secondary.opacity(0.3)).disabled(sending || sent)
            if sent { Text(ko ? "신고를 보냈어요. 확인 후 필요한 경우 연락드릴게요." : "Report received. We may contact you if we need more details.").foregroundStyle(.green) }
            if failure { Text(ko ? "전송하지 못했어요. 연결을 확인하고 다시 눌러 주세요." : "Could not send. Check your connection and try again.").foregroundStyle(.red) }
            Button(sending ? (ko ? "보내는 중…" : "Sending…") : (ko ? "신고 보내기" : "Send report")) {
                sending = true; failure = false
                Task { do { try await diagnostics.submit(id: id, description: description); sent = true } catch { failure = true }; sending = false }
            }.buttonStyle(PrimaryButton()).disabled(sending || sent || description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || description.count > 10_000)
        }.padding(28).frame(width: 540, height: 480)
    }
}
