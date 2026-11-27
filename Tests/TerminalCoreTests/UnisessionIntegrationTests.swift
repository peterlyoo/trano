import Foundation
import XCTest
@testable import TerminalCore

final class UnisessionIntegrationTests: XCTestCase {
    // Implements: FR-UNI-1, FR-UNI-3, FR-UNI-6
    func testSharedNavigationUsesDistinctOverlayRouteBeforeLegacyOwnerAndPreservesUnknownFailure() {
        let reservations = RuntimeDetachedPaneReservations(supervisor: .bound("shared"), unisession: .known(["shared"]))
        XCTAssertThrowsError(try reservations.requireOrdinaryPane("shared", attachedPaneIDs: [])) { error in
            XCTAssertEqual(error as? UnisessionNavigationError, .requiresOverlay("shared"))
        }
        XCTAssertThrowsError(try DetachedPaneReservation.unavailable.requireOrdinaryPane("unknown", attachedPaneIDs: [])) { error in
            XCTAssertEqual(error as? UnisessionNavigationError, .unavailable)
        }
    }

    func testCombinedReservationsPreserveSupervisorAndEveryRetiredSharedPane() throws {
        let reservations = RuntimeDetachedPaneReservations(supervisor: .bound("legacy"), unisession: .known(["shared", "retired", "pending"]))
        for id in ["legacy", "shared", "retired", "pending"] {
            XCTAssertFalse(reservations.permitsDetachedStartupReuse(id))
            XCTAssertFalse(reservations.permitsGenericRecovery(id, attachedPaneIDs: []))
            XCTAssertThrowsError(try reservations.requireOrdinaryPane(id, attachedPaneIDs: []))
        }
        XCTAssertEqual(try reservations.reservedPaneIDs(), ["legacy", "shared", "retired", "pending"])
        XCTAssertTrue(reservations.permitsDetachedStartupReuse("ordinary"))
        XCTAssertNoThrow(try reservations.requireOrdinaryPane("ordinary", attachedPaneIDs: []))
    }

    func testAnyUnavailableOwnershipBlocksDetachedAdoptionButKeepsAttachedOrdinaryPanes() {
        for reservations in [RuntimeDetachedPaneReservations(supervisor: .unavailable, unisession: .known([])),
                             RuntimeDetachedPaneReservations(supervisor: .absent, unisession: .unavailable)] {
            XCTAssertThrowsError(try reservations.reservedPaneIDs())
            XCTAssertFalse(reservations.permitsDetachedStartupReuse("unknown"))
            XCTAssertFalse(reservations.permitsGenericRecovery("unknown", attachedPaneIDs: ["ordinary"]))
            XCTAssertTrue(reservations.permitsGenericRecovery("ordinary", attachedPaneIDs: ["ordinary"]))
            XCTAssertThrowsError(try reservations.requireOrdinaryPane("unknown", attachedPaneIDs: ["ordinary"]))
            XCTAssertNoThrow(try reservations.requireOrdinaryPane("ordinary", attachedPaneIDs: ["ordinary"]))
        }
    }

    func testPreReservedCreationIdentityIsExactAndRejectsCollisionOrRestoreOverride() throws {
        let reserved = UUID().uuidString.lowercased()
        XCTAssertEqual(try TerminalCreationIdentity.resolve(restoringID: nil, reservedID: reserved, existingPaneIDs: []), reserved)
        XCTAssertThrowsError(try TerminalCreationIdentity.resolve(restoringID: nil, reservedID: reserved, existingPaneIDs: [reserved]))
        XCTAssertThrowsError(try TerminalCreationIdentity.resolve(restoringID: reserved, reservedID: reserved, existingPaneIDs: []))
        XCTAssertThrowsError(try TerminalCreationIdentity.resolve(restoringID: nil, reservedID: "bad;id", existingPaneIDs: []))
        XCTAssertEqual(try TerminalCreationIdentity.resolve(restoringID: reserved, reservedID: nil, existingPaneIDs: [reserved]), reserved)
        XCTAssertNotNil(UUID(uuidString: try TerminalCreationIdentity.resolve(restoringID: nil, reservedID: nil, existingPaneIDs: [])))
    }

    func testLiveUnisessionConversationReturnsSharedOwnerWithoutWorkspaceOpenOrReplay() throws {
        let source = ConversationHistorySource(id: "source", provider: .codex, configurationRoot: "/tmp/provider", label: "Account")
        let sessionID = "33333333-3333-4333-8333-333333333333"
        let paneID = "44444444-4444-4444-8444-444444444444"
        let entry = AgentConversation(source: source, providerSessionID: sessionID, title: "Conversation", cwd: "/tmp/project", updatedAt: Date(), relativePath: "sessions/rollout-" + sessionID + ".jsonl")
        var state = RuntimeState()
        state.sessions = [TerminalSession(id: paneID, title: "Unisession", cwd: entry.cwd, pid: 123)]
        state.agentLaunches = [AgentLaunch(paneID: paneID, provider: .codex, providerSessionID: sessionID, cwd: entry.cwd, accountID: nil, configurationRoot: source.configurationRoot, bootID: "boot")]
        let context = ConversationResumeContext(state: state, livePaneIDs: [paneID], sources: [source], unisessionPaneID: paneID)
        var writes = 0
        let operations = ConversationResumeOperations(context: { context }, validate: { $0 }, create: { _ in
            writes += 1; throw TerminalError.invalid("Unexpected create")
        }, stage: { _, _, _ in writes += 1; throw TerminalError.invalid("Unexpected stage") }, launch: { _, _ in writes += 1 },
            open: { _ in writes += 1 }, rollback: { _ in writes += 1 })
        let outcome = try ConversationResumeCoordinator.resume(entry, workspaceID: nil, operations: operations)
        XCTAssertEqual(outcome.paneID, paneID)
        XCTAssertTrue(outcome.existing)
        XCTAssertTrue(outcome.unisession)
        XCTAssertFalse(outcome.supervisor)
        XCTAssertEqual(writes, 0)
    }
}
