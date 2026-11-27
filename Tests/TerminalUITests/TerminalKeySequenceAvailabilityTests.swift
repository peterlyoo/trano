import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor final class TerminalKeySequenceAvailabilityTests: XCTestCase {
    // Implements: FR-SET-84
    func testAvailabilityChangeDuringHintPresentationCancelsThePrefix() throws {
        _ = NSApplication.shared
        let owner = NSWindow(contentRect: NSRect(x: -14000, y: -14000, width: 600, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        owner.isReleasedWhenClosed = false
        defer { owner.close() }
        var available = true
        var dispatched: [ActionID] = []
        let controller = try TerminalKeySequenceController(owner: owner, overrides: [ActionID.newSession.rawValue: ["ctrl+x,ctrl+n"]],
            eligible: { true }, composing: { false }, supportsAction: { _ in available },
            onHints: { if !$0.isEmpty { available = false } }, dispatch: { dispatched.append($0) })
        XCTAssertFalse(controller.handle(try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control, timestamp: 1, windowNumber: owner.windowNumber, context: nil, characters: "x", charactersIgnoringModifiers: "x", isARepeat: false, keyCode: 7)), showHints: true))
        XCTAssertTrue(controller.hints.isEmpty)
        XCTAssertTrue(dispatched.isEmpty)
    }
}
