import Foundation

/// On-device vocabulary extraction from local AI-assistant history (Claude Code today; Codex and
/// Cursor later). Reads only what the user typed, counts tokens on this Mac and returns TERMS and
/// COUNTS. Message text never leaves this function. Same rules as the server's counter
/// (server/lib/vocab/count.ts + candidates.ts) so both paths rank terms the same way.
struct LocalHistoryImporter {
    struct Candidate: Codable, Hashable { var term: String; var count: Int; var score: Double; var forms: [String]; var cap_ratio: Double? }
    struct Result {
        var messages: Int
        var latin: [Candidate]
        var hangul: [Candidate]
        var latinCounts: [String: Int]
        var hangulCounts: [String: Int]
        var sourcesFound: [String]
    }

    var home = FileManager.default.homeDirectoryForCurrentUser
    var now = Date()
    var maxBytes = 400 * 1024 * 1024

    /// Which local histories exist (shown in the consent sheet before anything is read).
    func availableSources() -> [String] {
        var found: [String] = []
        if FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/history.jsonl").path)
            || FileManager.default.fileExists(atPath: home.appendingPathComponent(".claude/projects").path) { found.append("Claude Code") }
        return found
    }

    func run() -> Result {
        var counter = Counter(now: now)
        var budget = maxBytes
        var seen = Set<String>()
        // 1. Typed prompts.
        for line in lines(home.appendingPathComponent(".claude/history.jsonl"), budget: &budget) {
            guard let d = json(line), let text = d["display"] as? String, !text.hasPrefix("/"), seen.insert(text).inserted else { continue }
            counter.ingest(text, at: date(d["timestamp"]))
        }
        // 2. Human turns inside transcripts (skip tool results, meta, sidechains, long English agent briefs).
        let projects = home.appendingPathComponent(".claude/projects")
        let files = (FileManager.default.enumerator(at: projects, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "jsonl" }
        for file in files {
            for line in lines(file, budget: &budget) where line.contains("\"type\":\"user\"") {
                guard let d = json(line), d["type"] as? String == "user", d["isMeta"] as? Bool != true, d["isSidechain"] as? Bool != true,
                      let message = d["message"] as? [String: Any] else { continue }
                var text = ""
                if let s = message["content"] as? String { text = s }
                else if let parts = message["content"] as? [[String: Any]] {
                    if parts.contains(where: { $0["type"] as? String == "tool_result" }) { continue }
                    text = parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined(separator: " ")
                }
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !["<", "Caveat:", "[Request interrupted", "This session is being continued", "Base directory for this skill"].contains(where: { trimmed.hasPrefix($0) }) else { continue }
                let korean = trimmed.range(of: "[가-힣]", options: .regularExpression) != nil
                if !korean && trimmed.count > 400 { continue }
                guard seen.insert(trimmed).inserted else { continue }
                counter.ingest(trimmed, at: date(d["timestamp"]))
            }
            if budget <= 0 { break }
        }
        return counter.result(sources: availableSources())
    }

    // MARK: file helpers

    private func lines(_ url: URL, budget: inout Int) -> [Substring] {
        guard budget > 0, let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        budget -= data.count
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
    }
    private func json(_ line: Substring) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
    }
    private func date(_ v: Any?) -> Date? {
        if let n = v as? Double { return Date(timeIntervalSince1970: n > 1e11 ? n / 1000 : n) }
        if let s = v as? String { return ISO8601DateFormatter.flexible.date(from: s) ?? ISO8601DateFormatter().date(from: s) }
        return nil
    }

    // MARK: counting (mirrors server/lib/vocab/count.ts)

    struct Stats { var count = 0; var weight = 0.0; var forms: [String: Int] = [:]; var capMid = 0; var lower = 0 }

    struct Counter {
        let now: Date
        var tokens: [String: Stats] = [:]
        var messages = 0

