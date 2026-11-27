import AppKit
import XCTest
@testable import TranoApp
import TerminalCore

final class DeveloperNativeEffectsTests: XCTestCase {
    // Implements: FR-SET-101, FR-SET-102
    @MainActor func testRewrappingRetainedTerminalReusesOnlyOneCursorOverlay() {
        let terminal = NSView(frame: .zero)
        let first = DeveloperTerminalContainer(terminal: terminal, rowHeight: { 20 })
        let firstOverlay = first.cursorOverlay
        let second = DeveloperTerminalContainer(terminal: terminal, rowHeight: { 20 })
        XCTAssertTrue(terminal.superview === second)
        XCTAssertEqual(terminal.subviews.compactMap { $0 as? DeveloperCursorOverlay }.count, 1)
        XCTAssertNil(firstOverlay.superview)
        XCTAssertFalse(firstOverlay.hasActiveTimer)
    }

    // Implements: FR-SET-101
    @MainActor func testContainerFillsViewportUnlessBottomAnchoringIsExplicitlyEnabled() {
        let terminal = NSView(frame: .zero)
        let container = DeveloperTerminalContainer(terminal: terminal, rowHeight: { 20 })
        container.frame = NSRect(x: 0, y: 0, width: 801, height: 413)
        container.layout()
        XCTAssertEqual(terminal.frame, container.bounds)
        container.anchoring = .bottom
        container.layout()
        XCTAssertEqual(terminal.frame, NSRect(x: 0, y: 13, width: 801, height: 400))
        container.anchoring = .top
        container.layout()
        XCTAssertEqual(terminal.frame, container.bounds)
    }

    // Implements: FR-SET-102
    @MainActor func testCursorOverlayIsPassiveAndExpiresWhenInactive() {
        let overlay = DeveloperCursorOverlay(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        var caret = CGRect(x: 10, y: 20, width: 8, height: 18)
        overlay.caretFrame = { caret }
        overlay.style = .comet
        overlay.reducesMotion = { false }
        overlay.sample(at: 1, active: true)
        caret.origin.x = 150
        overlay.sample(at: 1.02, active: true)
        XCTAssertFalse(overlay.renderedPoints.isEmpty)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 20, y: 20)))
        overlay.sample(at: 1.04, active: false)
        XCTAssertTrue(overlay.renderedPoints.isEmpty)
        XCTAssertFalse(overlay.hasActiveTimer)
        overlay.stop()
        XCTAssertTrue(overlay.renderedPoints.isEmpty)
    }

    // Implements: FR-SET-102
    @MainActor func testReducedMotionClearsCursorOverlayImmediately() {
        let overlay = DeveloperCursorOverlay(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        var caret = CGRect(x: 10, y: 20, width: 8, height: 18)
        var reduce = false
        overlay.caretFrame = { caret }; overlay.reducesMotion = { reduce }; overlay.style = .blaze
        overlay.sample(at: 1, active: true)
        caret.origin.x = 150; overlay.sample(at: 1.02, active: true)
        XCTAssertFalse(overlay.renderedPoints.isEmpty)
        reduce = true; overlay.sample(at: 1.03, active: true)
        XCTAssertTrue(overlay.renderedPoints.isEmpty)
        XCTAssertFalse(overlay.hasActiveTimer)
    }
}
