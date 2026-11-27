import XCTest
@testable import TerminalCore

final class DecisionNavigationTests: XCTestCase {
    // Implements: FR-DECISION-5, FR-NAV-4
    func testDetachedDecisionPaneDoesNotRestoreAnotherPanesCloseSnapshot() throws {
        let f = try fixture()
        defer { dispose(f) }
        let closed = try f.runtime.create(title: "Closed sibling", cwd: f.root.path, shell: "/bin/sleep", arguments: ["90"])
        let anchor = try f.runtime.create(title: "Live anchor", cwd: f.root.path, shell: "/bin/sleep", arguments: ["90"])
        try f.runtime.update { state in
            try state.layout.selectTab(f.tab)
            try state.layout.split(tabID: f.tab, paneID: closed.id, axis: .horizontal)
            try state.layout.split(tabID: f.tab, paneID: anchor.id, axis: .vertical)
            state.layout.closePane(closed.id)
            state.layout.detach(f.pane)
            try state.layout.selectTab(f.otherTab)
        }
        let before = try f.runtime.list().map(\.pid)
        _ = try f.runtime.navigateToDecisionSession(f.requestID, generation: f.launch.id)
        let layout = try f.runtime.state().layout
        XCTAssertEqual(layout.focusedPaneID, f.pane)
        XCTAssertEqual(layout.tabs.first { $0.id == f.tab }?.panes, [anchor.id])
        XCTAssertFalse(layout.tabs.flatMap(\.panes).contains(closed.id))
        XCTAssertEqual(layout.closedTabs.last?.focusedPaneID, closed.id)
        XCTAssertEqual(try f.runtime.list().map(\.pid), before)
    }

    // Implements: FR-DECISION-5
    func testNavigatesToExactBoundPaneAcrossWorkspacesWithoutAnsweringOrStartingAProcess() throws {
        let f = try fixture()
        defer { dispose(f) }
        let pids = try f.runtime.list().map(\.pid)
        let before = try XCTUnwrap(try f.runtime.decisionInbox().first)
        XCTAssertEqual(try f.runtime.navigateToDecisionSession(f.requestID, generation: f.launch.id), f.pane)
        let state = try f.runtime.state()
        XCTAssertEqual(state.layout.selectedWorkspaceID, f.workspace)
        XCTAssertEqual(state.layout.selectedTabID, f.tab)
        XCTAssertEqual(state.layout.focusedPaneID, f.pane)
        XCTAssertEqual(try f.runtime.list().map(\.pid), pids)
        XCTAssertEqual(try f.runtime.decisionInbox().first, before)
        XCTAssertNotNil(try f.runtime.decisionGateReason(paneID: f.pane, generation: f.launch.id))
    }

    // Implements: FR-DECISION-5
    func testExplicitNavigationReopensClosedWorkspaceWithOriginalTabAndJobs() throws {
        let f = try fixture()
        defer { dispose(f) }
        let pids = try f.runtime.list().map(\.pid)
        try f.runtime.update { $0.layout.closeWorkspace(f.workspace) }
        _ = try f.runtime.navigateToDecisionSession(f.requestID, generation: f.launch.id)
        let state = try f.runtime.state()
        XCTAssertEqual(state.layout.selectedWorkspaceID, f.workspace)
        XCTAssertEqual(state.layout.selectedTabID, f.tab)
        XCTAssertEqual(state.layout.focusedPaneID, f.pane)
        XCTAssertFalse(try XCTUnwrap(state.layout.workspaces.first { $0.id == f.workspace }).closed)
        XCTAssertEqual(try f.runtime.list().map(\.pid), pids)
        XCTAssertEqual(try f.runtime.decisionInbox().first?.status, "pending")
    }

    // Implements: FR-DECISION-5
    func testExplicitNavigationReopensAStaleClosedSelectionRatherThanNormalizingToAnotherWorkspace() throws {
        let f = try fixture()
        defer { dispose(f) }
        try f.runtime.update { state in
            try state.layout.selectTab(f.tab)
            let index = try XCTUnwrap(state.layout.workspaces.firstIndex { $0.id == f.workspace })
            state.layout.workspaces[index].closed = true
        }
        _ = try f.runtime.navigateToDecisionSession(f.requestID, generation: f.launch.id)
        let layout = try f.runtime.state().layout
        XCTAssertEqual(layout.selectedWorkspaceID, f.workspace)
        XCTAssertEqual(layout.selectedTabID, f.tab)
        XCTAssertEqual(layout.focusedPaneID, f.pane)
        XCTAssertFalse(try XCTUnwrap(layout.workspaces.first { $0.id == f.workspace }).closed)
    }

    // Implements: FR-DECISION-5
    func testRestoresExactClosedTabAndPrunesPanesAlreadyAttachedElsewhere() throws {
        let f = try fixture()
        defer { dispose(f) }
        let shared = try f.runtime.create(title: "Shared", cwd: f.root.path, shell: "/bin/sleep", arguments: ["120"])
        let unrelated = try f.runtime.create(title: "Unrelated", cwd: f.root.path, shell: "/bin/sleep", arguments: ["120"])
        var unrelatedTab = ""
        try f.runtime.update { state in
            try state.layout.selectTab(f.tab)
            try state.layout.split(tabID: f.tab, paneID: shared.id, axis: .vertical)
            state.layout.closeTab(f.tab)
            state.layout.addTab(paneID: shared.id)
            try state.layout.selectTab(f.otherTab)
            unrelatedTab = state.layout.addTab(paneID: unrelated.id)
            state.layout.closeTab(unrelatedTab)
            try state.layout.selectTab(f.otherTab)
        }
        let pids = try f.runtime.list().map(\.pid)
        _ = try f.runtime.navigateToDecisionSession(f.requestID, generation: f.launch.id)
        let layout = try f.runtime.state().layout
        XCTAssertEqual(layout.selectedTabID, f.tab)
        XCTAssertEqual(layout.tabs.first { $0.id == f.tab }?.panes, [f.pane])
        XCTAssertEqual(layout.tabs.flatMap(\.panes).filter { $0 == shared.id }.count, 1)
        XCTAssertTrue(layout.closedTabs.contains { $0.id == unrelatedTab })
        XCTAssertFalse(layout.closedTabs.contains { $0.id == f.tab })
        XCTAssertFalse(layout.tabs.contains { $0.id == unrelatedTab })
        XCTAssertEqual(try f.runtime.list().map(\.pid), pids)
    }

