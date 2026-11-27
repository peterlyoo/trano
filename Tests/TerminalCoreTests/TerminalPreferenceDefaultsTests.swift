import XCTest
@testable import TerminalCore

final class TerminalPreferenceDefaultsTests: XCTestCase {
    // Implements: FR-SET-86
    func testNewPixelScrollingRemainsOptInForExistingWholeLineBehavior() {
        XCTAssertFalse(TerminalPreferences().smoothScrolling)
        XCTAssertFalse(TerminalPreferences().resolved(legacy: TerminalSettings()).smoothScrolling)
    }
}
