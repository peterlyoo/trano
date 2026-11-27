import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class PickerKeyboardTests: XCTestCase {
    // Implements: FR-NAV-2
    @MainActor func testDownArrowSelectsNextCommandWhileSearchEditorOwnsFocus() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let editor = try searchEditor(fixture)
        editor.insertText("font", replacementRange: NSRange(location: 0, length: 0))
        try await layout(fixture)
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        try await layout(fixture)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle { fixture.store.picker == nil && fixture.store.state.settings.fontSize != 14 }
        XCTAssertEqual(fixture.store.state.settings.fontSize, 13)
        XCTAssertNil(fixture.store.message)
    }

    // Implements: FR-NAV-2
    @MainActor func testUpArrowReturnsToPreviousCommandWithoutChangingSearchText() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let editor = try searchEditor(fixture)
        editor.insertText("font", replacementRange: NSRange(location: 0, length: 0))
        try await layout(fixture)
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.moveDown(_:)))
        editor.doCommand(by: #selector(NSResponder.moveUp(_:)))
        try await layout(fixture)
        XCTAssertEqual(editor.string, "font")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle { fixture.store.picker == nil && fixture.store.state.settings.fontSize != 14 }
        XCTAssertEqual(fixture.store.state.settings.fontSize, 13)
    }

    // Implements: FR-NAV-2
    @MainActor func testFilteringAfterNavigationResetsSelectionAndEscapeDismisses() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let editor = try searchEditor(fixture)
        for _ in 0..<20 { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        editor.selectAll(nil)
        editor.insertText("queued input", replacementRange: editor.selectedRange())
        try await layout(fixture)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await settle { fixture.store.followUpPaneID == fixture.paneID }
        XCTAssertNil(fixture.store.picker)
        fixture.store.dismissFollowUps()
        fixture.store.picker = .commands
        let content = NSHostingView(rootView: PickerView(store: fixture.store, kind: .commands))
        fixture.window.contentView = content
        try await Task.sleep(for: .milliseconds(100))
        content.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(fields(in: content).first { $0.isEditable })
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        let replacementEditor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        replacementEditor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        XCTAssertNil(fixture.store.picker)
    }

    // Implements: FR-NAV-2, FR-INPUT-1
    @MainActor func testMarkedTextDoesNotChooseOrDismissThePalette() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let editor = try searchEditor(fixture)
        editor.insertText("font", replacementRange: NSRange(location: 0, length: 0))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        let text = Data(editor.string.utf8)
        let field = try XCTUnwrap(fields(in: fixture.hosting).first { $0.isEditable })
        _ = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.moveDown(_:)))
        _ = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.insertNewline(_:)))
        _ = field.delegate?.control?(field, textView: editor, doCommandBy: #selector(NSResponder.cancelOperation(_:)))
        let delegate = ApplicationDelegate()
        delegate.windows[fixture.window] = fixture.store
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertFalse(delegate.handle(escape))
        XCTAssertEqual(fixture.store.picker, .commands)
        XCTAssertEqual(fixture.store.state.settings.fontSize, 14)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(Data(editor.string.utf8), text)
    }

    // Implements: FR-NAV-2
    @MainActor func testArrowNavigationScrollsTheSelectedCommandIntoView() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let editor = try searchEditor(fixture)
        for _ in 0..<20 { editor.doCommand(by: #selector(NSResponder.moveDown(_:))) }
        try await layout(fixture)
        let selected = try XCTUnwrap(region("picker-selected-command", in: fixture.hosting))
        let viewport = try XCTUnwrap(region("picker-results", in: fixture.hosting))
        XCTAssertTrue(viewport.convert(viewport.bounds, to: fixture.hosting).insetBy(dx: -0.5, dy: -0.5).contains(selected.convert(selected.bounds, to: fixture.hosting)))
        XCTAssertTrue(fixture.window.firstResponder === editor)
        let field = try XCTUnwrap(fields(in: fixture.hosting).first { $0.isEditable })
        XCTAssertEqual(field.delegate?.control?(field, textView: editor, doCommandBy: NSSelectorFromString("copy:")), false)
    }

    private struct Fixture {
        let root: URL
        let store: AppStore
        let paneID: String
        let window: NSWindow
        let hosting: NSHostingView<PickerView>
    }

    @MainActor private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-picker-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let paneID = UUID().uuidString.lowercased()
        try runtime.update { state in
            state.settings.automaticRestore = false
            state.settings.fontSize = 14
            state.sessions = [TerminalSession(id: paneID, title: "Picker pane", cwd: root.path, pid: 0, agent: .shell, alive: false)]
            state.layout.addTab(paneID: paneID)
        }
        let store = AppStore(runtime: runtime)
        try await settle { !store.loading }
        store.picker = .commands
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let hosting = NSHostingView(rootView: PickerView(store: store, kind: .commands))
        window.contentView = hosting
        window.orderFrontRegardless()
        let fixture = Fixture(root: root, store: store, paneID: paneID, window: window, hosting: hosting)
        try await layout(fixture)
        return fixture
    }

    @MainActor private func searchEditor(_ fixture: Fixture) throws -> NSTextView {
        let field = try XCTUnwrap(fields(in: fixture.hosting).first { $0.isEditable })
        XCTAssertTrue(fixture.window.makeFirstResponder(field))
        return try XCTUnwrap(field.currentEditor() as? NSTextView)
    }

    @MainActor private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }

    @MainActor private func settle(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while !predicate() && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(predicate(), "Picker operation did not settle")
    }

    @MainActor private func layout(_ fixture: Fixture) async throws {
        try await Task.sleep(for: .milliseconds(100))
        fixture.hosting.layoutSubtreeIfNeeded()
    }

    @MainActor private func dispose(_ fixture: Fixture) {
        fixture.store.picker = nil
        fixture.store.dismissFollowUps()
        fixture.window.close()
        try? FileManager.default.removeItem(at: fixture.root)
    }
}
