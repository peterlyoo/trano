#if os(macOS)
import AppKit
import QuartzCore
import XCTest
@testable import SwiftTerm

final class TerminalCursorPreferencesTests: XCTestCase {
    // Implements: FR-SET-80, FR-SET-81
    @MainActor func testCursorTimingDefaultsRemainUnchanged() throws {
        let view = makeView()
        XCTAssertEqual(view.cursorBlinkInterval, 0.7, accuracy: 0.000_001)
        XCTAssertNil(view.forcedCursorStyle)
        let caret = try XCTUnwrap(view.caretView)
        caret.style = .blinkBlock
        XCTAssertEqual(try animation(caret).duration, 0.7, accuracy: 0.000_001)
    }

    // Implements: FR-SET-80, FR-SET-81
    @MainActor func testChangingIntervalUpdatesTheNativeAnimationForEveryBlinkStyle() throws {
        let view = makeView()
        let caret = try XCTUnwrap(view.caretView)
        for style in [CursorStyle.blinkBlock, .blinkBar, .blinkUnderline] {
            caret.style = style
            view.cursorBlinkInterval = 0.23
            XCTAssertEqual(view.cursorBlinkInterval, 0.23, accuracy: 0.000_001)
            let value = try animation(caret)
            XCTAssertEqual(value.duration, 0.23, accuracy: 0.000_001)
            XCTAssertTrue(value.autoreverses)
            XCTAssertEqual(value.repeatCount, Float.infinity)
            view.cursorBlinkInterval = 0.41
            XCTAssertEqual(try animation(caret).duration, 0.41, accuracy: 0.000_001)
        }
    }

    // Implements: FR-SET-80, FR-SET-81
    @MainActor func testIntervalSelectedBeforeBlinkingIsAppliedWhenBlinkingStarts() throws {
        let view = makeView()
        let caret = try XCTUnwrap(view.caretView)
        caret.style = .steadyBlock
        view.cursorBlinkInterval = 0.31
        XCTAssertNil(caret.layer?.animation(forKey: #keyPath(CALayer.opacity)))
        caret.style = .blinkUnderline
        XCTAssertEqual(try animation(caret).duration, 0.31, accuracy: 0.000_001)
    }

    // Implements: FR-SET-80, FR-SET-81
    @MainActor func testInputResetUsesConfiguredDurationAndInitialVisibleDelay() throws {
        let view = makeView()
        let caret = try XCTUnwrap(view.caretView)
        caret.style = .blinkBar
        view.cursorBlinkInterval = 0.29
        let layer = try XCTUnwrap(caret.layer)
        let before = layer.convertTime(CACurrentMediaTime(), from: nil)
        caret.resetBlinkAfterInput()
        let after = layer.convertTime(CACurrentMediaTime(), from: nil)
        let value = try animation(caret)
        XCTAssertEqual(value.duration, 0.29, accuracy: 0.000_001)
        XCTAssertGreaterThanOrEqual(value.beginTime, before + 0.29 - 0.001)
        XCTAssertLessThanOrEqual(value.beginTime, after + 0.29 + 0.001)
        XCTAssertEqual(layer.opacity, 1)
        caret.style = .steadyBar
        caret.resetBlinkAfterInput()
        XCTAssertNil(layer.animation(forKey: #keyPath(CALayer.opacity)))
    }

    // Implements: FR-SET-80, FR-SET-81
    @MainActor func testInvalidIntervalsAreFiniteAndBounded() {
        let view = makeView()
        view.cursorBlinkInterval = -1
        XCTAssertEqual(view.cursorBlinkInterval, 0.05, accuracy: 0.000_001)
        view.cursorBlinkInterval = 100
        XCTAssertEqual(view.cursorBlinkInterval, 10, accuracy: 0.000_001)
        for invalid in [Double.nan, Double.infinity, -Double.infinity] {
            view.cursorBlinkInterval = invalid
            XCTAssertEqual(view.cursorBlinkInterval, 0.7, accuracy: 0.000_001)
        }
    }

    // Implements: FR-SET-82, FR-SET-83
    @MainActor func testForcedStyleSurvivesProgramRequestsAndRestoresCurrentProgramStyleWhenRemoved() async throws {
        let view = makeView()
        let caret = try XCTUnwrap(view.caretView)
        view.forcedCursorStyle = .steadyUnderline
        XCTAssertEqual(caret.style.tagName, "steadyUnderline")
        view.feed(text: "\u{1b}[6 q")
        let deadline = Date().addingTimeInterval(2)
        while view.terminalStateSnapshot().cursorStyle.tagName != "steadyBar", Date() < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(view.terminalStateSnapshot().cursorStyle.tagName, "steadyBar")
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(caret.style.tagName, "steadyUnderline")
        view.forcedCursorStyle = nil
        XCTAssertEqual(caret.style.tagName, "steadyBar")
    }

    // Implements: FR-SET-80, FR-SET-81
    @MainActor func testMetalCursorTimerUsesCustomIntervalAndKeepsResetBehavior() {
        let redraws = Locked(0)
        let state = MetalRedrawState()
        state.configure { redraws.withLock { $0 += 1 } }
        let controller = MetalCursorBlinkController(redrawState: state)
        _ = state.setCursorBlinkWanted(true)
        controller.apply(shouldBlink: true, interval: 0.05)
        XCTAssertTrue(controller.isRunning)
        RunLoop.current.run(until: Date().addingTimeInterval(0.14))
        XCTAssertGreaterThan(redraws.withLock { $0 }, 0)
        let beforeReset = redraws.withLock { $0 }
        controller.resetAfterInput()
        XCTAssertTrue(state.cursorBlinkOn)
        XCTAssertTrue(controller.isRunning)
        XCTAssertEqual(redraws.withLock { $0 }, beforeReset + 1)
        _ = state.setCursorBlinkWanted(false)
        controller.apply(shouldBlink: false, interval: 0.05)
        XCTAssertFalse(controller.isRunning)
    }

    @MainActor private func makeView() -> TerminalView {
        _ = NSApplication.shared
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
        view.caretViewTracksFocus = false
        return view
    }

    @MainActor private func animation(_ caret: CaretView) throws -> CABasicAnimation {
        try XCTUnwrap(caret.layer?.animation(forKey: #keyPath(CALayer.opacity)) as? CABasicAnimation)
    }
}
#endif
