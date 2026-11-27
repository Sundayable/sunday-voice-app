import Foundation

/// Pure post-meeting assembly: who said each line, removal of loudspeaker echo, readable paragraphs.
/// No audio, model or file access here, so every rule is unit-tested with plain values.
enum MeetingTranscriptBuilder {
    struct Line: Equatable, Sendable {
        var source: MeetingAudioSource
        /// Voice index inside its source; nil when voices could not be separated.
        var voice: Int?
        var startSeconds: TimeInterval
        var endSeconds: TimeInterval
        var text: String
    }

    /// A voice heard for less than this share of a source's speech (and less than `minorVoiceSeconds`)
    /// is treated as a split of the main voice rather than another person.
    static let minorVoiceShare = 0.08
    static let minorVoiceSeconds: TimeInterval = 25
    /// A meeting-audio voice heard for at least this long gets its own number.
    static let remoteVoiceSeconds: TimeInterval = 4
    static let paragraphGapSeconds: TimeInterval = 2
    static let paragraphMaxSeconds: TimeInterval = 75

    /// Gives each recognized line the voice that is speaking for most of its duration.
    static func attribute(_ lines: [TimedText], turns: [SpeakerTurn], source: MeetingAudioSource) -> [Line] {
        let ordered = turns.sorted { $0.startSeconds < $1.startSeconds }
        return lines.map { line in
            if let voice = line.voice {
                return Line(source: source, voice: voice, startSeconds: line.startSeconds, endSeconds: line.endSeconds, text: line.text)
            }
            var overlap: [Int: TimeInterval] = [:]
            for turn in ordered where turn.endSeconds > line.startSeconds && turn.startSeconds < line.endSeconds {
                overlap[turn.speaker, default: 0] += min(turn.endSeconds, line.endSeconds) - max(turn.startSeconds, line.startSeconds)
            }
            var voice = overlap.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
            if voice == nil, !ordered.isEmpty {
                // Recognizer and voice boundaries rarely line up exactly: fall back to the nearest turn.
                let middle = (line.startSeconds + line.endSeconds) / 2
                let nearest = ordered.min { distance(middle, $0) < distance(middle, $1) }
                if let nearest, distance(middle, nearest) <= 3 { voice = nearest.speaker }
            }
            return Line(source: source, voice: voice, startSeconds: line.startSeconds, endSeconds: line.endSeconds, text: line.text)
        }
    }

    private static func distance(_ time: TimeInterval, _ turn: SpeakerTurn) -> TimeInterval {
        time < turn.startSeconds ? turn.startSeconds - time : max(0, time - turn.endSeconds)
    }

    /// Without headphones the microphone also hears the call. Those lines already exist, cleaner,
    /// in the meeting audio, so the microphone copy is dropped.
    static func removeEcho(microphone: [Line], system: [Line], toleranceSeconds: TimeInterval = 2.5, threshold: Double = 0.6) -> [Line] {
        guard !system.isEmpty else { return microphone }
        let reference = system.sorted { $0.startSeconds < $1.startSeconds }
        return microphone.filter { line in
            let own = bigrams(line.text)
            guard own.count >= 4 else {
                // Too short to compare reliably ("네", "okay"): keep unless the call audio says the same word at the same moment.
                let word = normalized(line.text)
                guard !word.isEmpty else { return false }
                return !reference.contains {
                    $0.endSeconds > line.startSeconds - 1 && $0.startSeconds < line.endSeconds + 1 && normalized($0.text).contains(word)
                }
            }
            var heard = Set<String>()
            for other in reference where other.endSeconds > line.startSeconds - toleranceSeconds && other.startSeconds < line.endSeconds + toleranceSeconds {
                heard.formUnion(bigrams(other.text))
            }
            guard !heard.isEmpty else { return true }
            let shared = own.filter { heard.contains($0) }.count
            return Double(shared) / Double(own.count) < threshold
        }
    }

