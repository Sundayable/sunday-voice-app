import Foundation

/// Chooses which stretches of a source are decoded. In a call each source is silent while the
/// other side talks, so decoding only where a voice was found roughly halves the work and keeps
/// the recognizer away from long silences, where it tends to invent text.
/// Every region holds one voice, so each recognized line belongs to exactly one person.
enum MeetingSpeechRegions {
    struct Region: Equatable, Sendable {
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let speaker: Int?
    }

    /// One recognizer window is 30 s; staying under it lets a region decode in a single pass.
    static let maxWindowSeconds: TimeInterval = 28
    static let paddingSeconds: TimeInterval = 0.3
    static let joinGapSeconds: TimeInterval = 1.5
    /// Shorter blips are breaths and clicks, not words.
    static let minimumTurnSeconds: TimeInterval = 0.3

    static func plan(turns: [SpeakerTurn], totalSeconds: TimeInterval) -> [Region] {
        let ordered = turns.filter { $0.endSeconds - $0.startSeconds >= minimumTurnSeconds }.sorted { $0.startSeconds < $1.startSeconds }
        // 1. Islands: consecutive turns by the same voice with only a short pause between them.
        var islands: [(start: TimeInterval, end: TimeInterval, speaker: Int)] = []
        for turn in ordered {
            if let last = islands.last, last.speaker == turn.speaker, turn.startSeconds - last.end <= joinGapSeconds {
                islands[islands.count - 1].end = max(last.end, turn.endSeconds)
            } else {
                islands.append((turn.startSeconds, turn.endSeconds, turn.speaker))
            }
        }
        // 2. Pack neighbouring islands of one voice into a window while the span still fits.
        //    Another voice in between always starts a new region. A monologue longer than a
        //    window stays whole and is cut at pauses by the recognizer.
        var packed: [(start: TimeInterval, end: TimeInterval, speaker: Int)] = []
        for island in islands {
            if let last = packed.last, last.speaker == island.speaker, island.end - last.start <= maxWindowSeconds {
                packed[packed.count - 1].end = max(last.end, island.end)
            } else {
                packed.append(island)
            }
        }
        // 3. Widen slightly for word onsets, without reaching into the neighbouring voice.
        return packed.indices.map { index in
            let item = packed[index]
            var start = max(0, item.start - paddingSeconds)
            var end = min(totalSeconds, item.end + paddingSeconds)
            if index > 0 { start = max(start, min(item.start, (packed[index - 1].end + item.start) / 2)) }
            if index + 1 < packed.count { end = min(end, max(item.end, (item.end + packed[index + 1].start) / 2)) }
            return Region(startSeconds: start, endSeconds: max(start, end), speaker: item.speaker)
        }
    }

    /// Cuts a region longer than one recognizer window at its quietest moments, so every piece
    /// decodes in a single pass and all pieces of a meeting can be decoded side by side.
    static func windows(for region: Region, samples: [Float], sampleRate: Double) -> [Region] {
        var pieces: [Region] = []
        var start = region.startSeconds
        let frame = max(1, Int(sampleRate / 10))
        while region.endSeconds - start > maxWindowSeconds {
            // Look for the pause in the last quarter of the window: early enough to stay inside it,
            // late enough that pieces stay long (each piece costs a full recognizer pass).
            let low = max(0, min(samples.count, Int((start + maxWindowSeconds * 0.75) * sampleRate)))
            let high = max(low, min(samples.count, Int((start + maxWindowSeconds) * sampleRate)))
            var cut = high
            var quietest = Float.greatestFiniteMagnitude
            var position = low
            while position + frame <= high {
                var energy: Float = 0
                for index in position..<(position + frame) { energy += samples[index] * samples[index] }
                if energy < quietest { quietest = energy; cut = position + frame / 2 }
                position += frame
            }
            let seconds = Double(cut) / sampleRate
            guard seconds > start + 1 else { break }
            pieces.append(Region(startSeconds: start, endSeconds: seconds, speaker: region.speaker))
            start = seconds
        }
        pieces.append(Region(startSeconds: start, endSeconds: region.endSeconds, speaker: region.speaker))
        return pieces
    }
}
