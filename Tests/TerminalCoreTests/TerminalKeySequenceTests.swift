import XCTest
@testable import TerminalCore

final class TerminalKeySequenceTests: XCTestCase {
    // Implements: FR-SET-84
    func testPrefixShowsOnlyFollowingCommandsAndCompletionDispatchesTheExactAction() throws {
        let map = try TerminalKeySequenceMap(overrides: [
            ActionID.newTab.rawValue: ["ctrl+x,ctrl+t"],
            ActionID.splitRight.rawValue: ["ctrl+x,ctrl+d"]
        ])
        var tracker = TerminalKeySequenceTracker()
        let expected = map.hints(after: ["ctrl+x"])
        XCTAssertEqual(Set(expected.map(\.binding)), Set(["ctrl+t", "ctrl+d"]))
        XCTAssertEqual(Set(expected.map(\.action)), Set([.newTab, .splitRight]))
        XCTAssertTrue(expected.allSatisfy { !$0.title.isEmpty })
        XCTAssertEqual(tracker.consume("ctrl+x", map: map, showHints: true, now: 1), .pending(expected))
        XCTAssertEqual(tracker.prefix, ["ctrl+x"])
        XCTAssertEqual(tracker.consume("ctrl+d", map: map, showHints: true, now: 1.1), .action(.splitRight))
        XCTAssertTrue(tracker.prefix.isEmpty)
        XCTAssertNil(map.singles.action(for: "cmd+t"))
    }

    // Implements: FR-SET-84
    func testDisablingHintsKeepsTheSequenceUsableWithoutAVisibleHintList() throws {
        let map = try TerminalKeySequenceMap(overrides: [ActionID.newTab.rawValue: ["ctrl+x,ctrl+t"]])
        var tracker = TerminalKeySequenceTracker()
        XCTAssertEqual(tracker.consume("ctrl+x", map: map, showHints: false, now: 1), .pending([]))
        XCTAssertEqual(tracker.consume("ctrl+t", map: map, showHints: false, now: 1.2), .action(.newTab))
    }

    // Implements: FR-SET-84
    func testEscapeInvalidContinuationAndTimeoutClearPendingState() throws {
        let map = try TerminalKeySequenceMap(overrides: [ActionID.newTab.rawValue: ["ctrl+x,ctrl+t"]])
        var tracker = TerminalKeySequenceTracker()
        _ = tracker.consume("ctrl+x", map: map, showHints: true, now: 1)
        XCTAssertEqual(tracker.consume("escape", map: map, showHints: true, now: 1.1), .cancelled)
        XCTAssertTrue(tracker.prefix.isEmpty)
        _ = tracker.consume("ctrl+x", map: map, showHints: true, now: 2)
        XCTAssertEqual(tracker.consume("ctrl+j", map: map, showHints: true, now: 2.1), .cancelled)
        _ = tracker.consume("ctrl+x", map: map, showHints: true, now: 3)
        XCTAssertEqual(tracker.consume("ctrl+t", map: map, showHints: true, now: 6), .unhandled)
        XCTAssertTrue(tracker.prefix.isEmpty)
    }

    // Implements: FR-SET-84
    func testCompositionAndOwnerLossNeverCaptureTextAsAContinuation() throws {
        let map = try TerminalKeySequenceMap(overrides: [ActionID.newTab.rawValue: ["ctrl+x,ctrl+t"]])
        var tracker = TerminalKeySequenceTracker()
        _ = tracker.consume("ctrl+x", map: map, showHints: true, now: 1)
        XCTAssertEqual(tracker.consume("ctrl+t", map: map, showHints: true, now: 1.1, composing: true), .unhandled)
        XCTAssertTrue(tracker.prefix.isEmpty)
        _ = tracker.consume("ctrl+x", map: map, showHints: true, now: 2)
        tracker.cancel()
        XCTAssertTrue(tracker.prefix.isEmpty)
        XCTAssertEqual(tracker.consume("ctrl+t", map: map, showHints: true, now: 2.1), .unhandled)
    }

    // Implements: FR-SET-84
    func testSequencesRejectAmbiguousPrefixesReservedStrokesAndDuplicateActions() {
        for overrides in [
            [ActionID.newTab.rawValue: ["cmd+k,ctrl+t"]],
            [ActionID.newTab.rawValue: ["cmd+q,ctrl+t"]],
            [ActionID.newTab.rawValue: ["ctrl+x,ctrl+t"], ActionID.splitRight.rawValue: ["CTRL+x,CTRL+t"]],
            [ActionID.newTab.rawValue: ["ctrl+x,ctrl+t"], ActionID.splitRight.rawValue: ["ctrl+x,ctrl+t,ctrl+d"]],
            [ActionID.newTab.rawValue: ["ctrl+x,t"]]
        ] { XCTAssertThrowsError(try TerminalKeySequenceMap(overrides: overrides)) }
    }

    // Implements: FR-SET-84
    func testUnconfiguredSingleShortcutsRetainTheirExistingActions() throws {
        let map = try TerminalKeySequenceMap()
        XCTAssertEqual(map.singles.action(for: "cmd+t"), .newTab)
        XCTAssertFalse(map.hasPrefix(["ctrl+x"]))
        var tracker = TerminalKeySequenceTracker()
        XCTAssertEqual(tracker.consume("cmd+t", map: map, showHints: true, now: 1), .unhandled)
    }
}
