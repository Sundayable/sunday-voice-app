import Foundation

/// The last few final dictations, kept in memory on this Mac only (never written to disk, never
/// logged). They are sent as preceding context with the next utterance: appended to the STT
/// prompt and attached to the rewrite request, so a topic word said a minute ago ("Xcode") is
/// recognised again instead of a sound-alike ("육백"). The server never stores them.
@MainActor
final class RecentContext {
    struct Entry: Equatable {
        var id: String
        /// What was heard (after the personal replacement map); used for the STT prompt.
        var transcript: String
        /// What was inserted, or the user's correction of it; used for the rewrite.
        var output: String
        var mode: DictationMode
        var app: String?
        var at: Double
    }

    struct Limits {
        var capacity = 8
        var perUtterance = 3
        /// Context from the same app stays useful for a while…
        var sameAppAge = 20.0 * 60
        /// …other apps' dictations only right after they happened, and only if this app has none.
        var otherAppAge = 3.0 * 60
        var entryChars = 200
        var sttChars = 400
        var rewriteChars = 600
    }

    /// gpt-live-transcribe rejects a session.update whose prompt is longer than this (probed 2026-10-04).
    static let sttPromptLimit = 1024
    static let sttHeader = " Recent dictation by this speaker, for context only: "

    var enabled = true { didSet { if !enabled { clear() } } }
    var limits = Limits()
    private(set) var entries: [Entry] = []

    nonisolated init() {}

    func record(id: String, transcript: String, output: String, mode: DictationMode, app: String?, at: Double = uptime()) {
        guard enabled else { return }
        let t = Self.collapse(transcript), o = Self.collapse(output)
        guard !t.isEmpty || !o.isEmpty else { return }
        entries.append(Entry(id: id, transcript: t, output: o, mode: mode, app: app, at: at))
        if entries.count > limits.capacity { entries.removeFirst(entries.count - limits.capacity) }
    }

    /// The user fixed the inserted text: later context should carry the fixed wording.
    func amend(id: String, output: String) {
        guard let i = entries.firstIndex(where: { $0.id == id }) else { return }
        let o = Self.collapse(output)
        entries[i].output = o
        // As-spoken mode inserts what was heard, so the fix is also the better transcript.
        if entries[i].mode == .bilingual { entries[i].transcript = o }
    }

    func clear() { entries = [] }

    /// Up to `perUtterance` recent entries, oldest first: the current app's own recent dictations,
    /// or — when it has none — dictations from any app in the last few minutes.
    func select(app: String?, now: Double = uptime()) -> [Entry] {
        guard enabled else { return [] }
        let fresh = entries.filter { now - $0.at >= 0 }
        var picked = fresh.filter { $0.app == app && now - $0.at <= limits.sameAppAge }
        if picked.isEmpty { picked = fresh.filter { now - $0.at <= limits.otherAppAge } }
        return Array(picked.suffix(limits.perUtterance))
    }

    /// The server's base prompt plus recent transcripts, never longer than the API limit.
    func sttPrompt(base: String, app: String?, now: Double = uptime()) -> String {
        let texts = select(app: app, now: now).map(\.transcript).filter { !$0.isEmpty }
        let room = Self.sttPromptLimit - base.utf16.count - Self.sttHeader.utf16.count
        let budget = min(limits.sttChars, room)
        guard !texts.isEmpty, budget >= 40 else { return base }
        let fitted = Self.fit(texts, entryChars: limits.entryChars, totalChars: budget, separator: " / ")
        guard !fitted.isEmpty else { return base }
        return base + Self.sttHeader + fitted.joined(separator: " / ")
    }

    /// Recent inserted texts (oldest first) for the rewrite request.
    func rewriteContext(app: String?, now: Double = uptime()) -> [String] {
        let texts = select(app: app, now: now).map(\.output).filter { !$0.isEmpty }
        return Self.fit(texts, entryChars: limits.entryChars, totalChars: limits.rewriteChars, separator: "\n")
    }

    // MARK: pure helpers

    nonisolated static func collapse(_ s: String) -> String {
        s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Keep the newest texts that fit `totalChars` (UTF-16 units, separators included), oldest
    /// dropped first. Each text keeps at most its last `entryChars`, cut at a word boundary.
    nonisolated static func fit(_ texts: [String], entryChars: Int, totalChars: Int, separator: String) -> [String] {
        var out: [String] = [], used = 0
        for raw in texts.reversed() {
            let sep = out.isEmpty ? 0 : separator.utf16.count
            let left = totalChars - used - sep
            guard left >= 12 else { break }
            let text = tail(collapse(raw), max: min(entryChars, left))
            guard !text.isEmpty else { continue }
            out.insert(text, at: 0); used += sep + text.utf16.count
        }
        return out
    }

    /// The end of `text` within `max` UTF-16 units, starting at a word boundary, marked with "…".
    nonisolated static func tail(_ text: String, max: Int) -> String {
        guard text.utf16.count > max else { return text }
        guard max > 1 else { return "" }
        var kept = ""
        for ch in text.reversed() {
            if kept.utf16.count + ch.utf16.count > max - 1 { break }
            kept.insert(ch, at: kept.startIndex)
        }
        // Drop a partial leading word when there is a later boundary to start from.
        if let space = kept.firstIndex(of: " "), kept.distance(from: kept.startIndex, to: space) < kept.count / 2 {
            kept = String(kept[kept.index(after: space)...])
        }
        return "…" + kept
    }
}

/// Learning from the user's own fixes: when an inserted dictation is edited in place, the words
/// they typed instead are a correction signal. Pure functions here; the engine does the AX read.
enum CorrectionSignal {
    struct Correction: Equatable { var from: String; var to: String; var corrected: String }

