import Foundation

/// 1:1 port of worker.py's deterministic text checks: `normalized`, `canonical_transcript`,
/// `preserve_bilingual` and `english_preserves_details`. Regexes are kept verbatim (ICU and
/// Python `re` agree on every construct used here: ordered alternation, lookarounds, `\b`, `\s`).
struct QualityChecks: Sendable {
    /// Ordered source→target replacements applied to transcripts (worker `canonical_terms`).
    var canonicalTerms: [(String, String)]
    /// Names that must survive an English rewrite: target → accepted spellings in the source.
    var nameAliases: [(target: String, forms: [String])]

    /// Values from Dan's installed config v4 and worker.py; the server may override canonical terms.
    static let defaultCanonicalTerms: [(String, String)] = [
        ("Ads 리포트", "Ads report"), ("애즈 리포트", "Ads report"), ("Ads 레포트", "Ads report"),
    ]
    /// KoEn v4's hard-coded names; Sunday Voice derives aliases per user from the server's terms instead.
    static let koenNameAliases: [(target: String, forms: [String])] = [
        ("Lauren", ["Lauren", "로렌"]), ("Sundayable", ["Sundayable", "선데이어블"]), ("Dan", ["Dan"]),
    ]
    static let defaultNameAliases: [(target: String, forms: [String])] = []

    /// Latin-script user terms (dictionary + voice import) become names that must survive English rewrites.
    static func aliases(fromTerms terms: [String]) -> [(target: String, forms: [String])] {
        terms.filter { $0.range(of: "^[A-Za-z][A-Za-z0-9 .&'-]{1,39}$", options: .regularExpression) != nil && !$0.contains(" ") }
            .map { ($0, [$0]) }
    }

    init(canonicalTerms: [(String, String)] = QualityChecks.defaultCanonicalTerms,
         nameAliases: [(target: String, forms: [String])] = QualityChecks.defaultNameAliases) {
        self.canonicalTerms = canonicalTerms; self.nameAliases = nameAliases
    }

    // MARK: normalized

