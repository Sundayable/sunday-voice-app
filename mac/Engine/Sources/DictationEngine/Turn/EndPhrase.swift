import Foundation

/// Spoken end phrase for hands-free dictation ("입력했어" / "입력완료" / final word "엔터"): detected in on-device partial
/// results to stop recording, and stripped from the end of the final transcript before pasting.
public enum EndPhrase {
    /// Tolerates spacing, 요-ending and trailing punctuation the rewrite may add.
    static let tail = try! NSRegularExpression(pattern: #"[\s,.。·~-]*(?:[입김임인잉]\s*[력녁역]\s*(?:했\s*(?:어|습\s*니\s*다)\s*요?|해\s*써|완\s*료(?:\s*요|\s*했\s*(?:어|습\s*니\s*다)\s*요?)?)|[엔앤]\s*터|[Ee]nter)[\s.!?。~]*$"#)
    static let anywhere = try! NSRegularExpression(pattern: #"[입김임인잉]\s*[력녁역]\s*(?:했\s*(?:어|습\s*니\s*다)\s*요?|해\s*써|완\s*료(?:\s*요|\s*했\s*(?:어|습\s*니\s*다)\s*요?)?)"#)

    /// "엔터" counts only as the last word of the utterance; the caller waits briefly for more words.
    static let enterLast = try! NSRegularExpression(pattern: #"(?:^|[\s,.!?])(?:[엔앤]\s*터|[Ee]nter)[\s.!?。~]*$"#)

    public static func endsWithEnter(_ partial: String) -> Bool {
        enterLast.firstMatch(in: partial, range: NSRange(partial.startIndex..., in: partial)) != nil
    }

    /// True if the transcript ends with an end phrase (what `strip` removes).
    public static func endsWithPhrase(_ text: String) -> Bool {
        strip(text) != text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func strip(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let out = tail.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True once the phrase appears in a (partial) on-device transcript.
    public static func heard(in partial: String) -> Bool {
        anywhere.firstMatch(in: partial, range: NSRange(partial.startIndex..., in: partial)) != nil
    }
}
