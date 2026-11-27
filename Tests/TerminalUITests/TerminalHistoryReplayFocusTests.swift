import AppKit
import XCTest
@testable import TranoApp

@MainActor private final class ReplayFocusKeyWindow: NSWindow {
    var reportsKey = true
    override var isKeyWindow: Bool { reportsKey }
}
final class TerminalHistoryReplayFocusTests: XCTestCase {
    // Implements: FR-INPUT-1, FR-NAV-4
    @MainActor func testReplayRequiresTheCurrentNativeKeyWindowAndExactResponder() throws {
        _ = NSApplication.shared
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
        let terminal = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 300))
        let editor = NSTextView(frame: NSRect(x: 320, y: 0, width: 320, height: 300))
        content.addSubview(terminal); content.addSubview(editor)
        let window = ReplayFocusKeyWindow(contentRect: content.frame, styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = content
        window.setFrameOrigin(NSPoint(x: -18000, y: -18000)); window.orderFrontRegardless()
        defer { window.close() }
        XCTAssertTrue(window.makeFirstResponder(terminal))
        XCTAssertTrue(TerminalHistoryReplayFocus.ownsInput(terminal, in: window))
        window.reportsKey = false
        XCTAssertFalse(TerminalHistoryReplayFocus.ownsInput(terminal, in: window))
        window.reportsKey = true
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertFalse(TerminalHistoryReplayFocus.ownsInput(terminal, in: window))
        XCTAssertTrue(window.makeFirstResponder(terminal))
        terminal.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(terminal.hasMarkedText())
        XCTAssertTrue(TerminalHistoryReplayFocus.ownsInput(terminal, in: window))
        terminal.unmarkText()
    }
    // Implements: FR-INPUT-1, FR-NAV-4
    @MainActor func testAWindowCannotOwnAnotherWindowsTerminal() throws {
        _ = NSApplication.shared
        let terminal = NSTextView(frame: NSRect(x: 0, y: 0, width: 320, height: 200))
        let first = ReplayFocusKeyWindow(contentRect: terminal.frame, styleMask: [], backing: .buffered, defer: false)
        let second = ReplayFocusKeyWindow(contentRect: terminal.frame, styleMask: [], backing: .buffered, defer: false)
        first.isReleasedWhenClosed = false; second.isReleasedWhenClosed = false
        first.contentView = terminal
        first.setFrameOrigin(NSPoint(x: -18000, y: -18000)); second.setFrameOrigin(NSPoint(x: -19000, y: -19000))
        defer { first.close(); second.close() }
        XCTAssertTrue(first.makeFirstResponder(terminal))
        XCTAssertFalse(TerminalHistoryReplayFocus.ownsInput(terminal, in: second))
    }
}
