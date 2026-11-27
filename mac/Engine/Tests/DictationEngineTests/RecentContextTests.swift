import XCTest
@testable import DictationEngine

@MainActor
final class RecentContextTests: XCTestCase {
    let xcode = "com.apple.dt.Xcode", slack = "com.tinyspeck.slackmacgap"

    func testSelectsSameAppFirstThenRecentOtherApps() {
        let c = RecentContext()
        c.record(id: "1", transcript: "slack 1", output: "s1", mode: .bilingual, app: slack, at: 100)
        c.record(id: "2", transcript: "xcode 1", output: "x1", mode: .bilingual, app: xcode, at: 200)
        c.record(id: "3", transcript: "slack 2", output: "s2", mode: .bilingual, app: slack, at: 300)
        XCTAssertEqual(c.select(app: xcode, now: 400).map(\.id), ["2"])
        XCTAssertEqual(c.select(app: slack, now: 400).map(\.id), ["1", "3"])
        // An app with no history borrows only the last few minutes from other apps.
        XCTAssertEqual(c.select(app: "com.apple.TextEdit", now: 350).map(\.id), ["2", "3"])
        XCTAssertEqual(c.select(app: "com.apple.TextEdit", now: 300 + 181).map(\.id), [])
        // Same-app context expires after 20 minutes.
        XCTAssertEqual(c.select(app: xcode, now: 200 + 20 * 60 + 1).map(\.id), [])
    }

    func testKeepsAtMostThreePerUtteranceAndCapacityOverall() {
        let c = RecentContext()
        for i in 0..<12 { c.record(id: "\(i)", transcript: "t\(i)", output: "o\(i)", mode: .english, app: xcode, at: Double(i)) }
        XCTAssertEqual(c.entries.count, 8)
        XCTAssertEqual(c.select(app: xcode, now: 20).map(\.id), ["9", "10", "11"])
        XCTAssertEqual(c.rewriteContext(app: xcode, now: 20), ["o9", "o10", "o11"])
    }

    func testSTTPromptStaysWithinTheAPILimit() {
        let c = RecentContext()
        let long = String(repeating: "이번 주 Xcode 릴리스 공증 진행 ", count: 40)
        for i in 0..<3 { c.record(id: "\(i)", transcript: long, output: long, mode: .bilingual, app: nil, at: Double(i)) }
        let base = String(repeating: "b", count: 600)
        let prompt = c.sttPrompt(base: base, app: nil, now: 10)
        XCTAssertTrue(prompt.hasPrefix(base + RecentContext.sttHeader))
        XCTAssertLessThanOrEqual(prompt.utf16.count, RecentContext.sttPromptLimit)
        XCTAssertLessThanOrEqual(prompt.utf16.count - base.utf16.count - RecentContext.sttHeader.utf16.count, 400)
        // The newest dictation survives; truncated text keeps its end and is marked.
        XCTAssertTrue(prompt.hasSuffix("진행"))
        XCTAssertTrue(prompt.contains("…"))
        // A base prompt that leaves no room is sent unchanged.
        let full = String(repeating: "b", count: 1000)
        XCTAssertEqual(c.sttPrompt(base: full, app: nil, now: 10), full)
    }

    func testFitDropsOldestAndCountsUTF16() {
        let out = RecentContext.fit(["오래된 문장 하나", "중간 문장", "최신 문장 🙂"], entryChars: 200, totalChars: 20, separator: " / ")
        XCTAssertEqual(out.last, "최신 문장 🙂")
        XCTAssertLessThanOrEqual(out.joined(separator: " / ").utf16.count, 20)
        XCTAssertFalse(out.contains("오래된 문장 하나"))
        XCTAssertEqual(RecentContext.tail("one two three four five", max: 12), "…four five")
        XCTAssertEqual(RecentContext.tail("short", max: 12), "short")
    }

    func testEmptyHistoryOrDisabledKeepsBasePrompt() {
        let c = RecentContext()
        XCTAssertEqual(c.sttPrompt(base: "Base.", app: nil), "Base.")
        c.record(id: "1", transcript: "Paseo", output: "Paseo", mode: .bilingual, app: nil)
        c.enabled = false
        XCTAssertEqual(c.sttPrompt(base: "Base.", app: nil), "Base.")
        XCTAssertTrue(c.entries.isEmpty)
        c.record(id: "2", transcript: "x", output: "x", mode: .bilingual, app: nil)
        XCTAssertTrue(c.entries.isEmpty, "nothing is recorded while off")
    }

    func testAmendReplacesOutputAndBilingualTranscript() {
        let c = RecentContext()
        c.record(id: "a", transcript: "육백 해놨어", output: "육백 해놨어", mode: .bilingual, app: nil)
        c.record(id: "b", transcript: "육백 해놨어", output: "I did 600.", mode: .english, app: nil)
        c.amend(id: "a", output: "Xcode 로그인 해놨어")
        c.amend(id: "b", output: "I signed in to Xcode.")
        XCTAssertEqual(c.entries.map(\.transcript), ["Xcode 로그인 해놨어", "육백 해놨어"])
        XCTAssertEqual(c.entries.map(\.output), ["Xcode 로그인 해놨어", "I signed in to Xcode."])
    }

