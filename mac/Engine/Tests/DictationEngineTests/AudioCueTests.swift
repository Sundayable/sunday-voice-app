import AppKit
import XCTest
@testable import DictationEngine

/// Start cue (Tink) when audio is live, end cue (Pop) after the stream closes.
final class AudioCueTests: XCTestCase {
    func testPreRollNeverReachesBackIntoTheEndCue() {
        // Normal: 100 ms lead before the press.
        XCTAssertEqual(DictationEngine.preRollStart(pressAt: 100, lead: 0.1, endCueAudibleUntil: 50), 99.9, accuracy: 1e-9)
        // Re-pressed while the previous end cue still rings: pre-roll starts after it.
        XCTAssertEqual(DictationEngine.preRollStart(pressAt: 100, lead: 0.1, endCueAudibleUntil: 99.95), 99.95, accuracy: 1e-9)
    }

    func testCueSoundsExistOnThisMac() {
        XCTAssertNotNil(NSSound(named: "Tink"))
        XCTAssertNotNil(NSSound(named: "Pop"))
    }

    func testStartCueIsLouderThanEndCueAndNeitherIsBoosted() {
        // NSSound volume above 1.0 would be a gain stage; keep both at or below the file level.
        XCTAssertLessThanOrEqual(DictationEngine.startCueVolume, 1.0)
        XCTAssertGreaterThan(DictationEngine.startCueVolume, DictationEngine.endCueVolume)
        XCTAssertGreaterThan(DictationEngine.endCueVolume, 0.25, "both louder than the 0.25 Dan found too quiet")
    }
}
