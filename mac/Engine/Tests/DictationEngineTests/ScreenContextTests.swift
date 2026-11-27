import XCTest
@testable import DictationEngine

final class ScreenContextTests: XCTestCase {
    func testExtractsProperNounsAndLatinTokensFromTitleAndCaretWindow() {
        let title = "Derma 9 shop — Pull Request #42 · Vercel"
        let surrounding = "오늘 Next.js랑 Supabase 연결하고 Luma 이벤트 페이지 확인해줘. https://example.com/secret/token test@example.com a1b2c3d4e5f6"
        let terms = ScreenContext.extractTerms(windowTitle: title, surroundingText: surrounding)
        XCTAssertTrue(terms.contains("Derma 9"))
        XCTAssertTrue(terms.contains("Vercel"))
        XCTAssertTrue(terms.contains("Next.js"))
        XCTAssertTrue(terms.contains("Supabase"))
        XCTAssertTrue(terms.contains("Luma"))
        // URLs, email addresses, and hex hashes must never be emitted as screen terms.
        XCTAssertFalse(terms.contains(where: { $0.contains("example.com") || $0.contains("a1b2c3d4") }))
    }

    func testSliceAroundCaretStaysBoundedAndSafe() {
        let prefix = String(repeating: "가", count: 400)
        let center = " HyperFrames "
        let suffix = String(repeating: "나", count: 400)
        let full = prefix + center + suffix
        let caret = (prefix as NSString).length + 5
        let slice = ScreenContext.sliceAroundCaret(full, utf16Location: caret, radius: 50)
        XCTAssertTrue(slice.contains("HyperFrames"))
        XCTAssertLessThanOrEqual(slice.utf16.count, 102)
    }

    func testSttSuffixRespectsBudget() {
        let terms = ["Sundayable", "WhisperKit", "Next.js", "Supabase", "Cloudflare", "HyperFrames"]
        let suffix = ScreenContext.sttSuffix(for: terms, budget: 48)
        XCTAssertTrue(suffix.hasPrefix(" Screen terms: "))
        XCTAssertLessThanOrEqual(suffix.utf16.count, 48)
        XCTAssertEqual(ScreenContext.sttSuffix(for: terms, budget: 10), "")
    }

    func testLocalPersonalDictionaryAppliesReplacementsAndCleanup() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sv-local-dict-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("local-replacements.json")
        let rules = [
            LocalReplacementRule(from: "버셀", to: "Vercel"),
            LocalReplacementRule(from: "루마", to: "Luma"),
        ]
        try JSONEncoder().encode(rules).write(to: file)
        let dict = LocalPersonalDictionary(fileURL: file)
        XCTAssertEqual(dict.promptTerms(), ["Vercel", "Luma"])
        XCTAssertEqual(dict.apply(to: "음, 버셀 배포하고 루마 확인해줘"), "Vercel 배포하고 Luma 확인해줘")
    }
}
