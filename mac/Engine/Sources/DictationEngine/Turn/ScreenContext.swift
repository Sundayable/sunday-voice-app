import AppKit
import ApplicationServices
import Foundation

/// Reads minimal, ephemeral proper-noun / Latin screen terms from the frontmost window title and
/// ±300 characters around the focused caret (Accessibility). Never reads password fields, never
/// reads Sunday Voice's own windows, and never logs or persists screen text.
enum ScreenContext {
    /// Password managers and credential vaults are skipped unconditionally.
    static let blockedBundlePrefixes: [String] = [
        "com.1password.", "com.agilebits.onepassword", "com.bitwarden.",
        "com.apple.keychainaccess", "com.dashlane.", "org.keepassxc.", "com.lastpass.",
    ]

    private static let stopwords: Set<String> = [
        "a", "an", "and", "are", "as", "at", "be", "been", "being", "but", "by", "can", "com",
        "could", "did", "do", "does", "done", "edit", "email", "file", "for", "from", "get",
        "got", "had", "has", "have", "he", "her", "here", "him", "his", "home", "how", "http",
        "https", "if", "in", "inbox", "into", "is", "it", "its", "just", "let", "like", "mail",
        "make", "may", "me", "more", "most", "my", "new", "no", "not", "now", "of", "ok", "on",
        "one", "only", "or", "org", "our", "out", "over", "page", "please", "re", "reply", "run",
        "said", "same", "search", "see", "send", "sent", "she", "should", "so", "some", "tab",
        "than", "thanks", "that", "the", "their", "them", "then", "there", "these", "they",
        "this", "to", "too", "untitled", "up", "us", "use", "very", "was", "we", "were", "what",
        "when", "where", "which", "who", "will", "window", "with", "would", "www", "yes", "you",
        "your", "chrome", "safari", "finder", "messages", "notes", "terminal", "code", "app",
    ]

    /// Captures proper-noun / Latin screen terms for the focused target. Runs in < 0.5 ms p95.
    @MainActor
    static func capture(target: Paster.Target, enabled: Bool) -> [String] {
        guard enabled, AXIsProcessTrusted(), !target.isOwnApp, let app = target.app else { return [] }
        if let bundle = target.bundleID?.lowercased(),
           blockedBundlePrefixes.contains(where: { bundle.hasPrefix($0) }) {
            return []
        }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.08)

        var title: String?
        var focusedWindow: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
           let winRef = focusedWindow, CFGetTypeID(winRef) == AXUIElementGetTypeID() {
            let win = winRef as! AXUIElement
            AXUIElementSetMessagingTimeout(win, 0.08)
            var titleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(win, kAXTitleAttribute as CFString, &titleRef) == .success {
                title = titleRef as? String
            }
        }

