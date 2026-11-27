import Foundation
import XCTest
@testable import TerminalCore

final class SupervisorNavigationTests: XCTestCase {
    // Implements: FR-SUP-1, FR-SUP-5
    func testReservedSupervisorRoutesToItsPanelWithoutAdoptingItAsAnOrdinaryTab() {
        let pane = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try SupervisorNavigationGuard.requireOrdinaryPane(pane, reservation: .bound(pane), attachedPaneIDs: [])) {
            guard case .requiresPanel(let routed)? = $0 as? SupervisorNavigationError else { return XCTFail("Wrong routing error") }
            XCTAssertEqual(routed, pane)
        }
        XCTAssertThrowsError(try SupervisorNavigationGuard.requireOrdinaryPane(pane, reservation: .bound(pane), attachedPaneIDs: [pane]))
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testOrdinaryPaneNavigationRemainsAvailableWithKnownReservation() {
        let own = UUID().uuidString.lowercased(), peer = UUID().uuidString.lowercased()
        XCTAssertNoThrow(try SupervisorNavigationGuard.requireOrdinaryPane(peer, reservation: .bound(own), attachedPaneIDs: []))
        XCTAssertNoThrow(try SupervisorNavigationGuard.requireOrdinaryPane(peer, reservation: .absent, attachedPaneIDs: []))
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testUnsafeReservationAllowsExistingWorkspacePanesButRefusesDetachedAdoption() {
        let attached = UUID().uuidString.lowercased(), detached = UUID().uuidString.lowercased()
        XCTAssertNoThrow(try SupervisorNavigationGuard.requireOrdinaryPane(attached, reservation: .unavailable, attachedPaneIDs: [attached]))
        XCTAssertThrowsError(try SupervisorNavigationGuard.requireOrdinaryPane(detached, reservation: .unavailable, attachedPaneIDs: [attached]))
    }
}
