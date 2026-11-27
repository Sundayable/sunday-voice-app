import XCTest
@testable import DictationEngine

/// Paste read-back: a transcript counts as pasted only if the field now contains it once more than
/// before; otherwise it stays on the clipboard.
final class PasteCheckTests: XCTestCase {
    func testLandedWhenTheTextAppearsOnceMore() {
        XCTAssertTrue(Paster.pasteLanded(before: "", after: "Send it to Lauren.", inserted: "Send it to Lauren."))
        XCTAssertTrue(Paster.pasteLanded(before: "Hi. ", after: "Hi. 내일 보내 주세요", inserted: " 내일 보내 주세요"))
        // The same sentence already in the document: needs one more occurrence.
        XCTAssertFalse(Paster.pasteLanded(before: "확인해줘", after: "확인해줘", inserted: "확인해줘"))
        XCTAssertTrue(Paster.pasteLanded(before: "확인해줘", after: "확인해줘 확인해줘", inserted: "확인해줘"))
    }

    func testFieldsThatReflowWhitespaceStillCount() {
        XCTAssertTrue(Paster.pasteLanded(before: "", after: "Line one\nline two", inserted: "Line one line two"))
        XCTAssertFalse(Paster.pasteLanded(before: "draft", after: "draft", inserted: "Line one line two"))
        XCTAssertTrue(Paster.pasteLanded(before: "x", after: "x", inserted: "   "), "nothing to check")
    }

    func testListsAndTablesAreNotTextFields() {
        for role in ["AXOutline", "AXTable", "AXList", "AXWindow"] { XCTAssertTrue(Paster.nonTextRoles.contains(role), role) }
        for role in ["AXTextArea", "AXTextField", "AXComboBox", "AXWebArea", "AXGroup"] { XCTAssertFalse(Paster.nonTextRoles.contains(role), role) }
    }

    func testDeliveryRecordRoundTrips() throws {
        let r = DeliveryRecord(id: "a", text: "안녕", mode: .english, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap",
                               at: Date(timeIntervalSince1970: 1_790_000_000), outcome: .failed)
        XCTAssertEqual(try JSONDecoder().decode(DeliveryRecord.self, from: JSONEncoder().encode(r)), r)
    }
}
