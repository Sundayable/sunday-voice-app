import AppKit
import XCTest
@testable import Sunday_Voice

@MainActor
final class BrandStringsTests: XCTestCase {
    private var macRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testUserFacingResourcesContainNoLegacyBrand() throws {
        var checked = 0
        for directory in ["Resources", "Config"] {
            let root = macRoot.appendingPathComponent(directory)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let file as URL in files where ["xcstrings", "strings", "stringsdict", "plist"].contains(file.pathExtension) {
                let data = try Data(contentsOf: file)
                let object: Any
                if file.pathExtension == "xcstrings" { object = try JSONSerialization.jsonObject(with: data) }
                else { object = try PropertyListSerialization.propertyList(from: data, format: nil) }
                for value in stringValues(object) {
                    XCTAssertFalse(hasLegacyBrand(value), "Legacy brand in \(file.path): \(value)")
                }
                checked += 1
            }
        }
        XCTAssertGreaterThanOrEqual(checked, 4, "The catalog and both permission localizations must be scanned")
        for value in stringValues(Bundle.main.infoDictionary ?? [:]) {
            XCTAssertFalse(hasLegacyBrand(value), "Legacy brand in the built app Info.plist: \(value)")
        }
    }

    func testAppAndEngineStringLiteralsContainNoLegacyBrand() throws {
        // Inspect literals, not identifiers or historical comments. The private queue label is
        // an internal identifier kept for diagnostics, never shown in a user interface.
        let literals = try NSRegularExpression(pattern: #""(?:\\.|[^"\\])*""#)
        let allowedInternalIdentifiers: Set<String> = ["koen.mic.control"]
        for directory in ["Sources/App", "Engine/Sources"] {
            let files = try XCTUnwrap(FileManager.default.enumerator(at: macRoot.appendingPathComponent(directory), includingPropertiesForKeys: nil))
            for case let file as URL in files where file.pathExtension == "swift" {
                let source = try String(contentsOf: file, encoding: .utf8)
                for match in literals.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                    let range = try XCTUnwrap(Range(match.range, in: source))
                    let value = String(source[range].dropFirst().dropLast())
                    if allowedInternalIdentifiers.contains(value) { continue }
                    XCTAssertFalse(hasLegacyBrand(value), "Legacy brand literal in \(file.path): \(value)")
                }
            }
        }
    }

    func testReadyStatusFitsMenuHeaderInBothLanguages() throws {
        Theme.registerFonts()
        let font = Theme.nsLabel(10.5)
        let originalLanguage = UILanguage.choice
        defer { UILanguage.choice = originalLanguage }
        for language in ["en", "ko"] {
            let path = try XCTUnwrap(Bundle.main.path(forResource: language, ofType: "lproj"))
            let bundle = try XCTUnwrap(Bundle(path: path))
            let status = bundle.localizedString(forKey: "menu.ready", value: nil, table: nil)
            XCTAssertNotEqual(status, "menu.ready")
            let width = (status.uppercased() as NSString).size(withAttributes: [.font: font]).width
            XCTAssertLessThanOrEqual(width, 232, "\(language) ready status clips in the 260-point header")
            XCTAssertFalse(status.contains("Control") || status.contains("Mouse") || status.contains("F18"), "Ready status must not advertise fixed keys after reassignment")
            UILanguage.choice = language
            let quit = bundle.localizedString(forKey: "menu.quit", value: nil, table: nil)
            XCTAssertTrue(MenuStyle.quitTitle.contains(AppIdentity.name), "Localized quit must use the current product name")
            XCTAssertEqual(MenuStyle.quitTitle, String(format: quit, AppIdentity.name))
        }
    }

    private func hasLegacyBrand(_ text: String) -> Bool {
        text.range(of: "KoEn", options: .caseInsensitive) != nil
    }

    private func stringValues(_ object: Any) -> [String] {
        if let value = object as? String { return [value] }
        if let values = object as? [Any] { return values.flatMap(stringValues) }
        if let values = object as? [String: Any] { return values.values.flatMap(stringValues) }
        return []
    }
}
