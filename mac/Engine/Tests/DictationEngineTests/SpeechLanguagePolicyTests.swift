import XCTest
@testable import DictationEngine

final class SpeechLanguagePolicyTests: XCTestCase {
    func testAllowedLanguagesContainOnlyEnAndKo() {
        XCTAssertEqual(SpeechLanguagePolicy.allowedLanguages.sorted(), ["en", "ko"])
        XCTAssertTrue(SpeechLanguagePolicy.isAllowed("en-US"))
        XCTAssertTrue(SpeechLanguagePolicy.isAllowed("ko_KR"))
        XCTAssertFalse(SpeechLanguagePolicy.isAllowed("ja"))
        XCTAssertFalse(SpeechLanguagePolicy.isAllowed("es"))
    }

    func testFilterKeepsAllowedSubsetAndFallsBackToAllowlist() {
        XCTAssertEqual(SpeechLanguagePolicy.filter(["ko", "ja", "en-US"]), ["ko", "en"])
        XCTAssertEqual(SpeechLanguagePolicy.filter(["ja", "fr"]), SpeechLanguagePolicy.allowedLanguages)
        XCTAssertEqual(SpeechLanguagePolicy.filter([]), SpeechLanguagePolicy.allowedLanguages)
    }

    @MainActor
    func testSessionUpdateFiltersServerGrantLanguages() {
        let grant = STTSessionGrant(
            client_secret: "",
            expires_at: 0,
            url: URL(string: "wss://voice.sundayable.com/api/stt/stream")!,
            model: "gpt-live-transcribe",
            session: .init(delay: "minimal", prompt: "", keywords: [], languages: ["ko", "ja", "en", "es"]),
            replacements: nil,
            transport: "relay-v1"
        )
        let payload = RealtimeSTTSocket.sessionUpdate(grant, prompt: "test")
        let session = payload["session"] as? [String: Any]
        let audio = session?["audio"] as? [String: Any]
        let input = audio?["input"] as? [String: Any]
        let transcription = input?["transcription"] as? [String: Any]
        XCTAssertEqual(transcription?["languages"] as? [String], ["ko", "en"])
    }

    func testTranscriptScriptCheckRejectsDisallowedLanguages() {
        XCTAssertTrue(SpeechLanguagePolicy.isAllowedTranscript("이번 Ads report 확인해줘."))
        XCTAssertTrue(SpeechLanguagePolicy.isAllowedTranscript("Hello world 123"))
        XCTAssertFalse(SpeechLanguagePolicy.isAllowedTranscript("おはようございます"))
        XCTAssertFalse(SpeechLanguagePolicy.isAllowedTranscript("Hola mundo", detectedLanguage: "es"))
    }
}
