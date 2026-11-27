import AppKit
import DictationEngine
import OSLog

/// The last 20 finished dictations, newest first, so a transcript that didn't paste can be copied
/// back (Dan, 2026-10-05). Stored only on this Mac (owner-only file in Application Support), never
/// uploaded or logged; cleared from the menu or on sign-out.
@MainActor
final class RecentTranscripts {
    static let limit = 20
    private(set) var items: [DeliveryRecord] = []
    private let url: URL?

    nonisolated static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SundayVoice/recent-transcripts.json")
    }

    /// `url: nil` keeps the list in memory only (tests, gallery).
    init(url: URL? = RecentTranscripts.defaultURL) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([DeliveryRecord].self, from: data) {
            items = Array(saved.prefix(Self.limit))
        }
    }

    var latest: DeliveryRecord? { items.first }

    /// New dictations go on top; a later outcome for the same id (paste check) updates it in place.
    @discardableResult func record(_ r: DeliveryRecord) -> Bool {
        // Synthetic QA must never evict a user's dictations from this bounded history.
        guard !r.isDiagnostic else { return true }
        if let i = items.firstIndex(where: { $0.id == r.id }) { items[i] = r }
        else { items.insert(r, at: 0); if items.count > Self.limit { items.removeLast(items.count - Self.limit) } }
        return save()
    }

    func clear() {
        items = []
        if let url { try? FileManager.default.removeItem(at: url) }
    }

    private func save() -> Bool {
        let started = ProcessInfo.processInfo.systemUptime
        defer {
            let milliseconds = (ProcessInfo.processInfo.systemUptime - started) * 1000
            Logger(subsystem: AppIdentity.bundleID, category: "recent-transcripts")
                .info("recent_save_ms=\(milliseconds, privacy: .public)")
        }
        guard let url else { return true }
        do {
            let data = try JSONEncoder().encode(items)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // The atomic replacement's temporary file is protected by its private directory too.
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize(); try handle.close()
            return true
        } catch { return false }
    }

    /// Menu title: "14:05 · Slack · Send it to Lauren by Fri…".
    static func title(_ r: DeliveryRecord, now: Date = Date()) -> String {
        let f = DateFormatter()
        f.dateFormat = Calendar.current.isDate(r.at, inSameDayAs: now) ? "HH:mm" : "M/d HH:mm"
        let flat = r.text.split(whereSeparator: \.isNewline).joined(separator: " ")
        let snippet = flat.count > 44 ? String(flat.prefix(43)) + "…" : flat
        return [f.string(from: r.at), r.appName, snippet].compactMap { $0 }.joined(separator: " · ")
    }

    static func copy(_ text: String) {
        let board = NSPasteboard.general
        board.clearContents(); board.setString(text, forType: .string)
    }
}
