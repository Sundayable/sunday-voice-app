import XCTest
@testable import Sunday_Voice
final class DiagnosticsTests: XCTestCase {
    func testCrashSummaryExcludesOtherAppsPathsAndUnapprovedFields() throws {
        let report: [String: Any] = ["bundleInfo": ["CFBundleIdentifier": "test.voice"],
            "exception": ["type": "EXC_BAD_ACCESS", "signal": "SIGSEGV", "secret": "private"],
            "threads": [["triggered": true, "frames": [["symbol": "Voice.capture()"], ["symbol": "/Users/private/name"], ["symbol": "user@example.com"]]]],
            "path": "/Users/private/app", "token": "secret"]
        let data = Data("{}\n".utf8) + (try JSONSerialization.data(withJSONObject: report))
        let summary = try XCTUnwrap(CrashSummary.extract(data, bundleID: "test.voice"))
        XCTAssertTrue(summary.contains("EXC_BAD_ACCESS"))
        XCTAssertTrue(summary.contains("Voice.capture()"))
        XCTAssertFalse(summary.contains("private"))
        XCTAssertFalse(summary.contains("example.com"))
        XCTAssertFalse(summary.contains("secret"))
        XCTAssertNil(CrashSummary.extract(data, bundleID: "other.app"))
    }
}
