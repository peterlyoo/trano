import XCTest
@testable import TerminalCore
@testable import TranoApp

final class WorktreeCleanupPresentationTests: XCTestCase {
    // Implements: FR-WT-5
    func testInterruptedOrUnownedStateDoesNotOfferRetryAndBranchesAreKept() {
        XCTAssertEqual(WorktreeCleanupPresentation.title(.removed), "Cleaned Up")
        XCTAssertEqual(WorktreeCleanupPresentation.title(.needsReview), "Review Needed")
        XCTAssertFalse(WorktreeCleanupPresentation.canRetry(status: .needsReview, completed: true, enabled: true))
        XCTAssertFalse(WorktreeCleanupPresentation.canRetry(status: .tracked, completed: false, enabled: true))
        XCTAssertTrue(WorktreeCleanupPresentation.canRetry(status: .held, completed: true, enabled: true))
        XCTAssertFalse(WorktreeCleanupPresentation.canRetry(status: .held, completed: true, enabled: false))
    }
}
