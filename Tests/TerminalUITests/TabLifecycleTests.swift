import AppKit
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

final class TabLifecycleTests: XCTestCase {
    // Implements: FR-NAV-2, U03
    @MainActor func testFindCommandKeepsFocusInItsSearchField() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-find-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "Find", cwd: root.path, shell: "/bin/sleep", arguments: ["60"])
        try runtime.update { $0.layout.addTab(paneID: pane.id) }
        let store = AppStore(runtime: runtime)
        let deadline = Date().addingTimeInterval(3)
        while store.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try XCTUnwrap(window.contentView)
        let terminal = TranoView(frame: content.bounds)
        terminal.paneID = pane.id
        store.terminalViews[pane.id] = terminal
        content.addSubview(terminal)
        defer {
            store.terminalViews.removeAll()
            window.close()
            try? runtime.terminate(pane.id)
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(window.makeFirstResponder(terminal))
        store.execute(.find)
        let search = try XCTUnwrap(window.firstResponder)
        XCTAssertFalse(search === terminal)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === search)
        for action in [ActionID.findNext, .findPrevious] {
            store.execute(action)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertTrue(window.firstResponder === search)
        }
    }

    // Implements: FR-NAV-2, U03
    @MainActor func testCommandSelectionReturnsFocusFromPickerToTerminal() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-focus-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let pane = try runtime.create(title: "Focus", cwd: root.path, arguments: ["-f"])
        try runtime.update { $0.layout.addTab(paneID: pane.id) }
        let store = AppStore(runtime: runtime)
        let deadline = Date().addingTimeInterval(3)
        while store.loading && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = try XCTUnwrap(window.contentView)
        let terminal = TranoView(frame: content.bounds)
        terminal.paneID = pane.id
        store.terminalViews[pane.id] = terminal
        content.addSubview(terminal)
        let field = NSTextField(string: "Clear Scrollback")
        field.frame = NSRect(x: 100, y: 100, width: 300, height: 24)
        content.addSubview(field)
        defer {
            store.terminalViews.removeAll()
            window.close()
            try? runtime.terminate(pane.id)
            try? FileManager.default.removeItem(at: root)
        }
        store.picker = .commands
        XCTAssertTrue(window.makeFirstResponder(field))
        XCTAssertFalse(window.firstResponder === terminal)
        store.picker = nil
        field.removeFromSuperview()
        store.execute(.clear)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(window.firstResponder === terminal)
    }

    // Implements: FR-NAV-1, FR-NAV-4, U09
    @MainActor func testNewTabsAndSwitchesPreservePaneRenderersAndProcesses() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-tabs-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let first = try runtime.create(title: "First", cwd: root.path, arguments: ["-f"])
        try runtime.update { $0.layout.addTab(paneID: first.id) }
        for name in ["HOME", "ZDOTDIR"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: runtime.executable)
            process.arguments = ["-S", runtime.socketPath, "set-environment", "-g", name, root.path]
            try process.run(); process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0)
        }
        let store = AppStore(runtime: runtime)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        window.contentView = hosting
        defer {
            let views = Array(store.terminalViews.values)
            store.terminalViews.removeAll()
            views.forEach { $0.terminate() }
            window.close()
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            try? FileManager.default.removeItem(at: root)
        }
        await settle(until: { !store.loading && store.terminalViews[first.id]?.process.running == true }, hosting: hosting)
        let firstView = try XCTUnwrap(store.terminalViews[first.id])
        let firstClientPID = firstView.process.shellPid
        XCTAssertGreaterThan(firstClientPID, 0)
        var views = [first.id: firstView]
        var clients = [first.id: firstClientPID]

        for count in 2...3 {
            store.newTab()
            await settle(until: { store.state.layout.tabs.count == count && store.focusedID != first.id }, hosting: hosting)
            let id = try XCTUnwrap(store.focusedID)
            await settle(until: { store.terminalViews[id]?.process.running == true }, hosting: hosting, timeout: 1)
            let visible = terminals(in: hosting)
            XCTAssertEqual(visible.count, 1)
            XCTAssertEqual(visible.first?.paneID, id, "A new tab must mount its own pane renderer")
            XCTAssertNotNil(store.terminalViews[id], "The new pane must have its own cache entry")
            if let view = store.terminalViews[id] {
                XCTAssertFalse(view === firstView)
                views[id] = view
                clients[id] = view.process.shellPid
            }
            XCTAssertEqual(firstView.paneID, first.id)
            XCTAssertEqual(firstView.process.shellPid, firstClientPID, "New Tab must not terminate the previous attach client")
        }

        let shells = Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) })
        for _ in 0..<2 {
            for tab in store.state.layout.tabs {
                store.selectTab(tab.id)
                await settle(until: { store.state.layout.selectedTabID == tab.id }, hosting: hosting)
                try await Task.sleep(for: .milliseconds(100))
                hosting.layoutSubtreeIfNeeded()
                let id = try XCTUnwrap(tab.panes.first)
                let visible = try XCTUnwrap(terminals(in: hosting).first)
                XCTAssertEqual(visible.paneID, id)
                XCTAssertTrue(visible === views[id])
                XCTAssertEqual(visible.process.shellPid, clients[id])
                XCTAssertFalse(String(decoding: visible.getBufferAsData(), as: UTF8.self).contains("[terminated]"))
            }
        }
        let after = try runtime.list()
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: after.map { ($0.id, $0.pid) }), shells)
        XCTAssertTrue(after.allSatisfy(\.alive))
        XCTAssertEqual(store.terminalViews.count, 3)
    }

    @MainActor private func settle(until predicate: () -> Bool, hosting: NSView, timeout: TimeInterval = 4) async {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            hosting.layoutSubtreeIfNeeded()
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTFail("Native tab state did not settle before deadline")
    }

    @MainActor private func terminals(in view: NSView) -> [TranoView] {
        (view as? TranoView).map { [$0] } ?? view.subviews.flatMap { terminals(in: $0) }
    }
}
