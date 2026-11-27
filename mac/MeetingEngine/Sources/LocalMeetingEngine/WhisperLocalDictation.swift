import CoreML
import Foundation
import WhisperKit

/// Free local offline dictation backend powered by the already-cached `WhisperKit large-v3-turbo`
/// CoreML model in `MeetingModels` (0 MB extra download, ~179 MB app RAM on ANE).
/// Injects local AX screen terms and personal vocabulary via `DecodingOptions.promptTokens`.
public actor WhisperLocalDictation {
    public static let backendIdentifier = "whisperkit-large-v3-turbo"
    public static var allowedLanguages: [String] { SpeechLanguagePolicy.allowedLanguages }

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

    /// Transcribes 24 kHz mono Int16 PCM audio locally using WhisperKit + `promptTokens`.
    /// Enforces `SpeechLanguagePolicy.allowedLanguages` (en + ko only); unsupported language hints
    /// or non-allowed detected languages are gracefully ignored (returning "").
    public func transcribe(pcm24kMono: Data, languageHint: String? = nil, promptTerms: [String]) async throws -> String {
        if SpeechLanguagePolicy.isUnsupportedExplicitHint(languageHint) {
            return ""
        }
        let resolvedHint = SpeechLanguagePolicy.validatedHint(languageHint)
        let samples = Self.resample24kInt16To16kFloat(pcm24kMono)
        guard samples.count >= 1600 else { return "" } // < 0.1 s
        let (wk, tok) = try await ensureLoaded()
        let promptString = Self.buildPromptString(terms: promptTerms)
        let promptTokens: [Int]? = promptString.isEmpty ? nil : tok.encode(text: " " + promptString)

        func run(language: String?) async throws -> [TranscriptionResult] {
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
                promptTokens: promptTokens,
                suppressBlank: true,
                compressionRatioThreshold: 2.4,
                logProbThreshold: -1.0,
                noSpeechThreshold: 0.75,
                concurrentWorkerCount: 1
            )
            return try await wk.transcribe(audioArray: samples, decodeOptions: options)
        }

        let results = try await run(language: resolvedHint)
        let detected = results.first?.language ?? ""
        if resolvedHint == nil && !detected.isEmpty && !SpeechLanguagePolicy.isAllowed(detected) {
            return ""
        }
        let text = results
            .flatMap(\.segments)
            .filter { $0.noSpeechProb < 0.8 && $0.compressionRatio < 2.8 }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard SpeechLanguagePolicy.isAllowedTranscript(text, detectedLanguage: resolvedHint ?? detected) else {
            return ""
        }
        return text
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
