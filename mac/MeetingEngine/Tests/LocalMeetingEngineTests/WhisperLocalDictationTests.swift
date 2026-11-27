import XCTest
@testable import LocalMeetingEngine

final class WhisperLocalDictationTests: XCTestCase {
    func testResample24kInt16To16kFloatProducesExpectedLengthAndRange() {
        // 0.1 s @ 24 kHz mono = 2400 Int16 samples = 4800 bytes → 1600 Float samples @ 16 kHz.
        var samples = [Int16](repeating: 0, count: 2400)
        for i in 0..<samples.count {
            let v = sin(2.0 * .pi * 440.0 * Double(i) / 24_000.0)
            samples[i] = Int16(max(-32767, min(32767, v * 16000.0)))
        }
        let pcm = samples.withUnsafeBufferPointer { Data(buffer: $0) }
        let out = WhisperLocalDictation.resample24kInt16To16kFloat(pcm)
        XCTAssertEqual(out.count, 1600)
        XCTAssertTrue(out.allSatisfy { $0 >= -1.0 && $0 <= 1.0 })
        XCTAssertGreaterThan(out.map(abs).max() ?? 0, 0.4)
    }

    func testBuildPromptStringDeduplicatesAndCapsLength() {
        let prompt = WhisperLocalDictation.buildPromptString(
            terms: ["Luma", "Vercel", "luma", "  Derma 9 shop ", "Next.js", ""],
            maxTerms: 10,
            maxChars: 36
        )
        XCTAssertEqual(prompt, "Luma, Vercel, Derma 9 shop, Next.js")
        let bounded = WhisperLocalDictation.buildPromptString(
            terms: ["Alpha", "Beta", "Gamma", "Delta"],
            maxTerms: 10,
            maxChars: 14
        )
        XCTAssertEqual(bounded, "Alpha, Beta")
    }

    func testSpeechLanguagePolicyEnforcesEnAndKoOnly() {
        XCTAssertEqual(SpeechLanguagePolicy.allowedLanguages.sorted(), ["en", "ko"])
        XCTAssertTrue(SpeechLanguagePolicy.isAllowed("en"))
        XCTAssertTrue(SpeechLanguagePolicy.isAllowed("ko"))
        XCTAssertTrue(SpeechLanguagePolicy.isAllowed("en-US"))
        XCTAssertTrue(SpeechLanguagePolicy.isAllowed("ko_KR"))
        XCTAssertFalse(SpeechLanguagePolicy.isAllowed("ja"))
        XCTAssertFalse(SpeechLanguagePolicy.isAllowed("es"))
        XCTAssertFalse(SpeechLanguagePolicy.isAllowed("fr"))
        XCTAssertTrue(SpeechLanguagePolicy.isUnsupportedExplicitHint("ja"))
        XCTAssertFalse(SpeechLanguagePolicy.isUnsupportedExplicitHint("ko"))
        XCTAssertFalse(SpeechLanguagePolicy.isUnsupportedExplicitHint(nil))
        XCTAssertEqual(SpeechLanguagePolicy.filterLanguages(["ja", "ko-KR", "en-US", "fr"]), ["en", "ko"])
    }

    func testSpeechLanguagePolicyFiltersDisallowedTranscriptsAndExpandsWithSingleList() {
        XCTAssertTrue(SpeechLanguagePolicy.isAllowedTranscript("이번 Ads report 확인해줘.", detectedLanguage: "ko"))
        XCTAssertTrue(SpeechLanguagePolicy.isAllowedTranscript("Ship Sunday Voice Pro.", detectedLanguage: "en"))
        XCTAssertFalse(SpeechLanguagePolicy.isAllowedTranscript("Bonjour tout le monde", detectedLanguage: "fr"))
        XCTAssertFalse(SpeechLanguagePolicy.isAllowedTranscript("おはようございます"))
        XCTAssertFalse(SpeechLanguagePolicy.isAllowedTranscript("Привет мир"))
        XCTAssertTrue(SpeechLanguagePolicy.isAllowedTranscript("おはようございます", detectedLanguage: "ja", allowed: ["ko", "en", "ja"]))
    }

    func testWhisperLocalDictationGracefullyIgnoresUnsupportedLanguageHint() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sv-lang-test-\(UUID().uuidString)")
        let local = WhisperLocalDictation(directory: dir)
        let pcm = Data(repeating: 0, count: 4800)
        // Unsupported language hint returns empty gracefully without requiring model files.
        let result = try await local.transcribe(pcm24kMono: pcm, languageHint: "ja", promptTerms: [])
        XCTAssertEqual(result, "")
    }
}
