import Foundation

/// Pluggable on-device speech-to-text backend for Free Local Mode (zero external APIs).
/// Default implementation: `WhisperLocalDictation` (WhisperKit large-v3-turbo CoreML, reusing the
/// Meetings model cache). Designed so a future MLX backend (e.g. `qwen3-asr-0.6b-mlx`) plugs in
/// behind this exact protocol without changing `DictationEngine` or the UI.
public protocol LocalDictationTranscriber: AnyObject, Sendable {
    /// Stable identifier (e.g. "whisperkit-large-v3-turbo", future "qwen3-asr-0.6b-mlx").
    var backendID: String { get }
    /// True when the required local model weights are present on disk.
    var isReady: Bool { get }
    /// Transcribe 24 kHz mono Int16 PCM locally with optional proper-noun prompt terms.
    func transcribe(pcm24kMono: Data, mode: DictationMode, promptTerms: [String]) async throws -> String
    /// Optional background prewarm so first local dictation avoids cold CoreML/MLX compile lag.
    func prewarm() async
    /// Free model memory when the user switches back to cloud mode or quits.
    func unload() async
}

public extension LocalDictationTranscriber {
    func prewarm() async {}
    func unload() async {}
}

public enum LocalDictationError: Error, Equatable, Sendable {
    case modelNotReady
    case emptyAudio
    case failed(String)
}

/// One local replacement entry (mis-hearing → canonical spelling) for offline dictation.
public struct LocalReplacementRule: Codable, Equatable, Sendable {
    public var from: String
    public var to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

/// On-device personal replacement map stored in `~/Library/Application Support/SundayVoice/local-replacements.json`.
/// Used in Free Local Mode so custom names/terms work with zero server calls.
public final class LocalPersonalDictionary: Sendable {
    public let fileURL: URL

    public init(fileURL: URL? = nil) {
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
            self.fileURL = support.appendingPathComponent("SundayVoice/local-replacements.json")
        }
    }

    public func loadRules() -> [LocalReplacementRule] {
        guard let data = try? Data(contentsOf: fileURL),
              let rules = try? JSONDecoder().decode([LocalReplacementRule].self, from: data) else {
            return []
        }
        return rules
            .filter { !$0.from.isEmpty && !$0.to.isEmpty }
            .sorted { $0.from.utf16.count > $1.from.utf16.count }
    }

    /// Canonical target terms to bias local STT (`promptTokens`) alongside screen terms.
    public func promptTerms(limit: Int = 16) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for rule in loadRules() {
            let t = rule.to.trimmingCharacters(in: .whitespacesAndNewlines)
            guard (2...40).contains(t.count), !seen.contains(t.lowercased()) else { continue }
            seen.insert(t.lowercased())
            out.append(t)
            if out.count >= limit { break }
        }
        return out
    }

    /// Applies personal replacement rules + built-in canonical terms + deterministic filler/spacing cleanup.
    public func apply(to raw: String) -> String {
        let userPairs = loadRules().map { ($0.from, $0.to) }
        let checks = QualityChecks(canonicalTerms: userPairs + QualityChecks.defaultCanonicalTerms)
        let replaced = checks.canonicalTranscript(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        return QualityChecks.preserveBilingual(source: replaced, cleaned: replaced)
    }
}