    // Implements: FR-DECISION-5
    func testDetachedLivePaneGetsAViewWithoutCreatingAnotherShell() throws {
        let f = try fixture()
        defer { dispose(f) }
        let before = try f.runtime.list()
        try f.runtime.update { state in state.layout.detach(f.pane); try state.layout.selectTab(f.otherTab) }
        _ = try f.runtime.navigateToDecisionSession(f.requestID, generation: f.launch.id)
        let state = try f.runtime.state()
        XCTAssertEqual(state.layout.focusedPaneID, f.pane)
        XCTAssertEqual(state.layout.tabs.flatMap(\.panes).filter { $0 == f.pane }.count, 1)
        XCTAssertEqual(try f.runtime.list().map(\.id), before.map(\.id))
        XCTAssertEqual(try f.runtime.list().map(\.pid), before.map(\.pid))
    }

    // Implements: FR-DECISION-5
    func testWrongRequestGenerationAndResolvedQuestionCannotChangeNavigation() throws {
        let f = try fixture()
        defer { dispose(f) }
        let before = try f.runtime.state().layout
        XCTAssertThrowsError(try f.runtime.navigateToDecisionSession(UUID().uuidString, generation: f.launch.id))
        XCTAssertThrowsError(try f.runtime.navigateToDecisionSession(f.requestID, generation: UUID().uuidString))
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertEqual(try f.runtime.decisionInbox().first?.status, "pending")
        _ = try f.runtime.resolveDecision(f.requestID, generation: f.launch.id, action: "choose", optionID: "one")
        XCTAssertThrowsError(try f.runtime.navigateToDecisionSession(f.requestID, generation: f.launch.id))
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertEqual(try f.runtime.decisionInbox().first?.status, "resolved")
    }

    // Implements: FR-DECISION-5
    func testReplacedLaunchCannotNavigateToTheNewAgentInTheSamePane() throws {
        let f = try fixture()
        defer { dispose(f) }
        try f.runtime.update { $0.agentLaunches[0].id = UUID().uuidString.lowercased() }
        let before = try f.runtime.state().layout
        XCTAssertThrowsError(try f.runtime.navigateToDecisionSession(f.requestID, generation: f.launch.id))
        XCTAssertEqual(try f.runtime.state().layout, before)
    }

    // Implements: FR-DECISION-5
    func testDeadOrMissingBackendPaneCannotNavigate() throws {
        for removeRecord in [false, true] {
            let f = try fixture()
            defer { dispose(f) }
            if removeRecord { try f.runtime.update { $0.sessions.removeAll { $0.id == f.pane } } }
            else { try f.runtime.host.kill(f.pane) }
            let before = try f.runtime.state().layout
            XCTAssertThrowsError(try f.runtime.navigateToDecisionSession(f.requestID, generation: f.launch.id))
            XCTAssertEqual(try f.runtime.state().layout, before)
        }
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let pane: String
        let launch: AgentLaunch
        let requestID: String
        let workspace: String
        let tab: String
        let otherTab: String
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-decision-nav-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        let pane = try runtime.create(title: "Same title", cwd: root.path, shell: "/bin/sleep", arguments: ["120"])
        let other = try runtime.create(title: "Same title", cwd: root.path, shell: "/bin/sleep", arguments: ["120"])
        var workspace = "", tab = "", otherTab = ""
        try runtime.update { state in
            state.settings.automaticRestore = false
            workspace = state.layout.addWorkspace(title: "Question")
            tab = state.layout.addTab(paneID: pane.id)
            _ = state.layout.addWorkspace(title: "Elsewhere")
            otherTab = state.layout.addTab(paneID: other.id)
        }
        var launch = try runtime.beginAgentLaunch(paneID: pane.id, provider: .codex, cwd: root.path, configurationRoot: root.appendingPathComponent("provider").path)
        launch.providerSessionID = UUID().uuidString.lowercased()
        try runtime.update { $0.agentLaunches = [launch] }
        let requestID = UUID().uuidString.lowercased()
        let question: JSONValue = .object([
            "schema_version": .string("1.0"), "request_id": .string(requestID), "thread_id": .string(UUID().uuidString.lowercased()),
            "source": .object(["agent": .string("codex"), "session_id": .string(launch.providerSessionID!), "workspace": .string(root.path)]),
            "question": .string("Choose storage"),
            "options": .array(["one", "two"].map { .object(["id": .string($0), "label": .string($0), "description": .string($0)]) })])
        let response = try runtime.decisionAdapter(.object(["type": .string("submit"), "question": question,
            "trano_binding": .object(["pane_id": .string(pane.id), "generation": .string(launch.id)])]))
        XCTAssertEqual(response["ok"], .bool(true))
        XCTAssertEqual(response["status"], .string("pending"))
        return Fixture(root: root, runtime: runtime, pane: pane.id, launch: launch, requestID: requestID, workspace: workspace, tab: tab, otherTab: otherTab)
    }

    private func dispose(_ f: Fixture) {
        f.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: f.root)
    }
}
