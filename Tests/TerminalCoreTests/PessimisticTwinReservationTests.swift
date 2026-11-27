import XCTest
@testable import TerminalCore

final class PessimisticTwinReservationTests: XCTestCase {
    // Implements: FR-TWIN-8, FR-TWIN-9
    func testLiveAndArchivedTwinPanesAreNeverRestoredAsOriginalResumes() throws {
        let pane = UUID().uuidString.lowercased()
        let reservation = RuntimeDetachedPaneReservations(supervisor: .absent, unisession: .known([]), twinPaneIDs: [pane])
        XCTAssertFalse(reservation.permitsDetachedStartupReuse(pane))
        XCTAssertFalse(reservation.permitsGenericRecovery(pane, attachedPaneIDs: [pane]))
        XCTAssertTrue(reservation.permitsGenericRecovery("ordinary", attachedPaneIDs: []))
        XCTAssertEqual(try reservation.reservedPaneIDs(), [pane])
        XCTAssertNoThrow(try reservation.requireOrdinaryPane(pane, attachedPaneIDs: [pane]))
    }
    func testUnreadableTwinOwnershipDisablesGenericStartupReuseAndRecovery() {
        let reservation = RuntimeDetachedPaneReservations(supervisor: .absent, unisession: .known([]), twinPaneIDs: nil)
        XCTAssertFalse(reservation.permitsDetachedStartupReuse("pane"))
        XCTAssertFalse(reservation.permitsGenericRecovery("pane", attachedPaneIDs: ["pane"]))
        XCTAssertThrowsError(try reservation.reservedPaneIDs())
    }
}