    private static let whitespaceRun = Rx(#"\s+"#)
    private static let hangulGap = Rx(#"(?<=[가-힣])\s+(?=[가-힣])"#)
    private static let trailingSentence: Set<Character> = [".", "!", "?", "。", "！", "？", " "]

    /// Ignore Korean word-spacing and terminal sentence punctuation, but keep decimal points,
    /// signs, URLs and Latin word boundaries meaningful.
    static func normalized(_ text: String) -> String {
        var s = whitespaceRun.sub(text.trimmingCharacters(in: .whitespacesAndNewlines), " ")
        while let last = s.last, trailingSentence.contains(last) { s.removeLast() }
        return hangulGap.sub(s, "")
    }

    /// Length in code points, matching Python `len`.
    static func length(_ s: String) -> Int { s.unicodeScalars.count }

    func canonicalTranscript(_ text: String) -> String {
        var t = text
        for (source, target) in canonicalTerms { t = t.replacingOccurrences(of: source, with: target) }
        return t
    }

    // MARK: preserve_bilingual

    private static let leadingFillers = Rx(#"^(?:(?:um|uh|erm|hmm|음|어)[,，]?\s+)+"#, [.caseInsensitive])
    private static let koreanHourSpacing = Rx(#"(?<![가-힣])(열두|열한|다섯|여섯|일곱|여덟|아홉|한|두|세|네|열)시(?=$|[\s,.!?]|에|까지|부터)"#)
    private static let dottedAbbreviation = Rx(#"\b(?:[A-Za-z]\.){2,}"#)
    private static let latinWord = Rx(#"[a-z]+(?:['’-][a-z]+)*"#)
    private static let hangul = Rx(#"[가-힣]"#)
    private static let number = Rx(#"[-+]?\d+(?:[.,]\d+)*"#)
    private static let selfCorrectionCue = Rx(
        #"말고|아\s*아니|(?:^|[\s,.!?])아니(?:요)?(?:[\s,.!?]|$)|아니라|\b(?:wait\s+no|no\s+wait|scratch\s+that|i\s+mean|actually|rather|sorry\s*,?\s*no)\b"#,
        [.caseInsensitive]
    )

    /// True when the spoken source contains an explicit Korean or English self-correction marker.
    static func hasSelfCorrectionCue(_ text: String) -> Bool {
        selfCorrectionCue.search(text)
    }

    /// Fail closed to the original transcript if cleanup changes its language mix.
    /// When an explicit self-correction cue appears (e.g. "말고", "아 아니", "wait no"), retracted
    /// words or numbers may be dropped while still blocking translations and invented numbers.
    static func preserveBilingual(source: String, cleaned: String) -> String {
        func finish(_ s: String) -> String {
            let stripped = leadingFillers.sub(s.trimmingCharacters(in: .whitespacesAndNewlines), "")
            // Keep common spoken Korean hour expressions correctly spaced.
            return koreanHourSpacing.sub(stripped, "$1 시")
        }
        func words(_ s: String) -> Set<String> {
            let undotted = dottedAbbreviation.sub(s) { $0[0]!.replacingOccurrences(of: ".", with: "") }
            return Set(latinWord.findAll(undotted.lowercased()))
        }
        let trimmedCleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCleaned.isEmpty else { return finish(source) }
        if hangul.search(source) && !hangul.search(trimmedCleaned) { return finish(source) }
        if hasSelfCorrectionCue(source) {
            // Allow retracted words/numbers to be removed, but reject invented numbers or runaway output.
            let sourceNumbers = Set(number.findAll(source))
            let cleanedNumbers = Set(number.findAll(trimmedCleaned))
            if !cleanedNumbers.isSubset(of: sourceNumbers) { return finish(source) }
            if length(trimmedCleaned) > max(length(source) + 12, Int(Double(length(source)) * 1.4)) { return finish(source) }
            // Pure English self-correction must keep at least one Latin word from the source.
            if !hangul.search(source) {
                let sourceWords = words(source).subtracting(["um", "uh", "erm", "hmm", "ah", "wait", "no", "scratch", "that", "actually", "sorry"])
                if !sourceWords.isEmpty && words(trimmedCleaned).isDisjoint(with: sourceWords) { return finish(source) }
            }
            return finish(trimmedCleaned)
        }
        let required = words(source).subtracting(["um", "uh", "erm", "hmm", "ah"])
        if !required.isSubset(of: words(trimmedCleaned)) { return finish(source) }
        if number.findAll(source) != number.findAll(trimmedCleaned) { return finish(source) }
        return finish(trimmedCleaned)
    }

    // MARK: english_preserves_details

    private static let units = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                                "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen"]
    private static let tens = ["twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let values: [String: Int] = {
        var v = [String: Int]()
        for (i, name) in units.enumerated() { v[name] = i }
        for (i, name) in tens.enumerated() { v[name] = 20 + 10 * i }
        return v
    }()
    // Same alternation order as the Python dict iteration (units, tens, then scales).
    private static let vocabulary = (units + tens).joined(separator: "|") + "|hundred|thousand|million"
    private static let spokenNumber = Rx(#"\b(?:"# + vocabulary + #")(?:[-\s]+(?:"# + vocabulary + #"|and))*\b"#, [.caseInsensitive])
    private static let spokenSplit = Rx(#"[-\s]+"#)
    private static let clockWord = Rx(#"\b("# + units[..<13].joined(separator: "|") + #")(?=\s+[ap]\.?\s*m\b)"#, [.caseInsensitive])
    private static let hours: [String: Int] = ["한": 1, "두": 2, "세": 3, "네": 4, "다섯": 5, "여섯": 6, "일곱": 7, "여덟": 8, "아홉": 9, "열": 10, "열한": 11, "열두": 12]
    // sorted(hours, key=len, reverse=True) — stable, so dict order within equal lengths.
    private static let hourPattern = Rx(#"(?<![가-힣])(다섯|여섯|일곱|여덟|아홉|열한|열두|한|두|세|네|열)\s*시(?=$|[\s,.!?]|에|까지|부터|쯤)"#)
    private static let afternoonSource = Rx(#"오후\s*(?:\d+|한|두|세|네|다섯|여섯|일곱|여덟|아홉|열)\s*시"#)
    private static let morningSource = Rx(#"오전\s*(?:\d+|한|두|세|네|다섯|여섯|일곱|여덟|아홉|열)\s*시"#)
    private static let afternoonOutput = Rx(#"\bp\.?\s*m\.?\b|afternoon|evening"#, [.caseInsensitive])
    private static let morningOutput = Rx(#"\ba\.?\s*m\.?\b|morning"#, [.caseInsensitive])
    private static let addedAcknowledgment = Rx(#"(?:sure|of course)[,!]"#, [.caseInsensitive])
    private static let sourceAcknowledgment = Rx(#"\bsure\b|of course|물론"#, [.caseInsensitive])
    private static let addedGreeting = Rx(#"(?:hi|hello|hey|dear)\b[^\n]{0,40}[,!\n]"#, [.caseInsensitive])
    private static let sourceGreeting = Rx(#"\b(?:hi|hello|hey|dear)\b|안녕|하이|헬로"#, [.caseInsensitive])
    private static let addedSignOff = Rx(#"\n\s*(?:thanks|thank you|best|regards|cheers|sincerely)[!,.]?\s*(?:\n|$)"#, [.caseInsensitive])
    private static let sourceThanks = Rx(#"thank|thanks|regards|cheers|고마|감사"#, [.caseInsensitive])

    private static func numbers(_ input: String, spoken: Bool) -> [String: Int] {
        var text = input
        if spoken {
            // Recognize explicit numbers and common dictated English cardinal numbers.
            text = spokenNumber.sub(text) { groups in
                var total = 0, part = 0
                for word in spokenSplit.sub(groups[0]!.lowercased(), " ").split(separator: " ").map(String.init) {
                    if let v = values[word] { part += v }
                    else if word == "hundred" { part = max(1, part) * 100 }
                    else if word == "thousand" || word == "million" { total += max(1, part) * (word == "thousand" ? 1000 : 1_000_000); part = 0 }
                }
                return String(total + part)
            }
        } else {
            text = clockWord.sub(text) { groups in String(values[groups[1]!.lowercased()]!) }
        }
        text = hourPattern.sub(text) { groups in String(hours[groups[1]!]!) + "시" }
        var counter = [String: Int]()
        for n in number.findAll(text) { counter[n.replacingOccurrences(of: ",", with: ""), default: 0] += 1 }
        return counter
    }

    /// Reject detectable name/number/time omissions; this is not a semantic proof.
    func englishPreservesDetails(source: String, output: String) -> Bool {
        let selfCorrected = Self.hasSelfCorrectionCue(source)
        if !selfCorrected {
            for (target, forms) in nameAliases {
                let present = forms.contains { form in
                    Rx(#"(?<![A-Za-z])"# + NSRegularExpression.escapedPattern(for: form) + #"(?![A-Za-z])"#, [.caseInsensitive]).search(source)
                }
                if present && !Rx(#"\b"# + NSRegularExpression.escapedPattern(for: target) + #"\b"#, [.caseInsensitive]).search(output) { return false }
            }
            let wanted = Self.numbers(source, spoken: false), found = Self.numbers(output, spoken: true)
            if wanted.contains(where: { found[$0.key, default: 0] < $0.value }) { return false }
            if Self.afternoonSource.search(source) && !Self.afternoonOutput.search(output) { return false }
            if Self.morningSource.search(source) && !Self.morningOutput.search(output) { return false }
        }
        if Self.addedAcknowledgment.matchStart(output) && !Self.sourceAcknowledgment.search(source) { return false }
        // A rewrite must not turn dictation into an email: no greeting/sign-off that wasn't spoken.
        if Self.addedGreeting.matchStart(output) && !Self.sourceGreeting.search(source) { return false }
        if Self.addedSignOff.search(output) && !Self.sourceThanks.search(source) { return false }
        return true
    }

    // MARK: speculation trigger

    /// A complete-sounding sentence ending: start its rewrite immediately (worker.receive).
    private static let sentenceEnd = Rx(#"(?:[.!?]|주세요|습니다|해요|돼요|세요)$"#)
    static func endsSentence(_ text: String) -> Bool { sentenceEnd.search(text) }
}
