import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class HeaderContextMenuTests: XCTestCase {
    // Implements: FR-NAV-7
    @MainActor func testNativeTabAndBlankStripExposeMenusWithoutTakingLeftClickTargets() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let content = try XCTUnwrap(f.window.contentView)
        let overlay = try XCTUnwrap(regions("tab-context-menu-" + f.tabs[1], in: content).first)
        XCTAssertNil(overlay.hitTest(NSPoint(x: overlay.frame.midX, y: overlay.frame.midY)))
        let tabMenu = try XCTUnwrap(overlay.menu(for: mouseEvent(.rightMouseDown, in: overlay, window: f.window)))
        XCTAssertEqual(try item("header-new-tab", in: tabMenu).title, "New Tab")
        XCTAssertTrue(try item("header-rename-tab", in: tabMenu).isEnabled)
        let controlMenu = try XCTUnwrap(overlay.menu(for: mouseEvent(.leftMouseDown, modifiers: .control, in: overlay, window: f.window)))
        XCTAssertNotNil(find("header-close-tab", in: controlMenu))
        let drag = try XCTUnwrap(regions("window-drag-region", in: content).max { $0.bounds.width < $1.bounds.width })
        XCTAssertGreaterThan(drag.bounds.width, 100)
        let frame = try XCTUnwrap(content.superview)
        XCTAssertTrue(frame.hitTest(drag.convert(NSPoint(x: drag.bounds.midX, y: drag.bounds.midY), to: frame)) === drag)
        let blankMenu = try XCTUnwrap(drag.menu(for: mouseEvent(.rightMouseDown, in: drag, window: f.window)))
        for (id, title) in [("header-new-tab", "New Tab"), ("header-rename-session", "Rename Session…"),
                            ("header-close-session", "Close Session"), ("header-new-session", "New Session"),
                            ("header-add-remote-host", "Add Remote Host…"), ("header-customize-view", "Customize View")] {
            XCTAssertEqual(try item(id, in: blankMenu).title, title)
            XCTAssertTrue(try item(id, in: blankMenu).isEnabled)
        }
        XCTAssertNotNil(try item("header-customize-view", in: blankMenu).submenu)
        XCTAssertNil(find("header-close-tab", in: blankMenu))
        XCTAssertEqual(f.store.state.layout.selectedTabID, f.tabs[1])
    }

    // Implements: FR-NAV-7, FR-NAV-4
    @MainActor func testNewTabAndSessionActionsSurviveRedrawAndPreserveExistingJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try pids(f)
        let menu = f.store.headerContextMenu()
        let newTab = try item("header-new-tab", in: menu)
        XCTAssertEqual(newTab.keyEquivalent, "y")
        XCTAssertEqual(newTab.keyEquivalentModifierMask, [.command, .shift])
        XCTAssertTrue(newTab.target === newTab)
        f.store.showSessionsSidebar.toggle()
        f.window.contentView?.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(40))
        try perform("header-new-tab", in: menu)
        try await settle(f) { f.store.state.layout.currentTabs.count == 3 }
        let added = try XCTUnwrap(f.store.selectedTab?.panes.first)
        XCTAssertFalse(f.panes.contains(added))
        XCTAssertGreaterThan(try XCTUnwrap(try f.runtime.list().first { $0.id == added }).pid, 0)
        try perform("header-new-session", in: f.store.headerContextMenu())
        try await settle(f) { f.store.state.layout.workspaces.count == 2 && f.store.state.layout.selectedWorkspaceID != f.workspace }
        XCTAssertEqual(f.store.state.layout.currentTabs.count, 1)
        let sessionPane = try XCTUnwrap(f.store.focusedID)
        XCTAssertNotEqual(sessionPane, added)
        let after = try pids(f)
        for (id, pid) in before { XCTAssertEqual(after[id], pid) }
        XCTAssertEqual(after.count, before.count + 2)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-7, FR-NAV-4
    @MainActor func testClickedTabReorderAndCloseKeepBackendJobsAndSessionCloseRetainsLayout() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try pids(f)
        let menu = f.store.headerContextMenu(tabID: f.tabs[0])
        XCTAssertTrue(try item("header-rename-tab", in: menu).title.hasPrefix("Rename Tab"))
        XCTAssertTrue(try item("header-rename-tab", in: menu).isEnabled)
        try perform("header-move-tab-forward", in: menu)
        try await settle(f) { f.store.state.layout.currentTabs.map(\.id) == [f.tabs[1], f.tabs[0]] }
        try perform("header-move-tab-backward", in: f.store.headerContextMenu(tabID: f.tabs[0]))
        try await settle(f) { f.store.state.layout.currentTabs.map(\.id) == f.tabs }
        try perform("header-close-tab", in: f.store.headerContextMenu(tabID: f.tabs[0]))
        try await settle(f) { f.store.state.layout.currentTabs.map(\.id) == [f.tabs[1]] }
        XCTAssertEqual(f.store.state.layout.closedTabs.last?.id, f.tabs[0])
        let retainedTabs = try f.runtime.state().layout.tabs
        try perform("header-close-session", in: f.store.headerContextMenu())
        try await settle(f) { f.store.state.layout.selectedWorkspaceID == nil }
        XCTAssertTrue(try XCTUnwrap(try f.runtime.state().layout.workspaces.first).closed)
        XCTAssertEqual(try f.runtime.state().layout.tabs, retainedTabs)
        XCTAssertEqual(try pids(f), before)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-7
    @MainActor func testProfileCheckmarksAndDefaultTargetInactiveTabsFocusedPane() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let menu = f.store.headerContextMenu(tabID: f.tabs[0])
        XCTAssertNotNil(try item("header-profiles", in: menu).submenu)
        XCTAssertEqual(try item("header-profile-default", in: menu).state, .on)
        XCTAssertEqual(try item("header-profile-" + f.profile.id, in: menu).state, .off)
        try perform("header-profile-" + f.profile.id, in: menu)
        try await settle(f) { f.store.state.settings.paneAppearanceProfiles[f.panes[1]] == f.profile.id }
        XCTAssertNil(f.store.state.settings.paneAppearanceProfiles[f.panes[0]])
        XCTAssertNil(f.store.state.settings.paneAppearanceProfiles[f.panes[2]])
        XCTAssertEqual(f.store.state.layout.selectedTabID, f.tabs[1])
        let selected = f.store.headerContextMenu(tabID: f.tabs[0])
        XCTAssertEqual(try item("header-profile-default", in: selected).state, .off)
        XCTAssertEqual(try item("header-profile-" + f.profile.id, in: selected).state, .on)
        try perform("header-profile-default", in: selected)
        try await settle(f) { f.store.state.settings.paneAppearanceProfiles[f.panes[1]] == nil }
        XCTAssertEqual(try item("header-profile-default", in: f.store.headerContextMenu(tabID: f.tabs[0])).state, .on)
    }

    // Implements: FR-NAV-7
    @MainActor func testCustomizeDestinationsAndSidebarCheckmarkUseOwningStore() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        var managedProfiles = 0
        let menu = f.store.headerContextMenu(showProfiles: { managedProfiles += 1 })
        XCTAssertEqual(try item("header-sidebar", in: menu).state, .off)
        try perform("header-sidebar", in: menu)
        XCTAssertTrue(f.store.showSessionsSidebar)
        let expanded = f.store.headerContextMenu()
        XCTAssertEqual(try item("header-sidebar", in: expanded).state, .on)
        try perform("header-sidebar", in: expanded)
        XCTAssertFalse(f.store.showSessionsSidebar)
        try perform("header-manage-profiles", in: menu)
        XCTAssertEqual(managedProfiles, 1)
        try perform("header-appearance", in: menu)
        XCTAssertTrue(f.store.showSettings)
        f.store.showSettings = false
        try perform("header-add-remote-host", in: f.store.headerContextMenu())
        XCTAssertTrue(f.store.showRemoteHosts)
        XCTAssertFalse(f.store.showAccounts)
    }

    // Implements: FR-NAV-7
    @MainActor func testPendingInputDisablesFreshMenusAndRefusesPreviouslyOpenedActions() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try f.runtime.state().layout
        let blockers: [(String, () -> Void, () -> Void)] = [
            ("decision", { f.store.decisionPaneID = f.panes[2] }, { f.store.decisionPaneID = nil }),
            ("queued input", { f.store.followUpPaneID = f.panes[2] }, { f.store.followUpPaneID = nil }),
            ("picker", { f.store.picker = .commands }, { f.store.picker = nil }),
            ("settings", { f.store.showSettings = true }, { f.store.showSettings = false }),
            ("voice", { f.store.showVoice = true }, { f.store.showVoice = false }),
            ("remote hosts", { f.store.showRemoteHosts = true }, { f.store.showRemoteHosts = false }),
            ("accounts", { f.store.showAccounts = true }, { f.store.showAccounts = false }),
            ("extensions", { f.store.showExtensions = true }, { f.store.showExtensions = false }),
            ("message", { f.store.message = "Keep this draft" }, { f.store.message = nil })
        ]
        for (name, block, unblock) in blockers {
            let stale = f.store.headerContextMenu(tabID: f.tabs[0])
            block()
            let disabled = f.store.headerContextMenu(tabID: f.tabs[0])
            XCTAssertFalse(try item("header-new-tab", in: disabled).isEnabled, name)
            XCTAssertFalse(try item("header-close-tab", in: disabled).isEnabled, name)
            XCTAssertFalse(try item("header-rename-session", in: disabled).isEnabled, name)
            try perform("header-new-tab", in: stale)
            try perform("header-close-tab", in: stale)
            try perform("header-profile-" + f.profile.id, in: stale)
            try perform("header-sidebar", in: stale)
            await drain(f.store)
            XCTAssertEqual(try f.runtime.state().layout, before, name)
            XCTAssertTrue(try f.runtime.state().settings.paneAppearanceProfiles.isEmpty, name)
            XCTAssertFalse(f.store.showSessionsSidebar, name)
            unblock()
        }
        XCTAssertEqual(try f.runtime.list().count, f.panes.count)
    }

    // Implements: FR-NAV-7, FR-NAV-4
    @MainActor func testClosedAndMovedTargetsCannotMutateReplacementWorkspaceEvenWhenQueued() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try pids(f)
        let closedMenu = f.store.headerContextMenu(tabID: f.tabs[1])
        try f.runtime.update { $0.layout.closeTab(f.tabs[1]) }
        let closedLayout = try f.runtime.state().layout
        try perform("header-new-tab", in: closedMenu)
        try perform("header-close-session", in: closedMenu)
        await drain(f.store)
        XCTAssertEqual(try f.runtime.state().layout, closedLayout)
        f.store.refresh()
        try await settle(f) { f.store.state.layout.tabs.count == 1 }

        let movedMenu = f.store.headerContextMenu(tabID: f.tabs[0])
        f.store.queue.suspend()
        var suspended = true
        defer { if suspended { f.store.queue.resume() } }
        try perform("header-close-tab", in: movedMenu)
        try perform("header-profile-" + f.profile.id, in: movedMenu)
        var destination = ""
        try f.runtime.update { state in
            destination = state.layout.addWorkspace(title: "Other")
            try state.layout.transferTab(f.tabs[0], from: f.workspace, to: destination)
        }
        let movedLayout = try f.runtime.state().layout
        suspended = false
        f.store.queue.resume()
        await drain(f.store)
        XCTAssertEqual(try f.runtime.state().layout, movedLayout)
        XCTAssertEqual(try f.runtime.state().layout.tabs.first?.workspaceID, destination)
        XCTAssertTrue(try f.runtime.state().settings.paneAppearanceProfiles.isEmpty)
        XCTAssertEqual(try pids(f), before)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-7, FR-NAV-4
    @MainActor func testQueuedRenameCannotFollowTabIntoAnotherWorkspace() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let context = HeaderMenuContext(workspaceID: f.workspace, tabID: f.tabs[0], paneID: f.panes[1])
        let originalTitle = try XCTUnwrap(try f.runtime.state().layout.tabs.first { $0.id == f.tabs[0] }).title
        f.store.queue.suspend()
        var suspended = true
        defer { if suspended { f.store.queue.resume() } }
        f.store.commitHeaderRename(.renameTab, name: "Late rename", context: context)
        var destination = ""
        try f.runtime.update { state in
            destination = state.layout.addWorkspace(title: "Rename destination")
            try state.layout.transferTab(f.tabs[0], from: f.workspace, to: destination)
        }
        let movedLayout = try f.runtime.state().layout
        suspended = false
        f.store.queue.resume()
        await drain(f.store)
        let after = try f.runtime.state().layout
        XCTAssertEqual(after, movedLayout)
        let moved = try XCTUnwrap(after.tabs.first { $0.id == f.tabs[0] })
        XCTAssertEqual(moved.workspaceID, destination)
        XCTAssertEqual(moved.title, originalTitle)
    }

    // Implements: FR-NAV-7, FR-INPUT-1
    @MainActor func testLateCompositionKeepsNewTabInBackgroundAndRetainsOriginalResponder() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let originalTab = try XCTUnwrap(f.store.state.layout.selectedTabID)
        let terminal = try XCTUnwrap(f.store.terminalViews[f.panes[2]])
        let clientPID = terminal.process.shellPid
        let before = try pids(f)
        XCTAssertTrue(f.window.makeFirstResponder(terminal))
        XCTAssertFalse(terminal.hasMarkedText())
        let menu = f.store.headerContextMenu(sourceWindow: f.window)
        XCTAssertTrue(try item("header-new-tab", in: menu).isEnabled)
        f.store.queue.suspend()
        var suspended = true
        defer { if suspended { f.store.queue.resume() } }
        try perform("header-new-tab", in: menu)
        terminal.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        terminal.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let markedRange = terminal.markedRange()
        XCTAssertTrue(terminal.hasMarkedText())
        suspended = false
        f.store.queue.resume()
        try await settle(f) {
            let backend = try f.runtime.state()
            return backend.layout.tabs.count == 3 && f.store.state.layout.tabs.count == 3
        }
        for _ in 0..<2 { f.store.refresh(); await drain(f.store) }
        try await Task.sleep(for: .milliseconds(100))
        f.window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertEqual(f.store.state.layout.selectedTabID, originalTab)
        XCTAssertTrue(f.store.terminalViews[f.panes[2]] === terminal)
        XCTAssertEqual(terminal.process.shellPid, clientPID)
        XCTAssertTrue(terminal.process.running)
        XCTAssertTrue(f.window.firstResponder === terminal)
        XCTAssertTrue(terminal.hasMarkedText())
        XCTAssertEqual(terminal.markedRange(), markedRange)
        let after = try pids(f)
        for (id, pid) in before { XCTAssertEqual(after[id], pid) }
        XCTAssertEqual(after.count, before.count + 1)
    }

    // Implements: FR-NAV-7, FR-INPUT-1
    @MainActor func testLateCompositionCancelsQueuedTabAndSessionClose() async throws {
        for action in ["header-close-tab", "header-close-session"] {
            let f = try await fixture()
            defer { dispose(f) }
            let before = try f.runtime.state().layout
            let backendPIDs = try pids(f)
            let terminal = try XCTUnwrap(f.store.terminalViews[f.panes[2]])
            let clientPID = terminal.process.shellPid
            XCTAssertTrue(f.window.makeFirstResponder(terminal))
            XCTAssertFalse(terminal.hasMarkedText())
            let menu = f.store.headerContextMenu(tabID: f.tabs[1], sourceWindow: f.window)
            XCTAssertTrue(try item(action, in: menu).isEnabled)
            f.store.queue.suspend()
            var suspended = true
            defer { if suspended { f.store.queue.resume() } }
            try perform(action, in: menu)
            terminal.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
            let markedRange = terminal.markedRange()
            XCTAssertTrue(terminal.hasMarkedText())
            suspended = false
            f.store.queue.resume()
            await drain(f.store)
            f.store.refresh()
            await drain(f.store)
            try await Task.sleep(for: .milliseconds(100))
            f.window.contentView?.layoutSubtreeIfNeeded()
            XCTAssertEqual(try f.runtime.state().layout, before, action)
            XCTAssertEqual(f.store.state.layout.selectedTabID, f.tabs[1], action)
            XCTAssertNotNil(f.store.state.layout.tabs.first { $0.id == f.tabs[1] }, action)
            XCTAssertTrue(f.store.terminalViews[f.panes[2]] === terminal, action)
            XCTAssertEqual(terminal.process.shellPid, clientPID, action)
            XCTAssertTrue(f.window.firstResponder === terminal, action)
            XCTAssertTrue(terminal.hasMarkedText(), action)
            XCTAssertEqual(terminal.markedRange(), markedRange, action)
            XCTAssertEqual(try pids(f), backendPIDs, action)
            XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive), action)
        }
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let workspace: String
        let tabs: [String]
        let panes: [String]
        let profile: AppearanceProfile
    }

    @MainActor private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-menu-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        var panes: [String] = []
        for index in 0..<3 { panes.append(try runtime.create(title: "Menu \(index)", cwd: root.path, shell: "/bin/sleep", arguments: ["90"]).id) }
        var workspace = "", tabs: [String] = []
        let profile = AppearanceProfile(name: "Reading", settings: TerminalSettings())
        try runtime.update { state in
            state.settings.automaticRestore = false
            state.settings.appearanceProfiles = [profile]
            state.settings.keyBindings[ActionID.newTab.rawValue] = ["cmd+shift+y"]
            workspace = state.layout.addWorkspace(title: "Menu Session")
            tabs.append(state.layout.addTab(paneID: panes[0]))
            try state.layout.split(tabID: tabs[0], paneID: panes[1], axis: .horizontal)
            tabs.append(state.layout.addTab(paneID: panes[2]))
        }
        let store = AppStore(runtime: runtime)
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), contentView: NSHostingView(rootView: WorkspaceView(store: store)))
        window.orderFrontRegardless()
        let f = Fixture(root: root, runtime: runtime, store: store, window: window, workspace: workspace, tabs: tabs, panes: panes, profile: profile)
        try await settle(f) { !store.loading && store.terminalViews[panes[2]]?.process.running == true }
        return f
    }

    @MainActor private func dispose(_ f: Fixture) {
        f.store.floatingPanes.closeAll()
        for view in f.store.terminalViews.values { view.terminate() }
        f.store.terminalViews.removeAll()
        f.window.contentView = nil
        f.window.close()
        for pane in (try? f.runtime.list()) ?? [] { try? f.runtime.terminate(pane.id) }
        f.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: f.root)
    }

    @MainActor private func settle(_ f: Fixture, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            f.window.contentView?.layoutSubtreeIfNeeded()
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTFail("Header menu did not settle: " + (f.store.message ?? "no error"))
    }

    @MainActor private func drain(_ store: AppStore) async {
        await withCheckedContinuation { continuation in
            store.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func pids(_ f: Fixture) throws -> [String: Int32] {
        Dictionary(uniqueKeysWithValues: try f.runtime.list().map { ($0.id, $0.pid) })
    }

    @MainActor private func find(_ id: String, in menu: NSMenu) -> (NSMenu, Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.identifier?.rawValue == id { return (menu, index) }
            if let submenu = item.submenu, let match = find(id, in: submenu) { return match }
        }
        return nil
    }

    @MainActor private func item(_ id: String, in menu: NSMenu) throws -> NSMenuItem {
        let (owner, index) = try XCTUnwrap(find(id, in: menu), "Missing menu item: " + id)
        return owner.item(at: index)!
    }

    @MainActor private func perform(_ id: String, in menu: NSMenu) throws {
        let (owner, index) = try XCTUnwrap(find(id, in: menu), "Missing menu action: " + id)
        owner.performActionForItem(at: index)
    }

    @MainActor private func regions(_ id: String, in view: NSView) -> [NSView] {
        (view.identifier?.rawValue == id ? [view] : []) + view.subviews.flatMap { regions(id, in: $0) }
    }

    @MainActor private func mouseEvent(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [], in view: NSView, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
}
