import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class SessionPickerQuickSelectTests: XCTestCase {
    // Implements: FR-NAV-2
    func testCommandDigitOpensTheListedSessionAtThatPositionAndIgnoresOtherChords() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-picker-quick-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        var workspaces: [String] = []
        try runtime.update { state in
            state.settings.automaticRestore = false
            for title in ["alpha", "beta", "gamma"] {
                let paneID = UUID().uuidString.lowercased()
                state.sessions.append(TerminalSession(id: paneID, title: title, cwd: root.path, pid: 0, agent: .shell, alive: false))
                workspaces.append(state.layout.addWorkspace(title: title))
                state.layout.addTab(paneID: paneID)
            }
            try state.layout.selectWorkspace(workspaces[0])
        }
        let store = AppStore(runtime: runtime)
        try await settle { !store.loading }
        store.picker = .sessions
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 380), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        let hosting = NSHostingView(rootView: PickerView(store: store, kind: .sessions))
        window.contentView = hosting
        window.orderFrontRegardless()
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
        let field = try XCTUnwrap(fields(in: hosting).first { $0.isEditable })
        XCTAssertTrue(window.makeFirstResponder(field))
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)

        func chord(_ key: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: key, charactersIgnoringModifiers: key,
                isARepeat: false, keyCode: 0))
        }
        XCTAssertFalse(field.performKeyEquivalent(with: try chord("2", [.command, .shift])))
        XCTAssertFalse(field.performKeyEquivalent(with: try chord("0", .command)))
        XCTAssertTrue(field.performKeyEquivalent(with: try chord("9", .command)), "An unused position is consumed without choosing")
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(field.performKeyEquivalent(with: try chord("2", .command)))
        editor.unmarkText()
        editor.selectAll(nil)
        editor.insertText("", replacementRange: editor.selectedRange())
        try await Task.sleep(for: .milliseconds(120)); hosting.layoutSubtreeIfNeeded()
        XCTAssertEqual(store.picker, .sessions)
        XCTAssertEqual(store.state.layout.selectedWorkspaceID, workspaces[0])

        XCTAssertTrue(field.performKeyEquivalent(with: try chord("2", .command)))
        try await settle { store.picker == nil && store.state.layout.selectedWorkspaceID == workspaces[1] }
        XCTAssertNil(store.picker)
        XCTAssertEqual(store.state.layout.selectedWorkspaceID, workspaces[1])
    }

    private func settle(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition(), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
    }

    private func fields(in view: NSView) -> [NSTextField] {
        (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap { fields(in: $0) }
    }
}
