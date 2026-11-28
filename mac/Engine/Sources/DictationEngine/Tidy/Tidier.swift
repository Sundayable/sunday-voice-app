import Foundation

// "Tidy clipboard" (Dan, 2026-10-08): one key rewrites the copied text to be concise and correct, in its
// natural English, through the same server rewrite proxy as dictation (`mode: tidy`). The app owns the
// clipboard; this file owns the request, the fallback and the checks that keep every fact intact.

public enum TidyError: Error, Equatable, Sendable {
    /// Nothing usable on the clipboard (empty, whitespace, or not text).
    case empty
    case tooLong(limit: Int)
    case notSignedIn
    case quotaExceeded
    case subscriptionRequired
    /// The API predates tidy (it would clean the text as a dictation instead).
    case serverOutdated
    /// Both tiers returned text that dropped a link, number or mention, failed the English output checks.
    case unsafe
    case failed(String)
}

public struct TidyResult: Equatable, Sendable {
    public let text: String
    /// False when the text was already tidy (nothing to replace).
    public let changed: Bool
    public init(text: String, changed: Bool) { self.text = text; self.changed = changed }
}

/// Deterministic handling around the model: input limits and output acceptance.
public enum TidyText {
    /// Long clipboard text is split into requests below the deployed server cap.
    public static let maxCharacters = 24_000

