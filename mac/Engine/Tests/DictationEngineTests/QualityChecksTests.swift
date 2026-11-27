import XCTest
@testable import DictationEngine

/// Same cases as KoEn Dictation's scripts/test_worker.py.
final class QualityChecksTests: XCTestCase {
    func testCleanupCannotTranslateKoreanOrEnglishTerms() {
        let source = "이번 Ads report 1.5 확인해줘."
        XCTAssertEqual(QualityChecks.preserveBilingual(source: source, cleaned: "Please check this Ads report 1.5."), source)
        XCTAssertEqual(QualityChecks.preserveBilingual(source: source, cleaned: "이번 광고 보고서 1.5 확인해줘."), source)
        XCTAssertEqual(QualityChecks.preserveBilingual(source: source, cleaned: "이번 Ads report 15 확인해줘."), source)
        XCTAssertEqual(QualityChecks.preserveBilingual(source: "음 이번 Ads report 확인 해줘", cleaned: "이번 Ads report 확인해 줘."), "이번 Ads report 확인해 줘.")
    }

    func testSafeFallbackStillRemovesFillerAndFixesHourSpacing() {
        XCTAssertEqual(QualityChecks.preserveBilingual(source: "Um, send it at three p.m.", cleaned: "Send it at 3 PM."), "send it at three p.m.")
        XCTAssertEqual(QualityChecks.preserveBilingual(source: "음, 오후 세시까지 Ads report 보내줘.", cleaned: "Translate everything."), "오후 세 시까지 Ads report 보내줘.")
        XCTAssertEqual(QualityChecks.preserveBilingual(source: "Please send it at three p.m.", cleaned: "Please send it at three PM."), "Please send it at three PM.")
    }

    func testTranslationPreservesNamesNumbersAndSpokenHours() {
        let checks = QualityChecks(nameAliases: QualityChecks.koenNameAliases)
        let source = "Lauren에게 Sundayable의 42개 리드를 Friday 오후 세시까지 보내줘."
        XCTAssertTrue(checks.englishPreservesDetails(source: source, output: "Send 42 leads from Sundayable to Lauren by Friday at 3 PM."))
        XCTAssertTrue(checks.englishPreservesDetails(source: source, output: "Send forty-two leads from Sundayable to Lauren by Friday at three p.m."))
        XCTAssertFalse(checks.englishPreservesDetails(source: source, output: "Send 42 leads from Sundayable to Lauren by Friday afternoon."))
        XCTAssertFalse(checks.englishPreservesDetails(source: source, output: "Send 42 leads to Lauren by Friday at 3 PM."))
        XCTAssertFalse(checks.englishPreservesDetails(source: source, output: "Send 42 leads from Sundayable to Lauren by Friday at 3 AM."))
        XCTAssertFalse(checks.englishPreservesDetails(source: source, output: "Sure, send 42 leads from Sundayable to Lauren by Friday at 3 PM."))
        XCTAssertTrue(checks.englishPreservesDetails(source: "100개 보내줘.", output: "Send one hundred."))
        XCTAssertTrue(checks.englishPreservesDetails(source: "한 시간 뒤에 보내줘.", output: "Send it in an hour."))
    }

    func testRejectsEmailStyleAdditions() {
        let checks = QualityChecks()
        let source = "이번 Ads report 확인해줘. Lauren에게 Friday 오후 세 시까지 보내줘."
        XCTAssertFalse(checks.englishPreservesDetails(source: source, output: "Hi Lauren,\n\nCould you review the Ads report and send it by Friday at 3 PM?\n\nThanks!\nDan"))
        XCTAssertFalse(checks.englishPreservesDetails(source: source, output: "Please check the Ads report and send it to Lauren by Friday at 3 PM.\n\nThanks,"))
        XCTAssertTrue(checks.englishPreservesDetails(source: source, output: "Check the Ads report and send it to Lauren by Friday at 3 PM."))
        XCTAssertTrue(checks.englishPreservesDetails(source: "하이 로렌, 고마워요", output: "Hi Lauren, thanks!"))
    }

    func testNormalizationAndSentenceEnds() {
        XCTAssertEqual(QualityChecks.normalized("  로렌과 오후 세 시에  만나요. "), "로렌과오후세시에만나요")
        XCTAssertNotEqual(QualityChecks.normalized("견적은 1.5달러예요."), QualityChecks.normalized("견적은 15달러예요."))
        XCTAssertTrue(QualityChecks.endsSentence("확인해 주세요"))
        XCTAssertFalse(QualityChecks.endsSentence("확인해"))
        XCTAssertEqual(QualityChecks().canonicalTranscript("Ads 리포트 봐줘"), "Ads report 봐줘")
        XCTAssertEqual(QualityChecks.aliases(fromTerms: ["Lauren", "선데이", "Ads report", "Q4"]).map(\.target), ["Lauren", "Q4"])
    }

    func testPreserveBilingualAllowsExplicitSelfCorrections() {
        // Explicit Korean self-correction cues ("말고", "아 아니", "아니라") allow dropping retracted numbers/phrases.
        XCTAssertTrue(QualityChecks.hasSelfCorrectionCue("내일 3시 말고 모레 4시로"))
        XCTAssertEqual(
            QualityChecks.preserveBilingual(source: "내일 3시 말고 모레 4시로", cleaned: "모레 4시로"),
            "모레 4시로"
        )
        XCTAssertEqual(
            QualityChecks.preserveBilingual(source: "화요일에 아 아니 수요일 오전 10시에 보자", cleaned: "수요일 오전 10시에 보자"),
            "수요일 오전 10시에 보자"
        )
        // Explicit English self-correction cues ("wait no", "scratch that") allow dropping retracted names.
        XCTAssertTrue(QualityChecks.hasSelfCorrectionCue("John, wait no, Lauren"))
        XCTAssertEqual(
            QualityChecks.preserveBilingual(source: "John, wait no, Lauren", cleaned: "Lauren"),
            "Lauren"
        )
        XCTAssertEqual(
            QualityChecks.preserveBilingual(source: "Send it to John, wait no, Lauren", cleaned: "Send it to Lauren"),
            "Send it to Lauren"
        )
        // Guardrails still hold: invented numbers or full Korean→English translation are rejected.
        XCTAssertEqual(
            QualityChecks.preserveBilingual(source: "내일 3시 말고 모레 4시로", cleaned: "모레 5시로"),
            "내일 3시 말고 모레 4시로"
        )
        XCTAssertEqual(
            QualityChecks.preserveBilingual(source: "내일 3시 말고 모레 4시로", cleaned: "Make it 4 PM the day after tomorrow."),
            "내일 3시 말고 모레 4시로"
        )
    }

    func testEnglishModeAllowsExplicitSelfCorrections() {
        let checks = QualityChecks(nameAliases: [("John", ["John"]), ("Lauren", ["Lauren"])])
        XCTAssertTrue(checks.englishPreservesDetails(source: "Send it to John, wait no, Lauren", output: "Send it to Lauren."))
        XCTAssertTrue(checks.englishPreservesDetails(source: "내일 3시 말고 모레 4시로 바꿔줘", output: "Move it to 4 PM the day after tomorrow."))
        // Still rejects unrequested email greeting or acknowledgment even on self-corrected utterances.
        XCTAssertFalse(checks.englishPreservesDetails(source: "Send it to John, wait no, Lauren", output: "Sure, send it to Lauren."))
    }
}
