import AppKit
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class SupervisorSessionNavigationTests: XCTestCase {
    // Implements: FR-SUP-6
    func testClosedWorkspaceReopensExactTabAndLeavesQuietWindowSelectionIndependent() throws {
        var f = fixture()
        let originalWorkspace = try XCTUnwrap(f.state.layout.selectedWorkspaceID)
        let originalTab = try XCTUnwrap(f.state.layout.selectedTabID)
        let quietWorkspace = f.state.layout.addWorkspace(title: "quiet-window")
        f.state.layout.addTab(paneID: "quiet-pane")
        var quiet = WindowSelection()
        _ = quiet.resolve(f.state, ownAction: true, acceptsRequests: false)
        f.state.layout.closeWorkspace(originalWorkspace)
        let beforeSessions = f.state.sessions
        let request = NavigationRequest(workspaceID: quietWorkspace, tabID: f.state.layout.selectedTabID, paneID: "quiet-pane")
        f.state.navigationRequest = request
        let next = try SupervisorSessionNavigation.open(f.target, workspaceID: quietWorkspace, state: f.state, sessions: f.state.sessions)
        XCTAssertEqual(next.layout.selectedWorkspaceID, originalWorkspace)
        XCTAssertEqual(next.layout.selectedTabID, originalTab)
        XCTAssertEqual(next.layout.focusedPaneID, f.target.paneID)
        XCTAssertEqual(next.sessions, beforeSessions)
        XCTAssertEqual(next.navigationRequest?.id, request.id)
        let mirrored = quiet.resolve(next, ownAction: false, acceptsRequests: true)
        XCTAssertEqual(mirrored.layout.selectedWorkspaceID, quietWorkspace)
        XCTAssertEqual(mirrored.layout.focusedPaneID, "quiet-pane")
    }

    // Implements: FR-SUP-6
    func testClosedSplitPaneRestoresOriginalPlacementWithoutStealingForeignPane() throws {
        var f = fixture()
        let tabID = try XCTUnwrap(f.state.layout.selectedTabID)
        try f.state.layout.split(tabID: tabID, paneID: "sibling-pane", axis: .horizontal)
        let original = try XCTUnwrap(f.state.layout.tabs.first)
        f.state.layout.closePane(f.target.paneID)
        let restored = try SupervisorSessionNavigation.open(f.target, workspaceID: f.state.layout.selectedWorkspaceID, state: f.state, sessions: f.state.sessions)
        XCTAssertEqual(restored.layout.selectedTabID, tabID)
        XCTAssertEqual(restored.layout.tabs.first?.tree, original.tree)
        XCTAssertEqual(restored.layout.focusedPaneID, f.target.paneID)
    }

    // Implements: FR-SUP-6
    func testDetachedLivePaneGetsOnlyAViewAndKeepsExistingBackendAndLaunch() throws {
        var f = fixture()
        f.state.layout = WorkspaceLayout()
        let next = try SupervisorSessionNavigation.open(f.target, workspaceID: nil, state: f.state, sessions: f.state.sessions)
        XCTAssertEqual(next.sessions, f.state.sessions)
        XCTAssertEqual(next.agentLaunches.map(\.id), f.state.agentLaunches.map(\.id))
        XCTAssertEqual(next.layout.currentTabs.flatMap(\.panes), [f.target.paneID])
        XCTAssertEqual(next.layout.workspaces.count, 1)
        XCTAssertNotNil(next.layout.workspaces.first?.title.range(of: "^[a-z]+-[a-z]+(?:-[0-9]+)?$", options: .regularExpression))
    }

    // Implements: FR-SUP-6, FR-SUP-7
    func testChangedGenerationBackendProviderConversationOrRootRefusesBeforeLayoutChanges() throws {
        let f = fixture()
        for mutation in 0..<5 {
            var state = f.state
            state.layout.closeTab(state.layout.selectedTabID!)
            switch mutation {
            case 0: state.agentLaunches[0].id = UUID().uuidString.lowercased()
            case 1: state.sessions[0].pid += 1
            case 2: state.agentLaunches[0].providerPID = 99
            case 3: state.agentLaunches[0].providerSessionID = UUID().uuidString.lowercased()
            default: state.agentLaunches[0].cwd = "/changed-project"
            }
            let before = state.layout
            XCTAssertThrowsError(try SupervisorSessionNavigation.open(f.target, workspaceID: nil, state: state, sessions: state.sessions))
            XCTAssertEqual(state.layout, before)
        }
    }

    private struct Fixture { var state: RuntimeState; let target: SupervisorContinuationIdentity }
    private func fixture() -> Fixture {
        let pane = UUID().uuidString.lowercased(), generation = UUID().uuidString.lowercased(), conversation = UUID().uuidString.lowercased()
        let target = SupervisorContinuationIdentity(paneID: pane, backendPID: 4711,
            backendIdentity: SupervisorProcessIdentity(pid: 4711, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1),
            generation: generation, provider: .claude, providerPID: 4712,
            providerIdentity: SupervisorProcessIdentity(pid: 4712, ownerUID: getuid(), startedAtSeconds: 2, startedAtMicroseconds: 1),
            providerSessionID: conversation, configurationRoot: "/fixture/profile", cwd: "/fixture/project", providerExecutable: "/fixture/claude")
        var state = RuntimeState()
        state.sessions = [TerminalSession(id: pane, title: "Retained", cwd: target.cwd, pid: target.backendPID)]
        var launch = AgentLaunch(paneID: pane, provider: target.provider, providerSessionID: conversation,
            cwd: target.cwd, accountID: nil, configurationRoot: target.configurationRoot, bootID: "fixture", processID: 4700, providerPID: 4712)
        launch.id = generation
        state.agentLaunches = [launch]
        state.layout.addWorkspace(title: "original-workspace")
        state.layout.addTab(paneID: pane)
        return Fixture(state: state, target: target)
    }
}
