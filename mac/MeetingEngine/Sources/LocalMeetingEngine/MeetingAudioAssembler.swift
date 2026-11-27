import AVFoundation
import Foundation

/// Turns the crash-safe capture files of one recording back into continuous audio per source.
enum MeetingAudioAssembler {
    static let sampleRate: Double = 16_000

    /// Every capture file that has a saved description, plus audio whose description was never
    /// written because the app stopped mid-file. Those are placed after the last known audio.
    static func chunks(in directory: URL) -> [MeetingChunk] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var chunks: [MeetingChunk] = []
        var described = Set<String>()
        for file in files where file.pathExtension == "json" && file.deletingPathExtension().pathExtension == "caf" {
            guard let data = try? Data(contentsOf: file), let saved = try? JSONDecoder().decode(MeetingChunk.self, from: data) else { continue }
            let audio = file.deletingPathExtension()
            guard FileManager.default.fileExists(atPath: audio.path) else { continue }
            // The folder may have moved since capture; only the file name is trusted.
            chunks.append(MeetingChunk(id: saved.id, source: saved.source, startSeconds: saved.startSeconds, durationSeconds: saved.durationSeconds,
                                       url: audio, rms: saved.rms, recordedAt: saved.recordedAt, endedAt: saved.endedAt))
            described.insert(audio.lastPathComponent)
        }
        for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where file.pathExtension == "caf" && !described.contains(file.lastPathComponent) {
            let name = file.deletingPathExtension().lastPathComponent
            guard let source = MeetingAudioSource.allCases.first(where: { name.hasSuffix("-\($0.rawValue)") }),
                  let audio = try? AVAudioFile(forReading: file), audio.length > 0 else { continue }
            let duration = Double(audio.length) / audio.fileFormat.sampleRate
            let end = chunks.filter { $0.source == source }.map { $0.startSeconds + $0.durationSeconds }.max() ?? 0
            chunks.append(MeetingChunk(id: UUID(), source: source, startSeconds: end, durationSeconds: duration, url: file, rms: 1))
        }
        return chunks.sorted { $0.startSeconds < $1.startSeconds }
    }

    /// 16 kHz mono samples on the meeting clock. Silence fills capture gaps so both sources stay aligned.
    /// Unreadable files are skipped and counted, never fatal: the rest of the meeting is still transcribed.
    static func samples(for source: MeetingAudioSource, chunks: [MeetingChunk]) -> (samples: [Float], unreadable: Int) {
        var samples: [Float] = []
        var unreadable = 0
        let own = chunks.filter { $0.source == source }.sorted { $0.startSeconds < $1.startSeconds }
        if let last = own.last { samples.reserveCapacity(Int((last.startSeconds + last.durationSeconds) * sampleRate) + 1) }
        for chunk in own {
            guard let audio = try? read(chunk.url), !audio.isEmpty else { unreadable += 1; continue }
            let position = Int((chunk.startSeconds * sampleRate).rounded())
            // Sub-quarter-second timestamp jitter is appended as contiguous audio; only real gaps are padded.
            if position > samples.count + Int(sampleRate / 4) {
                samples.append(contentsOf: repeatElement(0, count: position - samples.count))
            }
            samples.append(contentsOf: audio)
        }
        return (samples, unreadable)
    }

    static func read(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0 else { return [] }
        // Thirty-second blocks bound memory for long imports; capture files fit in one block.
        let blockFrames = AVAudioFrameCount(format.sampleRate * 30)
        guard let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: blockFrames) else { throw MeetingEngineError.audioFormat }
        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(file.length) * sampleRate / format.sampleRate) + 1024)
        if format.sampleRate == sampleRate, format.channelCount == 1, format.commonFormat == .pcmFormatFloat32 {
            while file.framePosition < file.length {
                try file.read(into: input)
                guard input.frameLength > 0, let channel = input.floatChannelData else { break }
                samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(input.frameLength)))
            }
            return samples
        }
        guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(sampleRate * 30) + 4096) else {
            throw MeetingEngineError.audioFormat
        }
        var readFailure: Error?
        var finished = false
        while !finished {
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { _, state in
                guard file.framePosition < file.length else { state.pointee = .endOfStream; return nil }
                do {
                    try file.read(into: input)
                    guard input.frameLength > 0 else { state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData
                    return input
                } catch {
                    readFailure = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readFailure { throw readFailure }
            guard status != .error, failure == nil, let channel = output.floatChannelData else { throw MeetingEngineError.audioFormat }
            samples.append(contentsOf: UnsafeBufferPointer(start: channel[0], count: Int(output.frameLength)))
            finished = status == .endOfStream || (status == .inputRanDry && file.framePosition >= file.length) || output.frameLength == 0
        }
        return samples
    }

    static func rms(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var total: Double = 0
        for value in samples { total += Double(value) * Double(value) }
        return Float((total / Double(samples.count)).squareRoot())
    }

    /// Compact copy of one source kept beside the transcript when the user keeps recordings.
    static func writeArchive(_ samples: [Float], to url: URL) throws {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw MeetingEngineError.audioFormat
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: sampleRate,
                                       AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000]
        try? FileManager.default.removeItem(at: url)
        var file: AVAudioFile? = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        let block = Int(sampleRate) * 30
        var offset = 0
        while offset < samples.count {
            let count = min(block, samples.count - offset)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let channel = buffer.floatChannelData else {
                throw MeetingEngineError.audioFormat
            }
            samples.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress! + offset, count: count) }
            buffer.frameLength = AVAudioFrameCount(count)
            try file?.write(from: buffer)
            offset += count
        }
        file = nil // Closes and finalizes the container.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Splits a local audio file into capture-style files so imports and diagnostics use the real pipeline.
    static func importFile(_ url: URL, as source: MeetingAudioSource, into directory: URL, chunkSeconds: Double = 20) throws -> Double {
        let audio = try read(url)
        guard !audio.isEmpty, let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else {
            throw MeetingEngineError.invalidFile
        }
        let size = Int(chunkSeconds * sampleRate)
        var offset = 0
        while offset < audio.count {
            let count = min(size, audio.count - offset)
            let id = UUID()
            let target = directory.appendingPathComponent("\(id.uuidString)-\(source.rawValue).caf")
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)), let channel = buffer.floatChannelData else {
                throw MeetingEngineError.invalidFile
            }
            audio.withUnsafeBufferPointer { channel[0].update(from: $0.baseAddress! + offset, count: count) }
            buffer.frameLength = AVAudioFrameCount(count)
            var file: AVAudioFile? = try AVAudioFile(forWriting: target, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file?.write(from: buffer)
            file = nil
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            let slice = Array(audio[offset..<(offset + count)])
            let chunk = MeetingChunk(id: id, source: source, startSeconds: Double(offset) / sampleRate,
                                     durationSeconds: Double(count) / sampleRate, url: target, rms: rms(slice))
            try MeetingSessionStore.privateWrite(JSONEncoder().encode(chunk), to: target.appendingPathExtension("json"))
            offset += count
        }
        return Double(audio.count) / sampleRate
    }
}
