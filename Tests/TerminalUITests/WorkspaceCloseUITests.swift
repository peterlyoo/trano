import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class WorkspaceCloseUITests: XCTestCase {
    // Implements: FR-NAV-2, FR-NAV-4
    @MainActor func testCmdShiftTRevivesClosedWorkspaceWithItsOriginalTabsAndJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let original = try XCTUnwrap(f.source.selectedTab)
        let tabs = try f.runtime.state().layout.tabs
        let jobs = try f.runtime.list().map(\.pid)
        f.source.closeWorkspace(f.alpha)
        try await settle(f) { f.source.state.layout.selectedWorkspaceID == f.beta }
        XCTAssertTrue(f.delegate.handle(try shortcut("t", code: 17, flags: [.command, .shift], in: f.window)))
        try await settle(f) { f.source.state.layout.selectedWorkspaceID == f.alpha }
        XCTAssertFalse(try XCTUnwrap(f.source.state.layout.workspaces.first { $0.id == f.alpha }).closed)
        XCTAssertEqual(f.source.selectedTab?.id, original.id)
        XCTAssertEqual(f.source.selectedTab?.tree, original.tree)
        XCTAssertEqual(try f.runtime.state().layout.tabs, tabs)
        XCTAssertEqual(try f.runtime.list().map(\.pid), jobs)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-2, FR-NAV-4
    @MainActor func testCmdShiftTReopensTheLastClosedSplitPaneWithoutRestartingJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let tab = try XCTUnwrap(f.source.selectedTab)
        let pids = try f.runtime.list().map(\.pid)
        let survivor = try XCTUnwrap(f.source.terminalViews[f.panes[0]])
        let client = survivor.process.shellPid
        XCTAssertTrue(f.delegate.handle(try shortcut("w", code: 13, flags: .command, in: f.window)))
        try await settle(f) { f.source.selectedTab?.panes == [f.panes[0]] }
        XCTAssertTrue(f.delegate.handle(try shortcut("t", code: 17, flags: [.command, .shift], in: f.window)))
        await drain(f.source)
        XCTAssertEqual(f.source.selectedTab?.id, tab.id)
        XCTAssertEqual(f.source.selectedTab?.tree, tab.tree)
        XCTAssertEqual(f.source.focusedID, f.panes[1])
        XCTAssertTrue(f.source.terminalViews[f.panes[0]] === survivor)
        XCTAssertEqual(survivor.process.shellPid, client)
        XCTAssertEqual(try f.runtime.list().map(\.pid), pids)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-2, FR-NAV-4
    @MainActor func testCmdShiftTRestoresTabsInCloseOrderEvenFromAnEmptyWindow() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let first = try XCTUnwrap(f.source.selectedTab)
        let second = try XCTUnwrap(f.source.state.layout.tabs.first { $0.workspaceID == f.beta })
        let pids = try f.runtime.list().map(\.pid)
        f.source.execute(.closeTab)
        try await settle(f) { f.source.selectedTab?.id == second.id }
        XCTAssertTrue(f.delegate.handle(try shortcut("w", code: 13, flags: .command, in: f.window)))
        try await settle(f) { f.source.selectedTab == nil }
        for tab in [second, first] {
            XCTAssertTrue(f.delegate.handle(try shortcut("t", code: 17, flags: [.command, .shift], in: f.window)))
            try await settle(f) { f.source.selectedTab?.id == tab.id }
            XCTAssertEqual(f.source.selectedTab?.tree, tab.tree)
            try await settle(f) { f.source.terminalViews[tab.focusedPaneID!]?.window === f.window && f.window.firstResponder === f.source.terminalViews[tab.focusedPaneID!] }
        }
        let restored = try f.runtime.state().layout
        XCTAssertTrue(f.delegate.handle(try shortcut("t", code: 17, flags: [.command, .shift], in: f.window)))
        await drain(f.source)
        XCTAssertEqual(try f.runtime.state().layout, restored)
        XCTAssertEqual(try f.runtime.list().map(\.pid), pids)
    }

    // Implements: FR-NAV-2, FR-NAV-4, FR-INPUT-1
    @MainActor func testQueuedReopenDoesNotConsumeHistoryIfCompositionStartsBeforeCommit() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        f.source.execute(.closeTab)
        try await settle(f) { f.source.state.layout.selectedWorkspaceID == f.beta }
        let before = try f.runtime.state().layout
        let terminal = try XCTUnwrap(f.source.terminalViews[f.panes[2]])
        f.source.queue.suspend()
        XCTAssertTrue(f.delegate.handle(try shortcut("t", code: 17, flags: [.command, .shift], in: f.window)))
        terminal.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        f.source.queue.resume()
        await drain(f.source)
        XCTAssertTrue(terminal.hasMarkedText())
        XCTAssertEqual(try f.runtime.state().layout, before)
        terminal.unmarkText()
    }

    // Implements: FR-NAV-4, FR-NAV-6
    @MainActor func testQueuedKeyboardClosePreservesInputThatStartsCompositionBeforeCommit() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try f.runtime.state().layout
        f.source.queue.suspend()
        var suspended = true
        defer { if suspended { f.source.queue.resume() } }
        f.source.execute(.closePane)
        let editor = NSTextView(frame: NSRect(x: 20, y: 20, width: 200, height: 40))
        f.window.contentView?.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(editor.hasMarkedText())
        suspended = false
        f.source.queue.resume()
        await withCheckedContinuation { continuation in
            f.source.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }

        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertTrue(f.window.firstResponder === editor)
        XCTAssertTrue(editor.hasMarkedText())
        editor.unmarkText()
    }

    // Implements: FR-NAV-4, FR-NAV-6
    @MainActor func testQueuedCloseCannotRetargetTheNextWorkspaceAfterItsOriginalWorkspaceCloses() async throws {
        for action in [ActionID.closePane, .closeTab] {
            let f = try await fixture()
            defer { dispose(f) }
            let before = try f.runtime.list().map(\.pid)
            let successorTab = try XCTUnwrap(f.source.state.layout.tabs.first { $0.workspaceID == f.beta })
            f.mirror.queue.suspend()
            var suspended = true
            defer { if suspended { f.mirror.queue.resume() } }
            f.mirror.execute(action)
            f.source.closeWorkspace(f.alpha)
            try await settle(f) { f.source.state.layout.workspaces.first { $0.id == f.alpha }?.closed == true }
            suspended = false
            f.mirror.queue.resume()
            await withCheckedContinuation { continuation in
                f.mirror.queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
            f.mirror.refresh()
            try await Task.sleep(for: .milliseconds(150))

            XCTAssertTrue(try f.runtime.state().layout.tabs.contains { $0.id == successorTab.id }, action.rawValue)
            XCTAssertEqual(f.mirror.state.layout.selectedWorkspaceID, f.beta)
            XCTAssertEqual(try f.runtime.list().map(\.pid), before)
            XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
        }
    }

    // Implements: FR-NAV-4, FR-NAV-6
    @MainActor func testLastTabCloseAdvancesBothMirrorsWithoutClosingWindowsOrJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let tab = try XCTUnwrap(f.source.selectedTab?.id)
        let before = try f.runtime.list().map(\.pid)
        f.source.perform { try $0.update { $0.layout.closeTab(tab) } }
        try await settle(f) { f.source.selectedTab?.id != tab && !f.source.loading }
        for _ in 0..<3 { f.source.refresh(); f.mirror.refresh(); try await Task.sleep(for: .milliseconds(100)) }

        XCTAssertEqual(f.source.state.layout.selectedWorkspaceID, f.beta)
        XCTAssertEqual(f.mirror.state.layout.selectedWorkspaceID, f.beta)
        XCTAssertTrue(f.source.state.layout.workspaces.first { $0.id == f.alpha }?.closed == true)
        XCTAssertEqual(f.source.focusedID, f.panes[2])
        XCTAssertTrue(f.window.isVisible)
        XCTAssertTrue(f.mirrorWindow.isVisible)
        XCTAssertEqual(f.delegate.windows.count, 2)
        XCTAssertEqual(try f.runtime.list().map(\.pid), before)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-4, FR-NAV-6
    @MainActor func testCommandWClosesOnePaneThenAdvancesAfterTheLastPaneWithoutClosingWindow() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try f.runtime.list().map(\.pid)
        var windowCloses = 0
        f.source.onCloseWindow = { windowCloses += 1 }
        let focused = try XCTUnwrap(f.source.focusedID)
        try await settle(f) { f.source.terminalViews[focused]?.window === f.window }
        XCTAssertTrue(f.window.makeFirstResponder(try XCTUnwrap(f.source.terminalViews[focused])))
        f.source.execute(.closePane)
        try await settle(f) { f.source.selectedTab?.panes.count == 1 && f.window.firstResponder === f.source.terminalViews[f.panes[0]] }
        XCTAssertEqual(f.source.state.layout.selectedWorkspaceID, f.alpha)
        let sibling = try XCTUnwrap(f.source.terminalViews[f.panes[0]])
        XCTAssertTrue(f.window.firstResponder === sibling, "Keyboard close must hand input to the surviving pane")
        f.source.execute(.closePane)
        try await settle(f) { f.source.focusedID != f.panes[0] }
        try await settle(f) { f.source.terminalViews[f.panes[2]]?.window === f.window && f.window.firstResponder === f.source.terminalViews[f.panes[2]] }

        XCTAssertEqual(f.source.state.layout.selectedWorkspaceID, f.beta)
        XCTAssertEqual(f.source.focusedID, f.panes[2])
        XCTAssertTrue(f.window.firstResponder === f.source.terminalViews[f.panes[2]], "Last-tab close must hand input to the next workspace")
        XCTAssertEqual(windowCloses, 0)
        XCTAssertTrue(f.window.isVisible)
        XCTAssertEqual(try f.runtime.list().map(\.pid), before)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-4, FR-NAV-6, FR-NAV-7
    @MainActor func testNativeMenuLastTabCloseAdvancesAndRestoreKeepsOriginalPaneIdentities() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let tab = try XCTUnwrap(f.source.selectedTab)
        let before = try f.runtime.list().map(\.pid)
        let menu = f.source.headerContextMenu(tabID: tab.id)
        let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "header-close-tab" })
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        try await settle(f) { f.source.selectedTab?.id != tab.id }
        XCTAssertEqual(f.source.state.layout.selectedWorkspaceID, f.beta)
        f.source.execute(.restoreTab)
        try await settle(f) { f.source.selectedTab?.id == tab.id }

        XCTAssertEqual(f.source.state.layout.selectedWorkspaceID, f.alpha)
        XCTAssertEqual(f.source.selectedTab?.tree, tab.tree)
        XCTAssertEqual(f.source.selectedTab?.focusedPaneID, tab.focusedPaneID)
        XCTAssertEqual(try f.runtime.list().map(\.pid), before)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-4, FR-NAV-6
    @MainActor func testHeaderCloseHidesWorkspaceAcrossMirrorsAndClosesItsFloatWithoutStoppingJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try f.runtime.state().layout.tabs
        let pids = try f.runtime.list().map(\.pid)
        f.source.floatingPanes.toggle(f.panes[0])
        try await settle(f) { f.source.floatingPaneIDs.contains(f.panes[0]) && f.source.terminalViews[f.panes[0]]?.window != nil && f.source.terminalViews[f.panes[0]]?.window !== f.window }
        let floating = try XCTUnwrap(f.source.terminalViews[f.panes[0]]?.window)
        let close = try XCTUnwrap(region("header-workspace-close-" + f.alpha, in: f.window.contentView!) as? NSButton)
        XCTAssertTrue(close.target === close)
        close.performClick(nil)
        try await settle(f) {
            f.source.state.layout.workspaces.first { $0.id == f.alpha }?.closed == true &&
            f.source.state.layout.selectedWorkspaceID == f.beta && f.mirror.state.layout.selectedWorkspaceID == f.beta &&
            f.source.terminalViews[f.panes[0]] == nil && f.mirror.terminalViews[f.panes[0]] == nil
        }
        XCTAssertFalse(floating.isVisible)
        XCTAssertTrue(f.source.floatingPaneIDs.isEmpty)
        for _ in 0..<3 { f.source.refresh(); f.mirror.refresh(); try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(try f.runtime.state().layout.workspaces.first { $0.id == f.alpha }?.closed == true)
        XCTAssertEqual(try f.runtime.state().layout.tabs, before)
        XCTAssertEqual(try f.runtime.list().map(\.pid), pids)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
        if let old = region("sidebar-workspace-" + f.alpha, in: f.window.contentView!) {
            XCTAssertTrue(old.isHiddenOrHasHiddenAncestor || old.visibleRect.isEmpty, "Closed row remains visible: bounds=\(old.bounds), visible=\(old.visibleRect), hidden=\(old.isHiddenOrHasHiddenAncestor)")
        }
    }

    // Implements: FR-NAV-4, FR-NAV-6
    @MainActor func testPickerCloseDoesNotSelectTheInactiveWorkspaceOrDismissPicker() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        f.source.picker = .sessions
        try await settle(f) { self.region("picker-workspace-close-" + f.beta, in: f.window.contentView!) != nil }
        let close = try XCTUnwrap(region("picker-workspace-close-" + f.beta, in: f.window.contentView!) as? NSButton)
        close.performClick(nil)
        try await settle(f) { f.source.state.layout.workspaces.first { $0.id == f.beta }?.closed == true }
        XCTAssertEqual(f.source.state.layout.selectedWorkspaceID, f.alpha)
        XCTAssertEqual(f.source.picker, .sessions)
        XCTAssertNil(region("picker-workspace-close-" + f.beta, in: f.window.contentView!))
        XCTAssertNotNil(region("picker-workspace-close-" + f.alpha, in: f.window.contentView!))
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-4, FR-NAV-6
    @MainActor func testLastWorkspaceCloseStaysEmptyUntilExplicitSearchReopensIt() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try f.runtime.list().map(\.pid)
        let closeBeta = try XCTUnwrap(region("sidebar-workspace-close-" + f.beta, in: f.window.contentView!) as? NSButton)
        closeBeta.performClick(nil)
        try await settle(f) { f.source.state.layout.workspaces.first { $0.id == f.beta }?.closed == true }
        let closeAlpha = try XCTUnwrap(region("header-workspace-close-" + f.alpha, in: f.window.contentView!) as? NSButton)
        closeAlpha.performClick(nil)
        try await settle(f) { f.source.state.layout.selectedWorkspaceID == nil && f.mirror.state.layout.selectedWorkspaceID == nil }
        f.source.refresh(); f.mirror.refresh()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(f.source.state.layout.selectedWorkspaceID)
        XCTAssertEqual(try f.runtime.list().map(\.pid), before)
        f.source.picker = .sessions
        try await settle(f) { self.region("picker-search-field", in: f.window.contentView!) != nil }
        XCTAssertNil(region("picker-workspace-close-" + f.alpha, in: f.window.contentView!))
        let field = try XCTUnwrap(region("picker-search-field", in: f.window.contentView!) as? NSTextField)
        XCTAssertTrue(f.window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        editor.insertText("Alpha", replacementRange: NSRange(location: 0, length: 0))
        try await Task.sleep(for: .milliseconds(100))
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle(f) { f.source.state.layout.selectedWorkspaceID == f.alpha && f.source.picker == nil }
        XCTAssertFalse(try XCTUnwrap(try f.runtime.state().layout.workspaces.first { $0.id == f.alpha }).closed)
        XCTAssertEqual(try f.runtime.list().map(\.pid), before)
    }

    // Implements: FR-NAV-4
    @MainActor func testQueuedOperationFromAMirrorCannotReopenItsClosedWorkspace() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try f.runtime.list().map(\.pid)
        f.mirror.queue.suspend()
        var suspended = true
        defer { if suspended { f.mirror.queue.resume() } }
        f.mirror.perform { runtime in try runtime.update { $0.settings.fontSize = 19 } }
        let close = try XCTUnwrap(region("header-workspace-close-" + f.alpha, in: f.window.contentView!) as? NSButton)
        close.performClick(nil)
        try await settle(f) { f.source.state.layout.workspaces.first { $0.id == f.alpha }?.closed == true }
        suspended = false
        f.mirror.queue.resume()
        try await settle(f) { f.mirror.state.settings.fontSize == 19 }
        XCTAssertTrue(try f.runtime.state().layout.workspaces.first { $0.id == f.alpha }?.closed == true)
        XCTAssertEqual(f.mirror.state.layout.selectedWorkspaceID, f.beta)
        XCTAssertEqual(try f.runtime.list().map(\.pid), before)
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let source: AppStore
        let mirror: AppStore
        let window: NSWindow
        let mirrorWindow: NSWindow
        let delegate: ApplicationDelegate
        let alpha: String
        let beta: String
        let panes: [String]
    }

    @MainActor private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-close-ui-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        var panes: [String] = []
        for index in 0..<3 { panes.append(try runtime.create(title: "Close \(index)", cwd: root.path, shell: "/bin/sleep", arguments: ["90"]).id) }
        var alpha = "", beta = ""
        try runtime.update { state in
            state.settings.automaticRestore = false
            alpha = state.layout.addWorkspace(title: "Alpha")
            let tab = state.layout.addTab(paneID: panes[0])
            try state.layout.split(tabID: tab, paneID: panes[1], axis: .horizontal)
            beta = state.layout.addWorkspace(title: "Beta")
            state.layout.addTab(paneID: panes[2])
            try state.layout.selectWorkspace(alpha)
        }
        let source = AppStore(runtime: runtime), mirror = AppStore(runtime: runtime)
        source.showSessionsSidebar = true
        let window = makeWindow(source), mirrorWindow = makeWindow(mirror)
        let delegate = ApplicationDelegate()
        delegate.store = source; delegate.window = window
        for (view, model) in [(window, source), (mirrorWindow, mirror)] {
            view.delegate = delegate; delegate.windows[view] = model
            delegate.observeSettings(model, window: view); delegate.configureFloatingPanes(model)
        }
        let f = Fixture(root: root, runtime: runtime, source: source, mirror: mirror, window: window, mirrorWindow: mirrorWindow, delegate: delegate, alpha: alpha, beta: beta, panes: panes)
        try await settle(f) { !source.loading && !mirror.loading && source.terminalViews[panes[0]]?.process.running == true && mirror.terminalViews[panes[0]]?.process.running == true }
        return f
    }

    @MainActor private func makeWindow(_ store: AppStore) -> NSWindow {
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), contentView: NSHostingView(rootView: WorkspaceView(store: store)))
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        return window
    }

    @MainActor private func drain(_ store: AppStore) async {
        await withCheckedContinuation { continuation in
            store.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    @MainActor private func shortcut(_ key: String, code: UInt16, flags: NSEvent.ModifierFlags, in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: key.uppercased(), charactersIgnoringModifiers: key,
            isARepeat: false, keyCode: code))
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }

    @MainActor private func settle(_ f: Fixture, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            f.window.contentView?.layoutSubtreeIfNeeded(); f.mirrorWindow.contentView?.layoutSubtreeIfNeeded()
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        XCTFail("Workspace close did not settle: " + (f.source.message ?? f.mirror.message ?? "no error"))
    }

    @MainActor private func dispose(_ f: Fixture) {
        f.source.floatingPanes.closeAll(); f.mirror.floatingPanes.closeAll()
        f.window.close(); f.mirrorWindow.close()
        for session in (try? f.runtime.list()) ?? [] { try? f.runtime.terminate(session.id) }
        try? FileManager.default.removeItem(at: f.root)
    }
}
