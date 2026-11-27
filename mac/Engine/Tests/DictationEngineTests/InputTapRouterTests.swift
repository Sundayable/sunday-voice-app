import XCTest
import ApplicationServices
@testable import DictationEngine

@MainActor
final class InputTapRouterTests: XCTestCase {
    func testOrdinaryKeyEventsPassThroughOnceWithoutBeingSwallowed() async throws {
        let received = expectation(description: "One internal observation per original event")
        received.expectedFulfillmentCount = 2
        var types: [CGEventType] = []
        let router = InputTapRouter(mouseButtons: [4]) { type, event in
            MainActor.assumeIsolated {
                types.append(type)
                XCTAssertEqual(event.getIntegerValueField(.keyboardEventKeycode), 0)
                received.fulfill()
            }
        }
        // Construct events only: no tap is installed and nothing is posted to the desktop.
        let down = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        let up = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false))
        XCTAssertFalse(router.route(.keyDown, down), "The callback returns the original key event")
        XCTAssertFalse(router.route(.keyUp, up))
        await fulfillment(of: [received], timeout: 1)
        XCTAssertEqual(types, [.keyDown, .keyUp])
    }
}
