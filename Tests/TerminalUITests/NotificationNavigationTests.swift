import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class NotificationNavigationTests: XCTestCase {
    @MainActor func testNotificationOpensTheExactPaneFromAnyPlace() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-nn-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        let panes = try (0..<6).map { try runtime.create(title: "N\($0)", cwd: root.path, shell: "/bin/sleep", arguments: ["90"]).id }
        var a = "", b = "", c = ""
        try runtime.update { state in
            state.settings.automaticRestore = false
            a = state.layout.addWorkspace(title: "A"); let tab = state.layout.addTab(paneID: panes[0])
            try state.layout.split(tabID: tab, paneID: panes[1], axis: .horizontal)
            state.layout.addTab(paneID: panes[2])
            b = state.layout.addWorkspace(title: "B"); state.layout.addTab(paneID: panes[3]); state.layout.addTab(paneID: panes[4])
            c = state.layout.addWorkspace(title: "C"); state.layout.addTab(paneID: panes[5])
            try state.layout.selectWorkspace(a)
            try state.layout.focusPane(panes[1])
        }
        try runtime.update { $0.layout.closeWorkspace(c) }
        try runtime.update { try $0.layout.selectWorkspace(a) }
        let store = AppStore(runtime: runtime)
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700),
                                          contentView: NSHostingView(rootView: WorkspaceView(store: store)))
        window.orderFrontRegardless()
        defer {
            for view in store.terminalViews.values { view.terminate() }
            store.terminalViews.removeAll(); window.contentView = nil; window.close()
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root)
        }
        func settle(_ what: String, _ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat { window.contentView?.layoutSubtreeIfNeeded(); if condition() { return }; try await Task.sleep(for: .milliseconds(20)) } while Date() < deadline
            XCTFail(what + ": " + (store.message ?? "no error") + " selected=\(store.state.layout.selectedWorkspaceID ?? "-") focus=\(store.focusedID ?? "-")")
        }
        func shown(_ pane: String) -> Bool {
            store.focusedID == pane && store.selectedTab?.panes.contains(pane) == true && store.terminalViews[pane]?.window === window
        }
        try await settle("loaded") { !store.loading && shown(panes[1]) }
        for (pane, label) in [(panes[0], "other pane of the split"), (panes[2], "other tab"), (panes[4], "other session, background tab"),
                              (panes[5], "closed session"), (panes[1], "back to the first session")] {
            store.attach(pane)
            try await settle(label) { shown(pane) }
        }
        try runtime.setMasterWorkspace(a)
        try runtime.update { state in
            let index = state.sessions.firstIndex { $0.id == panes[3] }!
            state.sessions[index].activity.state = .blocked; state.sessions[index].activity.updatedAt = Date()
        }
        try await settle("master view presents B") { store.state.layout.isPresentedInMasterView(store.state.layout.tabs.first { $0.panes.contains(panes[3]) }!.id) }
        store.attach(panes[3])
        try await settle("presented pane from the master view") { shown(panes[3]) }
        XCTAssertEqual(store.state.layout.selectedWorkspaceID, a)
        store.attach(panes[4])
        try await settle("pane the master view does not present") { shown(panes[4]) }
        XCTAssertEqual(store.state.layout.selectedWorkspaceID, b)
    }
}
