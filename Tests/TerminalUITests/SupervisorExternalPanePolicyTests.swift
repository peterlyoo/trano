import Foundation
import Darwin
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class SupervisorExternalPanePolicyTests: XCTestCase {
    // Implements: FR-SUP-1, FR-SUP-5
    func testOnlyTheBoundLocalPaneWithTheExactBackendPIDIsVisible() {
        let policy = SupervisorExternalPanePolicy(binding: binding())
        let own = session()
        var changedPID = own
        changedPID.pid += 1
        var remote = own
        remote.remote = RemoteReference(hostID: "remote-fixture", sessionID: own.id)
        var nonlocalHost = own
        nonlocalHost.host = "remote-fixture"
        var unrelated = own
        unrelated.id = "00000000-0000-4000-8000-000000000020"
        XCTAssertEqual(policy.sessions([unrelated, changedPID, remote, nonlocalHost, own]), [own])
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testAChangedBackendPIDProducesNoVisibleSession() {
        let policy = SupervisorExternalPanePolicy(binding: binding())
        var changedPID = session()
        changedPID.pid += 1
        XCTAssertTrue(policy.sessions([changedPID]).isEmpty)
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testProjectionClearsNormalNavigationAndLayoutWithoutChangingTheInputSnapshot() throws {
        let policy = SupervisorExternalPanePolicy(binding: binding())
        var snapshot = RuntimeState()
        let ordinaryPane = "00000000-0000-4000-8000-000000000020"
        let workspace = snapshot.layout.addWorkspace(title: "quiet-lake")
        let tab = snapshot.layout.addTab(paneID: ordinaryPane)
        snapshot.navigationRequest = NavigationRequest(workspaceID: workspace, tabID: tab, paneID: ordinaryPane)
        snapshot.sessions = [TerminalSession(id: ordinaryPane, title: "Ordinary", cwd: "/tmp/ordinary", pid: 7001), session()]
        snapshot.settings.fontName = "JetBrainsMono-Regular"
        snapshot.settings.fontSize = 18
        snapshot.accounts = [AccountProfile(provider: .claude, label: "Fixture account")]
        snapshot.revision = 42
        let before = try encoded(snapshot)

        var projected = policy.project(snapshot)
        XCTAssertEqual(projected.layout, WorkspaceLayout())
        XCTAssertNil(projected.navigationRequest)
        XCTAssertEqual(projected.sessions, [session()])
        XCTAssertEqual(projected.settings, snapshot.settings)
        XCTAssertEqual(projected.accounts, snapshot.accounts)
        XCTAssertEqual(projected.revision, 42)
        XCTAssertEqual(try encoded(snapshot), before)

        var normalSelection = WindowSelection()
        projected = normalSelection.resolve(projected, ownAction: true, acceptsRequests: true)
        XCTAssertNil(projected.layout.selectedWorkspaceID)
        XCTAssertNil(projected.layout.selectedTabID)
        XCTAssertNil(projected.layout.focusedPaneID)
        XCTAssertEqual(snapshot.layout.selectedWorkspaceID, workspace)
        XCTAssertEqual(snapshot.layout.selectedTabID, tab)
        XCTAssertEqual(snapshot.layout.focusedPaneID, ordinaryPane)
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testTheRoleOnlyRetainsItsBindingAndNeverClaimsWorkspaceOwnership() {
        var original = binding()
        let policy = SupervisorExternalPanePolicy(binding: original)
        original.stoppedAt = Date(timeIntervalSince1970: 2)
        XCTAssertFalse(policy.allowsWorkspaceOwnership)
        XCTAssertEqual(policy.retainedPaneIDs, [original.paneID])
        XCTAssertNil(policy.binding.stoppedAt)
        XCTAssertEqual(policy.binding.backendPID, original.backendPID)
    }

    // Implements: FR-SUP-1, FR-SUP-5
    func testStoppedPaneMetadataCanRemainVisibleWithoutGrantingWorkspaceOwnership() {
        var stoppedBinding = binding()
        stoppedBinding.stoppedAt = Date(timeIntervalSince1970: 2)
        let policy = SupervisorExternalPanePolicy(binding: stoppedBinding)
        var stoppedSession = session()
        stoppedSession.alive = false
        XCTAssertEqual(policy.sessions([stoppedSession]), [stoppedSession])
        XCTAssertFalse(policy.allowsWorkspaceOwnership)
        XCTAssertEqual(policy.retainedPaneIDs, [stoppedSession.id])
    }

    private func binding() -> SupervisorBinding {
        SupervisorBinding(paneID: "00000000-0000-4000-8000-000000000010", backendPID: 4711,
            configuration: SupervisorConfiguration(provider: .claude, cwd: "/tmp"),
            createdAt: Date(timeIntervalSince1970: 1), processIdentity: SupervisorProcessIdentity(
                pid: 4711, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1))
    }

    private func session() -> TerminalSession {
        let binding = binding()
        var session = TerminalSession(id: binding.paneID, title: "Supervisor", cwd: "/tmp", pid: binding.backendPID)
        session.createdAt = Date(timeIntervalSince1970: 1)
        session.activity.updatedAt = Date(timeIntervalSince1970: 1)
        return session
    }

    private func encoded(_ state: RuntimeState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(state)
    }
}
