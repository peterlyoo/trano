import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class TerminalContextMenuUnitTests: XCTestCase {
    // Implements: U09, FR-NAV-4
    @MainActor func testNativeContextActionsHaveStableTargetsAndRevalidateOwnership() throws {
        _ = NSApplication.shared
        var valid = true
        var delivered: [TerminalContextCommand] = []
        let menu = TerminalContextMenu.make(hasSelection: true, canPaste: true, canAct: { valid }, perform: { delivered.append($0) })
        let actions: [(String, TerminalContextCommand)] = [("terminal-zoom", .action(.zoom)), ("terminal-close", .action(.closePane)), ("terminal-reset-font", .action(.resetFont)), ("terminal-reset", .reset)]
        for (id, command) in actions {
            let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == id })
            XCTAssertTrue(item.isEnabled)
            XCTAssertTrue(item.target === item)
            _ = item.target?.perform(item.action, with: item)
            XCTAssertEqual(delivered.last, command)
        }
        valid = false
        let before = delivered
        for item in menu.items where item.action != nil { _ = item.target?.perform(item.action, with: item) }
        XCTAssertEqual(delivered, before)
        XCTAssertNil(menu.items.first { $0.identifier?.rawValue == "terminal-clear" })
    }
    // Implements: U09, FR-NAV-4
    @MainActor func testUnsupportedExternalActionsAndUnavailableClipboardRowsAreDisabled() throws {
        _ = NSApplication.shared
        var supported = true
        var invoked = 0
        let menu = TerminalContextMenu.make(hasSelection: false, canPaste: false,
            supports: { command in if case .action(.zoom) = command { return false }; return supported },
            canAct: { true }, perform: { _ in invoked += 1 })
        for id in ["terminal-copy", "terminal-paste", "terminal-zoom"] {
            XCTAssertFalse(try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == id }).isEnabled)
        }
        let reset = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "terminal-reset" })
        supported = false
        _ = reset.target?.perform(reset.action, with: reset)
        XCTAssertEqual(invoked, 0)
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "terminal-increase-font" }?.title, "Zoom In")
        XCTAssertEqual(menu.items.first { $0.identifier?.rawValue == "terminal-decrease-font" }?.title, "Zoom Out")
    }
    // Implements: U02
    func testHistoryWheelAccumulatorPreservesFractionsAndBoundsUntrustedDeltas() {
        var wheel = TerminalHistoryWheelAccumulator()
        XCTAssertEqual(wheel.take(delta: 3, precise: true, cellHeight: 10), 0)
        XCTAssertEqual(wheel.take(delta: 8, precise: true, cellHeight: 10), 1)
        XCTAssertEqual(wheel.take(delta: -2, precise: true, cellHeight: 10), 0)
        wheel.reset()
        XCTAssertEqual(wheel.take(delta: -10, precise: true, cellHeight: 10), -1)
        XCTAssertEqual(wheel.take(delta: 0.1, precise: false, cellHeight: 10), 1)
        XCTAssertEqual(wheel.take(delta: 1e200, precise: false, cellHeight: 10), 1000)
        XCTAssertEqual(wheel.take(delta: .infinity, precise: true, cellHeight: 10), 0)
        XCTAssertEqual(wheel.take(delta: .nan, precise: true, cellHeight: 10), 0)
    }
}
