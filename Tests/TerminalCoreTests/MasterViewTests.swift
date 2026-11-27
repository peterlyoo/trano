import XCTest
@testable import TerminalCore

final class MasterViewTests: XCTestCase {
    private func session(_ id: String, _ state: ActivityState, at time: TimeInterval = 100) -> TerminalSession {
        var value = TerminalSession(id: id, title: id, cwd: "/tmp", pid: 0)
        value.activity.state = state
        value.activity.updatedAt = Date(timeIntervalSince1970: time)
        return value
    }

    /// Master "M" plus work sessions "A" (blocked, running) and "B" (done, error, idle) with one tab per pane.
    private func layout() -> (WorkspaceLayout, master: String, a: String, b: String) {
        var layout = WorkspaceLayout()
        let master = layout.addWorkspace(title: "M"); layout.addTab(paneID: "m1")
        let a = layout.addWorkspace(title: "A"); layout.addTab(paneID: "blocked"); layout.addTab(paneID: "running")
        let b = layout.addWorkspace(title: "B"); layout.addTab(paneID: "done"); layout.addTab(paneID: "error"); layout.addTab(paneID: "idle")
        return (layout, master, a, b)
    }

    private let sessions: [String: ActivityState] = ["m1": .idle, "blocked": .blocked, "running": .running, "done": .done, "error": .error, "idle": .idle]
    private var sessionList: [TerminalSession] { sessions.map { session($0.key, $0.value) } }
    private func tabID(_ layout: WorkspaceLayout, pane: String) -> String { layout.tabs.first { $0.panes.contains(pane) }!.id }

    func testProjectionPresentsOnlySessionsThatNeedReviewInStripOrder() throws {
        var (layout, master, _, _) = layout()
        try layout.selectWorkspace(master)
        let projection = try XCTUnwrap(MasterView.projection(layout: layout, sessions: sessionList, readAt: [:], workspaceID: master))
        XCTAssertEqual(projection.tabIDs, ["blocked", "done", "error"].map { tabID(layout, pane: $0) })

        let read = ["done": Date(timeIntervalSince1970: 100), "error": Date(timeIntervalSince1970: 100), "blocked": Date(timeIntervalSince1970: 100)]
        XCTAssertEqual(MasterView.projection(layout: layout, sessions: sessionList, readAt: read, workspaceID: master)?.tabIDs,
                       [tabID(layout, pane: "blocked")], "a decision stays presented until answered; a read completion leaves")
        XCTAssertNil(MasterView.projection(layout: layout, sessions: sessionList, readAt: [:], workspaceID: nil))
        XCTAssertNil(MasterView.projection(layout: layout, sessions: sessionList, readAt: [:], workspaceID: "missing"))
    }

    func testClosedWorkspacesAreNotPresentedAndTheShownTabStaysAfterItIsRead() throws {
        var (layout, master, _, b) = layout()
        layout.closeWorkspace(b)
        try layout.selectWorkspace(master)
        XCTAssertEqual(MasterView.projection(layout: layout, sessions: sessionList, readAt: [:], workspaceID: master)?.tabIDs,
                       [tabID(layout, pane: "blocked")])

        var reopened = self.layout().0
        let masterID = reopened.workspaces[0].id
        try reopened.selectWorkspace(masterID)
        reopened.masterView = MasterView.projection(layout: reopened, sessions: sessionList, readAt: [:], workspaceID: masterID)
        let done = tabID(reopened, pane: "done")
        try reopened.selectTab(done)
        let read = ["done": Date(timeIntervalSince1970: 100)]
        XCTAssertTrue(MasterView.projection(layout: reopened, sessions: sessionList, readAt: read, workspaceID: masterID)!.tabIDs.contains(done))
        try reopened.selectTab(reopened.tabs[0].id)
        XCTAssertFalse(MasterView.projection(layout: reopened, sessions: sessionList, readAt: read, workspaceID: masterID)!.tabIDs.contains(done))
    }

