import AppKit
import XCTest
@testable import SwiftTerm

@MainActor final class QuickLookVendorLinkTests: XCTestCase {
    // Implements: FR-SET-104
    func testImplicitWebLinkAfterHangulAndWideGlyphsUsesNativeGrid() {
        let view = makeView()
        view.feed(text: "한글🙂 https://example.com/docs\r\n")
        XCTAssertEqual(view.link(atViewPoint: point(column: 9, row: 0, in: view)), "https://example.com/docs")
        XCTAssertNil(view.link(atViewPoint: point(column: 1, row: 0, in: view)))
    }

    // Implements: FR-SET-104
    func testOSC8TargetComesFromLinkedWideLabelRatherThanVisibleText() {
        let view = makeView()
        view.feed(text: "가🙂 \u{1B}]8;;https://example.com/agent?q=1\u{1B}\\한국 문서\u{1B}]8;;\u{1B}\\ 끝")
        XCTAssertEqual(view.link(atViewPoint: point(column: 5, row: 0, in: view)), "https://example.com/agent?q=1")
        XCTAssertEqual(view.link(atViewPoint: point(column: 6, row: 0, in: view)), "https://example.com/agent?q=1")
        XCTAssertNil(view.link(atViewPoint: point(column: 1, row: 0, in: view)))
    }

    // Implements: FR-SET-104
    func testOutsideNonfiniteAndBlankPointsCannotClampIntoAnExistingLink() {
        let view = makeView()
        view.feed(text: "https://example.com")
        for point in [NSPoint(x: -1, y: view.bounds.midY), NSPoint(x: view.bounds.maxX, y: view.bounds.midY),
                      NSPoint(x: 5, y: -1), NSPoint(x: 5, y: view.bounds.maxY),
                      NSPoint(x: CGFloat.nan, y: 20), NSPoint(x: 10, y: CGFloat.infinity)] {
            XCTAssertNil(view.link(atViewPoint: point))
        }
        XCTAssertNil(view.link(atViewPoint: point(column: 50, row: 2, in: view)))
        XCTAssertEqual(view.link(atViewPoint: point(column: 2, row: 0, in: view)), "https://example.com")
    }

    private func makeView() -> TerminalView {
        let view = TerminalView(frame: NSRect(x: 0, y: 0, width: 1000, height: 240),
            font: .monospacedSystemFont(ofSize: 14, weight: .regular),
            options: TerminalOptions(cols: 100, rows: 10, scrollback: 20))
        view.frameDriver.invalidate()
        return view
    }
    private func point(column: Int, row: Int, in view: TerminalView) -> NSPoint {
        NSPoint(x: (CGFloat(column) + 0.5) * view.cellDimension.width,
                y: view.bounds.maxY - (CGFloat(row) + 0.5) * view.cellDimension.height)
    }
}