    /// Compare what was inserted (`pasted`, at UTF-16 offset `start` of the field at paste time)
    /// with the field's current value. Returns the in-place replacement, widened to whole words,
    /// when the rest of the insertion is still there on both sides; nil if unchanged, deleted,
    /// rewritten wholesale, or only extended at the end (no anchor to bound the edit).
    static func diff(pasted: String, field: String, start: Int) -> Correction? {
        let ns = field as NSString
        guard start >= 0, start <= ns.length, !pasted.isEmpty else { return nil }
        // Still there, maybe shifted by edits elsewhere in the field: nothing was corrected.
        let near = NSRange(location: max(0, start - 400), length: min(ns.length, start + 400 + (pasted as NSString).length) - max(0, start - 400))
        if ns.range(of: pasted, options: [], range: near).location != NSNotFound { return nil }
        let p = Array(pasted), t = Array(ns.substring(from: start))
        var prefix = 0
        while prefix < p.count, prefix < t.count, p[prefix] == t[prefix] { prefix += 1 }
        // Longest tail of the insertion that still follows the edit nearby.
        let window = min(t.count, prefix + (p.count - prefix) + 60)
        var anchor: (suffix: Int, at: Int)?
        var s = p.count - prefix
        while s >= 2 {
            let tailChars = Array(p[(p.count - s)...])
            var i = prefix
            while i + s <= window {
                if Array(t[i..<(i + s)]) == tailChars { anchor = (s, i); break }
                i += 1
            }
            if anchor != nil { break }
            s -= 1
        }
        guard let (suffix, at) = anchor else { return nil }
        var from = prefix, fromEnd = p.count - suffix, to = prefix, toEnd = at
        guard fromEnd >= from, toEnd >= to else { return nil }
        // Widen to whole words: Korean particles and Latin words change as a unit.
        while from > 0, !p[from - 1].isWhitespace { from -= 1; to -= 1 }
        while fromEnd < p.count, !p[fromEnd].isWhitespace, toEnd < t.count, p[fromEnd] == t[toEnd] { fromEnd += 1; toEnd += 1 }
        let old = String(p[from..<fromEnd]).trimmingCharacters(in: .whitespaces)
        let new = String(t[to..<toEnd]).trimmingCharacters(in: .whitespaces)
        let kept = p.count - (fromEnd - from)
        guard old != new, !new.isEmpty, old.count <= 24, new.count <= 48, kept * 2 >= p.count, kept >= 2 else { return nil }
        // Text typed right before/after an untouched word is an edit elsewhere, not a fix of it.
        if !old.isEmpty, new.hasPrefix(old) || new.hasSuffix(old) { return nil }
        let corrected = String(p[..<from]) + String(t[to..<toEnd]) + String(p[fromEnd...])
        return Correction(from: old, to: new, corrected: corrected)
    }

    private static let latinTerm = try! NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9.+#&'-]*[A-Za-z0-9+#]|[A-Z]")

    /// Typed-in names/terms worth learning: Latin-script words that the inserted text lacked,
    /// with a capital or a digit (brand-like), 2–40 characters.
    static func terms(_ c: Correction) -> [String] {
        let ns = c.to as NSString
        var out: [String] = []
        for m in latinTerm.matches(in: c.to, range: NSRange(location: 0, length: ns.length)) {
            var term = ns.substring(with: m.range)
            if term.hasSuffix("'s") { term = String(term.dropLast(2)) }
            guard (2...40).contains(term.count),
                  term.rangeOfCharacter(from: .uppercaseLetters) != nil || term.rangeOfCharacter(from: .decimalDigits) != nil,
                  c.from.range(of: term, options: .caseInsensitive) == nil,
                  !out.contains(where: { $0.caseInsensitiveCompare(term) == .orderedSame }) else { continue }
            out.append(term)
        }
        return out
    }
}

/// Counts learned terms (terms only, never text) and promotes one to the user's words once it
/// was typed in as a fix `threshold` times. Persisted in the app's defaults; cleared on sign-out.
@MainActor
final class CorrectionLearner {
    static let defaultsKey = "correctionTermCounts"
    static let confirmedKey = "correctionConfirmedTerms"
    private(set) var generation = UUID()
    var threshold = 2
    nonisolated(unsafe) private let defaults: UserDefaults

    nonisolated init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private var counts: [String: Int] {
        get { defaults.dictionary(forKey: Self.defaultsKey) as? [String: Int] ?? [:] }
        set { defaults.set(newValue, forKey: Self.defaultsKey) }
    }

    private var confirmed: Set<String> {
        get { Set(defaults.stringArray(forKey: Self.confirmedKey) ?? []) }
        set { defaults.set(newValue.sorted(), forKey: Self.confirmedKey) }
    }

    /// Retry an eligible term on later corrections until the server confirms it was saved.
    func observe(_ terms: [String]) -> [String] {
        var c = counts, promoted: [String] = []
        let saved = confirmed
        for term in terms {
            let key = term.lowercased()
            let n = (c[key] ?? 0) + 1
            if n >= threshold, !saved.contains(key) { promoted.append(term) }
            c[key] = n
        }
        if c.count > 300 { c = Dictionary(uniqueKeysWithValues: c.sorted { $0.value > $1.value }.prefix(200).map { ($0.key, $0.value) }) }
        counts = c
        confirmed = saved.intersection(c.keys)
        return promoted
    }

    func confirmAdded(_ terms: [String], generation expected: UUID) {
        guard generation == expected else { return }
        let c = counts
        confirmed.formUnion(terms.map { $0.lowercased() }.filter { (c[$0] ?? 0) >= threshold })
    }

    func clear() {
        generation = UUID()
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.confirmedKey)
    }
}