    func testSelectingAPresentedTabKeepsTheMasterViewSelected() throws {
        var (layout, master, a, _) = layout()
        try layout.selectWorkspace(master)
        layout.masterView = MasterView.projection(layout: layout, sessions: sessionList, readAt: [:], workspaceID: master)
        let blocked = tabID(layout, pane: "blocked")
        XCTAssertEqual(layout.currentTabs.map(\.id), [layout.tabs[0].id] + layout.masterView!.tabIDs)

        try layout.selectTab(blocked)
        XCTAssertEqual(layout.selectedWorkspaceID, master)
        XCTAssertEqual(layout.selectedTabID, blocked)
        XCTAssertEqual(layout.focusedPaneID, "blocked")
        XCTAssertEqual(layout.tabs.first { $0.id == blocked }?.workspaceID, a, "presenting a tab never moves it")

        try layout.selectWorkspace(a)
        try layout.selectWorkspace(master)
        XCTAssertEqual(layout.selectedTabID, blocked, "returning to the Master View restores the presented tab")

        try layout.selectTab(tabID(layout, pane: "running"))
        XCTAssertEqual(layout.selectedWorkspaceID, a, "a tab the Master View does not present opens in its own session")
    }

    func testSelectingAReadCompletionThatWasPresentedStaysInTheMasterView() throws {
        let root = URL(fileURLWithPath: "/tmp/tmv-" + UUID().uuidString.prefix(8))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        var master = ""
        try runtime.update { state in
            state.layout.addWorkspace(title: "Work"); state.layout.addTab(paneID: "w1")
            master = state.layout.addWorkspace(title: "Master"); state.layout.addTab(paneID: "m1")
            state.sessions = [self.session("m1", .idle), self.session("w1", .done, at: 300)]
        }
        try runtime.setMasterWorkspace(master)
        let work = try XCTUnwrap(runtime.state().layout.masterView?.tabIDs.first)
        // The window acknowledges the completion before its selection commits, as AppStore.selectTab does.
        try runtime.acknowledgeActivity("w1", updatedAt: Date(timeIntervalSince1970: 300))
        XCTAssertEqual(try runtime.state().layout.masterView?.tabIDs, [])
        try runtime.update { try $0.layout.selectPresentedTab(work) }
        let layout = try runtime.state().layout
        XCTAssertEqual(layout.selectedWorkspaceID, master)
        XCTAssertEqual(layout.selectedTabID, work)
        XCTAssertEqual(layout.focusedPaneID, "w1")
        XCTAssertEqual(layout.masterView?.tabIDs, [work], "the shown tab stays presented after it was read")

        try runtime.setMasterWorkspace(nil)
        let off = try runtime.state().layout
        XCTAssertEqual(off.selectedWorkspaceID, master)
        XCTAssertTrue(off.currentTabs.contains { $0.id == off.selectedTabID })
        XCTAssertEqual(off.focusedPaneID, "m1")
    }

    func testSelectionLeavesATabTheMasterViewStopsPresenting() throws {
        var (layout, master, a, _) = layout()
        try layout.selectWorkspace(master)
        layout.masterView = MasterView.projection(layout: layout, sessions: sessionList, readAt: [:], workspaceID: master)
        let blocked = tabID(layout, pane: "blocked")
        try layout.selectTab(blocked)

        var closedSource = layout
        closedSource.closeWorkspace(a)
        closedSource.masterView = MasterView.projection(layout: closedSource, sessions: sessionList, readAt: [:], workspaceID: master)
        closedSource.repairPresentedSelection()
        XCTAssertEqual(closedSource.selectedWorkspaceID, master)
        XCTAssertTrue(closedSource.currentTabs.contains { $0.id == closedSource.selectedTabID })
        XCTAssertTrue(closedSource.currentTabs.first { $0.id == closedSource.selectedTabID }!.panes.contains(closedSource.focusedPaneID!))

        var lastOfSource = layout
        lastOfSource.closeTab(tabID(lastOfSource, pane: "running"))
        lastOfSource.closeTab(blocked)
        XCTAssertEqual(lastOfSource.workspaces.first { $0.id == a }?.closed, true)
        XCTAssertEqual(lastOfSource.selectedWorkspaceID, master)
        XCTAssertTrue(lastOfSource.currentTabs.contains { $0.id == lastOfSource.selectedTabID })
        XCTAssertTrue(lastOfSource.tabs.first { $0.id == lastOfSource.selectedTabID }!.panes.contains(lastOfSource.focusedPaneID!))
    }

