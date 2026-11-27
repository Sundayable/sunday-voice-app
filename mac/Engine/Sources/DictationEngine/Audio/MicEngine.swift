import AVFoundation
import os

/// One long-lived microphone engine. It starts on the trigger press (before dictation is
/// confirmed), keeps the last ~1.2s in memory only, and stops after an idle deadline.
/// Audio leaves this class only through `beginStreaming`'s sink.
///
/// AVAudioEngine input taps deliver 100ms blocks on macOS regardless of the requested size,
/// so capture uses an AVAudioSinkNode (≈10ms render callbacks). The real-time callback only
/// copies samples into a preallocated ring; a consumer thread converts to PCM16 mono 24 kHz.
final class MicEngine {
    static let outputRate = 24000.0
    private let control = DispatchQueue(label: "koen.mic.control", qos: .userInteractive)
    private var engine: AVAudioEngine?
    private var sinkNode: AVAudioSinkNode?
    private var running = false
    private var idleDeadline = 0.0
    private var idleTimer: DispatchSourceTimer?
    private var configObserver: NSObjectProtocol?
    private var wiredFormat: AVAudioFormat?
    private var prepared = false

    // Real-time → consumer handoff. Guarded by rtLock; never allocates on the audio thread.
    private let rtLock = OSAllocatedUnfairLock()
    private let rtCapacity = 192_000
    private let rtSamples: UnsafeMutablePointer<Float>
    private var rtStart = 0, rtCount = 0
    private var rtRate = 48000.0, rtChannels = 1, rtGeneration = 0
    private var rtCallbacks = 0
    private let wake = DispatchSemaphore(value: 0)

    // Consumer state. Guarded by lock.
    private let lock = NSLock()
    private var chunks: [(end: Double, data: Data)] = []
    private var sink: ((Data) -> Void)?
    private var streamedAny = false
    private var recentPeak: Float = 0
    private var startRequestedAt = 0.0
    private var firstFramesAt: Double?
    private var lastStartMs: Double?
    private var lastFirstFramesMs: Double?

    /// Called on the main queue when the engine cannot start; argument is a reason code.
    var onFailure: ((String) -> Void)?
    /// Called on the main queue the first time frames arrive after a cold start.
    var onFramesFlowing: ((Double) -> Void)?
    var preRollSeconds = 1.2

    init() {
        rtSamples = .allocate(capacity: rtCapacity)
        let thread = Thread { [unowned self] in self.consume() }
        thread.name = "Dictation microphone"; thread.qualityOfService = .userInteractive; thread.start()
    }

    var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    var level: Float { lock.lock(); defer { lock.unlock() }; return recentPeak }
    /// Last cold start: engine start() duration and request → first frames, in ms.
    var coldStartTiming: (start: Double?, firstFrames: Double?) { lock.lock(); defer { lock.unlock() }; return (lastStartMs, lastFirstFramesMs) }

    /// Build the engine graph ahead of the first press (no capture, no microphone indicator).
    func prepare() { control.async { self.build() } }

    /// Start capture if needed and keep it alive for at least `keepAlive` seconds.
    func warm(keepAlive: Double) {
        let now = uptime()
        control.async { self.extend(now + keepAlive); self.startIfNeeded(requestedAt: now) }
    }

    /// Flush buffered audio newer than `since` (capped), then stream live audio to `sink`.
    /// Returns the seconds of pre-roll delivered. Ordering is guaranteed by the lock.
    @discardableResult func beginStreaming(since: Double, maxPreRoll: Double, sink: @escaping (Data) -> Void) -> Double {
        lock.lock(); defer { lock.unlock() }
        let picked = selectPreRoll(chunks.map { ($0.end, $0.data.count) }, since: since, limitBytes: Int(maxPreRoll * MicEngine.outputRate) * 2)
        for index in picked { sink(chunks[index].data) }
        self.sink = sink; streamedAny = !picked.isEmpty
        return Double(picked.reduce(0) { $0 + chunks[$1].data.count }) / 2 / MicEngine.outputRate
    }

