import CoreML
import Foundation
import os
import WhisperKit

/// Free local offline dictation backend powered by the already-cached `WhisperKit large-v3-turbo`
/// CoreML model in `MeetingModels` (0 MB extra download, ~179 MB app RAM on ANE).
/// Injects local AX screen terms and personal vocabulary via `DecodingOptions.promptTokens`.
public actor WhisperLocalDictation {
    public static let backendIdentifier = "whisperkit-large-v3-turbo"
    public static var allowedLanguages: [String] { SpeechLanguagePolicy.allowedLanguages }
    /// Minimum audio length (0.8 s at 16 kHz) that triggers explicit Korean/English fallback when auto-detect fails.
    public static let fallbackMinSamples = 12_800
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "ca.sundayable.sunday-voice", category: "local-stt")

    public nonisolated let directory: URL
    private var engine: WhisperKit?
    private var tokenizer: LocalWhisperTokenizer?
    private var loading: Task<(WhisperKit, LocalWhisperTokenizer), Error>?

    public init(directory: URL) {
        self.directory = directory
    }

    public nonisolated var backendID: String { Self.backendIdentifier }
    public nonisolated var isReady: Bool { WhisperMeetingTranscriber.readyModelURL(in: directory) != nil }

    public func prewarm() async {
        guard isReady else { return }
        _ = try? await ensureLoaded()
    }

    public func unload() async {
        if let engine { await engine.unloadModels() }
        engine = nil
        tokenizer = nil
    }

    /// Ordered allowed languages for explicit fallback decoding (preferred language first).
    public nonisolated static func fallbackLanguages(preferred: String?, allowed: [String] = SpeechLanguagePolicy.allowedLanguages) -> [String] {
        var ordered: [String] = []
        if let pref = SpeechLanguagePolicy.validatedHint(preferred, allowed: allowed) {
            ordered.append(pref)
        }
        for code in allowed where !ordered.contains(code) {
            ordered.append(code)
        }
        return ordered
    }

    /// Runs the primary decode and, if auto-detect mis-classifies into a disallowed language or returns
    /// empty text on substantial audio (>= 0.8 s), retries explicitly with allowed languages (ko / en)
    /// and without prompt noise so real speech is never dropped as "no speech".
    public nonisolated static func decodeWithFallback(
        audioSamplesCount: Int,
        explicitHint: String?,
        preferredLanguage: String?,
        allowed: [String] = SpeechLanguagePolicy.allowedLanguages,
        primary: () async throws -> (detected: String, text: String),
        fallback: (String) async throws -> (detected: String, text: String)
    ) async throws -> (text: String, fallbackUsed: String?, emptyReason: String?) {
        let first = try await primary()
        let firstDetected = first.detected.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstText = first.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let firstLangOK = explicitHint != nil || firstDetected.isEmpty || SpeechLanguagePolicy.isAllowed(firstDetected, allowed: allowed)
        if !firstText.isEmpty && firstLangOK && SpeechLanguagePolicy.isAllowedTranscript(firstText, detectedLanguage: explicitHint ?? firstDetected, allowed: allowed) {
            return (firstText, nil, nil)
        }

        let primaryReason: String
        if !firstLangOK { primaryReason = "disallowed_detected_\(SpeechLanguagePolicy.normalize(firstDetected))" }
        else if firstText.isEmpty { primaryReason = "empty_primary" }
        else { primaryReason = "disallowed_script" }

        guard explicitHint == nil, audioSamplesCount >= fallbackMinSamples else {
            return ("", nil, primaryReason)
        }

        for lang in fallbackLanguages(preferred: preferredLanguage, allowed: allowed) {
            let attempt = try await fallback(lang)
            let candidate = attempt.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !candidate.isEmpty && SpeechLanguagePolicy.isAllowedTranscript(candidate, detectedLanguage: lang, allowed: allowed) {
                return (candidate, lang, nil)
            }
        }
        return ("", nil, "\(primaryReason)_after_fallback")
    }

    /// Transcribes 24 kHz mono Int16 PCM audio locally using WhisperKit + `promptTokens`.
    /// Enforces `SpeechLanguagePolicy.allowedLanguages` (en + ko only); unsupported language hints
    /// are gracefully ignored, and auto-detect misses on real speech retry with explicit ko/en.
    public func transcribe(pcm24kMono: Data, languageHint: String? = nil, promptTerms: [String], preferredLanguage: String? = nil) async throws -> String {
        if SpeechLanguagePolicy.isUnsupportedExplicitHint(languageHint) {
            return ""
        }
        let resolvedHint = SpeechLanguagePolicy.validatedHint(languageHint)
        let samples = Self.resample24kInt16To16kFloat(pcm24kMono)
        guard samples.count >= 1600 else { return "" } // < 0.1 s
        let (wk, tok) = try await ensureLoaded()
        let promptString = Self.buildPromptString(terms: promptTerms)
        let promptTokens: [Int]? = promptString.isEmpty ? nil : tok.encode(text: " " + promptString)

        func run(language: String?, tokens: [Int]?, relaxed: Bool) async throws -> (detected: String, text: String) {
            let options = DecodingOptions(
                verbose: false,
                task: .transcribe,
                language: language,
                temperature: 0,
                temperatureFallbackCount: 2,
                usePrefillPrompt: true,
                detectLanguage: language == nil,
                skipSpecialTokens: true,
                withoutTimestamps: true,
                wordTimestamps: false,
                promptTokens: tokens,
                suppressBlank: true,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: relaxed ? 0.9 : 0.75,
                concurrentWorkerCount: 1
            )
            let results = try await wk.transcribe(audioArray: samples, decodeOptions: options)
            let detected = results.first?.language ?? ""
            let maxNoSpeech: Float = relaxed ? 0.92 : 0.8
            let text = results
                .flatMap(\.segments)
                .filter { $0.noSpeechProb < maxNoSpeech && $0.compressionRatio < 2.8 }
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (detected, text)
        }

        let outcome = try await Self.decodeWithFallback(
            audioSamplesCount: samples.count,
            explicitHint: resolvedHint,
            preferredLanguage: preferredLanguage,
            primary: { try await run(language: resolvedHint, tokens: promptTokens, relaxed: false) },
            fallback: { lang in try await run(language: lang, tokens: nil, relaxed: true) }
        )
        let audioSeconds = Double(samples.count) / 16_000.0
        if let used = outcome.fallbackUsed {
            Self.log.notice("local_fallback_recovered lang=\(used, privacy: .public) audio_s=\(audioSeconds, privacy: .public)")
        } else if outcome.text.isEmpty, let reason = outcome.emptyReason {
            Self.log.notice("local_decode_empty reason=\(reason, privacy: .public) audio_s=\(audioSeconds, privacy: .public)")
        }
        return outcome.text
    }

    private func ensureLoaded() async throws -> (WhisperKit, LocalWhisperTokenizer) {
        if let engine, let tokenizer { return (engine, tokenizer) }
        if let loading {
            let loaded = try await loading.value
            engine = loaded.0; tokenizer = loaded.1
            return loaded
        }
        let directory = self.directory
        let task = Task<(WhisperKit, LocalWhisperTokenizer), Error> {
            guard let modelURL = WhisperMeetingTranscriber.readyModelURL(in: directory) else {
                throw MeetingEngineError.modelMissing
            }
            let tokenizerDir = directory.appendingPathComponent("Tokenizer")
            let tok = try await LocalWhisperTokenizer.load(from: tokenizerDir)
            let config = WhisperKitConfig(
                model: WhisperMeetingTranscriber.modelName,
                modelFolder: modelURL.path,
                tokenizerFolder: tokenizerDir,
                computeOptions: ModelComputeOptions(
                    melCompute: .cpuAndGPU,
                    audioEncoderCompute: .cpuAndNeuralEngine,
                    textDecoderCompute: .cpuAndNeuralEngine
                ),
                verbose: false,
                logLevel: .none,
                prewarm: false,
                load: false,
                download: false
            )
            let candidate = try await OfflineOnlyWhisperKit(config)
            candidate.tokenizer = tok
            candidate.textDecoder.isModelMultilingual = true
            try await candidate.loadModels()
            return (candidate, tok)
        }
        self.loading = task
        defer { self.loading = nil }
        let loaded = try await task.value
        self.engine = loaded.0
        self.tokenizer = loaded.1
        return loaded
    }

    /// Deterministic linear resampler from 24 kHz mono Int16 PCM to 16 kHz mono Float32 [-1, 1].
    public nonisolated static func resample24kInt16To16kFloat(_ pcm: Data) -> [Float] {
        let inCount = pcm.count / 2
        guard inCount > 0 else { return [] }
        let scale: Float = 1.0 / 32768.0
        let outCount = max(1, (inCount * 2) / 3)
        var out = [Float](repeating: 0, count: outCount)
        pcm.withUnsafeBytes { raw in
            let samples = raw.bindMemory(to: Int16.self)
            for i in 0..<outCount {
                let srcPos = Double(i) * 1.5
                let lo = min(inCount - 1, Int(srcPos))
                let hi = min(inCount - 1, lo + 1)
                let frac = Float(srcPos - Double(lo))
                let a = Float(samples[lo]) * scale
                let b = Float(samples[hi]) * scale
                out[i] = a + (b - a) * frac
            }
        }
        return out
    }

    /// Formats concise comma-separated terms for Whisper `promptTokens` (prevents prompt echo/leak).
    public nonisolated static func buildPromptString(terms: [String], maxTerms: Int = 24, maxChars: Int = 220) -> String {
        var seen = Set<String>()
        var picked: [String] = []
        var used = 0
        for raw in terms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, t.count <= 40, !seen.contains(t.lowercased()) else { continue }
            let cost = t.utf16.count + (picked.isEmpty ? 0 : 2)
            guard picked.count < maxTerms, used + cost <= maxChars else { break }
            seen.insert(t.lowercased())
            picked.append(t)
            used += cost
        }
        return picked.joined(separator: ", ")
    }
}

