import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class WorkspaceMenuGeometryTests: XCTestCase {
    // Implements: FR-NAV-6, FR-NAV-8
    @MainActor func testWorkspaceMenuAttachesBelowSwitcherWithoutMovingTerminal() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        for size in [NSSize(width: 1000, height: 700), NSSize(width: 900, height: 620), NSSize(width: 1400, height: 900)] {
            f.window.setContentSize(size)
            try await layout(f)
            let terminal = try XCTUnwrap(f.store.terminalViews[f.panes[0]])
            let before = terminal.convert(terminal.bounds, to: f.content)
            f.store.picker = .sessions
            try await layout(f)
            let switcher = try XCTUnwrap(region("workspace-switcher", in: f.content))
            let picker = try XCTUnwrap(region("navigation-picker", in: f.content))
            let anchor = topRect(switcher, in: f.content)
            let menu = topRect(picker, in: f.content)
            XCTAssertTrue(picker.window === f.window)
            XCTAssertEqual(menu.minX, anchor.minX, accuracy: 0.5)
            XCTAssertEqual(menu.minY, anchor.maxY, accuracy: 0.5)
            XCTAssertLessThanOrEqual(menu.width, 360)
            XCTAssertLessThan(menu.height, 320, "A short workspace list should not reserve empty result space")
            XCTAssertTrue(f.content.bounds.contains(picker.convert(picker.bounds, to: f.content)))
            XCTAssertEqual(terminal.convert(terminal.bounds, to: f.content), before)
            if let path = ProcessInfo.processInfo.environment["TRANO_WORKSPACE_MENU_PREVIEW"], size.width == 1000 {
                let frame = try XCTUnwrap(f.content.superview)
                let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
                frame.cacheDisplay(in: frame.bounds, to: bitmap)
                try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
            }
            f.store.dismissPicker()
            try await layout(f)
        }
    }

    // Implements: FR-NAV-2, FR-NAV-6, FR-NAV-8, FR-INPUT-1
    @MainActor func testAttachedMenuKeepsKeyboardSelectionContextActionsAndDismissal() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let delegate = ApplicationDelegate()
        delegate.windows[f.window] = f.store
        f.store.picker = .sessions
        try await layout(f)
        let field = try XCTUnwrap(region("picker-search-field", in: f.content) as? PickerSearchTextField)
        XCTAssertTrue(f.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        XCTAssertFalse(try delegate.handle(key(53, characters: "\u{1b}", in: f.window)))
        XCTAssertEqual(editor.markedRange(), marked)
        editor.unmarkText()
        editor.selectAll(nil)
        editor.insertText("", replacementRange: editor.selectedRange())
        try await layout(f)
        let row = try XCTUnwrap(region("picker-workspace-context-" + f.workspaces[1], in: f.content))
        let rightClick = try XCTUnwrap(NSEvent.mouseEvent(with: .rightMouseDown, location: row.convert(NSPoint(x: 12, y: 12), to: nil), modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let menu = try XCTUnwrap(row.menu(for: rightClick))
        XCTAssertTrue(menu.items.contains { $0.identifier?.rawValue == "picker-rename-session" })
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await layout(f)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        let deadline = Date().addingTimeInterval(4)
        while f.store.state.layout.selectedWorkspaceID != f.workspaces[1], Date() < deadline { try await layout(f) }
        XCTAssertNil(f.store.picker)
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.workspaces[1])
        f.store.picker = .sessions
        try await layout(f)
        XCTAssertTrue(try delegate.handle(key(53, characters: "\u{1b}", in: f.window)))
        XCTAssertNil(f.store.picker)
        f.store.picker = .sessions
        try await layout(f)
        let outside = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 850, y: 100), modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(delegate.handle(outside))
        XCTAssertNil(f.store.picker)
        let live = try f.runtime.list()
        XCTAssertEqual(live.map(\.pid), f.pids)
        XCTAssertTrue(live.allSatisfy(\.alive))
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let content: NSHostingView<WorkspaceView>
        let window: NSWindow
        let panes: [String]
        let pids: [Int32]
        let workspaces: [String]
    }

    @MainActor private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-workspace-menu-" + UUID().uuidString)
        let runtime = try TerminalRuntime(root: root)
        let jobs = try ["amber-cedar", "quiet-river"].map { try runtime.create(title: $0, cwd: root.path, shell: "/bin/sleep", arguments: ["90"]) }
        var workspaces: [String] = []
        try runtime.update { state in
            state.settings.automaticRestore = false
            for job in jobs {
                state.layout.addWorkspace(title: job.title)
                workspaces.append(state.layout.selectedWorkspaceID!)
                state.layout.addTab(paneID: job.id)
            }
            try state.layout.selectWorkspace(workspaces[0])
        }
        let store = AppStore(runtime: runtime)
        let content = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700), contentView: content)
        window.setFrameOrigin(NSPoint(x: -14000, y: -14000))
        window.orderFrontRegardless()
        let f = Fixture(root: root, runtime: runtime, store: store, content: content, window: window, panes: jobs.map(\.id), pids: jobs.map(\.pid), workspaces: workspaces)
        let deadline = Date().addingTimeInterval(5)
        while (store.loading || store.terminalViews[jobs[0].id]?.process.running != true), Date() < deadline { try await layout(f) }
        XCTAssertFalse(store.loading)
        return f
    }

    @MainActor private func layout(_ f: Fixture) async throws {
        f.content.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        f.content.layoutSubtreeIfNeeded()
    }

    @MainActor private func dispose(_ f: Fixture) {
        f.store.picker = nil
        f.window.close()
        for view in f.store.terminalViews.values { view.terminate() }
        for pane in f.panes { try? f.runtime.terminate(pane) }
        try? FileManager.default.removeItem(at: f.root)
    }

    @MainActor private func key(_ code: UInt16, characters: String, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code))
    }

    @MainActor private func topRect(_ view: NSView, in host: NSView) -> NSRect {
        let rect = view.convert(view.bounds, to: host)
        return NSRect(x: rect.minX, y: host.isFlipped ? rect.minY : host.bounds.maxY - rect.maxY, width: rect.width, height: rect.height)
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }
}
