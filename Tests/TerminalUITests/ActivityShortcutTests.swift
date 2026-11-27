import AppKit
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class ActivityShortcutTests: XCTestCase {
    func testCommandPeriodTogglesTheActualActivityOverlayAndIgnoresRepeat() async throws {
        let f = try Fixture(); defer { f.close() }; try await f.ready()
        XCTAssertTrue(f.delegate.handle(try f.key()))
        XCTAssertTrue(f.store.showActivity)
        try await f.layout()
        XCTAssertNotNil(f.region("activity-panel"))
        XCTAssertTrue(f.delegate.handle(try f.key(repeating: true)))
        XCTAssertTrue(f.store.showActivity)
        XCTAssertTrue(f.delegate.handle(try f.key()))
        XCTAssertFalse(f.store.showActivity)
        try await f.layout()
        XCTAssertNil(f.region("activity-panel"))
        XCTAssertTrue(f.delegate.handle(try f.key(repeating: true)))
        XCTAssertFalse(f.store.showActivity)
        XCTAssertTrue(try f.runtime.list().isEmpty)
    }
    func testActivityConsumesNavigationKeysEvenWhenEmpty() async throws {
        let f = try Fixture(); defer { f.close() }; try await f.ready()
        XCTAssertTrue(f.delegate.handle(try f.key()))
        for code: UInt16 in [125, 126, 36, 76] {
            XCTAssertTrue(f.delegate.handle(try f.navigationKey(code)))
            XCTAssertTrue(f.store.showActivity)
        }
        XCTAssertTrue(try f.runtime.list().isEmpty)
    }

    func testExplicitActivityBindingAndDisableAreRespected() async throws {
        let f = try Fixture(); defer { f.close() }
        try await f.ready(overrides: [ActionID.activity.rawValue: ["cmd+alt+."]])
        XCTAssertFalse(f.delegate.handle(try f.key()))
        XCTAssertFalse(f.store.showActivity)
        XCTAssertTrue(f.delegate.handle(try f.key(flags: [.command, .option])))
        XCTAssertTrue(f.store.showActivity)
        f.store.showActivity = false
        f.store.state.settings.keyBindings = [ActionID.activity.rawValue: []]
        XCTAssertFalse(f.delegate.handle(try f.key()))
        XCTAssertFalse(f.store.showActivity)
    }
    func testSettingsAndComposingEditorKeepTheirInputOwnership() async throws {
        let f = try Fixture(); defer { f.close() }; try await f.ready()
        f.store.showSettings = true
        XCTAssertFalse(f.delegate.handle(try f.key()))
        XCTAssertFalse(f.store.showActivity)
        f.store.showSettings = false
        let editor = NSTextView(frame: NSRect(x: 10, y: 10, width: 100, height: 30))
        editor.isFieldEditor = true
        let container = NSView(frame: f.hosting.frame)
        f.hosting.removeFromSuperview(); container.addSubview(f.hosting)
        f.window.contentView = container; container.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(f.delegate.handle(try f.key()))
        XCTAssertTrue(editor.hasMarkedText()); XCTAssertFalse(f.store.showActivity)
        editor.unmarkText()
    }
    @MainActor private final class Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-activity-key-" + UUID().uuidString.prefix(8))
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let hosting: NSHostingView<WorkspaceView>
        let delegate = ApplicationDelegate()
        init() throws {
            _ = NSApplication.shared
            runtime = try TerminalRuntime(root: root)
            store = AppStore(runtime: runtime, recoverOnStartup: false)
            hosting = NSHostingView(rootView: WorkspaceView(store: store))
            window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1000, height: 700), contentView: hosting)
            window.animationBehavior = .none; window.orderFrontRegardless()
        }
        func ready(overrides: [String: [String]] = [:]) async throws {
            for _ in 0..<100 where store.loading { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertFalse(store.loading)
            store.state.settings.keyBindings = overrides
            delegate.window = window; delegate.store = store; delegate.windows[window] = store
            delegate.observeSettings(store, window: window)
            try await layout()
        }
        func key(flags: NSEvent.ModifierFlags = .command, repeating: Bool = false) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: ".", charactersIgnoringModifiers: ".", isARepeat: repeating, keyCode: 47))
        }
        func navigationKey(_ code: UInt16, flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: code == 36 ? "\r" : "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code))
        }
        func layout() async throws {
            for _ in 0..<4 { hosting.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(15)) }
        }
        func region(_ id: String) -> NSView? {
            func find(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == id { return view }
                return view.subviews.lazy.compactMap { find($0) }.first
            }
            return find(hosting)
        }
        func close() {
            store.terminalViews.removeAll(); window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
