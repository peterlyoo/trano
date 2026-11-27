import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class WorkspacePickerShortcutTests: XCTestCase {
    // Implements: FR-NAV-1, FR-NAV-2, FR-NAV-6
    @MainActor func testNewWorkspaceShortcutWorksFromTheSearchEditorAndUsesRandomLowercaseName() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        for query in ["", "Do not use this query as the new workspace name"] {
            let previous = try f.runtime.state()
            let editor = try await openPicker(f, query: query)
            XCTAssertTrue(f.window.firstResponder === editor)
            let handled = f.delegate.handle(try key("n", flags: [.command, .shift], code: 45, in: f.window))
            XCTAssertTrue(handled, "The workspace picker must route the configured New Session shortcut")
            guard handled else { return }
            XCTAssertNil(f.store.picker)
            try await settle(f) { f.store.state.layout.workspaces.count == previous.layout.workspaces.count + 1 }
            let state = try f.runtime.state()
            let created = try XCTUnwrap(state.layout.workspaces.first { workspace in !previous.layout.workspaces.contains { $0.id == workspace.id } })
            XCTAssertNotNil(created.title.range(of: "^[a-z]+-[a-z]+(?:-[0-9]+)?$", options: .regularExpression))
            XCTAssertNotEqual(created.title, query)
            XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, created.id)
            let tab = try XCTUnwrap(state.layout.currentTabs.first)
            XCTAssertEqual(tab.panes.count, 1)
            try await settle(f) { f.store.terminalViews[tab.panes[0]]?.window === f.window }
            let current = try f.runtime.list()
            XCTAssertEqual(current.first { $0.id == f.originalPane.id }?.pid, f.originalPane.pid)
            XCTAssertTrue(current.first { $0.id == f.originalPane.id }?.alive == true)
            XCTAssertEqual(current.count, previous.sessions.count + 1)
        }
    }

    // Implements: FR-NAV-2, FR-INPUT-1
    @MainActor func testMarkedTextAndOtherPickerKindsDoNotCreateAWorkspace() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let editor = try await openPicker(f, query: "검색")
        let before = try f.runtime.state().layout
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let text = Data(editor.string.utf8)
        XCTAssertFalse(f.delegate.handle(try key("n", flags: [.command, .shift], code: 45, in: f.window)))
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(Data(editor.string.utf8), text)
        XCTAssertEqual(f.store.picker, .sessions)
        editor.unmarkText()
        for kind in [AppStore.PickerKind.commands, .anything, .movePane] {
            f.store.picker = kind
            try await layout(f)
            XCTAssertFalse(f.delegate.handle(try key("n", flags: [.command, .shift], code: 45, in: f.window)))
            XCTAssertEqual(f.store.picker, kind)
        }
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertEqual(try f.runtime.list().count, 1)
    }

    // Implements: FR-NAV-2
    @MainActor func testWorkspacePickerHonorsNewSessionOverrideAndIgnoresUnrelatedShortcutsAndRepeats() async throws {
        let f = try await fixture(newSessionShortcut: "cmd+shift+y")
        defer { dispose(f) }
        let editor = try await openPicker(f, query: "Keep this input")
        let before = try f.runtime.state().layout
        let unrelated: [(String, NSEvent.ModifierFlags, UInt16)] = [("n", [.command, .shift], 45), ("t", .command, 17)]
        for (keyName, flags, code) in unrelated {
            XCTAssertFalse(f.delegate.handle(try key(keyName, flags: flags, code: code, in: f.window)))
            XCTAssertEqual(f.store.picker, .sessions)
            XCTAssertEqual(editor.string, "Keep this input")
        }
        XCTAssertTrue(f.delegate.handle(try key("y", flags: [.command, .shift], code: 16, repeatKey: true, in: f.window)))
        try await layout(f)
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertEqual(f.store.picker, .sessions)
        let handled = f.delegate.handle(try key("y", flags: [.command, .shift], code: 16, in: f.window))
        XCTAssertTrue(handled)
        guard handled else { return }
        try await settle(f) { f.store.state.layout.workspaces.count == before.workspaces.count + 1 }
        XCTAssertNil(f.store.picker)
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let originalPane: TerminalSession
        let store: AppStore
        let window: NSWindow
        let content: NSHostingView<WorkspaceView>
        let delegate: ApplicationDelegate
    }

    @MainActor private func fixture(newSessionShortcut: String? = nil) async throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-picker-shortcut-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.setPaneEnvironment(["HOME", "ZDOTDIR", "CLAUDE_CONFIG_DIR", "CODEX_HOME"].map { ($0, root.path) })
        let original = try runtime.create(title: "Existing terminal", cwd: root.path, shell: "/bin/sleep", arguments: ["90"])
        try runtime.update { state in
            state.settings.automaticRestore = false
            if let newSessionShortcut { state.settings.keyBindings[ActionID.newSession.rawValue] = [newSessionShortcut] }
            state.layout.addWorkspace(title: "existing-workspace")
            state.layout.addTab(paneID: original.id)
        }
        let store = AppStore(runtime: runtime, recoverOnStartup: false)
        let content = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), contentView: content)
        window.setFrameOrigin(NSPoint(x: -14000, y: -14000))
        window.orderFrontRegardless()
        let delegate = ApplicationDelegate()
        delegate.store = store; delegate.window = window
        delegate.windows[window] = store
        delegate.observeSettings(store, window: window)
        let f = Fixture(root: root, runtime: runtime, originalPane: original, store: store, window: window, content: content, delegate: delegate)
        try await settle(f) { !store.loading && store.terminalViews[original.id]?.process.running == true }
        return f
    }

    @MainActor private func openPicker(_ f: Fixture, query: String) async throws -> NSTextView {
        if let terminal = f.store.focusedID.flatMap({ f.store.terminalViews[$0] }) { f.window.makeFirstResponder(terminal) }
        XCTAssertTrue(f.delegate.handle(try key("k", flags: .command, code: 40, in: f.window)))
        XCTAssertEqual(f.store.picker, .sessions)
        try await layout(f)
        let field = try XCTUnwrap(region("picker-search-field", in: f.content) as? PickerSearchTextField)
        XCTAssertTrue(f.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText(query, replacementRange: editor.selectedRange())
        try await layout(f)
        return editor
    }

    @MainActor private func key(_ characters: String, flags: NSEvent.ModifierFlags, code: UInt16, repeatKey: Bool = false, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters.uppercased(), charactersIgnoringModifiers: characters, isARepeat: repeatKey, keyCode: code))
    }

    @MainActor private func settle(_ f: Fixture, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !predicate() && Date() < deadline { try await layout(f) }
        XCTAssertTrue(predicate(), "Workspace shortcut did not settle")
    }

    @MainActor private func layout(_ f: Fixture) async throws {
        f.content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(60))
        f.content.layoutSubtreeIfNeeded()
    }

    @MainActor private func dispose(_ f: Fixture) {
        f.store.picker = nil
        f.window.close()
        for terminal in f.store.terminalViews.values { terminal.terminate() }
        for pane in (try? f.runtime.list()) ?? [] { try? f.runtime.terminate(pane.id) }
        f.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: f.root)
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }
}
