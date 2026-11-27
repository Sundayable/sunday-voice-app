import Foundation

/// Single source of truth for accepted speech-recognition languages in LocalMeetingEngine
/// (covers both Free Local Mode dictation and offline meeting transcription).
/// To enable another language later, add its ISO-639-1 code to `allowedLanguages`.
public enum SpeechLanguagePolicy {
    public static let allowedLanguages: [String] = ["ko", "en"]

    public static func normalize(_ code: String) -> String {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init) ?? ""
    }

    public static func isAllowed(_ code: String?, allowed: [String] = allowedLanguages) -> Bool {
        guard let code, !code.isEmpty else { return false }
        return allowed.contains(normalize(code))
    }

    /// Returns normalized code when allowed, nil when omitted/empty or disallowed.
    public static func validatedHint(_ code: String?, allowed: [String] = allowedLanguages) -> String? {
        guard let code else { return nil }
        let normalized = normalize(code)
        guard !normalized.isEmpty, allowed.contains(normalized) else { return nil }
        return normalized
    }

    /// True when a caller explicitly passed a non-empty language hint that is not in `allowed`.
    public static func isUnsupportedExplicitHint(_ code: String?, allowed: [String] = allowedLanguages) -> Bool {
        guard let code else { return false }
        let normalized = normalize(code)
        return !normalized.isEmpty && !allowed.contains(normalized)
    }

    public static func filterLanguages(_ codes: [String], allowed: [String] = allowedLanguages) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in codes {
            let code = normalize(raw)
            guard !code.isEmpty, allowed.contains(code), !seen.contains(code) else { continue }
            seen.insert(code)
            out.append(code)
        }
        return out.sorted()
    }

    /// Validates both optional Whisper-detected language code and output script against `allowed`.
    public static func isAllowedTranscript(_ text: String, detectedLanguage: String? = nil, allowed: [String] = allowedLanguages) -> Bool {
        if let detected = detectedLanguage, !detected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !isAllowed(detected, allowed: allowed) {
            return false
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        var totalLetters = 0
        var disallowedLetters = 0
        for scalar in trimmed.unicodeScalars {
            guard scalar.properties.isAlphabetic else { continue }
            totalLetters += 1
            if !isAllowedScalar(scalar, allowed: allowed) {
                disallowedLetters += 1
            }
        }
        if totalLetters > 0 && disallowedLetters > 0 {
            let ratio = Double(disallowedLetters) / Double(totalLetters)
            if ratio >= 0.25 || (disallowedLetters >= 2 && disallowedLetters == totalLetters) {
                return false
            }
        }
        return true
    }

    private static func isAllowedScalar(_ scalar: UnicodeScalar, allowed: [String]) -> Bool {
        let v = scalar.value
        let isHangul = (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v)
            || (0x3130...0x318F).contains(v) || (0xA960...0xA97F).contains(v) || (0xD7B0...0xD7FF).contains(v)
        let isLatin = (0x0041...0x007A).contains(v) || (0x00C0...0x024F).contains(v) || (0x1E00...0x1EFF).contains(v)
        let isKana = (0x3040...0x309F).contains(v) || (0x30A0...0x30FF).contains(v) || (0x31F0...0x31FF).contains(v)
        let isHan = (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
        let isCyrillic = (0x0400...0x052F).contains(v)
        let isArabic = (0x0600...0x06FF).contains(v) || (0x0750...0x077F).contains(v)
        let isDevanagari = (0x0900...0x097F).contains(v)
        let isThai = (0x0E00...0x0E7F).contains(v)

        for code in allowed {
            switch code {
            case "ko": if isHangul { return true }
            case "en", "es", "fr", "de", "pt", "it", "vi": if isLatin { return true }
            case "ja": if isKana || isHan { return true }
            case "zh": if isHan { return true }
            case "ru": if isCyrillic { return true }
            case "ar": if isArabic { return true }
            case "hi": if isDevanagari { return true }
            case "th": if isThai { return true }
            default: break
            }
        }
        return false
    }
}