        var surrounding: String?
        if let element = target.element {
            AXUIElementSetMessagingTimeout(element, 0.08)
            var subrole: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            if (subrole as? String) == (kAXSecureTextFieldSubrole as String) {
                return []
            }
            var fieldValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &fieldValue) == .success,
               let value = fieldValue as? String, !value.isEmpty {
                var rangeRef: CFTypeRef?
                var caret = value.utf16.count
                if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
                   let rRef = rangeRef, CFGetTypeID(rRef) == AXValueGetTypeID() {
                    var cfRange = CFRange()
                    if AXValueGetType(rRef as! AXValue) == .cfRange,
                       AXValueGetValue(rRef as! AXValue, .cfRange, &cfRange),
                       cfRange.location >= 0 {
                        caret = min(cfRange.location, value.utf16.count)
                    }
                }
                surrounding = sliceAroundCaret(value, utf16Location: caret, radius: 300)
            }
        }
        return extractTerms(windowTitle: title, surroundingText: surrounding)
    }

    /// Slices ±`radius` UTF-16 units around `utf16Location` on safe Unicode scalar boundaries.
    nonisolated static func sliceAroundCaret(_ text: String, utf16Location: Int, radius: Int = 300) -> String {
        guard !text.isEmpty else { return "" }
        let total = text.utf16.count
        let clamped = max(0, min(total, utf16Location))
        let startOffset = max(0, clamped - radius)
        let endOffset = min(total, clamped + radius)
        let utf16 = text.utf16
        let rawStart = utf16.index(utf16.startIndex, offsetBy: startOffset)
        let rawEnd = utf16.index(utf16.startIndex, offsetBy: endOffset)
        let start = String.Index(rawStart, within: text) ?? text.startIndex
        let end = String.Index(rawEnd, within: text) ?? text.endIndex
        guard start <= end else { return "" }
        return String(text[start..<end])
    }

    private static let phrasePattern = try! NSRegularExpression(
        pattern: #"\b[A-Z][A-Za-z0-9._+#&'-]*(?:\s+(?:[A-Z][A-Za-z0-9._+#&'-]*|\d+[A-Za-z0-9]*)){1,2}\b"#
    )
    private static let tokenPattern = try! NSRegularExpression(
        pattern: #"(?<![A-Za-z0-9])[A-Za-z][A-Za-z0-9._+#&'-]{1,39}(?![A-Za-z0-9])"#
    )

    /// Pure extractor: returns deduplicated proper nouns / Latin / technical terms from title and
    /// surrounding text. Never returns full sentences or paragraphs.
    nonisolated static func extractTerms(windowTitle: String?, surroundingText: String?,
                                         maxTerms: Int = 18, maxTotalChars: Int = 220) -> [String] {
        var candidates: [String] = []
        let sources = [windowTitle, surroundingText].compactMap { $0 }.filter { !$0.isEmpty }
        for source in sources {
            // Strip URLs and email addresses so hosts/tokens aren't echoed as dictation words.
            let scrubbed = stripURLsAndEmails(source)
            let ns = scrubbed as NSString
            let fullRange = NSRange(location: 0, length: ns.length)

            for m in phrasePattern.matches(in: scrubbed, range: fullRange) {
                let phrase = cleanCandidate(ns.substring(with: m.range))
                if isUsefulPhrase(phrase) { candidates.append(phrase) }
            }
            for m in tokenPattern.matches(in: scrubbed, range: fullRange) {
                let token = cleanCandidate(ns.substring(with: m.range))
                if isUsefulToken(token) { candidates.append(token) }
            }
        }
        var seen = Set<String>()
        var result: [String] = []
        var used = 0
        for item in candidates {
            let key = item.lowercased()
            guard !seen.contains(key) else { continue }
            let cost = item.utf16.count + (result.isEmpty ? 0 : 2)
            guard result.count < maxTerms, used + cost <= maxTotalChars else { continue }
            seen.insert(key)
            result.append(item)
            used += cost
        }
        return result
    }

    private static let urlOrEmail = try! NSRegularExpression(
        pattern: #"https?://\S+|\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#,
        options: [.caseInsensitive]
    )

    private nonisolated static func stripURLsAndEmails(_ text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        return urlOrEmail.stringByReplacingMatches(in: text, range: range, withTemplate: " ")
    }

    private nonisolated static func cleanCandidate(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(.init(charactersIn: ".,;:!?()[]{}\"'`<>")))
        if s.hasSuffix("'s") || s.hasSuffix("’s") { s = String(s.dropLast(2)) }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static func isUsefulPhrase(_ phrase: String) -> Bool {
        guard (3...40).contains(phrase.count) else { return false }
        let parts = phrase.split(separator: " ").map(String.init)
        guard parts.count >= 2 else { return false }
        let meaningful = parts.filter { !stopwords.contains($0.lowercased()) }
        guard !meaningful.isEmpty else { return false }
        // Avoid generic sentence openings like "The New" or "Please Check".
        if parts.allSatisfy({ stopwords.contains($0.lowercased()) }) { return false }
        return true
    }

    private nonisolated static func isUsefulToken(_ token: String) -> Bool {
        guard (2...40).contains(token.count) else { return false }
        let lower = token.lowercased()
        guard !stopwords.contains(lower) else { return false }
        // Keep acronyms, capitalized brands, camelCase, dotted tech names (Next.js), or alphanumeric tokens (F4, M4).
        let hasUpper = token.rangeOfCharacter(from: .uppercaseLetters) != nil
        let hasDigit = token.rangeOfCharacter(from: .decimalDigits) != nil
        let hasTechPunct = token.contains(".") || token.contains("+") || token.contains("#") || token.contains("_")
        guard hasUpper || hasDigit || hasTechPunct else { return false }
        // Drop pure hex hashes / UUID fragments.
        if token.count >= 8, token.allSatisfy({ "0123456789abcdefABCDEF-".contains($0) }) { return false }
        return true
    }

    /// Formats a bounded prompt suffix for STT sessions (respecting `budget` UTF-16 units).
    nonisolated static func sttSuffix(for terms: [String], budget: Int) -> String {
        let header = " Screen terms: "
        guard !terms.isEmpty, budget > header.utf16.count + 8 else { return "" }
        var picked: [String] = []
        var used = header.utf16.count + 1 // trailing period
        for t in terms {
            let add = t.utf16.count + (picked.isEmpty ? 0 : 2)
            if used + add > budget { break }
            picked.append(t)
            used += add
        }
        guard !picked.isEmpty else { return "" }
        return header + picked.joined(separator: ", ") + "."
    }
}