    func endStreaming(keepAlive: Double) {
        lock.lock(); sink = nil; streamedAny = false; lock.unlock()
        let now = uptime()
        control.async { self.extend(now + keepAlive) }
    }

    func shutdown() { control.sync { self.stopEngine() } }

    // MARK: engine lifecycle (control queue)

    private func extend(_ deadline: Double) {
        idleDeadline = max(idleDeadline, deadline)
        idleTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: control)
        timer.schedule(deadline: .now() + max(0, idleDeadline - uptime()) + 0.01)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.lock.lock(); let streaming = self.sink != nil; self.lock.unlock()
            if streaming { self.extend(uptime() + 1) } else if uptime() >= self.idleDeadline { self.stopEngine() }
        }
        idleTimer = timer; timer.resume()
    }

    private func startIfNeeded(requestedAt: Double) {
        lock.lock(); let alreadyRunning = running; lock.unlock()
        if alreadyRunning { return }
        let begin = uptime()
        let reusedPrepared = engine != nil && prepared
        guard let audio = build() else { fail("no_microphone_input"); return }
        lock.lock(); startRequestedAt = requestedAt; firstFramesAt = nil; lock.unlock()
        do {
            try audio.start()
            lock.lock(); running = true; lastStartMs = (uptime() - begin) * 1000; lock.unlock()
        } catch {
            guard reusedPrepared else { fail("microphone_start_failed"); return }
            wiredFormat = nil; prepared = false
            guard let rebuilt = build() else { fail("no_microphone_input"); return }
            do {
                try rebuilt.start()
                lock.lock(); running = true; lastStartMs = (uptime() - begin) * 1000; lock.unlock()
            } catch { fail("microphone_start_failed") }
        }
    }

    /// Create (or re-wire after a device change) input → sink, then prepare. Control queue only.
    @discardableResult private func build() -> AVAudioEngine? {
        let audio = engine ?? AVAudioEngine()
        let input = audio.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { return nil }
        if engine != nil, sinkNode != nil, wiredFormat == format, prepared {
            rtLock.withLockUnchecked {
                rtRate = format.sampleRate; rtChannels = Int(format.channelCount); rtStart = 0; rtCount = 0; rtGeneration += 1; rtCallbacks = 0
            }
            return audio
        }
        if sinkNode == nil {
            let node = AVAudioSinkNode { [unowned self] _, frames, list in self.capture(frames, list) }
            audio.attach(node); sinkNode = node
        }
        if wiredFormat != format {
            audio.disconnectNodeInput(sinkNode!)
            audio.connect(input, to: sinkNode!, format: format); wiredFormat = format
        }
        rtLock.withLockUnchecked {
            rtRate = format.sampleRate; rtChannels = Int(format.channelCount); rtStart = 0; rtCount = 0; rtGeneration += 1; rtCallbacks = 0
        }
        if engine == nil {
            engine = audio
            configObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: nil) { [weak self] _ in
                self?.control.async { self?.restartAfterDeviceChange() }
            }
        }
        audio.prepare()
        prepared = true
        return audio
    }

    private func restartAfterDeviceChange() {
        wiredFormat = nil; prepared = false
        lock.lock(); let wanted = running; lock.unlock()
        engine?.stop(); lock.lock(); running = false; lock.unlock()
        if wanted || idleDeadline > uptime() { startIfNeeded(requestedAt: uptime()) }
    }

    private func stopEngine() {
        engine?.stop()
        lock.lock(); running = false; chunks.removeAll(); recentPeak = 0; lock.unlock()
        rtLock.withLockUnchecked { rtCount = 0; rtGeneration += 1 }
    }

    private func fail(_ code: String) {
        lock.lock(); running = false; lock.unlock()
        DispatchQueue.main.async { self.onFailure?(code) }
    }

    // MARK: real-time callback (audio I/O thread)

    private func capture(_ frames: AVAudioFrameCount, _ list: UnsafePointer<AudioBufferList>) -> OSStatus {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard let first = buffers.first, let raw = first.mData else { return noErr }
        let samples = raw.assumingMemoryBound(to: Float.self)
        let stride = max(1, Int(first.mNumberChannels))
        let count = Int(frames)
        rtLock.withLockUnchecked {
            for i in 0..<count {
                let index = (rtStart + rtCount) % rtCapacity
                rtSamples[index] = samples[i * stride]
                if rtCount < rtCapacity { rtCount += 1 } else { rtStart = (rtStart + 1) % rtCapacity }
            }
            rtCallbacks += 1
        }
        wake.signal()
        return noErr
    }

    // MARK: consumer thread

    private func consume() {
        var pending = [Float](); var generation = -1; var rate = 48000.0
        var converter: AVAudioConverter?
        let output = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: MicEngine.outputRate, channels: 1, interleaved: true)!
        while true {
            wake.wait()
            var drained = [Float](); var currentGeneration = 0; var currentRate = 0.0
            rtLock.withLockUnchecked {
                currentGeneration = rtGeneration; currentRate = rtRate
                if rtCount > 0 {
                    drained.reserveCapacity(rtCount)
                    for i in 0..<rtCount { drained.append(rtSamples[(rtStart + i) % rtCapacity]) }
                    rtStart = 0; rtCount = 0
                }
            }
            if currentGeneration != generation {
                generation = currentGeneration; rate = currentRate; pending.removeAll()
                converter = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1).flatMap { AVAudioConverter(from: $0, to: output) }
            }
            if drained.isEmpty { continue }
            pending.append(contentsOf: drained)
            lock.lock()
            if firstFramesAt == nil {
                let now = uptime(); firstFramesAt = now; lastFirstFramesMs = (now - startRequestedAt) * 1000
                let at = now; DispatchQueue.main.async { self.onFramesFlowing?(at) }
            }
            // First streamed audio leaves immediately; afterwards ~40ms batches keep IPC light.
            let urgent = sink != nil && !streamedAny
            lock.unlock()
            if !urgent && Double(pending.count) < rate * 0.04 { continue }
            guard let converter = converter, let data = convert(pending, rate: rate, converter: converter, output: output) else { pending.removeAll(); continue }
            pending.removeAll()
            deliver(data, end: uptime())
        }
    }

    private func convert(_ samples: [Float], rate: Double, converter: AVAudioConverter, output: AVAudioFormat) -> Data? {
        guard let inputFormat = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1),
              let source = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: AVAudioFrameCount(samples.count)) else { return nil }
        source.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * MicEngine.outputRate / rate) + 32
        guard let converted = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }
        var consumed = false; var error: NSError?
        converter.convert(to: converted, error: &error) { _, status in
            if consumed { status.pointee = .noDataNow; return nil }
            consumed = true; status.pointee = .haveData; return source
        }
        guard error == nil, converted.frameLength > 0, let pointer = converted.int16ChannelData?[0] else { return nil }
        return Data(bytes: pointer, count: Int(converted.frameLength) * 2)
    }

    private func deliver(_ data: Data, end: Double) {
        var peak: Int16 = 0
        data.withUnsafeBytes { raw in for v in raw.bindMemory(to: Int16.self) { peak = max(peak, v == Int16.min ? Int16.max : abs(v)) } }
        lock.lock(); defer { lock.unlock() }
        chunks.append((end, data))
        let limit = Int(preRollSeconds * MicEngine.outputRate) * 2
        var total = chunks.reduce(0) { $0 + $1.data.count }
        while total > limit, chunks.count > 1 { total -= chunks.removeFirst().data.count }
        recentPeak = Float(peak) / 32768
        if let sink = sink { sink(data); streamedAny = true }
    }
}

/// Pure pre-roll selection, shared with tests: newest chunks after `since`, capped to `limitBytes`.
func selectPreRoll(_ chunks: [(end: Double, bytes: Int)], since: Double, limitBytes: Int) -> [Int] {
    var picked = chunks.indices.filter { chunks[$0].end > since }
    var total = picked.reduce(0) { $0 + chunks[$1].bytes }
    while total > limitBytes, !picked.isEmpty { total -= chunks[picked.removeFirst()].bytes }
    return picked
}
