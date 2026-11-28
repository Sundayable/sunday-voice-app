import XCTest
@testable import DictationEngine

final class EndPhraseTests: XCTestCase {
    func testStripsTrailingPhrase() {
        XCTAssertEqual(EndPhrase.strip("오늘 회의 정리해 줘 입력했어"), "오늘 회의 정리해 줘")
        XCTAssertEqual(EndPhrase.strip("오늘 회의 정리해 줘. 입력 완료."), "오늘 회의 정리해 줘")
        XCTAssertEqual(EndPhrase.strip("Send the deck, 입력했어요!"), "Send the deck")
        XCTAssertEqual(EndPhrase.strip("입력완료"), "")
    }
    func testEnterAsLastWord() {
        XCTAssertEqual(EndPhrase.strip("내일 회의 잡아 줘 엔터"), "내일 회의 잡아 줘")
        XCTAssertEqual(EndPhrase.strip("내일 회의 잡아 줘. 엔터."), "내일 회의 잡아 줘")
        XCTAssertEqual(EndPhrase.strip("엔터 키 누르면 보내져"), "엔터 키 누르면 보내져")
        XCTAssertTrue(EndPhrase.endsWithEnter("테스트 엔터"))
        XCTAssertFalse(EndPhrase.endsWithEnter("엔터 키 누르면"))
        XCTAssertFalse(EndPhrase.endsWithEnter("센터"))
    }
    func testTranscriptionVariants() {
        XCTAssertEqual(EndPhrase.strip("보내 줘 앤터"), "보내 줘")
        XCTAssertEqual(EndPhrase.strip("보내 줘 엔터!"), "보내 줘")
        XCTAssertEqual(EndPhrase.strip("보내 줘 Enter."), "보내 줘")
        XCTAssertEqual(EndPhrase.strip("보내 줘 입력 했어"), "보내 줘")
        XCTAssertEqual(EndPhrase.strip("보내 줘. 입력했습니다."), "보내 줘")
        XCTAssertEqual(EndPhrase.strip("보내 줘 입력 완료요"), "보내 줘")
        XCTAssertTrue(EndPhrase.heard(in: "보내 줘 입력 했습니다"))
        XCTAssertTrue(EndPhrase.endsWithEnter("보내 줘 앤터."))
        XCTAssertTrue(EndPhrase.endsWithEnter("보내 줘. 엔터!"))
    }
    func testMisheardEndPhrase() {
        XCTAssertEqual(EndPhrase.strip("이것도 될 것 같아? 김력 완료."), "이것도 될 것 같아?")
        XCTAssertTrue(EndPhrase.heard(in: "보내 줘 임력했어"))
    }
    func testEndsWithPhrase() {
        XCTAssertTrue(EndPhrase.endsWithPhrase("보내 줘. 입력완료"))
        XCTAssertTrue(EndPhrase.endsWithPhrase("보내 줘 엔터."))
        XCTAssertFalse(EndPhrase.endsWithPhrase("엔터 키 누르면 보내져"))
    }
    func testKeepsPhraseInTheMiddle() {
        XCTAssertEqual(EndPhrase.strip("입력했어 라는 말은 빼고 보내"), "입력했어 라는 말은 빼고 보내")
    }
    func testHeardInPartials() {
        XCTAssertTrue(EndPhrase.heard(in: "테스트 입력 했어"))
        XCTAssertTrue(EndPhrase.heard(in: "테스트입력완료"))
        XCTAssertFalse(EndPhrase.heard(in: "입력창에 테스트"))
    }

    func testSendByVoiceKOAndENVariantsAtEndOnly() {
        // KO variants at end
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "내일 3시에 봬요 입력완료"),
                       .init(text: "내일 3시에 봬요", matched: true, matchedPhrase: "입력완료"))
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "내일 3시에 봬요. 입력 완료."),
                       .init(text: "내일 3시에 봬요", matched: true, matchedPhrase: "입력완료"))
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "회의 시작할게요 보내기"),
                       .init(text: "회의 시작할게요", matched: true, matchedPhrase: "보내기"))
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "지금 갈게, 보내기요!"),
                       .init(text: "지금 갈게", matched: true, matchedPhrase: "보내기"))
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "확인했어요 엔터."),
                       .init(text: "확인했어요", matched: true, matchedPhrase: "엔터"))
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "확인했어요 앤터"),
                       .init(text: "확인했어요", matched: true, matchedPhrase: "엔터"))

        // EN variants at end (including preserving ?/!)
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "See you at 3, send it."),
                       .init(text: "See you at 3", matched: true, matchedPhrase: "send it"))
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "Are you free? Press enter!"),
                       .init(text: "Are you free?", matched: true, matchedPhrase: "press enter"))
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "Looks good to me enter"),
                       .init(text: "Looks good to me", matched: true, matchedPhrase: "enter"))

        // Command-only utterance strips to empty
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "입력완료"),
                       .init(text: "", matched: true, matchedPhrase: "입력완료"))
        XCTAssertEqual(EndPhrase.extractSendCommand(from: "Send it!"),
                       .init(text: "", matched: true, matchedPhrase: "send it"))
    }

    func testSendByVoiceNeverTriggersMidSentenceOrInsideWords() {
        for sentence in [
            "보내기 전에 한번 더 확인해 주세요",
            "엔터 키를 누르면 바로 전송돼요",
            "입력완료라고 적지 말고 그대로 둬",
            "강남 센터에서 만나요",
            "Please send it tomorrow morning",
            "You can press enter on the keyboard to continue",
            "Let's meet the carpenter",
            "Do not re-enter the room",
        ] {
            let match = EndPhrase.extractSendCommand(from: sentence)
            XCTAssertFalse(match.matched, "mid-sentence/word must not trigger: \(sentence)")
            XCTAssertEqual(match.text, sentence)
        }
    }

    func testSendByVoiceCustomConfigurablePhrases() {
        let parsed = EndPhrase.parsePhrases("전송해줘, fire away,  전송해줘 \n")
        XCTAssertEqual(parsed, ["전송해줘", "fire away"])

        let customKO = EndPhrase.extractSendCommand(from: "자료 올렸습니다 전송해줘.", phrases: parsed)
        XCTAssertEqual(customKO, .init(text: "자료 올렸습니다", matched: true, matchedPhrase: "전송해줘"))

        let customEN = EndPhrase.extractSendCommand(from: "Ship it now, Fire Away!", phrases: parsed)
        XCTAssertEqual(customEN, .init(text: "Ship it now", matched: true, matchedPhrase: "fire away"))

        // Removed default phrase no longer triggers
        let removedDefault = EndPhrase.extractSendCommand(from: "회의 끝났어 입력완료", phrases: parsed)
        XCTAssertFalse(removedDefault.matched)
        XCTAssertEqual(removedDefault.text, "회의 끝났어 입력완료")
    }
}
