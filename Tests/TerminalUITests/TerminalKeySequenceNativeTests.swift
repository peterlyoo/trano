import AppKit
import XCTest
import TerminalCore
@testable import TranoApp

@MainActor
final class TerminalKeySequenceNativeTests: XCTestCase {
    final class Clock {
        var now = 1.0
        var delays: [TimeInterval] = []
        var actions: [() -> Void] = []
        var cancelled: [Bool] = []
        func schedule(_ delay: TimeInterval, _ action: @escaping () -> Void) -> () -> Void {
            let index = actions.count
            delays.append(delay); actions.append(action); cancelled.append(false)
            return { self.cancelled[index] = true }
        }
    }
    final class State {
        var eligible = true
        var target: String? = "pane-A"
        var composing = false
        var dispatched: [ActionID] = []
        var hints: [TerminalKeySequenceHint] = []
    }
    func window() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: -14000, y: -14000, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        return window
    }
    func key(_ character: String, owner: NSWindow, code: UInt16 = 7, flags: NSEvent.ModifierFlags = .control) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: owner.windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false, keyCode: code))
    }
    func controller(_ owner: NSWindow, state: State, clock: Clock, bindings: [String: [String]]? = nil) throws -> TerminalKeySequenceController {
        try TerminalKeySequenceController(owner: owner, overrides: bindings ?? [ActionID.newTab.rawValue: ["ctrl+x,ctrl+t"], ActionID.splitRight.rawValue: ["ctrl+x,ctrl+d"]], schedule: clock.schedule, now: { clock.now }, eligible: { state.eligible }, composing: { state.composing }, target: { state.target }, onHints: { state.hints = $0 }, dispatch: { state.dispatched.append($0) })
    }

    // Implements: FR-SET-84
    func testRealNativeEventsShowFollowingHintsAndDispatchExactAction() throws {
        let owner = window(); defer { owner.close() }
        let state = State(), clock = Clock()
        let controller = try controller(owner, state: state, clock: clock)
        XCTAssertTrue(controller.handle(try key("x", owner: owner), showHints: true))
        XCTAssertEqual(Set(state.hints.map(\.binding)), ["ctrl+t", "ctrl+d"])
        XCTAssertEqual(clock.delays, [1.5])
        XCTAssertTrue(controller.handle(try key("t", owner: owner, code: 17), showHints: true))
        XCTAssertEqual(state.dispatched, [.newTab])
        XCTAssertTrue(state.hints.isEmpty)
        XCTAssertTrue(controller.hints.isEmpty)
    }

    // Implements: FR-SET-84
    func testDisablingHintsPreservesSequenceAndRevalidatesBeforeDispatch() throws {
        let owner = window(); defer { owner.close() }
        let state = State(), clock = Clock()
        let controller = try controller(owner, state: state, clock: clock)
        XCTAssertTrue(controller.handle(try key("x", owner: owner), showHints: false))
        XCTAssertTrue(state.hints.isEmpty)
        XCTAssertTrue(controller.handle(try key("d", owner: owner, code: 2), showHints: false))
        XCTAssertEqual(state.dispatched, [.splitRight])
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        state.eligible = false
        XCTAssertFalse(controller.handle(try key("t", owner: owner, code: 17), showHints: true))
        XCTAssertEqual(state.dispatched, [.splitRight])
        XCTAssertTrue(state.hints.isEmpty)
    }

    // Implements: FR-SET-84
    func testWrongWindowMouseEscapeCompositionAndFocusLossCancel() throws {
        let owner = window(), other = window(); defer { owner.close(); other.close() }
        let state = State(), clock = Clock()
        let controller = try controller(owner, state: state, clock: clock)
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        XCTAssertFalse(controller.handle(try key("t", owner: other, code: 17), showHints: true))
        XCTAssertTrue(state.hints.isEmpty)
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        XCTAssertTrue(controller.handle(try key("\u{1b}", owner: owner, code: 53, flags: []), showHints: true))
        XCTAssertTrue(state.hints.isEmpty)
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        let mouse = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 1, windowNumber: owner.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertFalse(controller.handle(mouse, showHints: true))
        XCTAssertTrue(state.hints.isEmpty)
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        state.composing = true
        XCTAssertFalse(controller.handle(try key("t", owner: owner, code: 17), showHints: true))
        XCTAssertTrue(state.hints.isEmpty)
        state.composing = false
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: owner)
        XCTAssertTrue(state.hints.isEmpty)
        XCTAssertTrue(state.dispatched.isEmpty)
    }

    // Implements: FR-SET-84
    func testTimeoutAndHotReloadInvalidateStalePrefixesAndCallbacks() throws {
        let owner = window(); defer { owner.close() }
        let state = State(), clock = Clock()
        let controller = try controller(owner, state: state, clock: clock)
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        let stale = try XCTUnwrap(clock.actions.first)
        try controller.reload(overrides: [ActionID.splitDown.rawValue: ["ctrl+a,ctrl+d"]])
        XCTAssertTrue(state.hints.isEmpty)
        XCTAssertFalse(controller.handle(try key("t", owner: owner, code: 17), showHints: true))
        _ = controller.handle(try key("a", owner: owner, code: 0), showHints: true)
        stale()
        XCTAssertFalse(state.hints.isEmpty)
        try XCTUnwrap(clock.actions.last)()
        XCTAssertTrue(state.hints.isEmpty)
        XCTAssertFalse(controller.handle(try key("d", owner: owner, code: 2), showHints: true))
        XCTAssertTrue(state.dispatched.isEmpty)
    }

    // Implements: FR-SET-84
    func testModalAndUnmodifiedTextCancelWithoutCapturingNormalInput() throws {
        let owner = window(); defer { owner.close() }
        let state = State(), clock = Clock()
        let controller = try controller(owner, state: state, clock: clock)
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        NotificationCenter.default.post(name: NSWindow.willBeginSheetNotification, object: owner)
        XCTAssertTrue(state.hints.isEmpty)
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        XCTAssertFalse(controller.handle(try key("a", owner: owner, flags: []), showHints: true))
        XCTAssertTrue(state.hints.isEmpty)
        let empty = try self.controller(owner, state: state, clock: clock, bindings: [:])
        XCTAssertFalse(empty.handle(try key("t", owner: owner, code: 17, flags: .command), showHints: true))
        XCTAssertTrue(state.dispatched.isEmpty)
    }

    // Implements: FR-SET-84
    func testFailedReloadCancelsPendingPrefixAndCommaMenuShortcutStillExists() throws {
        let owner = window(); defer { owner.close() }
        let state = State(), clock = Clock()
        let controller = try controller(owner, state: state, clock: clock)
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        XCTAssertThrowsError(try controller.reload(overrides: [ActionID.newTab.rawValue: ["cmd+q,ctrl+t"]]))
        XCTAssertTrue(state.hints.isEmpty)
        XCTAssertFalse(controller.handle(try key("t", owner: owner, code: 17), showHints: true))
        XCTAssertTrue(state.dispatched.isEmpty)
        XCTAssertEqual(NativeKeyBinding.menuEquivalent("cmd+,").0, ",")
        XCTAssertEqual(NativeKeyBinding.menuEquivalent("cmd+,").1, .command)
    }

    // Implements: FR-SET-84
    func testResponderChangeInsideOwnerCancelsPendingSequence() throws {
        let owner = window(); defer { owner.close() }
        let editor = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        owner.contentView?.addSubview(editor)
        let state = State(), clock = Clock()
        let controller = try controller(owner, state: state, clock: clock)
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        XCTAssertTrue(owner.makeFirstResponder(editor))
        controller.refreshEligibility()
        XCTAssertTrue(state.hints.isEmpty)
        XCTAssertFalse(controller.handle(try key("t", owner: owner, code: 17), showHints: true))
        XCTAssertTrue(state.dispatched.isEmpty)
    }

    // Implements: FR-SET-84
    func testLogicalPaneChangeWithSameResponderCancelsBeforeOldSuffix() throws {
        let owner = window(); defer { owner.close() }
        let responder = owner.firstResponder
        let state = State(), clock = Clock()
        let controller = try controller(owner, state: state, clock: clock, bindings: [ActionID.closePane.rawValue: ["ctrl+x,ctrl+w"]])
        XCTAssertTrue(controller.handle(try key("x", owner: owner), showHints: true))
        state.target = "pane-B"
        XCTAssertTrue(owner.firstResponder === responder)
        controller.refreshEligibility()
        XCTAssertTrue(state.hints.isEmpty)
        XCTAssertFalse(controller.handle(try key("w", owner: owner, code: 13), showHints: true))
        state.target = "pane-A"
        XCTAssertFalse(controller.handle(try key("w", owner: owner, code: 13), showHints: true))
        XCTAssertTrue(state.dispatched.isEmpty)
        XCTAssertTrue(controller.handle(try key("x", owner: owner), showHints: true))
        XCTAssertTrue(controller.handle(try key("w", owner: owner, code: 13), showHints: true))
        XCTAssertEqual(state.dispatched, [.closePane])
    }

    // Implements: FR-SET-84
    func testLogicalPaneChangeIsCheckedOnSuffixWithoutRefreshOrVisibleHints() throws {
        let owner = window(); defer { owner.close() }
        let state = State(), clock = Clock()
        let controller = try controller(owner, state: state, clock: clock, bindings: [ActionID.closePane.rawValue: ["ctrl+x,ctrl+w"]])
        state.target = nil
        XCTAssertTrue(controller.handle(try key("x", owner: owner), showHints: false))
        state.target = "pane-B"
        XCTAssertFalse(controller.handle(try key("w", owner: owner, code: 13), showHints: false))
        XCTAssertTrue(state.dispatched.isEmpty)
        XCTAssertTrue(state.hints.isEmpty)
    }

    // Implements: FR-SET-84
    func testHintPresentationTargetChangeCancelsPrefixBeforeSchedulingTimeout() throws {
        let owner = window(); defer { owner.close() }
        let state = State(), clock = Clock()
        let controller = try TerminalKeySequenceController(owner: owner, overrides: [ActionID.closePane.rawValue: ["ctrl+x,ctrl+w"]], schedule: clock.schedule,
            now: { clock.now }, eligible: { state.eligible }, composing: { state.composing }, target: { state.target },
            onHints: { hints in state.hints = hints; if !hints.isEmpty { state.target = "pane-B" } },
            dispatch: { state.dispatched.append($0) })
        _ = controller.handle(try key("x", owner: owner), showHints: true)
        XCTAssertTrue(state.hints.isEmpty)
        XCTAssertTrue(clock.actions.isEmpty)
        XCTAssertFalse(controller.handle(try key("w", owner: owner, code: 13), showHints: true))
        XCTAssertTrue(state.dispatched.isEmpty)
    }

    // Implements: FR-SET-84
    func testHintDismissalCannotRetargetCompletedDestructiveAction() throws {
        let owner = window(); defer { owner.close() }
        let state = State(), clock = Clock()
        let controller = try TerminalKeySequenceController(owner: owner, overrides: [ActionID.closePane.rawValue: ["ctrl+x,ctrl+w"]], schedule: clock.schedule,
            now: { clock.now }, eligible: { state.eligible }, composing: { state.composing }, target: { state.target },
            onHints: { hints in state.hints = hints; if hints.isEmpty { state.target = "pane-B" } },
            dispatch: { state.dispatched.append($0) })
        XCTAssertTrue(controller.handle(try key("x", owner: owner), showHints: true))
        XCTAssertFalse(controller.handle(try key("w", owner: owner, code: 13), showHints: true))
        XCTAssertTrue(state.dispatched.isEmpty)
        XCTAssertTrue(state.hints.isEmpty)
    }

    // Implements: FR-SET-84
    func testOverlayIsTemporaryBoundedToItsOwnerAndNeverInterceptsInput() throws {
        let owner = window(), other = window(); defer { owner.close(); other.close() }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 300))
        let host = NSView(frame: NSRect(x: 20, y: 20, width: 260, height: 160))
        root.addSubview(host); owner.contentView = root
        let original = host.frame
        let overlay = TerminalKeySequenceOverlay(owner: owner)
        let hints = [TerminalKeySequenceHint(binding: "ctrl+t", title: "New Tab", action: .newTab)]
        overlay.present(hints, in: host, bounds: NSRect(x: -30, y: -30, width: 600, height: 600))
        XCTAssertTrue(overlay.superview === host)
        XCTAssertTrue(host.bounds.contains(overlay.frame))
        XCTAssertNil(overlay.hitTest(NSPoint(x: 10, y: 10)))
        XCTAssertEqual(host.frame, original)
        XCTAssertTrue(overlay.subviews.compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("New Tab") })
        overlay.present(Array(repeating: hints[0], count: 4), in: host, bounds: host.bounds)
        host.setFrameSize(NSSize(width: 120, height: 80))
        XCTAssertTrue(host.bounds.contains(overlay.frame))
        let firstLabel = try XCTUnwrap(overlay.subviews.first as? NSTextField)
        XCTAssertTrue(overlay.bounds.contains(firstLabel.frame))
        overlay.dismiss()
        XCTAssertNil(overlay.superview)
        let foreign = NSView(frame: host.frame); other.contentView = foreign
        overlay.present(hints, in: foreign, bounds: foreign.bounds)
        XCTAssertNil(overlay.superview)
    }

    // Implements: FR-SET-84
    func testRecorderCapturesTwoAndThreeStrokesAndDefaultSingleStillWorks() throws {
        let owner = window(); defer { owner.close() }
        let button = ShortcutButton()
        var values: [String] = []
        button.onChange = { values.append($0) }
        button.mode = .sequence(length: 2)
        button.beginRecording()
        button.capture(try key("x", owner: owner))
        XCTAssertTrue(button.recording)
        XCTAssertTrue(values.isEmpty)
        button.capture(try key("t", owner: owner, code: 17))
        XCTAssertEqual(values, ["ctrl+x,ctrl+t"])
        XCTAssertFalse(button.recording)
        button.mode = .sequence(length: 3)
        button.beginRecording()
        for (character, code) in [("x", UInt16(7)), ("d", 2), ("t", 17)] { button.capture(try key(character, owner: owner, code: code)) }
        XCTAssertEqual(values.last, "ctrl+x,ctrl+d,ctrl+t")
        button.mode = .single
        button.beginRecording()
        button.capture(try key("p", owner: owner, code: 35, flags: [.command, .shift]))
        XCTAssertEqual(values.last, "cmd+shift+p")
    }

    // Implements: FR-SET-84
    func testRecorderEscapeAndFocusLossNeverCommitPartialSequence() throws {
        let owner = window(); defer { owner.close() }
        let button = ShortcutButton()
        var values: [String] = []
        button.onChange = { values.append($0) }
        button.mode = .sequence(length: 2)
        button.beginRecording(); button.capture(try key("x", owner: owner))
        button.capture(try key("\u{1b}", owner: owner, code: 53, flags: []))
        XCTAssertFalse(button.recording)
        XCTAssertTrue(values.isEmpty)
        button.beginRecording(); button.capture(try key("x", owner: owner))
        _ = button.resignFirstResponder()
        XCTAssertFalse(button.recording)
        XCTAssertTrue(values.isEmpty)
        XCTAssertEqual(NativeKeyBinding.menuEquivalent("ctrl+x,ctrl+t").0, "")
    }
}
