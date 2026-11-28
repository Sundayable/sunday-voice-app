import DictationEngine
import Foundation
import LocalMeetingEngine

/// Connects `DictationEngine`'s pluggable `LocalDictationTranscriber` protocol to the on-device
/// `WhisperLocalDictation` actor (reusing `~/Library/Application Support/SundayVoice/MeetingModels`).
/// Future MLX backends (e.g. Qwen3-ASR-0.6B) drop in behind the same protocol with zero UI changes.
final class LocalDictationBridge: LocalDictationTranscriber {
    private let whisper: WhisperLocalDictation

    init(modelsDirectory: URL = LocalDictationBridge.defaultModelsDirectory()) {
        self.whisper = WhisperLocalDictation(directory: modelsDirectory)
    }

    static func defaultModelsDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("SundayVoice/MeetingModels", isDirectory: true)
    }

    var backendID: String { whisper.backendID }
    var isReady: Bool { whisper.isReady }

    func transcribe(pcm24kMono: Data, mode: DictationMode, promptTerms: [String]) async throws -> String {
        let saved = UserDefaults.standard.string(forKey: "uiLanguage")
        let preferred: String
        if saved == "ko" { preferred = "ko" }
        else if saved == "en" { preferred = "en" }
        else { preferred = (Locale.preferredLanguages.first ?? "").hasPrefix("ko") ? "ko" : "en" }
        return try await whisper.transcribe(
            pcm24kMono: pcm24kMono,
            languageHint: nil,
            promptTerms: promptTerms,
            preferredLanguage: preferred
        )
    }

    func prewarm() async {
        await whisper.prewarm()
    }

    func unload() async {
        await whisper.unload()
    }
}
