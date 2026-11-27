import AppKit
@testable import SwiftTerm
import XCTest
@testable import TerminalCore
@testable import TranoApp

@MainActor final class NewTabFocusTests: XCTestCase {
    // Implements: FR-NAV-1, FR-NAV-2
    func testNewTabReceivesFocusAndFirstKeyWhenItsViewIsCreatedAfterSelection() async throws {
        let f = try Fixture(); defer { f.close() }
        f.selectNewTab()
        await drain()
        XCTAssertNil(f.store.terminalViews[f.newID])
        let view = f.makeNewView()
        f.host.addSubview(view)
        await drain()
        XCTAssertTrue(f.window.firstResponder === view)
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: "a",
            charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        f.window.firstResponder?.keyDown(with: key)
        await drain()
        XCTAssertEqual(f.newInput.bytes, Data("a".utf8))
        XCTAssertTrue(f.oldInput.bytes.isEmpty)
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-1, FR-NAV-2
    func testCachedNewTerminalReceivesFocusWhenItMountsAfterTheDeferredCallback() async throws {
        let f = try Fixture(); defer { f.close() }
        let view = f.makeNewView()
        f.selectNewTab()
        await drain()
        XCTAssertNil(view.window)
        f.host.addSubview(view)
        await drain()
        XCTAssertTrue(f.window.firstResponder === view)
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-1, FR-NAV-2
    func testLateMountCannotStealFocusAfterSelectingAnotherTab() async throws {
        let f = try Fixture(); defer { f.close() }
        f.selectNewTab()
        await drain()
        var snapshot = f.store.state
        try snapshot.layout.selectTab(f.oldTab)
        f.store.applyCapturedNavigation(snapshot, sessions: snapshot.sessions)
        await drain()
        let view = f.makeNewView()
        f.host.addSubview(view)
        await drain()
        XCTAssertTrue(f.window.firstResponder === f.oldView)
        XCTAssertEqual(f.store.focusedID, f.oldID)
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-2, FR-INPUT-1
    func testSettingsEditorKeepsFocusWhenAnEarlierNewTabMounts() async throws {
        let f = try Fixture(); defer { f.close() }
        f.selectNewTab()
        await drain()
        f.store.showSettings = true
        let editor = NSTextView(frame: NSRect(x: 20, y: 20, width: 200, height: 40))
        f.host.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        let view = f.makeNewView()
        f.host.addSubview(view)
        await drain()
        XCTAssertTrue(f.window.firstResponder === editor)
        f.store.showSettings = false
        view.removeFromSuperview(); f.host.addSubview(view)
        await drain()
        XCTAssertTrue(f.window.firstResponder === editor)
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-2
    func testFocusRestorationPreservesTheTerminalSearchEditor() async throws {
        let f = try Fixture(); defer { f.close() }
        let editor = NSTextView(frame: NSRect(x: 20, y: 20, width: 200, height: 40))
        f.oldView.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        f.store.restoreTerminalFocus()
        await drain()
        XCTAssertTrue(f.window.firstResponder === editor)
        try f.assertNoJobs()
    }

    private func drain() async {
        for _ in 0..<3 {
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return stored }
        func record(_ bytes: [UInt8]) { lock.lock(); defer { lock.unlock() }; stored.append(contentsOf: bytes) }
    }

    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let oldID = UUID().uuidString.lowercased()
        let newID = UUID().uuidString.lowercased()
        let oldTab: String
        let oldView: TranoView
        let oldInput = Recorder()
        let newInput = Recorder()

        init() throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/t-focus-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            let model = AppStore(runtime: runtime, startServices: false)
            store = model
            var state = RuntimeState()
            state.settings.automaticRestore = false
            state.layout.addWorkspace(title: "focus-fixture")
            state.sessions = [TerminalSession(id: oldID, title: "Old", cwd: root.path, pid: 0, alive: false)]
            oldTab = state.layout.addTab(paneID: oldID)
            try runtime.update { $0 = state }
            model.state = state; model.sessions = state.sessions
            oldView = TranoView.makeClipboardTerminal(frame: host.bounds)
            oldView.store = model; oldView.paneID = oldID
            oldView.configure(TerminalSettings())
            let recorder = oldInput
            oldView.setProcessInputHandler { bytes, origin, _ in
                if case .user = origin { recorder.record(bytes) }
            }
            model.terminalViews[oldID] = oldView
            host.addSubview(oldView)
            window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 800, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            window.contentView = host; window.orderFrontRegardless()
            XCTAssertTrue(window.makeFirstResponder(oldView))
        }

        func selectNewTab() {
            var snapshot = store.state
            snapshot.sessions.append(TerminalSession(id: newID, title: "New", cwd: root.path, pid: 0, alive: false))
            snapshot.layout.addTab(paneID: newID)
            store.applyCapturedNavigation(snapshot, sessions: snapshot.sessions)
        }

        func makeNewView() -> TranoView {
            let view = TranoView.makeClipboardTerminal(frame: host.bounds)
            view.store = store; view.paneID = newID
            view.configure(TerminalSettings())
            let recorder = newInput
            view.setProcessInputHandler { bytes, origin, _ in
                if case .user = origin { recorder.record(bytes) }
            }
            store.terminalViews[newID] = view
            return view
        }

        func assertNoJobs() throws {
            XCTAssertTrue(store.terminalViews.values.allSatisfy { !$0.started && !$0.process.running })
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.host.socketPath))
            XCTAssertEqual(try runtime.state().sessions.map(\.id), [oldID])
        }

        func close() {
            for view in store.terminalViews.values { view.frameDriver.invalidate() }
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
