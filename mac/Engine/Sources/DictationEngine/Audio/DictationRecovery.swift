import Foundation

/// A local write-ahead journal. Audio is PCM16 mono, 24 kHz. Nothing here is sent to a server
/// except when the user explicitly retries a dictation through the normal transcription path.
public struct DictationRecoveryRecord: Codable, Equatable, Sendable {
    public let id: String
    public let startedAt: Date
    public let mode: DictationMode
    public let appName: String?
    public let bundleID: String?
    public var rawText = ""
    public var finalText = ""
    public var errorCode: String?
    public var complete = false
    public var audioBytes = 0
}

public final class DictationRecoveryStore: @unchecked Sendable {
    public static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SundayVoice/DictationRecovery", isDirectory: true)
    }
    public let root: URL
    private let lock = NSLock()
    private var writers: [String: FileHandle] = [:]
    private var records: [String: DictationRecoveryRecord] = [:]
    private var syncedBytes: [String: Int] = [:]

    public init(root: URL = DictationRecoveryStore.defaultURL) { self.root = root }
    private func folder(_ id: String) -> URL {
        // IDs originate in the engine; keep even diagnostic IDs a single safe path component.
        root.appendingPathComponent(Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_"), isDirectory: true)
    }
    public func audioURL(_ id: String) -> URL { folder(id).appendingPathComponent("audio.pcm") }
    private func save(_ record: DictationRecoveryRecord, sync: Bool = true) throws {
        let url = folder(record.id).appendingPathComponent("record.json")
        let data = try JSONEncoder().encode(record)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        if sync {
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize(); try handle.close()
        }
        records[record.id] = record
    }
    public func begin(id: String, mode: DictationMode, appName: String?, bundleID: String?) throws {
        try lock.withLock {
            try FileManager.default.createDirectory(at: folder(id), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            guard !FileManager.default.fileExists(atPath: audioURL(id).path),
                  FileManager.default.createFile(atPath: audioURL(id).path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteFileExists)
            }
            let handle = try FileHandle(forWritingTo: audioURL(id))
            writers[id] = handle
            try save(DictationRecoveryRecord(id: id, startedAt: Date(), mode: mode, appName: appName, bundleID: bundleID), sync: false)
        }
    }
    /// Called on the microphone consumer, before forwarding bytes to the main actor/network.
    /// No work runs on CoreAudio's real-time render callback. Flush each second and at stop.
    public func append(_ data: Data, id: String) throws {
        try lock.withLock {
            guard let handle = writers[id], var r = records[id] else { throw CocoaError(.fileWriteUnknown) }
            try handle.write(contentsOf: data)
            r.audioBytes += data.count; records[id] = r
            if r.audioBytes - (syncedBytes[id] ?? 0) >= 48_000 {
                try handle.synchronize(); syncedBytes[id] = r.audioBytes
            }
        }
    }
    public func seal(_ id: String) throws {
        try lock.withLock {
            if let handle = writers[id] {
                try handle.synchronize(); try handle.close(); writers[id] = nil
            }
            if let r = records[id] { try save(r) }
        }
    }
    public func checkpoint(_ id: String, raw: String? = nil, final: String? = nil, error: String? = nil, complete: Bool? = nil) throws {
        try lock.withLock {
            guard var r = records[id] ?? read(id) else { throw CocoaError(.fileReadNoSuchFile) }
            if let raw { r.rawText = raw }
            if let final { r.finalText = final }
            if let error { r.errorCode = error }
            if let complete { r.complete = complete; if complete { r.errorCode = nil } }
            try save(r)
            // Never unlink audio on an error/partial result. The final text is durably saved first.
            if r.complete, !r.finalText.isEmpty, writers[id] == nil, FileManager.default.fileExists(atPath: audioURL(id).path) {
                try FileManager.default.removeItem(at: audioURL(id))
            }
        }
    }
    /// Called only after history is durably saved or insertion is confirmed. Completed journal
    /// text must not outlive the user's bounded/clearable history. Unresolved audio is untouched.
    func retireCompleted(_ id: String) throws {
        try lock.withLock {
            guard let r = records[id] ?? read(id), r.complete, writers[id] == nil else { return }
            try FileManager.default.removeItem(at: folder(id))
            records[id] = nil; syncedBytes[id] = nil
        }
    }
    /// User-confirmed deletion. Never remove a live write-ahead journal.
    public func discardAll() throws {
        try lock.withLock {
            guard writers.isEmpty else { throw CocoaError(.fileWriteNoPermission) }
            if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
            records.removeAll(); syncedBytes.removeAll()
        }
    }
    private func read(_ id: String) -> DictationRecoveryRecord? {
        guard let data = try? Data(contentsOf: folder(id).appendingPathComponent("record.json")) else { return nil }
        return try? JSONDecoder().decode(DictationRecoveryRecord.self, from: data)
    }
    public func list() -> [DictationRecoveryRecord] {
        lock.withLock {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return dirs.compactMap { dir -> DictationRecoveryRecord? in
                guard let data = try? Data(contentsOf: dir.appendingPathComponent("record.json")),
                      var r = try? JSONDecoder().decode(DictationRecoveryRecord.self, from: data) else { return nil }
                r.audioBytes = ((try? FileManager.default.attributesOfItem(atPath: audioURL(r.id).path)[.size]) as? Int) ?? 0
                return r
            }.sorted { $0.startedAt > $1.startedAt }
        }
    }
}

public enum DictationLimits {
    public static let maximumRecordingSeconds: Double = 10 * 60
    public static let warningLeadSeconds: Double = 30
}
