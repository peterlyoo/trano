import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class MasterViewUITests: XCTestCase {
    @MainActor func testMasterViewPresentsSessionsThatNeedReviewWithoutMovingThem() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-mv-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        let panes = try (0..<2).map { try runtime.create(title: "MV \($0)", cwd: root.path, shell: "/bin/sleep", arguments: ["90"]).id }
        var master = "", work = "", tabs: [String] = []
        try runtime.update { state in
            state.settings.automaticRestore = false
            work = state.layout.addWorkspace(title: "Work"); tabs.append(state.layout.addTab(paneID: panes[1]))
            master = state.layout.addWorkspace(title: "Inbox"); tabs.insert(state.layout.addTab(paneID: panes[0]), at: 0)
        }
        let store = AppStore(runtime: runtime)
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700),
                                          contentView: NSHostingView(rootView: WorkspaceView(store: store)))
        window.orderFrontRegardless()
        defer {
            for view in store.terminalViews.values { view.terminate() }
            store.terminalViews.removeAll()
            window.contentView = nil
            window.close()
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            runtime.shutdownTestHost()
            try? FileManager.default.removeItem(at: root)
        }
        func settle(_ what: String, _ condition: () throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                window.contentView?.layoutSubtreeIfNeeded()
                if try condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            } while Date() < deadline
            XCTFail(what + ": " + (store.message ?? "no error"))
        }
        func menuItem(_ menu: NSMenu) throws -> (NSMenu, Int) {
            let index = try XCTUnwrap(menu.items.firstIndex { $0.identifier?.rawValue == "header-master-view" })
            return (menu, index)
        }
        func regions(_ id: String, in view: NSView) -> [NSView] {
            (view.identifier?.rawValue == id ? [view] : []) + view.subviews.flatMap { regions(id, in: $0) }
        }
        try await settle("window loads") { !store.loading && store.state.layout.selectedWorkspaceID == master && store.terminalViews[panes[0]] != nil }
        let pids = try runtime.list().map(\.pid)

        let (menu, index) = try menuItem(store.headerContextMenu())
        XCTAssertEqual(menu.item(at: index)?.title, "Use as Master View")
        XCTAssertEqual(menu.item(at: index)?.state, .off)
        menu.performActionForItem(at: index)
        try await settle("master view turns on") { store.state.layout.masterView?.workspaceID == master }
        XCTAssertEqual(store.state.layout.currentTabs.map(\.id), [tabs[0]], "a running or idle session is not presented")

        try runtime.update { state in
            let index = state.sessions.firstIndex { $0.id == panes[1] }!
            state.sessions[index].activity.state = .blocked
            state.sessions[index].activity.reason = "answer: Ship it? (Yes · No)"
            state.sessions[index].activity.updatedAt = Date()
        }
        try await settle("blocked session is presented") { store.state.layout.currentTabs.map(\.id) == tabs }
        let content = try XCTUnwrap(window.contentView)
        try await settle("source label renders") { !regions("tab-master-source-" + tabs[1], in: content).isEmpty }
        XCTAssertTrue(regions("tab-master-source-" + tabs[0], in: content).isEmpty)

        store.selectTab(tabs[1])
        try await settle("presented tab opens inside the master view") {
            store.state.layout.selectedTabID == tabs[1] && store.terminalViews[panes[1]]?.window === window
        }
        XCTAssertEqual(store.state.layout.selectedWorkspaceID, master)
        XCTAssertEqual(try runtime.state().layout.tabs.first { $0.id == tabs[1] }?.workspaceID, work)

        let tabMenu = store.headerContextMenu(tabID: tabs[1])
        func entry(_ id: String, in menu: NSMenu) throws -> NSMenuItem { try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == id }, id) }
        XCTAssertEqual(try entry("header-master-view", in: tabMenu).state, .on, "session actions target the Master View")
        for id in ["header-move-tab-backward", "header-move-tab-forward", "header-close-other-tabs", "header-close-tabs-right", "header-close-tabs-left"] {
            XCTAssertFalse(try entry(id, in: tabMenu).isEnabled, id + " would act on the hidden source session")
        }
        XCTAssertTrue(try entry("header-close-tab", in: tabMenu).isEnabled)

        // A completion is read as it is selected; selecting it must still keep the Master View.
        try runtime.update { state in
            let index = state.sessions.firstIndex { $0.id == panes[1] }!
            state.sessions[index].activity.state = .done
            state.sessions[index].activity.updatedAt = Date()
        }
        store.selectTab(tabs[0])
        try await settle("own tab selected") { store.state.layout.selectedTabID == tabs[0] }
        try await settle("completion is presented") { store.state.layout.currentTabs.map(\.id) == tabs }
        store.selectTab(tabs[1])
        try await settle("read completion opens inside the master view") {
            let read = try runtime.state().activityReadAt[panes[1]]
            return store.state.layout.selectedTabID == tabs[1] && store.terminalViews[panes[1]]?.window === window && read != nil
        }
        XCTAssertEqual(store.state.layout.selectedWorkspaceID, master)
        XCTAssertEqual(try runtime.state().layout.selectedWorkspaceID, master)

        let (onMenu, onIndex) = try menuItem(store.headerContextMenu())
        XCTAssertEqual(onMenu.item(at: onIndex)?.state, .on)
        onMenu.performActionForItem(at: onIndex)
        try await settle("master view turns off") { store.state.layout.masterView == nil && store.state.layout.currentTabs.map(\.id) == [tabs[0]] }
        try await settle("selection returns to a tab the session owns") { store.state.layout.selectedTabID == tabs[0] && store.focusedID == panes[0] }
        XCTAssertEqual(store.state.layout.selectedWorkspaceID, master)
        XCTAssertEqual(try runtime.list().map(\.pid), pids)
        XCTAssertTrue(try runtime.list().allSatisfy(\.alive))
    }
}
