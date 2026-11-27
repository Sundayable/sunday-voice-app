import CoreGraphics
import XCTest
@testable import DictationEngine

/// Key-ups the tap never sees (lock screen, password fields with secure input, a disabled tap) must not
/// leave a key "held" forever: that blocked every Fn / mouse trigger until the app was relaunched.
final class HeldKeysTests: XCTestCase {
    /// ⌃⌘Q locks the screen: the tap sees the downs, secure input swallows Q/⌘/⌃ ups.
    private func lockedWithControlCommandQ() -> HeldKeys {
        var keys = HeldKeys()
        keys.flagsChanged(code: 59, flags: [.maskControl])
        keys.flagsChanged(code: 55, flags: [.maskControl, .maskCommand])
        keys.keyDown(12, at: 0)
        return keys
    }

    func testFnHoldMatchesAfterMissedModifierUps() {
        var keys = lockedWithControlCommandQ()
        // Next morning: Fn down. Its flags carry only Fn.
        keys.flagsChanged(code: 63, flags: [.maskSecondaryFn])
        XCTAssertEqual(keys.held, [.fn])
        XCTAssertTrue(DictationEngine.matches([.fn], held: keys.held))
        keys.flagsChanged(code: 63, flags: [])
        XCTAssertTrue(keys.held.isEmpty)
    }

    func testFnShiftStillWorksAfterMissedUps() {
        var keys = lockedWithControlCommandQ()
        keys.flagsChanged(code: 63, flags: [.maskSecondaryFn])
        keys.flagsChanged(code: 56, flags: [.maskSecondaryFn, .maskShift])
        XCTAssertTrue(DictationEngine.matches([.fn, .shift], held: keys.held))
    }

    func testMouseEventFlagsClearStaleModifiers() {
        var keys = lockedWithControlCommandQ()
        keys.resync(flags: []) // a side-button click with no modifier held
        XCTAssertTrue(keys.held.isEmpty)
    }

    func testStaleSameKeyDoesNotInvertState() {
        var keys = HeldKeys()
        keys.flagsChanged(code: 63, flags: [.maskSecondaryFn]) // Fn down; its up is missed
        keys.flagsChanged(code: 63, flags: [.maskSecondaryFn]) // next Fn down
        XCTAssertEqual(keys.held, [.fn])
    }

    func testMissedKeyUpExpires() {
        var keys = lockedWithControlCommandQ()
        XCTAssertTrue(keys.anyKeyDown(now: 1))
        XCTAssertFalse(keys.anyKeyDown(now: 1 + HeldKeys.keyStaleAfter + 0.1))
    }

    func testKeyHeldWithRepeatsStaysDown() {
        var keys = HeldKeys()
        keys.keyDown(0, at: 0)
        keys.keyDown(0, at: 10) // auto-repeat
        XCTAssertTrue(keys.anyKeyDown(now: 10 + HeldKeys.keyStaleAfter - 1))
        keys.keyUp(0)
        XCTAssertFalse(keys.anyKeyDown(now: 11))
    }

    func testRightSideModifiers() {
        var keys = HeldKeys()
        keys.flagsChanged(code: 61, flags: [.maskAlternate])
        XCTAssertTrue(DictationEngine.matches([.rightOption], held: keys.held))
        keys.flagsChanged(code: 58, flags: [.maskAlternate])
        XCTAssertEqual(keys.held, [.option, .rightOption])
        keys.flagsChanged(code: 61, flags: [.maskAlternate])
        XCTAssertFalse(DictationEngine.matches([.rightOption], held: keys.held))
        keys.flagsChanged(code: 58, flags: [])
        XCTAssertTrue(keys.held.isEmpty)
    }
}