    // MARK: corrections

    func testInPlaceFixIsDetectedAndWidenedToWords() {
        let field = "메모: Xcode 로그인 해놨어 그리고 더"
        let c = CorrectionSignal.diff(pasted: "육백 해놨어", field: field, start: 4)
        XCTAssertEqual(c, .init(from: "육백", to: "Xcode 로그인", corrected: "Xcode 로그인 해놨어"))
        XCTAssertEqual(c.map(CorrectionSignal.terms), ["Xcode"])

        let particle = CorrectionSignal.diff(pasted: "파세오에서 워커 띄워줘", field: "Paseo에서 워커 띄워줘", start: 0)
        XCTAssertEqual(particle?.from, "파세오에서")
        XCTAssertEqual(particle?.to, "Paseo에서")
        XCTAssertEqual(particle.map(CorrectionSignal.terms), ["Paseo"])
    }

    func testNoCorrectionWhenUntouchedShiftedDeletedOrReplacedWholesale() {
        let pasted = "로렌한테 피드백 보내달라고 해"
        XCTAssertNil(CorrectionSignal.diff(pasted: pasted, field: pasted + " 그리고 추가", start: 0), "typed after it")
        XCTAssertNil(CorrectionSignal.diff(pasted: pasted, field: "앞에 추가함 " + pasted, start: 0), "shifted by an edit before it")
        XCTAssertNil(CorrectionSignal.diff(pasted: pasted, field: "", start: 0), "sent and cleared")
        XCTAssertNil(CorrectionSignal.diff(pasted: pasted, field: "완전히 다른 문장으로 바꿨음", start: 0), "rewritten wholesale")
        XCTAssertNil(CorrectionSignal.diff(pasted: pasted, field: "x", start: 5), "offset beyond field")
    }

    func testTermsAreBrandLikeLatinWordsMissingFromTheOriginal() {
        let c = CorrectionSignal.Correction(from: "the higgs field", to: "the Higgsfield and api LT33", corrected: "")
        XCTAssertEqual(CorrectionSignal.terms(c), ["Higgsfield", "LT33"])
        XCTAssertEqual(CorrectionSignal.terms(.init(from: "Lauren", to: "Lauren's", corrected: "")), [])
    }

    func testLearnerRetriesAnUnconfirmedPromotion() {
        let defaults = UserDefaults(suiteName: "RecentContextRetryTests-\(UUID().uuidString)")!
        let learner = CorrectionLearner(defaults: defaults)
        XCTAssertEqual(learner.observe(["Xcode"]), [])
        XCTAssertEqual(learner.observe(["Xcode"]), ["Xcode"])
        // The server write failed. A later correction must retry instead of forgetting it.
        XCTAssertEqual(learner.observe(["Xcode"]), ["Xcode"])
        let restarted = CorrectionLearner(defaults: defaults)
        XCTAssertEqual(restarted.observe(["Xcode"]), ["Xcode"], "retry survives app restart")
        learner.clear()
    }

    func testLearnerIgnoresConfirmationFromBeforeClear() {
        let defaults = UserDefaults(suiteName: "RecentContextClearTests-\(UUID().uuidString)")!
        let learner = CorrectionLearner(defaults: defaults)
        _ = learner.observe(["Xcode"])
        _ = learner.observe(["Xcode"])
        let oldGeneration = learner.generation
        learner.clear()
        _ = learner.observe(["Xcode"])
        XCTAssertEqual(learner.observe(["Xcode"]), ["Xcode"])
        learner.confirmAdded(["Xcode"], generation: oldGeneration)
        XCTAssertEqual(learner.observe(["Xcode"]), ["Xcode"], "old account response cannot confirm the new session")
        learner.clear()
    }

    func testLearnerPromotesOnSecondFixOnlyAndClears() {
        let defaults = UserDefaults(suiteName: "RecentContextTests-\(UUID().uuidString)")!
        let learner = CorrectionLearner(defaults: defaults)
        XCTAssertEqual(learner.observe(["Xcode"]), [])
        XCTAssertEqual(learner.observe(["xcode", "Paseo"]), ["xcode"])
        learner.confirmAdded(["xcode"], generation: learner.generation)
        XCTAssertEqual(learner.observe(["Xcode"]), [], "confirmed once")
        let restarted = CorrectionLearner(defaults: defaults)
        XCTAssertEqual(restarted.observe(["Xcode"]), [], "confirmation survives app restart")
        learner.clear()
        XCTAssertNil(defaults.dictionary(forKey: CorrectionLearner.defaultsKey))
        XCTAssertNil(defaults.array(forKey: CorrectionLearner.confirmedKey))
    }
}
