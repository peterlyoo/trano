import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class SessionPickerMenuTests: XCTestCase {
    // Implements: FR-NAV-8
    @MainActor func testNativeRowMenusKeepLeftClickAndSyntheticRowsUnchanged() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let editor = try await query("", in: f)
        let overlay = try XCTUnwrap(region("picker-workspace-context-" + f.workspaces[1], in: f.content))
        XCTAssertNil(overlay.hitTest(NSPoint(x: overlay.frame.midX, y: overlay.frame.midY)))
        XCTAssertNil(overlay.menu(for: try mouseEvent(.leftMouseDown, in: overlay, window: f.window)))
        for (type, modifiers) in [(NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()), (.leftMouseDown, .control)] {
            let menu = try XCTUnwrap(overlay.menu(for: mouseEvent(type, modifiers: modifiers, in: overlay, window: f.window)))
            for (id, title) in actions {
                let action = try item(id, in: menu)
                XCTAssertEqual(action.title, title)
                XCTAssertTrue(action.target === action)
                XCTAssertTrue(action.isEnabled)
            }
        }
        let first = f.store.workspacePickerContextMenu(workspaceID: f.workspaces[0], sourceWindow: f.window)
        let last = f.store.workspacePickerContextMenu(workspaceID: f.workspaces[2], sourceWindow: f.window)
        XCTAssertFalse(try item("picker-move-session-up", in: first).isEnabled)
        XCTAssertFalse(try item("picker-move-session-down", in: last).isEnabled)
        XCTAssertEqual(contextRegions(in: f.content).count, 3, "New Session must have no management menu")
        assertInput(f, editor: editor, query: "")
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.workspaces[0])

        _ = try await query("Missing workspace", in: f)
        XCTAssertTrue(contextRegions(in: f.content).isEmpty, "Create row must have no management menu")
        let cached = f.store.workspacePickerContextMenu(workspaceID: f.workspaces[1], sourceWindow: f.window)
        let before = try f.runtime.state().layout
        for kind in [AppStore.PickerKind.commands, .anything, .movePane] {
            f.store.picker = kind
            try await layout(f)
            XCTAssertTrue(contextRegions(in: f.content).isEmpty)
            XCTAssertTrue(f.store.workspacePickerContextMenu(workspaceID: f.workspaces[1], sourceWindow: f.window).items.allSatisfy { !$0.isEnabled })
            try perform("picker-close-session", in: cached)
            try perform("picker-move-session-up", in: cached)
            await drain(f.store)
            XCTAssertEqual(try f.runtime.state().layout, before)
        }
    }

    // Implements: FR-NAV-8, FR-NAV-4
    @MainActor func testInactiveMovePersistsAcrossClosedSlotsAndKeepsKeyboardTarget() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        var hidden = WorkspaceRecord(title: "Hidden retained workspace")
        hidden.closed = true
        try f.runtime.update { $0.layout.workspaces.insert(hidden, at: 1) }
        f.store.refresh()
        await drain(f.store)
        let editor = try await query("Session", in: f)
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await layout(f)
        XCTAssertEqual(selectedTitle(f), "Session Beta")
        let before = try f.runtime.state().layout
        let jobs = try pids(f)
        let terminal = try XCTUnwrap(f.store.terminalViews[f.panes[0]])
        let clientPID = terminal.process.shellPid
        let betaBefore = try sidebarY(f.workspaces[1], in: f)
        let gammaBefore = try sidebarY(f.workspaces[2], in: f)
        let menu = f.store.workspacePickerContextMenu(workspaceID: f.workspaces[2], sourceWindow: f.window)
        f.store.showSessionsSidebar.toggle()
        f.store.showSessionsSidebar.toggle()
        try await layout(f)
        try perform("picker-move-session-up", in: menu)
        let expected = [f.workspaces[0], hidden.id, f.workspaces[2], f.workspaces[1]]
        try await settle(f) { f.store.state.layout.workspaces.map(\.id) == expected }
        XCTAssertEqual(try TerminalRuntime(root: f.root).state().layout.workspaces.map(\.id), expected)
        XCTAssertEqual(try f.runtime.state().layout.tabs, before.tabs)
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, before.selectedWorkspaceID)
        XCTAssertEqual(f.store.state.layout.selectedTabID, before.selectedTabID)
        XCTAssertEqual(f.store.focusedID, before.focusedPaneID)
        XCTAssertTrue(f.store.terminalViews[f.panes[0]] === terminal)
        XCTAssertEqual(terminal.process.shellPid, clientPID)
        XCTAssertEqual(try pids(f), jobs)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
        assertInput(f, editor: editor, query: "Session")
        XCTAssertEqual(selectedTitle(f), "Session Beta")
        XCTAssertLessThan((betaBefore - gammaBefore) * (try sidebarY(f.workspaces[1], in: f) - sidebarY(f.workspaces[2], in: f)), 0)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle(f) { f.store.picker == nil && f.store.state.layout.selectedWorkspaceID == f.workspaces[1] }
        XCTAssertEqual(try pids(f), jobs)
    }

    // Implements: FR-NAV-8, FR-NAV-4
    @MainActor func testInactiveRenamePreservesSearchAndTheSelectedEntryIdentity() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let editor = try await query("Session", in: f)
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await layout(f)
        let before = try f.runtime.state().layout
        let jobs = try pids(f)
        f.store.commitPickerWorkspaceRename(f.workspaces[1], name: "Session Beta Renamed")
        try await settle(f) { f.store.state.layout.workspaces.first { $0.id == f.workspaces[1] }?.title == "Session Beta Renamed" }
        XCTAssertEqual(try f.runtime.state().layout.workspaces.first { $0.id == f.workspaces[0] }?.title, "Session Alpha")
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, before.selectedWorkspaceID)
        XCTAssertEqual(f.store.state.layout.selectedTabID, before.selectedTabID)
        XCTAssertEqual(try f.runtime.state().layout.tabs, before.tabs)
        XCTAssertEqual(try pids(f), jobs)
        assertInput(f, editor: editor, query: "Session")
        XCTAssertEqual(selectedTitle(f), "Session Beta Renamed")
        _ = try await query("Beta Renamed", in: f)
        XCTAssertNotNil(region("picker-workspace-context-" + f.workspaces[1], in: f.content))
        XCTAssertNil(region("picker-workspace-context-" + f.workspaces[0], in: f.content))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle(f) { f.store.picker == nil && f.store.state.layout.selectedWorkspaceID == f.workspaces[1] }
        XCTAssertEqual(try pids(f), jobs)
    }

    // Implements: FR-NAV-8, FR-NAV-4
    @MainActor func testClosingInactiveCurrentAndFinalRowsRetainsPickerAndAllJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let editor = try await query("Session", in: f)
        let before = try f.runtime.state().layout.tabs
        let jobs = try pids(f)
        for (index, selected) in [(1, Optional(f.workspaces[0])), (0, Optional(f.workspaces[2])), (2, nil)] {
            let id = f.workspaces[index]
            try perform("picker-close-session", in: f.store.workspacePickerContextMenu(workspaceID: id, sourceWindow: f.window))
            try await settle(f) { f.store.state.layout.workspaces.first { $0.id == id }?.closed == true && f.store.state.layout.selectedWorkspaceID == selected }
            assertInput(f, editor: editor, query: "Session")
            let closed = f.store.workspacePickerContextMenu(workspaceID: id, sourceWindow: f.window)
            for action in ["picker-close-session", "picker-move-session-up", "picker-move-session-down"] {
                XCTAssertFalse(try item(action, in: closed).isEnabled)
            }
        }
        for _ in 0..<2 { f.store.refresh(); await drain(f.store) }
        XCTAssertNil(f.store.state.layout.selectedWorkspaceID)
        XCTAssertTrue(try f.runtime.state().layout.workspaces.allSatisfy(\.closed))
        XCTAssertEqual(try f.runtime.state().layout.tabs, before)
        XCTAssertEqual(try pids(f), jobs)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
        assertInput(f, editor: editor, query: "Session")
    }

    // Implements: FR-NAV-8, FR-INPUT-1
    @MainActor func testMarkedSearchTextBlocksFreshCachedAndQueuedActions() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let editor = try await query("Session", in: f)
        let before = try f.runtime.state().layout
        let jobs = try pids(f)
        let cached = f.store.workspacePickerContextMenu(workspaceID: f.workspaces[1], sourceWindow: f.window)
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange(), bytes = Data(editor.string.utf8)
        let fresh = f.store.workspacePickerContextMenu(workspaceID: f.workspaces[1], sourceWindow: f.window)
        for (id, _) in actions { XCTAssertFalse(try item(id, in: fresh).isEnabled) }
        for id in ["picker-close-session", "picker-move-session-up", "picker-move-session-down"] { try perform(id, in: cached) }
        await drain(f.store)
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(Data(editor.string.utf8), bytes)
        XCTAssertTrue(f.window.firstResponder === editor)

        editor.unmarkText()
        _ = try await query("Session", in: f)
        let queued = f.store.workspacePickerContextMenu(workspaceID: f.workspaces[1], sourceWindow: f.window)
        f.store.queue.suspend()
        var suspended = true
        defer { if suspended { f.store.queue.resume() } }
        try perform("picker-close-session", in: queued)
        try perform("picker-move-session-down", in: queued)
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let lateMarked = editor.markedRange(), lateBytes = Data(editor.string.utf8)
        suspended = false
        f.store.queue.resume()
        await drain(f.store)
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertEqual(try pids(f), jobs)
        XCTAssertEqual(f.store.picker, .sessions)
        XCTAssertTrue(f.window.firstResponder === editor)
        XCTAssertEqual(editor.markedRange(), lateMarked)
        XCTAssertEqual(Data(editor.string.utf8), lateBytes)
        editor.unmarkText()
    }

    // Implements: FR-NAV-8, FR-INPUT-1
    @MainActor func testCompositionBeforePendingMutationCancelsAfterTheInitialActionGate() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let editor = try await query("Session", in: f)
        let targetID = f.workspaces[1]
        let before = try f.runtime.state().layout
        let jobs = try pids(f)
        let release = DispatchSemaphore(value: 0)
        var released = false
        defer { if !released { release.signal() } }
        try perform("picker-close-session", in: f.store.workspacePickerContextMenu(workspaceID: targetID, sourceWindow: f.window))
        await withCheckedContinuation { (started: CheckedContinuation<Void, Never>) in
            f.store.queue.async {
                started.resume()
                _ = release.wait(timeout: .now() + 5)
            }
        }
        try await Task.sleep(for: .milliseconds(80))
        let atBarrier = try f.runtime.state().layout
        let committed = atBarrier.workspaces.first { $0.id == targetID }?.closed == true
        var expected = before
        if committed { expected.closeWorkspace(targetID) }
        XCTAssertEqual(atBarrier, expected)
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange(), bytes = Data(editor.string.utf8)
        released = true
        release.signal()
        await drain(f.store)
        try await layout(f)
        XCTAssertEqual(try f.runtime.state().layout, expected, committed ? "Completed close must remain committed" : "Composition must cancel a close still waiting to mutate")
        XCTAssertEqual(try pids(f), jobs)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
        XCTAssertEqual(f.store.picker, .sessions)
        XCTAssertTrue(f.window.firstResponder === editor)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(Data(editor.string.utf8), bytes)
        editor.unmarkText()
    }

    // Implements: FR-NAV-8, FR-NAV-4
    @MainActor func testQueuedActionsRevalidateDeletedAndClosedWorkspaceIDs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let editor = try await query("Session", in: f)
        let jobs = try pids(f)
        f.store.queue.suspend()
        var suspended = true
        defer { if suspended { f.store.queue.resume() } }
        let deleted = f.store.workspacePickerContextMenu(workspaceID: f.workspaces[1], sourceWindow: f.window)
        try perform("picker-close-session", in: deleted)
        try perform("picker-move-session-up", in: deleted)
        f.store.commitPickerWorkspaceRename(f.workspaces[1], name: "Wrong target")
        try f.runtime.update { state in
            state.layout.workspaces.removeAll { $0.id == f.workspaces[1] }
            state.layout.tabs.removeAll { $0.workspaceID == f.workspaces[1] }
        }
        let removed = try f.runtime.state().layout
        suspended = false
        f.store.queue.resume()
        await drain(f.store)
        XCTAssertEqual(try f.runtime.state().layout, removed)

        f.store.refresh()
        await drain(f.store)
        f.store.queue.suspend()
        suspended = true
        let closed = f.store.workspacePickerContextMenu(workspaceID: f.workspaces[2], sourceWindow: f.window)
        try perform("picker-close-session", in: closed)
        try perform("picker-move-session-up", in: closed)
        try f.runtime.update { $0.layout.closeWorkspace(f.workspaces[2]) }
        let retained = try f.runtime.state().layout
        suspended = false
        f.store.queue.resume()
        await drain(f.store)
        XCTAssertEqual(try f.runtime.state().layout, retained)
        f.store.refresh()
        await drain(f.store)
        f.store.commitPickerWorkspaceRename(f.workspaces[2], name: "Closed retained session")
        await drain(f.store)
        let after = try f.runtime.state().layout
        XCTAssertEqual(after.selectedWorkspaceID, f.workspaces[0])
        XCTAssertTrue(try XCTUnwrap(after.workspaces.first { $0.id == f.workspaces[2] }).closed)
        XCTAssertEqual(after.workspaces.first { $0.id == f.workspaces[0] }?.title, "Session Alpha")
        XCTAssertEqual(after.tabs, retained.tabs)
        XCTAssertEqual(try pids(f), jobs)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
        assertInput(f, editor: editor, query: "Session")
    }

    private let actions = [("picker-rename-session", "Rename Session…"), ("picker-close-session", "Close Session"),
                           ("picker-move-session-up", "Move Up"), ("picker-move-session-down", "Move Down")]

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let workspaces: [String]
        let panes: [String]
        @MainActor var content: NSView { window.contentView! }
    }

    @MainActor private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-pm-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let panes = try (0..<3).map { try runtime.create(title: "Picker pane \($0)", cwd: root.path, shell: "/bin/sleep", arguments: ["120"]).id }
        var workspaces: [String] = []
        try runtime.update { state in
            state.settings.automaticRestore = false
            state.layout = WorkspaceLayout()
            for (index, title) in ["Session Alpha", "Session Beta", "Session Gamma"].enumerated() {
                workspaces.append(state.layout.addWorkspace(title: title))
                state.layout.addTab(paneID: panes[index])
            }
            try state.layout.selectWorkspace(workspaces[0])
        }
        let store = AppStore(runtime: runtime)
        store.showSessionsSidebar = true
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), contentView: NSHostingView(rootView: WorkspaceView(store: store)))
        window.orderFrontRegardless()
        let f = Fixture(root: root, runtime: runtime, store: store, window: window, workspaces: workspaces, panes: panes)
        try await settle(f) { !store.loading && store.terminalViews[panes[0]]?.process.running == true }
        store.picker = .sessions
        try await settle(f) { self.region("picker-search-field", in: f.content) != nil }
        try await layout(f)
        return f
    }

    @MainActor private func query(_ text: String, in f: Fixture) async throws -> NSTextView {
        let field = try XCTUnwrap(region("picker-search-field", in: f.content) as? NSTextField)
        XCTAssertTrue(f.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.selectAll(nil)
        editor.insertText(text, replacementRange: editor.selectedRange())
        try await layout(f)
        XCTAssertEqual(editor.string, text)
        return editor
    }

    @MainActor private func assertInput(_ f: Fixture, editor: NSTextView, query: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(f.store.picker, .sessions, file: file, line: line)
        XCTAssertEqual(Data(editor.string.utf8), Data(query.utf8), file: file, line: line)
        XCTAssertTrue(f.window.firstResponder === editor, file: file, line: line)
        XCTAssertTrue((region("picker-search-field", in: f.content) as? NSTextField)?.currentEditor() === editor, file: file, line: line)
        XCTAssertNil(f.store.message, file: file, line: line)
    }

    @MainActor private func selectedTitle(_ f: Fixture) -> String? {
        region("picker-selected-command", in: f.content)?.accessibilityLabel()
    }

    @MainActor private func sidebarY(_ id: String, in f: Fixture) throws -> CGFloat {
        let row = try XCTUnwrap(region("sidebar-workspace-" + id, in: f.content))
        return row.convert(row.bounds, to: f.content).midY
    }

    @MainActor private func item(_ id: String, in menu: NSMenu) throws -> NSMenuItem {
        try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == id }, "Missing picker menu item: " + id)
    }

    @MainActor private func perform(_ id: String, in menu: NSMenu) throws {
        let action = try item(id, in: menu)
        menu.performActionForItem(at: menu.index(of: action))
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }

    @MainActor private func contextRegions(in view: NSView) -> [NSView] {
        ((view.identifier?.rawValue.hasPrefix("picker-workspace-context-") == true) ? [view] : []) + view.subviews.flatMap { contextRegions(in: $0) }
    }

    @MainActor private func mouseEvent(_ type: NSEvent.EventType, modifiers: NSEvent.ModifierFlags = [], in view: NSView, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @MainActor private func settle(_ f: Fixture, _ condition: () throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            f.content.layoutSubtreeIfNeeded()
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTFail("Picker menu operation did not settle: " + (f.store.message ?? "no error"))
    }

    @MainActor private func layout(_ f: Fixture) async throws {
        try await Task.sleep(for: .milliseconds(80))
        f.content.layoutSubtreeIfNeeded()
    }

    @MainActor private func drain(_ store: AppStore) async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in
                store.queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
        }
    }

    @MainActor private func pids(_ f: Fixture) throws -> [String: Int32] {
        Dictionary(uniqueKeysWithValues: try f.runtime.list().map { ($0.id, $0.pid) })
    }

    @MainActor private func dispose(_ f: Fixture) {
        f.store.picker = nil
        f.store.floatingPanes.closeAll()
        for view in f.store.terminalViews.values { view.terminate() }
        f.store.terminalViews.removeAll()
        f.window.contentView = nil
        f.window.close()
        for pane in (try? f.runtime.list()) ?? [] { try? f.runtime.terminate(pane.id) }
        f.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: f.root)
    }
}
