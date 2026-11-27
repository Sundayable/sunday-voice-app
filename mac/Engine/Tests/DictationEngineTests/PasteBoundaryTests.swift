import XCTest
@testable import DictationEngine

/// Pure fixture-only tests: no AX calls, pasteboard, event tap or running app.
final class PasteBoundaryTests: XCTestCase {
    private func insertion(_ text: String, into value: String, at offset: Int? = nil, length: Int = 0) -> String {
        Paster.textForInsertion(text, in: value, selection: CFRange(location: offset ?? value.utf16.count, length: length))
    }

    func testConsecutiveNamesFixtureSentencesGetOneSeparator() {
        let first = "Send forty-two leads from Sundayable to Lauren by Friday at three p.m."
        let second = "Send forty-two leads from Sundayable to Lauren by Friday at three p.m."
        XCTAssertEqual(first + insertion(second, into: first), first + " " + second)
    }

    func testEmptyFieldAndEmptyResultStayExact() {
        XCTAssertEqual(insertion("Hello.", into: ""), "Hello.")
        XCTAssertEqual(insertion("", into: "Hello."), "")
        XCTAssertEqual(insertion("", into: "Hello.", at: 0), "")
    }

    func testEndOfWordOrSentenceAddsLeadingSpaceOnly() {
        for value in ["Hello", "42", "Done.", "Ready?", "Yes!", "Wait…", "(done)", "[done]", "“done”"] {
            XCTAssertEqual(insertion("Next", into: value), " Next", value)
        }
        XCTAssertEqual(insertion("Next  line.\n", into: "Done."), " Next  line.\n")
    }

    func testExistingWhitespaceAndNewlinesArePreserved() {
        for whitespace in [" ", "  ", "\t", "\n", "\r\n", "\u{00A0}", "\u{2003}", "\u{2028}"] {
            XCTAssertEqual(insertion("Next.", into: "Done." + whitespace), "Next.")
            XCTAssertEqual(insertion("Next.", into: whitespace + "End.", at: 0), "Next.")
            XCTAssertEqual(insertion(whitespace + "Next.", into: "Done."), whitespace + "Next.")
            XCTAssertEqual(insertion("Next." + whitespace, into: "End.", at: 0), "Next." + whitespace)
        }
    }

    func testMiddleInsertionAtWhitespaceOnlyAddsMissingSeparator() {
        let value = "Hello world"
        XCTAssertEqual(insertion("beautiful", into: value, at: 5), " beautiful")
        XCTAssertEqual(insertion("beautiful", into: value, at: 6), "beautiful ")
        XCTAssertEqual(insertion("beautiful", into: "Hello  world", at: 6), "beautiful")
        XCTAssertEqual(insertion("First.", into: "Next.", at: 0), "First. ")
        XCTAssertEqual(insertion("Next.", into: "Hello \nworld", at: 6), "Next.")
    }

    func testInteriorTokenBoundariesAreAmbiguousAndStayExact() {
        for (value, offset) in [("HelloWorld", 5), ("1.5", 2), ("example.com", 8), ("can't", 3), ("안녕하세요", 2)] {
            XCTAssertEqual(insertion("new", into: value, at: offset), "new", value)
        }
    }

    func testSelectionReplacementIsAlwaysExact() {
        XCTAssertEqual(insertion("new", into: "old", at: 0, length: 3), "new")
        XCTAssertEqual(insertion(" new\n", into: "Hello old world", at: 6, length: 3), " new\n")
        XCTAssertEqual(insertion("new", into: "Hello oldworld", at: 6, length: 3), "new")
        XCTAssertEqual(insertion("", into: "Hello old world", at: 6, length: 3), "")
        XCTAssertEqual(insertion("🙂", into: "Hello 👩🏽‍💻world", at: 6, length: "👩🏽‍💻".utf16.count), "🙂")
    }

    func testPunctuationAttachmentIsPreserved() {
        for punctuation in [".", ", next", "!", "?", ";", ":", ")", "]", "}", "”", "'s", "’s", "-up", "/path"] {
            XCTAssertEqual(insertion(punctuation, into: "Hello"), punctuation)
        }
        for prefix in ["(", "[", "{", "“", "'", "’", "-", "/", "@", "#"] {
            XCTAssertEqual(insertion("word", into: prefix), "word")
        }
        XCTAssertEqual(insertion("(next)", into: "Hello"), " (next)")
        XCTAssertEqual(insertion("world", into: ")", at: 0), "world")
        XCTAssertEqual(insertion("Next", into: "Done,"), " Next")
    }

    func testUTF16OffsetsAfterEmojiAndCombiningCharacters() {
        let prefix = "👩🏽‍💻 café"
        XCTAssertNotEqual(prefix.count, prefix.utf16.count)
        XCTAssertEqual(insertion("opens", into: prefix), " opens")
        XCTAssertEqual(insertion("opens", into: prefix + " today", at: prefix.utf16.count), " opens")
        XCTAssertEqual(insertion("new", into: "👩🏽‍💻 shop", at: "👩🏽‍💻 ".utf16.count), "new ")
        XCTAssertEqual(insertion("opens", into: "cafe\u{301}"), " opens")
        // A raw symbol/emoji boundary is not enough evidence to infer word spacing.
        XCTAssertEqual(insertion("🙂", into: "👍"), "🙂")
    }

    func testOffsetsInsideGraphemesNeverInventSeparators() {
        // These are UTF-16 positions inside one extended grapheme, not valid caret boundaries.
        for grapheme in ["🙂", "👩🏽‍💻", "🇨🇦", "e\u{301}", "가"] {
            for offset in 1..<grapheme.utf16.count {
                XCTAssertEqual(insertion("word", into: grapheme + " next", at: offset), "word", "\(grapheme) at \(offset)")
            }
        }
    }

    func testKoreanAndMixedLanguageProseBoundaries() {
        XCTAssertEqual(insertion("Lauren에게 보내줘.", into: "확인했어요."), " Lauren에게 보내줘.")
        XCTAssertEqual(insertion("보내줘.", into: "오늘"), " 보내줘.")
        XCTAssertEqual(insertion("Ads report", into: "오늘 보내줘.", at: 3), "Ads report ")
        XCTAssertEqual(insertion("안녕하세요.", into: "Hi.\n"), "안녕하세요.")
        XCTAssertEqual(insertion("한글", into: "한국어", at: 0, length: 3), "한글")
    }

    func testInvalidAXRangesFallBackWithoutOverflowOrMutation() {
        for range in [CFRange(location: -1, length: 0), CFRange(location: 99, length: 0),
                      CFRange(location: Int.max, length: 0), CFRange(location: 0, length: -1),
                      CFRange(location: 2, length: Int.max)] {
            XCTAssertEqual(Paster.textForInsertion("Next.", in: "Hi", selection: range), "Next.")
        }
    }
}