        static let urlish = try! NSRegularExpression(pattern: #"https?://\S+|www\.\S+|\S+@\S+\.\S+|[~/]?(?:/[\w.\-@ ]+){2,}|\b[\w-]+\.(?:com|ca|app|io|ai|dev|net|org|co|kr|md|json|py|ts|tsx|js|swift|html|sh|txt|png|jpg|mp4|wav)\b"#)
        static let code = try! NSRegularExpression(pattern: #"```[\s\S]*?```"#)
        static let tag = try! NSRegularExpression(pattern: #"<[^>]{1,80}>"#)
        /// Chat-tool placeholders and Windows paths ("[Image #1]", "[Pasted text #2 +40 lines]", C:\Users\…).
        static let placeholder = try! NSRegularExpression(pattern: #"\[(?:Image|Pasted text|File)[^\]]{0,40}\]|[A-Za-z]:\\\S+"#)
        static let latin = try! NSRegularExpression(pattern: #"(?<![A-Za-z0-9_])[A-Za-z][A-Za-z0-9]*(?:[-'’&.][A-Za-z0-9]+)*(?![A-Za-z0-9_])"#)
        static let hangul = try! NSRegularExpression(pattern: #"[가-힣]+"#)
        static let particles = "은 는 이 가 을 를 에 의 로 으로 도 만 과 와 랑 이랑 에서 에게 한테 께 까지 부터 처럼 보다 이나 나 이랑은 에는 에서는 으로는 로는 한테는 이라고 라고 이라는 라는 이에요 예요 이야 야 이고 고 이죠 죠 하고 이요 요 들 들이 들을 들은 들도"
            .split(separator: " ").map(String.init).sorted { $0.count > $1.count }

        static func stripParticle(_ w: String) -> String {
            for p in particles where w.count > p.count + 1 && w.hasSuffix(p) { return String(w.dropLast(p.count)) }
            return w
        }

        private mutating func add(_ key: String, at: Date?, form: String) -> String {
            var e = tokens[key] ?? Stats()
            e.count += 1
            let age = at.map { max(0, now.timeIntervalSince($0) / 86_400) } ?? 365
            e.weight += pow(0.5, age / 45)
            e.forms[form, default: 0] += 1
            tokens[key] = e
            return key
        }

        mutating func ingest(_ raw: String, at: Date?) {
            var text = raw as NSString
            for re in [Self.code, Self.tag, Self.placeholder, Self.urlish] {
                text = re.stringByReplacingMatches(in: text as String, range: NSRange(location: 0, length: text.length), withTemplate: " ") as NSString
            }
            messages += 1
            let clean = text as String
            for sentence in clean.split(whereSeparator: { ".!?。\n".contains($0) }).map(String.init) {
                let ns = sentence as NSString
                let matches = Self.latin.matches(in: sentence, range: NSRange(location: 0, length: ns.length))
                let firstPos = matches.first?.range.location ?? -1
                var words: [String] = []
                for m in matches {
                    let token = ns.substring(with: m.range)
                    words.append(token)
                    let w = token.trimmingCharacters(in: CharacterSet(charactersIn: ".'’&-"))
                    guard w.count >= 2, w.count <= 30, w.range(of: "^[0-9A-Fa-f]{6,}$", options: .regularExpression) == nil else { continue }
                    let before = ns.substring(to: m.range.location)
                    let initial = m.range.location == firstPos && before.range(of: "[가-힣]", options: .regularExpression) == nil
                    let key = add(w.lowercased(), at: at, form: w)
                    if w.first?.isUppercase == true && !initial { tokens[key]?.capMid += 1 }
                    else if w == w.lowercased() { tokens[key]?.lower += 1 }
                }
                for n in [2, 3] where words.count >= n {
                    for i in 0...(words.count - n) {
                        let g = Array(words[i..<(i + n)])
                        if g.allSatisfy({ $0.first?.isUppercase == true }) && !g.allSatisfy({ $0 == $0.uppercased() }) {
                            _ = add(g.joined(separator: " ").lowercased(), at: at, form: g.joined(separator: " "))
                        }
                    }
                }
                for m in Self.hangul.matches(in: sentence, range: NSRange(location: 0, length: ns.length)) {
                    let w = Self.stripParticle(ns.substring(with: m.range))
                    if w.count >= 2 { _ = add(w, at: at, form: ns.substring(with: m.range)) }
                }
            }
        }

        static let fonts = try! NSRegularExpression(pattern: "^(helvetica|arial|lucida|verdana|tahoma|calibri|segoe|georgia|times|roboto|menlo|monaco|sans-serif|serif|monospace)( |$)")
        static let dictionary: Set<String> = {
            guard let s = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) else { return [] }
            return Set(s.split(separator: "\n").map(String.init).filter { $0 == $0.lowercased() })
        }()

        /// Candidate selection identical to the server's (count ≥ 3; Latin: not a dictionary word,
        /// mostly capitalised mid-sentence, or an acronym).
        func result(sources: [String]) -> Result {
            var latin: [Candidate] = [], hangul: [Candidate] = []
            for (key, s) in tokens where s.count >= 3 {
                let forms = s.forms.sorted { $0.value > $1.value }.map(\.key)
                let score = (s.weight * 100).rounded() / 100
                if key.range(of: "[가-힣]", options: .regularExpression) != nil {
                    hangul.append(Candidate(term: key, count: s.count, score: score, forms: Array(forms.prefix(3)), cap_ratio: nil)); continue
                }
                if Self.fonts.firstMatch(in: key, range: NSRange(location: 0, length: (key as NSString).length)) != nil { continue }
                if key.range(of: "^[a-z]{2}-[a-z]{2}$", options: .regularExpression) != nil { continue }
                let top = forms.first ?? key
                if key.contains(" ") {
                    latin.append(Candidate(term: top, count: s.count, score: score * 0.8, forms: Array(forms.prefix(4)), cap_ratio: 1)); continue
                }
                let cap = Double(s.capMid) / Double(max(1, s.capMid + s.lower))
                let acronym = top == top.uppercased() && (2...6).contains(top.count) && top.rangeOfCharacter(from: .uppercaseLetters) != nil
                if !Self.dictionary.contains(key) || cap >= 0.6 || acronym {
                    latin.append(Candidate(term: top, count: s.count, score: score, forms: Array(forms.prefix(4)), cap_ratio: (cap * 100).rounded() / 100))
                }
            }
            latin.sort { $0.score > $1.score }; hangul.sort { $0.score > $1.score }
            let counts = tokens.sorted { $0.value.count > $1.value.count }
            return Result(
                messages: messages,
                latin: Array(latin.prefix(300)),
                hangul: Array(hangul.prefix(400)),
                latinCounts: Dictionary(uniqueKeysWithValues: counts.filter { $0.key.range(of: "[가-힣]", options: .regularExpression) == nil }.prefix(4000).map { ($0.key, $0.value.count) }),
                hangulCounts: Dictionary(uniqueKeysWithValues: counts.filter { $0.key.range(of: "[가-힣]", options: .regularExpression) != nil }.prefix(4000).map { ($0.key, $0.value.count) }),
                sourcesFound: sources)
        }
    }
}

extension ISO8601DateFormatter {
    static let flexible: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
}
