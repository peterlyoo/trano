import XCTest
@testable import TerminalCore

final class WorkspaceCloseTests: XCTestCase {
    // Implements: FR-NAV-1, FR-NAV-4, FR-NAV-6
    func testPassiveMirrorRefreshLeavesClosedWorkspaceAndSelectsAnOpenOne() throws {
        var state = RuntimeState()
        let first = state.layout.addWorkspace(title: "First")
        state.layout.addTab(paneID: "first-pane")
        var selection = WindowSelection()
        _ = selection.resolve(state, ownAction: false, acceptsRequests: false)
        let second = state.layout.addWorkspace(title: "Second")
        state.layout.addTab(paneID: "second-pane")
        state.layout.closeWorkspace(first)
        for _ in 0..<3 {
            let resolved = selection.resolve(state, ownAction: false, acceptsRequests: false)
            XCTAssertEqual(resolved.layout.selectedWorkspaceID, second)
            XCTAssertEqual(selection.workspaceID, second)
            XCTAssertTrue(try XCTUnwrap(resolved.layout.workspaces.first { $0.id == first }).closed)
            XCTAssertEqual(resolved.layout.tabs, state.layout.tabs)
            state = resolved
        }
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testPassiveMirrorRefreshAfterFinalCloseStaysEmpty() throws {
        var state = RuntimeState()
        let workspace = state.layout.addWorkspace(title: "Final")
        state.layout.addTab(paneID: "retained-pane")
        var selection = WindowSelection()
        _ = selection.resolve(state, ownAction: false, acceptsRequests: false)
        state.layout.closeWorkspace(workspace)
        for _ in 0..<3 {
            let resolved = selection.resolve(state, ownAction: false, acceptsRequests: false)
            XCTAssertNil(selection.workspaceID)
            XCTAssertNil(resolved.layout.selectedWorkspaceID)
            XCTAssertNil(resolved.layout.selectedTabID)
            XCTAssertNil(resolved.layout.focusedPaneID)
            XCTAssertTrue(resolved.layout.currentTabs.isEmpty)
            XCTAssertTrue(try XCTUnwrap(resolved.layout.workspaces.first).closed)
            XCTAssertEqual(resolved.layout.tabs, state.layout.tabs)
            state = resolved
        }
    }

    // Implements: FR-NAV-1, FR-NAV-4, FR-NAV-6
    func testInitialWindowRejectsStaleClosedSelectionWithoutReopeningItsTabs() throws {
        var state = RuntimeState()
        let closed = state.layout.addWorkspace(title: "Closed")
        let closedTab = state.layout.addTab(paneID: "closed-pane")
        let open = state.layout.addWorkspace(title: "Open")
        let openTab = state.layout.addTab(paneID: "open-pane")
        state.layout.closeWorkspace(closed)
        state.layout.selectedWorkspaceID = closed
        state.layout.selectedTabID = closedTab
        state.layout.focusedPaneID = "closed-pane"
        var selection = WindowSelection()
        let resolved = selection.resolve(state, ownAction: false, acceptsRequests: false)
        XCTAssertEqual(selection.workspaceID, open)
        XCTAssertEqual(resolved.layout.selectedWorkspaceID, open)
        XCTAssertEqual(resolved.layout.selectedTabID, openTab)
        XCTAssertTrue(try XCTUnwrap(resolved.layout.workspaces.first { $0.id == closed }).closed)
    }

    // Implements: FR-NAV-1, FR-NAV-4, FR-NAV-6
    func testExplicitNavigationRequestCanReopenClosedWorkspace() throws {
        var state = RuntimeState()
        let closed = state.layout.addWorkspace(title: "Retained")
        let tab = state.layout.addTab(paneID: "retained-pane")
        let open = state.layout.addWorkspace(title: "Open")
        state.layout.addTab(paneID: "open-pane")
        state.layout.closeWorkspace(closed)
        var selection = WindowSelection()
        _ = selection.resolve(state, ownAction: false, acceptsRequests: true)
        XCTAssertEqual(selection.workspaceID, open)
        try state.layout.selectWorkspace(closed)
        state.navigationRequest = NavigationRequest(workspaceID: closed, tabID: tab, paneID: "retained-pane")
        let resolved = selection.resolve(state, ownAction: false, acceptsRequests: true)
        XCTAssertEqual(selection.workspaceID, closed)
        XCTAssertEqual(resolved.layout.selectedTabID, tab)
        XCTAssertFalse(try XCTUnwrap(resolved.layout.workspaces.first { $0.id == closed }).closed)
    }

    // Implements: FR-NAV-1, FR-NAV-4, FR-NAV-6
    func testUnobservedNavigationRequestCannotReopenAWorkspaceClosedBeforeRefresh() throws {
        var state = RuntimeState()
        let closed = state.layout.addWorkspace(title: "Retained")
        let tab = state.layout.addTab(paneID: "retained-pane")
        let open = state.layout.addWorkspace(title: "Open")
        state.layout.addTab(paneID: "open-pane")
        var selection = WindowSelection()
        _ = selection.resolve(state, ownAction: false, acceptsRequests: true)
        try state.layout.selectWorkspace(closed)
        state.navigationRequest = NavigationRequest(workspaceID: closed, tabID: tab, paneID: "retained-pane")
        state.layout.closeWorkspace(closed)
        let resolved = selection.resolve(state, ownAction: false, acceptsRequests: true)
        XCTAssertEqual(selection.workspaceID, open)
        XCTAssertEqual(resolved.layout.selectedWorkspaceID, open)
        XCTAssertTrue(try XCTUnwrap(resolved.layout.workspaces.first { $0.id == closed }).closed)
    }

    // Implements: FR-NAV-1, FR-NAV-4, FR-NAV-6
    func testStartupPrefersOpenTabsOverRetainedClosedTabs() throws {
        let fixture = try makeFixture()
        defer { dispose(fixture) }
        let closedPane = try fixture.runtime.create(title: "Closed", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["90"])
        let openPane = try fixture.runtime.create(title: "Open", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["90"])
        var closed = "", openTab = ""
        try fixture.runtime.update { state in
            closed = state.layout.addWorkspace(title: "Closed")
            state.layout.addTab(paneID: closedPane.id)
            state.layout.closeWorkspace(closed)
            state.layout.addWorkspace(title: "Open")
            openTab = state.layout.addTab(paneID: openPane.id)
            state.layout.addWorkspace(title: "Empty selected")
        }
        XCTAssertEqual(try fixture.runtime.ensureInitialWorkspace(cwd: fixture.root.path), openPane.id)
        let after = try fixture.runtime.state()
        XCTAssertEqual(after.layout.selectedTabID, openTab)
        XCTAssertTrue(try XCTUnwrap(after.layout.workspaces.first { $0.id == closed }).closed)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) }), [closedPane.id: closedPane.pid, openPane.id: openPane.pid])
    }

    // Implements: FR-NAV-1, FR-NAV-4, FR-NAV-6
    func testStartupAfterAllClosedKeepsOldJobsAndNamedReopenKeepsTheirIdentity() throws {
        let fixture = try makeFixture()
        defer { dispose(fixture) }
        let retained = try fixture.runtime.create(title: "Retained", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["90"])
        var workspace = "", tab = ""
        try fixture.runtime.update { state in
            workspace = state.layout.addWorkspace(title: "Retained 한글")
            tab = state.layout.addTab(paneID: retained.id)
            state.layout.closeWorkspace(workspace)
        }
        let original = try XCTUnwrap(try fixture.runtime.state().layout.tabs.first)
        let fresh = try XCTUnwrap(fixture.runtime.ensureInitialWorkspace(cwd: fixture.root.path))
        XCTAssertNotEqual(fresh, retained.id)
        let after = try fixture.runtime.state()
        XCTAssertEqual(after.sessions.count, 2)
        XCTAssertEqual(after.layout.tabs.first { $0.id == tab }, original)
        XCTAssertTrue(try XCTUnwrap(after.layout.workspaces.first { $0.id == workspace }).closed)
        XCTAssertNotEqual(after.layout.selectedWorkspaceID, workspace)
        XCTAssertNil(try fixture.runtime.ensureInitialWorkspace(cwd: fixture.root.path))
        try fixture.runtime.performAction(.newSession, cwd: fixture.root.path, title: "  rEtAiNeD 한글  ")
        let reopened = try fixture.runtime.state()
        XCTAssertEqual(reopened.layout.selectedWorkspaceID, workspace)
        XCTAssertEqual(reopened.layout.selectedTabID, tab)
        XCTAssertEqual(reopened.layout.focusedPaneID, retained.id)
        XCTAssertEqual(reopened.layout.tabs.first { $0.id == tab }, original)
        XCTAssertFalse(try XCTUnwrap(reopened.layout.workspaces.first { $0.id == workspace }).closed)
        XCTAssertEqual(try fixture.runtime.list().first { $0.id == retained.id }?.pid, retained.pid)
        XCTAssertTrue(try fixture.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-1, FR-NAV-4, FR-NAV-6
    func testStartupReattachesOnlyDetachedLiveJobsAndDoesNotReopenClosedTabs() throws {
        let fixture = try makeFixture()
        defer { dispose(fixture) }
        let attached = try fixture.runtime.create(title: "Closed", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["90"])
        let detached = try fixture.runtime.create(title: "Detached", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["90"])
        var workspace = ""
        try fixture.runtime.update { state in
            workspace = state.layout.addWorkspace(title: "Closed")
            state.layout.addTab(paneID: attached.id)
            state.layout.closeWorkspace(workspace)
        }
        XCTAssertEqual(try fixture.runtime.ensureInitialWorkspace(cwd: fixture.root.path), detached.id)
        let after = try fixture.runtime.state()
        XCTAssertEqual(after.sessions.count, 2)
        XCTAssertEqual(after.layout.focusedPaneID, detached.id)
        XCTAssertTrue(try XCTUnwrap(after.layout.workspaces.first { $0.id == workspace }).closed)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) }), [attached.id: attached.pid, detached.id: detached.pid])
    }

    private struct Fixture { let root: URL; let runtime: TerminalRuntime }
    private func makeFixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-close-core-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        return Fixture(root: root, runtime: runtime)
    }
    private func dispose(_ fixture: Fixture) {
        fixture.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: fixture.root)
    }
}