private final class OfflineOnlyWhisperKit: WhisperKit {
    override func loadTokenizerIfNeeded() async throws {
        guard tokenizer != nil else { throw MeetingEngineError.invalidModel }
    }
}

private struct LocalWhisperTokenizer: WhisperTokenizer {
    let underlying: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    static func load(from directory: URL) async throws -> Self {
        let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: directory)
        func id(_ token: String) throws -> Int {
            guard let value = tokenizer.convertTokenToId(token) else { throw MeetingEngineError.invalidModel }
            return value
        }
        let special = try SpecialTokens(
            endToken: id("<|endoftext|>"),
            englishToken: id("<|en|>"),
            noSpeechToken: id("<|nospeech|>"),
            noTimestampsToken: id("<|notimestamps|>"),
            specialTokenBegin: id("<|endoftext|>"),
            startOfPreviousToken: id("<|startofprev|>"),
            startOfTranscriptToken: id("<|startoftranscript|>"),
            timeTokenBegin: id("<|0.00|>"),
            transcribeToken: id("<|transcribe|>"),
            translateToken: id("<|translate|>"),
            whitespaceToken: tokenizer.encode(text: " ", addSpecialTokens: false).first ?? 220
        )
        let data = try Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let added = json["added_tokens"] as? [[String: Any]] else { throw MeetingEngineError.invalidModel }
        let languages = Set(added.compactMap { item -> Int? in
            guard let text = item["content"] as? String,
                  text.range(of: "^<\\|[a-z]{2,3}\\|>$", options: .regularExpression) != nil else { return nil }
            return item["id"] as? Int
        })
        return Self(underlying: tokenizer, specialTokens: special, allLanguageTokens: languages)
    }

    func encode(text: String) -> [Int] { underlying.encode(text: text) }
    func decode(tokens: [Int]) -> String { underlying.decode(tokens: tokens) }
    func convertTokenToId(_ token: String) -> Int? { underlying.convertTokenToId(token) }
    func convertIdToToken(_ id: Int) -> String? { underlying.convertIdToToken(id) }
    func splitToWordTokens(tokenIds: [Int]) -> (words: [String], wordTokens: [[Int]]) {
        tokenIds.isEmpty ? ([], []) : ([decode(tokens: tokenIds)], [tokenIds])
    }
}
