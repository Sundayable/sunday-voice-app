import CoreML
import Foundation
import SpeakerKit
import WhisperKit

/// Offline speech recognition and voice separation for a finished recording.
/// Nothing here runs while a meeting is being captured.
actor WhisperMeetingTranscriber: MeetingTranscribing {
    static let modelName = "openai_whisper-large-v3-v20240930_626MB"
    static let tokenizerRepository = "openai/whisper-large-v3-turbo"
    static let speakerRepository = "argmaxinc/speakerkit-coreml"
    /// Sunday Voice records Korean and English meetings. A window detected as any other language
    /// is a detection slip on mixed speech and is decoded again in the meeting's main language.
    static let meetingLanguages = ["ko", "en"]
    nonisolated let directory: URL
    private var engine: StrictLocalWhisperKit?
    private var speakers: SpeakerKit?
    private var loading: Task<StrictLocalWhisperKit, Error>?
    private struct Manifest: Codable { let modelRelativePath: String; let model: String }

    init(directory: URL) { self.directory = directory }

    nonisolated var speechModelName: String { Self.modelName }
    nonisolated var speakerModelName: String { "\(Self.speakerRepository) (pyannote segmentation + embedding, VBx clustering)" }
    nonisolated var assetsAvailable: Bool { Self.readyModelURL(in: directory) != nil }
    nonisolated var speakerAssetsAvailable: Bool { Self.readySpeakerFolder(in: directory) != nil }

    nonisolated static func readyModelURL(in directory: URL) -> URL? {
        let marker = directory.appendingPathComponent("ready.json")
        guard let data = try? Data(contentsOf: marker), let manifest = try? JSONDecoder().decode(Manifest.self, from: data),
              manifest.model == modelName, !manifest.modelRelativePath.hasPrefix("/"),
              !manifest.modelRelativePath.components(separatedBy: "/").contains("..") else { return nil }
        let model = directory.appendingPathComponent(manifest.modelRelativePath)
        let required = ["MelSpectrogram.mlmodelc", "AudioEncoder.mlmodelc", "TextDecoder.mlmodelc"].map { model.appendingPathComponent($0) }
            + ["config.json", "tokenizer.json", "tokenizer_config.json"].map { directory.appendingPathComponent("Tokenizer").appendingPathComponent($0) }
        guard required.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return model
    }

    nonisolated static func speakerDownloadBase(in directory: URL) -> URL { directory.appendingPathComponent("Speakers", isDirectory: true) }

    /// The voice models are complete only when every compiled model this OS version loads is on disk.
    nonisolated static func readySpeakerFolder(in directory: URL) -> URL? {
        let folder = speakerDownloadBase(in: directory).appendingPathComponent("models").appendingPathComponent(speakerRepository)
        let required = [ModelInfo.segmenter().modelURL(baseURL: folder).appendingPathComponent("SpeakerSegmenter.mlmodelc"),
                        ModelInfo.embedder().modelURL(baseURL: folder).appendingPathComponent("SpeakerEmbedder.mlmodelc"),
                        ModelInfo.embedder().modelURL(baseURL: folder).appendingPathComponent("SpeakerEmbedderPreprocessor.mlmodelc"),
                        ModelInfo.plda().modelURL(baseURL: folder).appendingPathComponent("PldaProjector.mlmodelc")]
        return required.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) ? folder : nil
    }

    /// This is the only method in the meeting engine allowed to access a network.
    /// It fetches public model files; no account, audio or transcript data is part of any request.
    func prepare(progress: @escaping @Sendable (Double) -> Void) async throws {
        try MeetingSessionStore.privateDirectory(directory)
        progress(0)
        var usable = assetsAvailable
        if usable {
            // The user explicitly requested setup; repair incomplete or corrupt local files here only.
            do { try await loadSpeech() } catch {
                if error is CancellationError { throw error }
                usable = false
            }
        }
        if !usable {
            engine = nil
            try await downloadSpeech { progress(min(0.9, $0 * 0.9)) }
        }
        progress(0.9)
        if !speakerAssetsAvailable {
            do {
                let base = Self.speakerDownloadBase(in: directory)
                try MeetingSessionStore.privateDirectory(base)
                _ = try await SpeakerKit(PyannoteConfig(downloadBase: base.path, modelRepo: Self.speakerRepository, download: true, load: false, verbose: false))
            } catch {
                if error is CancellationError { throw error }
                throw MeetingEngineError.modelDownload
            }
            guard speakerAssetsAvailable else { throw MeetingEngineError.modelDownload }
        }
        progress(0.97)
        try await load()
        progress(1)
    }

    private func downloadSpeech(progress: @escaping @Sendable (Double) -> Void) async throws {
        let model: URL
        do {
            model = try await WhisperKit.download(variant: Self.modelName, downloadBase: directory.appendingPathComponent("Models")) { value in
                progress(value.fractionCompleted * 0.96)
            }
            let tokenizer = directory.appendingPathComponent("Tokenizer", isDirectory: true)
            try MeetingSessionStore.privateDirectory(tokenizer)
            for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
                let url = URL(string: "https://huggingface.co/\(Self.tokenizerRepository)/resolve/main/\(name)")!
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      (try? JSONSerialization.jsonObject(with: data)) != nil else { throw MeetingEngineError.modelDownload }
                try MeetingSessionStore.privateWrite(data, to: tokenizer.appendingPathComponent(name))
            }
            // Parse all tokenizer data locally before declaring setup complete.
            _ = try await StrictLocalTokenizer.load(from: tokenizer)
        } catch {
            if error is CancellationError { throw error }
            throw MeetingEngineError.modelDownload
        }
        let rootPath = directory.standardizedFileURL.path + "/"
        guard model.standardizedFileURL.path.hasPrefix(rootPath) else { throw MeetingEngineError.invalidModel }
        let manifest = Manifest(modelRelativePath: String(model.standardizedFileURL.path.dropFirst(rootPath.count)), model: Self.modelName)
        try MeetingSessionStore.privateWrite(JSONEncoder().encode(manifest), to: directory.appendingPathComponent("ready.json"))
        progress(1)
    }

    /// Loads from disk only. Speech and speaker models load in parallel; voice separation stays optional.
    func load() async throws {
        let speakerFolder = speakers == nil ? Self.readySpeakerFolder(in: directory) : nil
        let segmenterWorkers = min(6, max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        async let speechLoad: StrictLocalWhisperKit = loadSpeech()
        async let speakerLoad: SpeakerKit? = {
            guard let speakerFolder else { return nil }
            let config = PyannoteConfig(modelFolder: speakerFolder.path, download: false, load: true, verbose: false,
                                        concurrentSegmenterWorkers: segmenterWorkers)
            return try? await SpeakerKit(config)
        }()
        _ = try await speechLoad
        if let loadedSpeakers = await speakerLoad { speakers = loadedSpeakers }
    }

    @discardableResult
    private func loadSpeech() async throws -> StrictLocalWhisperKit {
        if let engine { return engine }
        if let loading { let value = try await loading.value; engine = value; return value }
        let directory = self.directory
        let loading = Task<StrictLocalWhisperKit, Error> {
            guard let model = Self.readyModelURL(in: directory) else { throw MeetingEngineError.modelMissing }
            let tokenizerDirectory = directory.appendingPathComponent("Tokenizer")
            // Direct local factory: malformed/missing tokenizers throw instead of using WhisperKit's Hub fallback.
            let tokenizer = try await StrictLocalTokenizer.load(from: tokenizerDirectory)
            let config = WhisperKitConfig(model: Self.modelName, modelFolder: model.path, tokenizerFolder: tokenizerDirectory,
                                          computeOptions: ModelComputeOptions(melCompute: .cpuAndGPU,
                                                                             audioEncoderCompute: .cpuAndNeuralEngine,
                                                                             textDecoderCompute: .cpuAndNeuralEngine),
                                          verbose: false, logLevel: .none, prewarm: false, load: false, download: false)
            let candidate = try await StrictLocalWhisperKit(config)
            candidate.tokenizer = tokenizer
            candidate.textDecoder.isModelMultilingual = true
            try await candidate.loadModels()
            return candidate
        }
        self.loading = loading
        defer { self.loading = nil }
        let value = try await loading.value
        engine = value
        return value
    }

    /// Frees model memory once no recording is waiting. The next meeting loads it again after capture.
    func unload() async {
        if let engine { await engine.unloadModels() }
        engine = nil
        if let speakers { await speakers.unloadModels() }
        speakers = nil
    }

    func recognize(_ samples: [Float], progress: @escaping @Sendable (Double) -> Void) async throws -> MeetingRecognition {
        let total = Double(samples.count) / MeetingAudioAssembler.sampleRate
        let result = try await recognizeTracks([(.system, samples)], meetingAudioSeconds: total) { detail in
            progress(detail.fraction)
        }
        return result[.system] ?? MeetingRecognition(lines: [], turns: [], languages: [])
    }

    /// Diarizes each track with live progress, then schedules all speech regions across tracks
    /// longest-first in a sliding worker pool so no worker stalls at batch or track boundaries.
    func recognizeTracks(_ tracks: [(source: MeetingAudioSource, samples: [Float])],
                         meetingAudioSeconds: Double,
                         progress: @escaping @Sendable (MeetingTranscriptionProgress) -> Void) async throws -> [MeetingAudioSource: MeetingRecognition] {
        guard let engine else { throw MeetingEngineError.modelMissing }
        guard !tracks.isEmpty else {
            progress(MeetingTranscriptionProgress(fraction: 1, processedAudioSeconds: meetingAudioSeconds, totalAudioSeconds: meetingAudioSeconds, estimatedRemainingSeconds: 0))
            return [:]
        }
        let began = Date()
        let rate = MeetingAudioAssembler.sampleRate
        let totalSamples = max(1.0, tracks.reduce(0.0) { $0 + Double($1.samples.count) })
        let diarizationShare = speakers == nil ? 0.02 : 0.10
        let decodeShare = 0.86

        progress(MeetingTranscriptionProgress(fraction: 0.02, processedAudioSeconds: 0, totalAudioSeconds: meetingAudioSeconds, estimatedRemainingSeconds: nil))

        // 1. Voice separation per track with live SpeakerKit progress.
        var turnsByTrack = Array(repeating: [SpeakerTurn](), count: tracks.count)
        var diarizedSamples = 0.0
        for (trackIndex, track) in tracks.enumerated() {
            try Task.checkCancellation()
            let trackWeight = Double(track.samples.count) / totalSamples
            if let speakers {
                let baseFraction = 0.02 + (diarizationShare - 0.02) * (diarizedSamples / totalSamples)
                let spanFraction = (diarizationShare - 0.02) * trackWeight
                if let result = try? await speakers.diarize(audioArray: track.samples, options: PyannoteDiarizationOptions(), progressCallback: { p in
                    let f = baseFraction + spanFraction * min(1, max(0, p.fractionCompleted))
                    progress(MeetingTranscriptionProgress(fraction: f,
                                                          processedAudioSeconds: 0,
                                                          totalAudioSeconds: meetingAudioSeconds,
                                                          estimatedRemainingSeconds: nil))
                }) {
                    turnsByTrack[trackIndex] = result.segments.compactMap { segment in
                        guard let speaker = segment.speaker.speakerId, segment.endTime > segment.startTime else { return nil }
                        return SpeakerTurn(speaker: speaker, startSeconds: Double(segment.startTime), endSeconds: Double(segment.endTime))
                    }
                }
            }
            diarizedSamples += Double(track.samples.count)
        }
        try Task.checkCancellation()
        let diarized = Date()
        progress(MeetingTranscriptionProgress(fraction: diarizationShare, processedAudioSeconds: 0, totalAudioSeconds: meetingAudioSeconds, estimatedRemainingSeconds: nil))

        // 2. Plan speech regions across every track and split monologues at quiet moments.
        struct PlannedRegion: Sendable {
            let id: Int
            let trackIndex: Int
            let region: MeetingSpeechRegions.Region
            var duration: Double { max(0.1, region.endSeconds - region.startSeconds) }
        }
        var plannedRegions: [PlannedRegion] = []
        for (trackIndex, track) in tracks.enumerated() {
            let trackSeconds = Double(track.samples.count) / rate
            let planned = turnsByTrack[trackIndex].isEmpty
                ? [MeetingSpeechRegions.Region(startSeconds: 0, endSeconds: trackSeconds, speaker: nil)]
                : MeetingSpeechRegions.plan(turns: turnsByTrack[trackIndex], totalSeconds: trackSeconds)
            let windows = planned.flatMap { MeetingSpeechRegions.windows(for: $0, samples: track.samples, sampleRate: rate) }
            for region in windows {
                plannedRegions.append(PlannedRegion(id: plannedRegions.count, trackIndex: trackIndex, region: region))
            }
        }
        let totalSpeechSeconds = max(0.1, plannedRegions.reduce(0.0) { $0 + $1.duration })

        // 3. Longest-processing-time-first sliding worker pool across all regions (eliminates straggler barriers).
        struct DecodedRegion: Sendable {
            let id: Int
            let trackIndex: Int
            let region: MeetingSpeechRegions.Region
            let language: String
            let lines: [TimedText]
        }
        let workerCount = min(6, max(4, ProcessInfo.processInfo.activeProcessorCount / 2))
        let sortedRegions = plannedRegions.sorted { $0.duration > $1.duration }
        var decodedByID = Array<DecodedRegion?>(repeating: nil, count: plannedRegions.count)
        var completedSpeech = 0.0
        var estimator = TranscriptionETAEstimator()
        estimator.start(at: ProcessInfo.processInfo.systemUptime)

        let baseOptions = Self.decodingOptions(language: nil)
        try await withThrowingTaskGroup(of: (DecodedRegion, Double).self) { group in
            var nextIndex = 0
            func enqueueNext() {
                guard nextIndex < sortedRegions.count else { return }
                let item = sortedRegions[nextIndex]
                nextIndex += 1
                let slice = Self.slice(item.region, in: tracks[item.trackIndex].samples, rate: rate)
                group.addTask {
                    let result = try await Self.decodeOne(region: item.region, audio: slice, language: nil, options: baseOptions, engine: engine)
                    return (DecodedRegion(id: item.id, trackIndex: item.trackIndex, region: item.region, language: result.language, lines: result.lines), item.duration)
                }
            }
            for _ in 0..<min(workerCount, sortedRegions.count) { enqueueNext() }
            for try await (item, duration) in group {
                try Task.checkCancellation()
                decodedByID[item.id] = item
                completedSpeech += duration
                let decodeFraction = min(1, completedSpeech / totalSpeechSeconds)
                let overall = diarizationShare + decodeShare * decodeFraction
                let processedMeetingAudio = meetingAudioSeconds * decodeFraction
                let eta = estimator.update(completedWork: completedSpeech, totalWork: totalSpeechSeconds, now: ProcessInfo.processInfo.systemUptime)
                progress(MeetingTranscriptionProgress(fraction: overall,
                                                      processedAudioSeconds: processedMeetingAudio,
                                                      totalAudioSeconds: meetingAudioSeconds,
                                                      estimatedRemainingSeconds: eta))
                enqueueNext()
            }
        }

        // 4. Re-decode any stray third-language detections per track using that track's dominant KO/EN language.
        var redecodedCount = 0
        var strayJobs: [(id: Int, trackIndex: Int, region: MeetingSpeechRegions.Region, language: String)] = []
        for trackIndex in tracks.indices {
            let trackItems = decodedByID.compactMap { $0 }.filter { $0.trackIndex == trackIndex }
            var counts: [String: Int] = [:]
            for item in trackItems where Self.meetingLanguages.contains(item.language) && !item.lines.isEmpty {
                counts[item.language, default: 0] += 1
            }
            let main = counts.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }?.key ?? Self.meetingLanguages[0]
            for item in trackItems where !Self.meetingLanguages.contains(item.language) {
                strayJobs.append((item.id, trackIndex, item.region, main))
            }
        }
        if !strayJobs.isEmpty {
            redecodedCount = strayJobs.count
            try await withThrowingTaskGroup(of: DecodedRegion.self) { group in
                var nextIndex = 0
                func enqueueStray() {
                    guard nextIndex < strayJobs.count else { return }
                    let job = strayJobs[nextIndex]
                    nextIndex += 1
                    let slice = Self.slice(job.region, in: tracks[job.trackIndex].samples, rate: rate)
                    let opts = Self.decodingOptions(language: job.language)
                    group.addTask {
                        let result = try await Self.decodeOne(region: job.region, audio: slice, language: job.language, options: opts, engine: engine)
                        return DecodedRegion(id: job.id, trackIndex: job.trackIndex, region: job.region, language: result.language, lines: result.lines)
                    }
                }
                for _ in 0..<min(workerCount, strayJobs.count) { enqueueStray() }
                for try await item in group {
                    try Task.checkCancellation()
                    decodedByID[item.id] = item
                    enqueueStray()
                }
            }
        }

        progress(MeetingTranscriptionProgress(fraction: 1, processedAudioSeconds: meetingAudioSeconds, totalAudioSeconds: meetingAudioSeconds, estimatedRemainingSeconds: 0))

        if ProcessInfo.processInfo.environment["MEETING_ENGINE_TIMING"] != nil {
            // Numbers only; never audio or text.
            FileHandle.standardError.write(Data(String(format: "TIMING tracks=%d audio=%.0fs voices=%.1fs regions=%d speech=%.0fs decode=%.1fs workers=%d redecoded=%d\n",
                tracks.count, meetingAudioSeconds, diarized.timeIntervalSince(began), plannedRegions.count, totalSpeechSeconds,
                Date().timeIntervalSince(diarized), workerCount, redecodedCount).utf8))
        }

        var output: [MeetingAudioSource: MeetingRecognition] = [:]
        for (trackIndex, track) in tracks.enumerated() {
            let items = decodedByID.compactMap { $0 }.filter { $0.trackIndex == trackIndex }
            let lines = items.flatMap(\.lines).sorted { $0.startSeconds < $1.startSeconds }
            let languages = Set(items.filter { !$0.lines.isEmpty }.map(\.language)).sorted()
            output[track.source] = MeetingRecognition(lines: lines, turns: turnsByTrack[trackIndex], languages: languages)
        }
        return output
    }

    private nonisolated static func decodingOptions(language: String?) -> DecodingOptions {
        DecodingOptions(verbose: false, task: .transcribe, language: language, temperature: 0,
                        temperatureFallbackCount: 2, usePrefillPrompt: true, detectLanguage: language == nil,
                        skipSpecialTokens: true, withoutTimestamps: false, wordTimestamps: false,
                        suppressBlank: true, compressionRatioThreshold: 2.4,
                        logProbThreshold: -1, noSpeechThreshold: 0.65, concurrentWorkerCount: 1)
    }

    private nonisolated static func slice(_ region: MeetingSpeechRegions.Region, in samples: [Float], rate: Double) -> [Float] {
        let start = max(0, min(samples.count, Int(region.startSeconds * rate)))
        let end = max(start, min(samples.count, Int(region.endSeconds * rate)))
        return Array(samples[start..<end])
    }

    private nonisolated static func decodeOne(region: MeetingSpeechRegions.Region, audio: [Float], language: String?,
                                              options: DecodingOptions, engine: StrictLocalWhisperKit) async throws -> (language: String, lines: [TimedText]) {
        let results = await engine.transcribe(audioArrays: [audio], decodeOptions: options)
        guard let found = results.first.flatMap({ $0 }) else { throw MeetingEngineError.transcriptionFailed }
        let length = region.endSeconds - region.startSeconds
        let lines = found.flatMap(\.segments).compactMap { segment -> TimedText? in
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.noSpeechProb < 0.65, segment.compressionRatio < 2.8, segment.avgLogprob > -1.3 else { return nil }
            let start = min(length, max(0, Double(segment.start)))
            let end = min(length, max(start, Double(segment.end)))
            return TimedText(startSeconds: region.startSeconds + start, endSeconds: region.startSeconds + end, text: text, voice: region.speaker)
        }
        return (found.first?.language ?? language ?? Self.meetingLanguages[0], lines)
    }
}

