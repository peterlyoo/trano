import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class CommandPaletteShortcutTests: XCTestCase {
    // Implements: FR-NAV-2
    func testOnlyCommandShiftPOpensTheDefaultCommandPalette() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-palette-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let store = AppStore(runtime: runtime, recoverOnStartup: false)
        let host = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1000, height: 700), contentView: host)
        window.animationBehavior = .none; window.orderFrontRegardless()
        let delegate = ApplicationDelegate()
        defer { window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        for _ in 0..<100 where store.loading { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(store.loading)
        delegate.window = window; delegate.store = store; delegate.windows[window] = store
        delegate.observeSettings(store, window: window)
        func key(_ shifted: Bool) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shifted ? [.command, .shift] : .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: shifted ? "P" : "p",
                charactersIgnoringModifiers: shifted ? "P" : "p", isARepeat: false, keyCode: 35))
        }
        let plainHandled = delegate.handle(try key(false))
        XCTAssertFalse(plainHandled)
        XCTAssertNil(store.picker)
        guard !plainHandled else { return }
        XCTAssertTrue(delegate.handle(try key(true)))
        XCTAssertEqual(store.picker, .commands)
        for _ in 0..<6 { host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(15)) }
        func search(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField,
               (field.placeholderString ?? field.placeholderAttributedString?.string) == "Search commands…" { return field }
            return view.subviews.lazy.compactMap { search($0) }.first
        }
        XCTAssertNotNil(search(host), "The actual command search, rather than session navigation, must be shown")
        XCTAssertTrue(try runtime.list().isEmpty)
    }
}
