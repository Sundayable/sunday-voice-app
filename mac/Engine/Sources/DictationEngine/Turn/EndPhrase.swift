import Foundation

/// Spoken send/end commands for dictation ("입력완료", "엔터", "보내기", "send it", "press enter", "enter").
/// Detected ONLY at the end of an utterance so mid-sentence mentions never trigger a send.
public enum EndPhrase {
    /// Default spoken send phrases (KO + EN). Configurable by the user in Settings → Keys.
    public static let defaultSendPhrases: [String] = [
        "입력완료",
        "엔터",
        "보내기",
        "send it",
        "press enter",
        "enter",
    ]

    public static let defaultSendPhrasesText: String = defaultSendPhrases.joined(separator: ", ")

    public struct SendCommandMatch: Equatable, Sendable {
        public let text: String
        public let matched: Bool
        public let matchedPhrase: String?

        public init(text: String, matched: Bool, matchedPhrase: String?) {
            self.text = text
            self.matched = matched
            self.matchedPhrase = matchedPhrase
        }
    }

    /// Legacy hands-free tail pattern (tolerates spacing, 요-ending, and common Korean ASR variants).
    static let tail = try! NSRegularExpression(pattern: #"[\s,.。·~-]*(?:[입김임인잉]\s*[력녁역]\s*(?:했\s*(?:어|습\s*니\s*다)\s*요?|해\s*써|완\s*료(?:\s*요|\s*했\s*(?:어|습\s*니\s*다)\s*요?)?)|[엔앤]\s*터|[Ee]nter)[\s.!?。~]*$"#)
    static let anywhere = try! NSRegularExpression(pattern: #"[입김임인잉]\s*[력녁역]\s*(?:했\s*(?:어|습\s*니\s*다)\s*요?|해\s*써|완\s*료(?:\s*요|\s*했\s*(?:어|습\s*니\s*다)\s*요?)?)"#)

    /// "엔터" counts only as the last word of the utterance; the caller waits briefly for more words.
    static let enterLast = try! NSRegularExpression(pattern: #"(?:^|[\s,.!?])(?:[엔앤]\s*터|[Ee]nter)[\s.!?。~]*$"#)

    public static func endsWithEnter(_ partial: String) -> Bool {
        enterLast.firstMatch(in: partial, range: NSRange(partial.startIndex..., in: partial)) != nil
    }

    /// True if the transcript ends with a hands-free end phrase (what `strip` removes).
    public static func endsWithPhrase(_ text: String) -> Bool {
        strip(text) != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let out = tail.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once the hands-free end phrase appears in a (partial) on-device transcript.
    public static func heard(in partial: String) -> Bool {
        anywhere.firstMatch(in: partial, range: NSRange(partial.startIndex..., in: partial)) != nil
    }

    /// Parse comma/newline/dot-separated user-configured phrases into a clean deduplicated list.
    public static func parsePhrases(_ raw: String) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for piece in raw.components(separatedBy: CharacterSet(charactersIn: ",\n·")) {
            let cleaned = piece
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard !cleaned.isEmpty else { continue }
            let key = cleaned.lowercased()
            if seen.insert(key).inserted {
                result.append(cleaned)
            }
        }
        return result
    }

    /// Detects and strips a configured spoken send command ONLY when it is the final phrase of the utterance.
    /// Never matches mid-sentence occurrences or substrings inside longer words (e.g. "센터", "carpenter", "보내기 전에").
    public static func extractSendCommand(from raw: String, phrases: [String] = defaultSendPhrases) -> SendCommandMatch {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return SendCommandMatch(text: "", matched: false, matchedPhrase: nil)
        }
        // Sort longest-first so multi-word commands ("press enter", "send it") match before shorter ones ("enter").
        let ordered = phrases
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        let nsRange = NSRange(trimmed.startIndex..., in: trimmed)
        for phrase in ordered {
            guard let regex = trailingRegex(for: phrase),
                  let match = regex.firstMatch(in: trimmed, range: nsRange),
                  let swiftRange = Range(match.range, in: trimmed) else {
                continue
            }
            // Capture group 1 (if present) preserves sentence-ending `?` or `!` right before the command.
            let prefix = String(trimmed[..<swiftRange.lowerBound])
            let preservedPunct: String
            if match.numberOfRanges > 1,
               match.range(at: 1).location != NSNotFound,
               let punctRange = Range(match.range(at: 1), in: trimmed) {
                preservedPunct = String(trimmed[punctRange])
            } else {
                preservedPunct = ""
            }
            let stripped = (prefix + preservedPunct).trimmingCharacters(in: .whitespacesAndNewlines)
            return SendCommandMatch(text: stripped, matched: true, matchedPhrase: phrase)
        }
        return SendCommandMatch(text: trimmed, matched: false, matchedPhrase: nil)
    }

    private static func trailingRegex(for phrase: String) -> NSRegularExpression? {
        let normalized = phrase
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        let compact = normalized.replacingOccurrences(of: " ", with: "").lowercased()

        // Built-in Korean ASR-tolerant patterns for default commands.
        let body: String
        let allowNoSpaceBefore: Bool
        switch compact {
        case "입력완료", "입력했어":
            body = #"[입김임인잉]\s*[력녁역]\s*(?:했\s*(?:어|습\s*니\s*다)\s*요?|해\s*써|완\s*료(?:\s*요|\s*했\s*(?:어|습\s*니\s*다)\s*요?)?)"#
            allowNoSpaceBefore = true
        case "엔터", "앤터":
            body = #"[엔앤]\s*터(?:\s*요)?"#
            allowNoSpaceBefore = false
        case "보내기":
            body = #"보\s*내\s*기(?:\s*요)?"#
            allowNoSpaceBefore = false
        default:
            let tokens = normalized.split(separator: " ").map { NSRegularExpression.escapedPattern(for: String($0)) }
            body = tokens.joined(separator: #"\s+"#)
            allowNoSpaceBefore = false
        }

        // Preserve `?` or `!` that ended the preceding sentence, while stripping separator punctuation (`,`, `.`, spaces).
        let boundaryPrefix: String
        if allowNoSpaceBefore {
            boundaryPrefix = #"([!?]?)[\s,.。·~—\-]*"#
        } else {
            boundaryPrefix = #"(?:^|([!?])[\s,.。·~—\-]*|[\s,.;:。·~—\-/(\x22'`“‘]+)"#
        }
        let pattern = "\(boundaryPrefix)(?:\(body))[\\s.!?。~…,\\x22'”’)]*$"
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }
}