    static func normalized(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    static func bigrams(_ text: String) -> [String] {
        let characters = Array(normalized(text))
        guard characters.count >= 2 else { return [] }
        return (0..<(characters.count - 1)).map { String(characters[$0...($0 + 1)]) }
    }

    /// Stable display names. One microphone voice is "You"; several voices on the microphone are
    /// people in the room. Meeting-audio voices are numbered in the order they first speak.
    static func speakerNames(for lines: [Line]) -> [MeetingAudioSource: [Int: String]] {
        var names: [MeetingAudioSource: [Int: String]] = [:]
        for source in MeetingAudioSource.allCases {
            let own = lines.filter { $0.source == source && $0.voice != nil }.sorted { $0.startSeconds < $1.startSeconds }
            guard !own.isEmpty else { continue }
            var talk: [Int: TimeInterval] = [:]
            for line in own { talk[line.voice!, default: 0] += max(0, line.endSeconds - line.startSeconds) }
            let total = talk.values.reduce(0, +)
            let main = talk.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }!.key
            // The microphone usually holds one person, so a small extra voice there is a split of that
            // person. In the meeting audio a short contribution is still a real participant.
            let real = talk.filter { voice, seconds in
                voice == main || (source == .microphone ? seconds >= minorVoiceSeconds && seconds >= total * minorVoiceShare
                                                        : seconds >= remoteVoiceSeconds)
            }.keys
            var order: [Int] = []
            for line in own where real.contains(line.voice!) && !order.contains(line.voice!) { order.append(line.voice!) }
            var map: [Int: String] = [:]
            if source == .microphone {
                if order.count == 1 { map[main] = "You" }
                else { for (index, voice) in order.enumerated() { map[voice] = "Room speaker \(index + 1)" } }
                // A brief extra voice on the microphone is almost always the same person.
                for voice in talk.keys where map[voice] == nil { map[voice] = map[main] }
            } else {
                for (index, voice) in order.enumerated() { map[voice] = "Speaker \(index + 1)" }
                // A few seconds from an unmatched voice: say so instead of guessing an identity.
                for voice in talk.keys where map[voice] == nil { map[voice] = "Speaker ?" }
            }
            names[source] = map
        }
        return names
    }

    /// Final transcript: both sources in time order, consecutive lines by one person joined.
    static func segments(microphone: [Line], system: [Line]) -> [MeetingSegment] {
        let kept = removeEcho(microphone: microphone, system: system) + system
        let names = speakerNames(for: kept)
        let ordered = kept.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.sorted {
            if $0.startSeconds != $1.startSeconds { return $0.startSeconds < $1.startSeconds }
            return $0.source.rawValue < $1.source.rawValue
        }
        var paragraphs: [(line: Line, name: String?)] = []
        for line in ordered {
            let name = line.voice.flatMap { names[line.source]?[$0] }
            if let last = paragraphs.last, last.line.source == line.source, last.name == name,
               line.startSeconds - last.line.endSeconds <= paragraphGapSeconds,
               line.endSeconds - last.line.startSeconds <= paragraphMaxSeconds {
                var joined = last.line
                joined.endSeconds = max(joined.endSeconds, line.endSeconds)
                joined.text = join(joined.text, line.text)
                paragraphs[paragraphs.count - 1] = (joined, name)
            } else {
                paragraphs.append((line, name))
            }
        }
        return paragraphs.enumerated().map { index, item in
            MeetingSegment(id: "\(item.line.source.rawValue):\(index)", source: item.line.source,
                           startSeconds: item.line.startSeconds, endSeconds: max(item.line.startSeconds, item.line.endSeconds),
                           text: item.line.text.trimmingCharacters(in: .whitespacesAndNewlines), speaker: item.name)
        }
    }

    private static func join(_ first: String, _ second: String) -> String {
        let a = first.trimmingCharacters(in: .whitespacesAndNewlines), b = second.trimmingCharacters(in: .whitespacesAndNewlines)
        return a.isEmpty ? b : b.isEmpty ? a : a + " " + b
    }

    static func timestamp(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }

    /// Plain-text transcript. This is also the text handed to downstream summarizers, so the
    /// header states exactly what the labels mean.
    static func text(for document: MeetingDocument) -> String {
        var lines = ["Meeting transcript", "Recorded: \(ISO8601DateFormatter().string(from: document.startedAt))"]
        let separated = document.segments.contains { $0.speaker != nil }
        if document.transcription != nil || separated {
            lines.append("Recorded and transcribed on this Mac.")
            lines.append(separated
                ? "Voices are separated automatically: You = this Mac's microphone; Speaker N = a voice in the meeting audio. Names are not identified."
                : "You = microphone; Meeting audio = Mac audio. Voices were not separated for this recording.")
        } else if document.recordingEndedAt != nil && document.finishedAt == nil {
            lines.append("Recording saved on this Mac. The transcript is written after the meeting.")
        } else {
            lines.append("Processed locally. You = microphone; Meeting audio = Mac audio (not remote speaker identification).")
        }
        lines.append("")
        for segment in document.segments {
            lines.append("[\(timestamp(segment.startSeconds))] \(segment.speakerLabel): \(segment.text)")
        }
        if document.segments.isEmpty {
            lines.append(document.finishedAt == nil ? "Transcript pending." : "No speech was detected.")
        }
        if document.incomplete && document.finishedAt != nil { lines.append("\nParts of this meeting may be missing. See the notes below.") }
        if document.recoveredChunkCount > 0 { lines.append("\(document.recoveredChunkCount) audio chunks remain in Recovery Audio for local recovery.") }
        lines.append(contentsOf: document.notes)
        return lines.joined(separator: "\n") + (document.recording?.textFooter ?? "")
    }
}
