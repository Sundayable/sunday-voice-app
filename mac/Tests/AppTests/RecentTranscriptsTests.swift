import XCTest
import DictationEngine
@testable import Sunday_Voice

/// Local recent list: newest first, outcome updates in place, capped, owner-only file, clearable.
@MainActor
final class RecentTranscriptsTests: XCTestCase {
    func rec(_ id: String, _ text: String = "text", outcome: DeliveryOutcome = .pasted) -> DeliveryRecord {
        DeliveryRecord(id: id, text: text, mode: .bilingual, appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", at: Date(), outcome: outcome)
    }

    func testNewestFirstUpdateInPlaceCappedAndPersisted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("recent.json")
        let list = RecentTranscripts(url: url)
        for i in 0..<25 { list.record(rec("\(i)")) }
        XCTAssertEqual(list.items.count, 20)
        XCTAssertEqual(list.latest?.id, "24")
        list.record(rec("24", outcome: .failed))
        XCTAssertEqual(list.items.count, 20)
        XCTAssertEqual(list.latest?.outcome, .failed, "a later paste check updates the same entry")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        XCTAssertEqual(RecentTranscripts(url: url).items.map(\.id), list.items.map(\.id), "survives a relaunch")
        list.clear()
        XCTAssertTrue(list.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testMenuTitleShowsTimeAppAndSnippet() {
        let long = String(repeating: "가", count: 60)
        let title = RecentTranscripts.title(rec("x", long))
        XCTAssertTrue(title.contains("Slack · "))
        XCTAssertTrue(title.hasSuffix("…"))
        XCTAssertLessThan(title.count, 70)
    }

    func testSyntheticBenchmarkCannotEvictHistoryOrRewriteItsFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("recent.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = RecentTranscripts(url: url)
        for i in 0..<RecentTranscripts.limit { list.record(rec("user-\(i)")) }
        let before = try Data(contentsOf: url)
        let ids = list.items.map(\.id)
        for i in 0..<30 {
            list.record(rec(DeliveryRecord.diagnosticIDPrefix + "\(i)", "Synthetic fixture"))
        }
        XCTAssertEqual(list.items.map(\.id), ids)
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(RecentTranscripts(url: url).items.map(\.id), ids)
    }

    func testTranscriptStaysOnClipboardByDefault() {
        UserDefaults.standard.removeObject(forKey: "keepTranscriptOnClipboard")
        XCTAssertTrue(Prefs.keepTranscriptOnClipboard)
        XCTAssertTrue(EngineConfiguration(apiBaseURL: URL(string: "https://example.test")!).keepTranscriptOnClipboard)
        XCTAssertNotEqual(L("settings.keepOnClipboard"), "settings.keepOnClipboard")
    }
    func testLongTextAndRetryReplacePartialWithoutTruncation() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("recent.json"), list = RecentTranscripts(url: dir.appendingPathComponent("recent.json"))
        XCTAssertTrue(list.record(rec("retry", "partial", outcome: .failed)))
        let long = String(repeating: "Synthetic words 42 ", count: 1500)
        XCTAssertTrue(list.record(rec("retry", long)))
        XCTAssertEqual(RecentTranscripts(url: url).latest?.text, long)
        XCTAssertEqual(list.items.count, 1)
    }

    func testFailedHistoryWriteIsReportedSoAudioIsRetained() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data("not a directory".utf8).write(to: dir)
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = RecentTranscripts(url: dir.appendingPathComponent("recent.json"))
        XCTAssertFalse(list.record(rec("pending", "Synthetic retained words")))
        XCTAssertEqual(list.latest?.text, "Synthetic retained words")
    }

}
