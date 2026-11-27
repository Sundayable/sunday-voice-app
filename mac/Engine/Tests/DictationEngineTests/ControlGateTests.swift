import XCTest
@testable import DictationEngine

/// Control hold: start after the delay, stop on release, any chord cancels and passes through.
final class ControlGateTests: XCTestCase {
    func testHoldStartsAfterDelayAndStopsOnRelease() {
        var gate = ControlGate()
        XCTAssertEqual(gate.modifiers(control: true, other: false, keysDown: false, now: 0, delay: 0.18), .none)
        XCTAssertEqual(gate.poll(now: 0.1), .none)
        XCTAssertEqual(gate.poll(now: 0.19), .start)
        XCTAssertEqual(gate.poll(now: 0.3), .none)
        XCTAssertEqual(gate.modifiers(control: false, other: false, keysDown: false, now: 1, delay: 0.18), .stop)
    }

    func testShortTapNeverStarts() {
        var gate = ControlGate()
        _ = gate.modifiers(control: true, other: false, keysDown: false, now: 0, delay: 0.18)
        XCTAssertEqual(gate.modifiers(control: false, other: false, keysDown: false, now: 0.1, delay: 0.18), .none)
        XCTAssertEqual(gate.poll(now: 0.5), .none)
    }

    func testChordCancelsActiveHold() {
        var gate = ControlGate()
        _ = gate.modifiers(control: true, other: false, keysDown: false, now: 0, delay: 0.18)
        XCTAssertEqual(gate.poll(now: 0.2), .start)
        XCTAssertEqual(gate.interfere(), .cancel)
        XCTAssertEqual(gate.modifiers(control: false, other: false, keysDown: false, now: 0.4, delay: 0.18), .none)
    }

    func testChordBeforeDelayBlocksStart() {
        var gate = ControlGate()
        _ = gate.modifiers(control: true, other: false, keysDown: false, now: 0, delay: 0.18)
        XCTAssertEqual(gate.interfere(), .none)
        XCTAssertEqual(gate.poll(now: 0.5), .none)
        var withOption = ControlGate()
        _ = withOption.modifiers(control: true, other: true, keysDown: false, now: 0, delay: 0.18)
        XCTAssertEqual(withOption.poll(now: 0.5), .none)
    }
}

/// Modifier-combo matching used by the generic hold triggers (Fn, Fn+Shift, Right Option, Control …).
final class ModifierMatchTests: XCTestCase {
    func testExactMatchAndSides() {
        XCTAssertTrue(DictationEngine.matches([.fn], held: [.fn]))
        XCTAssertFalse(DictationEngine.matches([.fn], held: [.fn, .shift]))
        XCTAssertTrue(DictationEngine.matches([.fn, .shift], held: [.shift, .fn]))
        XCTAssertTrue(DictationEngine.matches([.control], held: [.control]))
        XCTAssertTrue(DictationEngine.matches([.rightOption], held: [.option, .rightOption]))
        XCTAssertFalse(DictationEngine.matches([.rightOption], held: [.option])) // left Option only
        XCTAssertTrue(DictationEngine.matches([.option], held: [.option, .rightOption]))
        XCTAssertFalse(DictationEngine.matches([.control], held: []))
    }
}