    func testClosingTheLastOwnTabKeepsTheMasterViewOpen() throws {
        var (layout, master, _, _) = layout()
        try layout.selectWorkspace(master)
        layout.masterView = MasterView.projection(layout: layout, sessions: sessionList, readAt: [:], workspaceID: master)
        layout.closeTab(layout.tabs[0].id)
        XCTAssertEqual(layout.workspaces.first { $0.id == master }?.closed, false)
        XCTAssertEqual(layout.selectedWorkspaceID, master)
        XCTAssertEqual(layout.currentTabs.map(\.id), layout.masterView!.tabIDs)
    }

    func testNavigationRequestKeepsAMasterViewWindowOnPresentedSessions() throws {
        var (layout, master, a, _) = layout()
        try layout.selectWorkspace(master)
        var state = RuntimeState()
        state.layout = layout
        state.sessions = sessionList
        state.layout.masterView = MasterView.projection(layout: state.layout, sessions: state.sessions, readAt: [:], workspaceID: master)
        var window = WindowSelection()
        _ = window.resolve(state, ownAction: false, acceptsRequests: true)

        state.navigationRequest = NavigationRequest(workspaceID: a, paneID: "blocked")
        let shown = window.resolve(state, ownAction: false, acceptsRequests: true)
        XCTAssertEqual(shown.layout.selectedWorkspaceID, master)
        XCTAssertEqual(shown.layout.focusedPaneID, "blocked")

        state.navigationRequest = NavigationRequest(workspaceID: a, paneID: "running")
        XCTAssertEqual(window.resolve(state, ownAction: false, acceptsRequests: true).layout.selectedWorkspaceID, a)
    }

    func testRuntimeKeepsTheSettingOutsideStoredStateAndFollowsActivity() throws {
        let root = URL(fileURLWithPath: "/tmp/tmv-" + UUID().uuidString.prefix(8))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        var ids: (master: String, a: String) = ("", "")
        try runtime.update { state in
            ids.master = state.layout.addWorkspace(title: "Master"); state.layout.addTab(paneID: "m1")
            ids.a = state.layout.addWorkspace(title: "Work"); state.layout.addTab(paneID: "w1")
            state.sessions = [self.session("m1", .idle), self.session("w1", .running)]
        }
        XCTAssertThrowsError(try runtime.setMasterWorkspace("missing"))
        try runtime.setMasterWorkspace(ids.master)
        XCTAssertEqual(try runtime.masterWorkspaceID(), ids.master)
        XCTAssertEqual(try runtime.state().layout.masterView?.tabIDs, [])

        try runtime.update { $0.sessions[1].activity.state = .done; $0.sessions[1].activity.updatedAt = Date(timeIntervalSince1970: 200) }
        let work = try XCTUnwrap(runtime.state().layout.tabs.first { $0.panes == ["w1"] }?.id)
        XCTAssertEqual(try runtime.state().layout.masterView?.tabIDs, [work])
        try runtime.acknowledgeActivity("w1", updatedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(try runtime.state().layout.masterView?.tabIDs, [])

        let stored = try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertFalse(stored.contains("masterView"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("master-view.json").path))

        // A helper from an older build rewrites state.json with its own schema; the designation survives.
        try runtime.update { $0.revision += 0 }
        XCTAssertEqual(try runtime.masterWorkspaceID(), ids.master)
        try runtime.setMasterWorkspace(nil)
        XCTAssertNil(try runtime.masterWorkspaceID())

        let service = APIService(runtime: runtime)
        let set = service.route(APIRequest(method: "workspaces.master", params: ["id": .string(ids.master)]))
        XCTAssertNil(set.error)
        XCTAssertEqual(set.result, .object(["workspaceID": .string(ids.master), "tabIDs": .array([])]))
        XCTAssertNotNil(service.route(APIRequest(method: "workspaces.master", params: ["id": .number(1)])).error)
        XCTAssertEqual(service.route(APIRequest(method: "workspaces.master", params: ["id": .null])).result,
                       .object(["workspaceID": .null, "tabIDs": .array([])]))
    }
}
