import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class FollowUpQueueUITests: XCTestCase {
    // Implements: FR-QUEUE-4, FR-NAV-2
    @MainActor func testQueuedInputShortcutTogglesAndRespectsRemappingAndMarkedText() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.delegate.store = fixture.store
        fixture.delegate.window = fixture.window
        let action = try XCTUnwrap(ActionID(rawValue: "input.queued"))
        XCTAssertEqual(try KeyBindingMap().action(for: "cmd+shift+u"), action)
        let toggle = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, characters: "U", charactersIgnoringModifiers: "u", isARepeat: false, keyCode: 32))
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.terminal))
        XCTAssertTrue(fixture.delegate.handle(toggle))
        XCTAssertEqual(fixture.store.followUpPaneID, fixture.paneID)
        try await layout(fixture)
        let editor = try XCTUnwrap(fixture.store.followUpEditor)
        XCTAssertTrue(fixture.window.firstResponder === editor)
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertTrue(fixture.delegate.handle(toggle))
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertNotNil(fixture.store.followUpPaneID)
        editor.unmarkText()
        XCTAssertTrue(fixture.delegate.handle(toggle))
        XCTAssertNil(fixture.store.followUpPaneID)

        fixture.store.state.settings.keyBindings[action.rawValue] = ["cmd+ctrl+u"]
        try await layout(fixture)
        XCTAssertFalse(fixture.delegate.handle(toggle))
        XCTAssertNil(fixture.store.followUpPaneID)
        let remapped = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, characters: "u", charactersIgnoringModifiers: "u", isARepeat: false, keyCode: 32))
        XCTAssertTrue(fixture.delegate.handle(remapped))
        XCTAssertEqual(fixture.store.followUpPaneID, fixture.paneID)
        try await layout(fixture)
        let menu = NSMenuItem(title: "Queued Input", action: #selector(ApplicationDelegate.performMenuAction(_:)), keyEquivalent: "u")
        menu.identifier = NSUserInterfaceItemIdentifier(action.rawValue)
        XCTAssertTrue(fixture.delegate.validateMenuItem(menu))
        fixture.delegate.performMenuAction(menu)
        XCTAssertNil(fixture.store.followUpPaneID)
    }

    // Implements: FR-QUEUE-4
    @MainActor func testQueuedInputButtonReplacesProfileControlAndTargetsItsOwnPane() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let other = UUID().uuidString.lowercased()
        try fixture.runtime.update { state in
            state.sessions.append(TerminalSession(id: other, title: "Other pane", cwd: fixture.root.path, pid: 0, agent: .codex, alive: false))
            try state.layout.split(tabID: state.layout.selectedTabID!, paneID: other, axis: .horizontal)
        }
        fixture.store.refresh()
        try await settle { fixture.store.sessions.count == 2 }
        fixture.store.focus(fixture.paneID)
        try await settle { fixture.store.focusedID == fixture.paneID }
        try await layout(fixture)
        let toolbar = try XCTUnwrap(region("workspace-header", in: fixture.hosting))
        XCTAssertNil(region("follow-up-button", in: toolbar))
        for id in [fixture.paneID, other] {
            let header = try XCTUnwrap(region("pane-header-" + id, in: fixture.hosting))
            let control = try XCTUnwrap(region("queued-input-button-" + id, in: fixture.hosting) as? NSButton)
            XCTAssertEqual(control.accessibilityLabel(), "Queued Input")
            XCTAssertTrue(header.convert(header.bounds, to: fixture.hosting).contains(control.convert(control.bounds, to: fixture.hosting)))
            XCTAssertTrue(control.toolTip?.contains("⌘⇧U") == true)
        }
        let button = try XCTUnwrap(region("queued-input-button-" + other, in: fixture.hosting) as? NSButton)
        XCTAssertTrue(button.target === button)
        button.performClick(nil)
        XCTAssertEqual(fixture.store.followUpPaneID, other)
        try await layout(fixture)
        let panel = try XCTUnwrap(region("follow-up-panel", in: fixture.hosting))
        XCTAssertEqual(panel.accessibilityLabel(), "Queued Input")
        XCTAssertEqual(fixture.store.followUpPaneTitle, "Other pane")
    }

    // Implements: FR-QUEUE-1, FR-QUEUE-4
    @MainActor func testQueueActionsPreserveOrderAndExactMultilineUnicode() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.store.openFollowUps()
        let firstText = "한글 후속 입력\n" + "한글".decomposedStringWithCanonicalMapping + " 👩🏽‍💻"
        fixture.store.followUpDraft = firstText
        fixture.store.saveFollowUpDraft()
        try await settle { !fixture.store.followUpSaving && fixture.store.followUpItems.count == 1 }
        let first = try XCTUnwrap(fixture.store.followUpItems.first)
        XCTAssertEqual(Data(first.text.utf8), Data(firstText.utf8))
        XCTAssertEqual(fixture.store.followUpDraft, "")

        fixture.store.followUpDraft = "Second input"
        fixture.store.saveFollowUpDraft()
        try await settle { !fixture.store.followUpSaving && fixture.store.followUpItems.count == 2 }
        fixture.store.editFollowUp(first)
        fixture.store.followUpDraft = "수정한 입력\n두 번째 줄"
        fixture.store.saveFollowUpDraft()
        try await settle { !fixture.store.followUpSaving && fixture.store.followUpItems.first?.text == "수정한 입력\n두 번째 줄" }
        XCTAssertEqual(fixture.store.followUpItems.first?.id, first.id)
        XCTAssertEqual(fixture.store.followUpItems.last?.text, "Second input")
        XCTAssertEqual(fixture.store.focusedFollowUpCount, 2)

        fixture.store.removeFollowUp(try XCTUnwrap(fixture.store.followUpItems.first))
        try await settle { !fixture.store.followUpSaving && fixture.store.followUpItems.count == 1 }
        XCTAssertEqual(try fixture.runtime.followUps(paneID: fixture.paneID).map(\.text), ["Second input"])
        XCTAssertNil(fixture.store.followUpError)
    }

    // Implements: FR-QUEUE-1, FR-QUEUE-4
    @MainActor func testCancelAndDismissDiscardOnlyTheDraft() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let saved = try fixture.runtime.addFollowUp(paneID: fixture.paneID, text: "Keep this input")
        fixture.store.refresh()
        try await settle { fixture.store.state.followUpInputs.count == 1 }
        fixture.store.openFollowUps()
        fixture.store.editFollowUp(saved)
        fixture.store.followUpDraft = "Discard this edit"
        fixture.store.cancelFollowUpDraft()
        XCTAssertEqual(fixture.store.followUpDraft, "")
        XCTAssertNil(fixture.store.followUpEditingID)
        XCTAssertEqual(try fixture.runtime.followUps(paneID: fixture.paneID).first?.text, saved.text)

        fixture.store.followUpDraft = "Unsaved new input"
        fixture.store.dismissFollowUps()
        XCTAssertNil(fixture.store.followUpPaneID)
        XCTAssertEqual(fixture.store.followUpDraft, "")
        fixture.store.openFollowUps()
        XCTAssertEqual(fixture.store.followUpDraft, "")
        XCTAssertEqual(fixture.store.followUpItems.map(\.id), [saved.id])
    }

    // Implements: FR-QUEUE-1, FR-QUEUE-4
    @MainActor func testOpenQueueKeepsItsPaneTargetWhenSelectionChanges() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.store.openFollowUps()
        fixture.store.followUpDraft = "Original pane only"
        let otherID = UUID().uuidString.lowercased()
        try fixture.runtime.update { state in
            state.sessions.append(TerminalSession(id: otherID, title: "Other pane", cwd: fixture.root.path, pid: 0, agent: .codex, alive: false))
            state.layout.addTab(paneID: otherID)
        }
        fixture.store.selectTab(try XCTUnwrap(try fixture.runtime.state().layout.tabs.last?.id))
        try await settle { fixture.store.focusedID == otherID }
        XCTAssertEqual(fixture.store.followUpPaneID, fixture.paneID)
        fixture.store.saveFollowUpDraft()
        try await settle { !fixture.store.followUpSaving && fixture.store.followUpItems.count == 1 }
        XCTAssertEqual(try fixture.runtime.followUps(paneID: fixture.paneID).map(\.text), ["Original pane only"])
        XCTAssertTrue(try fixture.runtime.followUps(paneID: otherID).isEmpty)
        XCTAssertEqual(fixture.store.focusedFollowUpCount, 0)
    }

    // Implements: FR-QUEUE-4
    @MainActor func testQueueOverlayStaysInWorkspaceWithoutChangingTerminalBounds() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        for size in [NSSize(width: 1280, height: 800), NSSize(width: 900, height: 620)] {
            for sidebar in [false, true] {
                fixture.store.showSessionsSidebar = sidebar
                fixture.window.setContentSize(size)
                try await layout(fixture)
                let before = fixture.terminal.convert(fixture.terminal.bounds, to: fixture.hosting)
                fixture.store.openFollowUps()
                try await layout(fixture)
                let panel = try XCTUnwrap(region("follow-up-panel", in: fixture.hosting))
                let workspace = try XCTUnwrap(region("terminal-workspace", in: fixture.hosting))
                let panelRect = panel.convert(panel.bounds, to: fixture.hosting)
                XCTAssertTrue(panel.window === fixture.window)
                XCTAssertLessThanOrEqual(panelRect.width, 380.5)
                XCTAssertLessThanOrEqual(panelRect.height, 540.5)
                XCTAssertTrue(workspace.convert(workspace.bounds, to: fixture.hosting).insetBy(dx: -0.5, dy: -0.5).contains(panelRect))
                XCTAssertTrue(fixture.hosting.bounds.insetBy(dx: -0.5, dy: -0.5).contains(panelRect))
                XCTAssertEqual(fixture.terminal.convert(fixture.terminal.bounds, to: fixture.hosting), before)
                for control in ["queued-input-button-" + fixture.paneID, "follow-up-add", "follow-up-save", "follow-up-cancel"] {
                    XCTAssertNotNil(region(control, in: fixture.hosting), control)
                }
                fixture.store.dismissFollowUps()
                try await layout(fixture)
                XCTAssertNil(region("follow-up-panel", in: fixture.hosting))
                XCTAssertEqual(fixture.terminal.convert(fixture.terminal.bounds, to: fixture.hosting), before)
            }
        }
    }

    // Implements: FR-QUEUE-4
    @MainActor func testNativeEditorBindsUnicodeAndKeepsIMECompositionBeforeDismissal() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.store.openFollowUps()
        try await layout(fixture)
        let editor = try XCTUnwrap(region("follow-up-editor", in: fixture.hosting) as? NSTextView)
        XCTAssertFalse(editor.isRichText)
        XCTAssertTrue(fixture.window.makeFirstResponder(editor))
        let text = "한글 입력\nNext line 👩🏽‍💻"
        editor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        XCTAssertEqual(Data(fixture.store.followUpDraft.utf8), Data(text.utf8))
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(fixture.delegate.handle(try key(53, "\u{1b}", window: fixture.window)))
        XCTAssertNotNil(fixture.store.followUpPaneID)
        editor.unmarkText()
        XCTAssertTrue(fixture.delegate.handle(try key(53, "\u{1b}", window: fixture.window)))
        XCTAssertNil(fixture.store.followUpPaneID)
        XCTAssertEqual(fixture.store.followUpDraft, "")
    }

    // Implements: FR-QUEUE-4, FR-NAV-2
    @MainActor func testOutsideClickDismissesAndClosedQueuePreservesTypingAndFindFocus() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.store.openFollowUps()
        try await layout(fixture)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 16, y: 100), modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(fixture.delegate.handle(click))
        XCTAssertNil(fixture.store.followUpPaneID)
        XCTAssertFalse(fixture.delegate.handle(try key(0, "a", window: fixture.window)))
        XCTAssertFalse(fixture.delegate.handle(try key(53, "\u{1b}", window: fixture.window)))
        XCTAssertTrue(fixture.window.makeFirstResponder(fixture.terminal))
        fixture.store.execute(.find)
        let search = try XCTUnwrap(fixture.window.firstResponder)
        XCTAssertFalse(search === fixture.terminal)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(fixture.window.firstResponder === search)
    }

    // Implements: FR-QUEUE-1, FR-QUEUE-4
    @MainActor func testNativeButtonsCommitEditCancelAndDeleteWithoutChangingTerminalBounds() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let before = fixture.terminal.convert(fixture.terminal.bounds, to: fixture.hosting)
        fixture.store.openFollowUps()
        try await layout(fixture)
        let editor = try XCTUnwrap(region("follow-up-editor", in: fixture.hosting) as? NSTextView)
        let text = "한글 NFC 한글\nquote \" ‘ ’ — 👩🏽‍💻"
        editor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        let add = try XCTUnwrap(region("follow-up-save", in: fixture.hosting) as? NSButton)
        try await layout(fixture)
        XCTAssertEqual(add.title, "Add")
        XCTAssertTrue(add.isEnabled)
        try assertNativeAction(add)
        add.performClick(nil)
        try await settle { !fixture.store.followUpSaving && fixture.store.followUpItems.count == 1 }
        let item = try XCTUnwrap(fixture.store.followUpItems.first)
        XCTAssertEqual(Data(item.text.utf8), Data(text.utf8))
        try await layout(fixture)
        let edit = try XCTUnwrap(region("follow-up-edit-" + item.id, in: fixture.hosting) as? NSButton)
        try assertNativeAction(edit)
        edit.performClick(nil)
        try await layout(fixture)
        XCTAssertEqual(Data(editor.string.utf8), Data(text.utf8))
        XCTAssertEqual(add.title, "Save")
        try assertNativeAction(add)
        fixture.store.followUpDraft = "Unsaved edit"
        try await layout(fixture)
        let cancel = try XCTUnwrap(region("follow-up-cancel", in: fixture.hosting) as? NSButton)
        try assertNativeAction(cancel)
        cancel.performClick(nil)
        XCTAssertNil(fixture.store.followUpEditingID)
        XCTAssertEqual(try fixture.runtime.followUps(paneID: fixture.paneID).first?.text, text)
        edit.performClick(nil)
        fixture.store.followUpDraft = "Saved edit\n두 줄"
        try await layout(fixture)
        add.performClick(nil)
        try await settle { !fixture.store.followUpSaving && fixture.store.followUpItems.first?.text == "Saved edit\n두 줄" }
        try await layout(fixture)
        let delete = try XCTUnwrap(region("follow-up-delete-" + item.id, in: fixture.hosting) as? NSButton)
        try assertNativeAction(delete)
        delete.performClick(nil)
        try await settle { !fixture.store.followUpSaving && fixture.store.followUpItems.isEmpty }
        XCTAssertTrue(try fixture.runtime.followUps(paneID: fixture.paneID).isEmpty)
        XCTAssertEqual(fixture.terminal.convert(fixture.terminal.bounds, to: fixture.hosting), before)
        XCTAssertGreaterThan(editor.bounds.width, 100)
    }

    // Implements: FR-QUEUE-4
    @MainActor func testMarkedTextBlocksOutsideDismissalAndNativeSaveUntilCommitted() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.store.openFollowUps()
        try await layout(fixture)
        let editor = try XCTUnwrap(region("follow-up-editor", in: fixture.hosting) as? NSTextView)
        XCTAssertTrue(fixture.window.makeFirstResponder(editor))
        editor.insertText("Prefix ", replacementRange: NSRange(location: 0, length: 0))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let bytes = Data(editor.string.utf8)
        let click = try XCTUnwrap(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 16, y: 100), modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        XCTAssertTrue(fixture.delegate.handle(click))
        fixture.store.saveFollowUpDraft()
        fixture.store.cancelFollowUpDraft()
        try await layout(fixture)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(Data(editor.string.utf8), bytes)
        XCTAssertNotNil(fixture.store.followUpPaneID)
        XCTAssertTrue(try fixture.runtime.followUps(paneID: fixture.paneID).isEmpty)
        editor.unmarkText()
        fixture.store.saveFollowUpDraft()
        try await settle { !fixture.store.followUpSaving && fixture.store.followUpItems.count == 1 }
        XCTAssertEqual(Data(try XCTUnwrap(fixture.store.followUpItems.first?.text).utf8), bytes)
    }

    // Implements: FR-QUEUE-4
    @MainActor func testQueueDisablesTerminalActionsAndHintsWithoutInterceptingEditorCommands() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.delegate.store = fixture.store
        fixture.delegate.window = fixture.window
        let menu = NSMenuItem(title: "New Tab", action: #selector(ApplicationDelegate.performMenuAction(_:)), keyEquivalent: "t")
        fixture.store.openFollowUps()
        try await layout(fixture)
        let editor = try XCTUnwrap(region("follow-up-editor", in: fixture.hosting) as? NSTextView)
        XCTAssertTrue(fixture.window.makeFirstResponder(editor))
        XCTAssertFalse(fixture.store.canShowTabShortcutHints)
        XCTAssertFalse(fixture.delegate.validateMenuItem(menu))
        let tabCount = fixture.store.state.layout.tabs.count
        fixture.store.execute(.newTab)
        XCTAssertEqual(fixture.store.state.layout.tabs.count, tabCount)
        let copy = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, characters: "c", charactersIgnoringModifiers: "c", isARepeat: false, keyCode: 8))
        XCTAssertFalse(fixture.delegate.handle(copy))
        fixture.store.refresh()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(fixture.window.firstResponder === editor)
        fixture.store.dismissFollowUps()
        XCTAssertTrue(fixture.delegate.validateMenuItem(menu))
    }

    // Implements: FR-QUEUE-1, FR-QUEUE-4
    @MainActor func testEditorAppliesCanonicallyEquivalentDraftChangesByteForByte() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.store.openFollowUps()
        fixture.store.followUpDraft = "한글"
        try await layout(fixture)
        let editor = try XCTUnwrap(region("follow-up-editor", in: fixture.hosting) as? NSTextView)
        let decomposed = "한글".decomposedStringWithCanonicalMapping
        fixture.store.followUpDraft = decomposed
        try await layout(fixture)
        XCTAssertEqual(Data(editor.string.utf8), Data(decomposed.utf8))
        fixture.store.saveFollowUpDraft()
        try await settle { !fixture.store.followUpSaving && fixture.store.followUpItems.count == 1 }
        XCTAssertEqual(Data(try XCTUnwrap(fixture.store.followUpItems.first?.text).utf8), Data(decomposed.utf8))
    }

    @MainActor private func key(_ code: UInt16, _ text: String, window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: text, charactersIgnoringModifiers: text, isARepeat: false, keyCode: code))
    }

    @MainActor private func assertNativeAction(_ button: NSButton, file: StaticString = #filePath, line: UInt = #line) throws {
        let target = try XCTUnwrap(button.target as? NSObject, file: file, line: line)
        let action = try XCTUnwrap(button.action, file: file, line: line)
        XCTAssertTrue(target === button, "Native button must own its action target", file: file, line: line)
        XCTAssertTrue(target.responds(to: action), file: file, line: line)
        XCTAssertEqual(NSStringFromSelector(action), "invokeFollowUpAction:", file: file, line: line)
    }

    @MainActor private func settle(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Queue operation did not settle")
    }

    @MainActor private func layout(_ fixture: Fixture) async throws {
        fixture.hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(120))
        fixture.hosting.layoutSubtreeIfNeeded()
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }

    @MainActor private func dispose(_ fixture: Fixture) {
        fixture.store.dismissFollowUps()
        fixture.store.terminalViews.removeAll()
        fixture.window.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let paneID: String
        let store: AppStore
        let terminal: TranoView
        let window: NSWindow
        let hosting: NSHostingView<WorkspaceView>
        let delegate: ApplicationDelegate
    }

    @MainActor private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-queue-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let paneID = UUID().uuidString.lowercased()
        try runtime.update { state in
            state.settings.automaticRestore = false
            state.sessions = [TerminalSession(id: paneID, title: "Queue pane", cwd: root.path, pid: 0, agent: .claude, alive: false)]
            state.layout.addTab(paneID: paneID)
        }
        let store = AppStore(runtime: runtime)
        try await settle { !store.loading }
        let terminal = TranoView(frame: .zero)
        terminal.started = true
        terminal.paneID = paneID
        terminal.store = store
        store.terminalViews[paneID] = terminal
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        window.contentView = hosting
        window.appearance = NSAppearance(named: .darkAqua)
        window.orderFrontRegardless()
        let delegate = ApplicationDelegate()
        delegate.windows[window] = store
        delegate.observeSettings(store, window: window)
        hosting.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(150))
        return Fixture(root: root, runtime: runtime, paneID: paneID, store: store, terminal: terminal, window: window, hosting: hosting, delegate: delegate)
    }
}