/// Never invokes the upstream tokenizer loader, which can otherwise download on parse failure.
private final class StrictLocalWhisperKit: WhisperKit {
    override func loadTokenizerIfNeeded() async throws {
        guard tokenizer != nil else { throw MeetingEngineError.invalidModel }
    }
}

/// Adapter using the dependency's disk-only tokenizer factory. Segment timestamps are used;
/// word-level alignment is intentionally disabled.
private struct StrictLocalTokenizer: WhisperTokenizer {
    let underlying: TokenizerWrapper
    let specialTokens: SpecialTokens
    let allLanguageTokens: Set<Int>

    static func load(from directory: URL) async throws -> Self {
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json"] {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            _ = try JSONSerialization.jsonObject(with: data)
        }
        let tokenizer = try await AutoTokenizerWrapper.from(modelFolder: directory)
        func id(_ token: String) throws -> Int {
            guard let value = tokenizer.convertTokenToId(token) else { throw MeetingEngineError.invalidModel }
            return value
        }
        let special = try SpecialTokens(endToken: id("<|endoftext|>"), englishToken: id("<|en|>"),
                                        noSpeechToken: id("<|nospeech|>"), noTimestampsToken: id("<|notimestamps|>"),
                                        specialTokenBegin: id("<|endoftext|>"), startOfPreviousToken: id("<|startofprev|>"),
                                        startOfTranscriptToken: id("<|startoftranscript|>"), timeTokenBegin: id("<|0.00|>"),
                                        transcribeToken: id("<|transcribe|>"), translateToken: id("<|translate|>"), whitespaceToken: tokenizer.encode(text: " ", addSpecialTokens: false).first ?? 220)
        let data = try Data(contentsOf: directory.appendingPathComponent("tokenizer.json"))
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let added = json["added_tokens"] as? [[String: Any]] else { throw MeetingEngineError.invalidModel }
        let languages = Set(added.compactMap { item -> Int? in
            guard let text = item["content"] as? String, text.range(of: "^<\\|[a-z]{2,3}\\|>$", options: .regularExpression) != nil else { return nil }
            return item["id"] as? Int
        })
        guard languages.contains(try id("<|ko|>")), languages.contains(special.englishToken) else { throw MeetingEngineError.invalidModel }
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