    /// The clipboard string to send, or why there is nothing to tidy.
    public static func prepare(_ raw: String?) throws -> String {
        let text = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw TidyError.empty }
        guard text.count <= maxCharacters else { throw TidyError.tooLong(limit: maxCharacters) }
        return text
    }

    /// Model output → clipboard text, or nil when it must not replace the source.
    public static func accept(_ output: String, source: String) -> String? {
        var out = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.contains("<copied_text>") { out = marker.sub(out, "").trimmingCharacters(in: .whitespacesAndNewlines) }
        if !source.contains("```"), let inner = fence.firstGroup(out) { out = inner }
        out = stripPreamble(out, source: source)
        out = unquote(out, source: source)
        if !source.contains("**") { out = out.replacingOccurrences(of: "**", with: "") }
        if !heading.search(source) { out = heading.sub(out, "") }
        out = trailingSpaces.sub(out, "") // markdown hard breaks ("regards,  ")
        out = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !out.isEmpty else { return nil }
        guard keepsDetails(source: source, output: out), isEnglishOutput(source: source, output: out) else { return nil }
        // Concise means no longer than the source, allowing for added punctuation and Korean spacing.
        let expansion = source.unicodeScalars.contains { $0.value > 0x2FF && CharacterSet.letters.contains($0) } ? 4.0 : 1.15
        guard out.count <= Int(Double(source.count) * expansion) + 40 else { return nil }
        return out
    }

    // MARK: checks

    private static let fence = Rx(#"^```[A-Za-z]*\n([\s\S]*?)\n?```$"#)
    private static let heading = Rx(#"(?m)^#{1,6}\s+"#)
    private static let marker = Rx(#"</?copied_text>"#)
    private static let trailingSpaces = Rx(#"(?m)[ \t]+$"#)
    private static let preamble = Rx(#"^(?:sure|okay|ok|here(?:'s| is| are)|tidied|revised|cleaned|polished|rewritten|edited)\b[^\n]{0,60}:\s*\n+"#, [.caseInsensitive])
    private static let link = Rx(#"(?:https?://|www\.)[^\s<>()\[\]]+|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)
    private static let mention = Rx(#"(?<![A-Za-z0-9._%+-])@[A-Za-z0-9_.-]+"#)
    private static let number = Rx(#"\d+(?:[.,:]\d+)*"#)
    private static let hangul = Rx(#"[가-힣]"#)
    private static let latinWord = Rx(#"[A-Za-z]{2,}"#)

    private static func stripPreamble(_ s: String, source: String) -> String {
        preamble.matchStart(source) ? s : preamble.sub(s, "")
    }

    private static func unquote(_ s: String, source: String) -> String {
        for (open, close) in [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("「", "」")] {
            let src = source.trimmingCharacters(in: .whitespacesAndNewlines)
            if s.count > 2, s.hasPrefix(open), s.hasSuffix(close), !(src.hasPrefix(open) && src.hasSuffix(close)) {
                return String(s.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return s
    }

    /// Links, email addresses, @mentions and numbers in the source all survive (each value once is enough:
    /// a concise rewrite may drop a repeated mention). Numeric spellings stay exact.
    static func keepsDetails(source: String, output: String) -> Bool {
        func trimLink(_ s: String) -> String { s.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?'\"”’")) }
        let links = Set(link.findAll(source).map(trimLink))
        guard links.allSatisfy({ output.contains($0) }) else { return false }
        let mentions = Set(mention.findAll(source).map(trimLink))
        guard mentions.allSatisfy({ output.contains($0) }) else { return false }
        func numbers(_ s: String) -> Set<String> {
            Set(number.findAll(link.sub(s, " ")))
        }
        return numbers(source).isSubset(of: numbers(output))
    }

    /// Permit original-script names, but reject untranslated Korean sentences and newly invented names.
    static func isEnglishOutput(source: String, output: String) -> Bool {
        let words = Rx(#"[가-힣]+"#).findAll(output)
        guard words.allSatisfy({ source.contains($0) }) else { return false }
        let koreanCount = words.reduce(0) { $0 + $1.count }
        guard koreanCount == 0 || (latinWord.search(output) && koreanCount * 5 < output.count) else { return false }
        return !Rx(#"[가-힣]+(?:어요|아요|해요|세요|니다|했어|한다|이다)(?:[.!?\s]|$)"#).search(output)
    }

}

/// gpt-4.1-mini (server "primary" for tidy) within a deadline, then Groq, each output checked.
public final class Tidier: @unchecked Sendable {
    let backend: TidyBackend
    var primaryDeadline: Double = 25
    var fallbackDeadline: Double = 30

    public convenience init(apiBaseURL: URL, tokens: AccessTokenProvider) {
        self.init(backend: ServerClient(baseURL: apiBaseURL, tokens: tokens))
    }
    init(backend: TidyBackend) { self.backend = backend }

    public func tidy(_ raw: String?) async throws -> TidyResult {
        let source = try TidyText.prepare(raw)
        if source.utf16.count > 5000 {
            var rest = source[...], pieces: [String] = []
            while !rest.isEmpty {
                var end = rest.startIndex, units = 0, boundary: String.Index?
                while end < rest.endIndex {
                    let next = rest.index(after: end), cost = rest[end..<next].utf16.count
                    if units + cost > 5000 { break }
                    units += cost
                    if rest[end].isWhitespace { boundary = next }
                    end = next
                }
                guard end > rest.startIndex else { throw TidyError.tooLong(limit: 5000) }
                if end != rest.endIndex, let boundary { end = boundary }
                pieces.append(String(rest[..<end])); rest = rest[end...]
            }
            var out: [String] = []
            for piece in pieces { out.append(try await tidy(piece).text) }
            let joined = out.joined(separator: "\n\n")
            guard let accepted = TidyText.accept(joined, source: source) else { throw TidyError.unsafe }
            return TidyResult(text: accepted, changed: accepted != source)
        }
        var lastError: FailureCode?
        for (tier, deadline) in [(RewriteTier.primary, primaryDeadline), (.fallback, fallbackDeadline)] {
            do {
                let out = try await withDeadline(deadline) { try await self.backend.tidy(source, tier: tier) }
                if let accepted = TidyText.accept(out, source: source) {
                    return TidyResult(text: accepted, changed: accepted != source)
                }
                lastError = FailureCode("tidy_unsafe")
                Log.rewrite.info("tidy_output_rejected tier=\(tier.rawValue, privacy: .public)")
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let code = FailureCode.from(error)
                switch code {
                case .notSignedIn: throw TidyError.notSignedIn
                case .quotaExceeded: throw TidyError.quotaExceeded
                case .subscriptionRequired: throw TidyError.subscriptionRequired
                case .serverOutdated: throw TidyError.serverOutdated
                default: lastError = code
                }
                Log.rewrite.info("tidy_failed tier=\(tier.rawValue, privacy: .public) code=\(code.code, privacy: .public)")
            }
        }
        throw lastError?.code == "tidy_unsafe" ? TidyError.unsafe : TidyError.failed(lastError?.code ?? "unknown")
    }
}

protocol TidyBackend: AnyObject, Sendable {
    func tidy(_ text: String, tier: RewriteTier) async throws -> String
}

extension ServerClient: TidyBackend {}
