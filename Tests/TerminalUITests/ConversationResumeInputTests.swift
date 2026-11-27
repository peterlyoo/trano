import AppKit
import XCTest
@testable import TranoApp

@MainActor final class ConversationResumeInputTests: XCTestCase {
    func key(_ character: String, code: UInt16, repeatKey: Bool = false) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, characters: character, charactersIgnoringModifiers: character,
            isARepeat: repeatKey, keyCode: code))
    }
    // Implements: FR-RESUME-2, FR-RESUME-3
    func testEscapeAndTogglePassThroughHangulCompositionWithoutDismissing() throws {
        var dismissals = 0
        for event in [try key("\u{1b}", code: 53), try key("r", code: 15)] {
            XCTAssertFalse(ConversationResumeInput.handle(event, composing: true, terminalIsResponder: false,
                toggle: event.keyCode == 15, dismiss: { dismissals += 1 }))
        }
        XCTAssertEqual(dismissals, 0)
    }
    // Implements: FR-RESUME-2, FR-RESUME-3, FR-RESUME-5
    func testCommittedEscapeDismissesAndSearchInputRemainsNativeWhileTerminalInputIsBlocked() throws {
        var dismissals = 0
        XCTAssertTrue(ConversationResumeInput.handle(try key("\u{1b}", code: 53), composing: false, terminalIsResponder: false, toggle: false, dismiss: { dismissals += 1 }))
        XCTAssertEqual(dismissals, 1)
        XCTAssertFalse(ConversationResumeInput.handle(try key("한", code: 4), composing: false, terminalIsResponder: false, toggle: false, dismiss: { XCTFail("Plain search input cannot dismiss") }))
        XCTAssertTrue(ConversationResumeInput.handle(try key("a", code: 0), composing: false, terminalIsResponder: true, toggle: false, dismiss: { XCTFail("Hidden terminal input cannot dismiss") }))
    }
}
