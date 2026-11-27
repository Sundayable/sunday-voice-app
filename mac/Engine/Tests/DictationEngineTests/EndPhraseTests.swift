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
}
