import AppKit
import Darwin
import XCTest
@testable import SwiftTerm
@testable import TerminalCore
@testable import TranoApp

@MainActor final class TabShortcutRoutingTests: XCTestCase {
    // Implements: FR-NAV-1, FR-NAV-2
    func testControlTabShortcutsCycleOrdinaryWindowTabs() async throws {
        let f = try Fixture(); defer { f.close() }
        XCTAssertTrue(f.window.makeFirstResponder(f.views[1]))
        XCTAssertTrue(f.delegate.handle(try f.key(flags: [.control, .shift])))
        await f.drain()
        XCTAssertEqual(f.store.state.layout.selectedTabID, f.tabs[0])
        XCTAssertTrue(f.delegate.handle(try f.key(flags: .control)))
        await f.drain()
        XCTAssertEqual(f.store.state.layout.selectedTabID, f.tabs[1])
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-1, FR-NAV-2
    func testControlTabShortcutsCycleMainTabsWhenOwnedUnisessionRendererHasFocus() async throws {
        let f = try Fixture(); defer { f.close() }
        XCTAssertTrue(f.window.makeFirstResponder(f.externalView))
        XCTAssertTrue(f.delegate.handle(try f.key(flags: [.control, .shift])))
        await f.drain()
        XCTAssertEqual(f.store.state.layout.selectedTabID, f.tabs[0])
        XCTAssertTrue(f.window.makeFirstResponder(f.externalView))
        XCTAssertTrue(f.delegate.handle(try f.key(flags: .control)))
        await f.drain()
        XCTAssertEqual(f.store.state.layout.selectedTabID, f.tabs[1])
        XCTAssertTrue(f.recorder.bytes.isEmpty)
        try f.assertNoJobs()
    }

    // Implements: FR-INPUT-1, FR-NAV-2
    func testRawShiftTabPassesAppRoutingAndReachesLegacyTerminalExactlyOnce() throws {
        let f = try Fixture(); defer { f.close() }
        XCTAssertTrue(f.window.makeFirstResponder(f.externalView))
        for characters in ["\u{19}", "\t"] {
            f.recorder.reset()
            let event = try f.key(flags: .shift, characters: characters)
            XCTAssertFalse(f.delegate.handle(event))
            f.externalView.keyDown(with: event)
            XCTAssertEqual(f.recorder.bytes, Array("\u{1b}[Z".utf8))
            XCTAssertEqual(f.store.state.layout.selectedTabID, f.tabs[1])
        }
        f.externalView.feed(text: "\u{1b}[>1u")
        f.recorder.reset()
        let event = try f.key(flags: .shift, characters: "\u{19}")
        XCTAssertFalse(f.delegate.handle(event))
        f.externalView.keyDown(with: event)
        XCTAssertEqual(f.recorder.bytes, Array("\u{1b}[9;2u".utf8))
        try f.assertNoJobs()
    }

    // Implements: FR-INPUT-1
    func testControlReturnReachesTheTerminalProgramInsteadOfTheContextualMenu() throws {
        let f = try Fixture(); defer { f.close() }
        XCTAssertTrue(f.window.makeFirstResponder(f.externalView))
        func controlReturn() throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .control,
                timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: "\r",
                charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        }
        XCTAssertTrue(f.externalView.performKeyEquivalent(with: try controlReturn()))
        XCTAssertEqual(f.recorder.bytes, Array("\r".utf8))
        let row = try XCTUnwrap(f.externalStore.sessions.firstIndex { $0.id == f.externalView.paneID })
        f.externalStore.sessions[row].foregroundProgram = .claude
        f.recorder.reset()
        XCTAssertTrue(f.externalView.performKeyEquivalent(with: try controlReturn()))
        XCTAssertEqual(f.recorder.bytes, Array("\u{1b}[27;5;13~".utf8))
        f.externalView.feed(text: "\u{1b}[>1u")
        f.recorder.reset()
        XCTAssertTrue(f.externalView.performKeyEquivalent(with: try controlReturn()))
        XCTAssertEqual(f.recorder.bytes, Array("\u{1b}[13;5u".utf8))
        try f.assertNoJobs()
    }

    // Implements: FR-INPUT-1, FR-NAV-2
    func testMarkedTextFieldEditorAndSettingsProtectTabSelection() async throws {
        let f = try Fixture(); defer { f.close() }
        XCTAssertTrue(f.window.makeFirstResponder(f.externalView))
        f.externalView.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0))
        XCTAssertFalse(f.delegate.handle(try f.key(flags: [.control, .shift])))
        XCTAssertTrue(f.externalView.hasMarkedText())
        f.externalView.unmarkText()
        let editor = NSTextView(frame: NSRect(x: 10, y: 10, width: 150, height: 30))
        editor.isFieldEditor = true
        f.host.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        XCTAssertFalse(f.delegate.handle(try f.key(flags: [.control, .shift])))
        XCTAssertTrue(f.window.makeFirstResponder(f.externalView))
        f.store.showSettings = true
        XCTAssertFalse(f.delegate.handle(try f.key(flags: [.control, .shift])))
        f.store.showSettings = false
        await f.drain()
        XCTAssertEqual(f.store.state.layout.selectedTabID, f.tabs[1])
        try f.assertNoJobs()
    }

    // Implements: FR-NAV-2
    func testUnregisteredOrdinaryAndDifferentRuntimeRenderersCannotNavigateMainTabs() async throws {
        for ownership in [Fixture.Ownership.unregistered, .ordinary, .differentRuntime] {
            let f = try Fixture(ownership: ownership); defer { f.close() }
            XCTAssertTrue(f.window.makeFirstResponder(f.externalView))
            XCTAssertTrue(f.delegate.handle(try f.key(flags: [.control, .shift])))
            await f.drain()
            XCTAssertEqual(f.store.state.layout.selectedTabID, f.tabs[1])
            try f.assertNoJobs()
        }
    }

    private final class Recorder: @unchecked Sendable {
        private let storage = SwiftTerm.Locked<[UInt8]>([])
        var bytes: [UInt8] { storage.withLock { $0 } }
        func record(_ bytes: [UInt8]) { storage.withLock { $0.append(contentsOf: bytes) } }
        func reset() { storage.withLock { $0.removeAll() } }
    }

    @MainActor private final class Fixture {
        enum Ownership { case unisession, unregistered, ordinary, differentRuntime }
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let externalStore: AppStore
        let externalView: TranoView
        let window: NSWindow
        let delegate = ApplicationDelegate()
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
        let views: [TranoView]
        let tabs: [String]
        let recorder = Recorder()
        private let foreignRoot: URL?
        private let initialSessions: [TerminalSession]

        init(ownership: Ownership = .unisession) throws {
            _ = NSApplication.shared
            let directory = URL(fileURLWithPath: "/tmp/trano-tab-route-" + UUID().uuidString.prefix(8))
            root = directory
            let engine = try TerminalRuntime(root: directory)
            runtime = engine
            let model = AppStore(runtime: engine, startServices: false)
            store = model
            let container = host
            let externalID = UUID().uuidString.lowercased()
            let binding = UnisessionBinding(paneID: externalID, backendPID: 900001,
                processIdentity: SupervisorProcessIdentity(pid: 900001, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 0))
            let paneRows = (0..<3).map { TerminalSession(id: UUID().uuidString.lowercased(), title: "Tab \($0)", cwd: directory.path, pid: 0, alive: false) }
            let externalRow = TerminalSession(id: externalID, title: "Unisession", cwd: root.path, pid: binding.backendPID, alive: false)
            var snapshot = RuntimeState()
            snapshot.settings.automaticRestore = false
            snapshot.layout.addWorkspace(title: "routing")
            tabs = paneRows.map { snapshot.layout.addTab(paneID: $0.id) }
            try snapshot.layout.selectTab(tabs[1])
            snapshot.sessions = paneRows + [externalRow]
            initialSessions = snapshot.sessions
            try runtime.update { $0 = snapshot }
            store.state = snapshot; store.sessions = snapshot.sessions
            let externalRuntime: TerminalRuntime
            if ownership == .differentRuntime {
                let other = URL(fileURLWithPath: root.path + "-foreign")
                foreignRoot = other
                externalRuntime = try TerminalRuntime(root: other)
            } else { foreignRoot = nil; externalRuntime = runtime }
            externalStore = AppStore(runtime: externalRuntime,
                unisessionBinding: ownership == .ordinary ? nil : binding, startServices: false)
            externalStore.applyExternalSnapshot(snapshot, sessions: snapshot.sessions)
            views = paneRows.map { pane in
                let view = TranoView.makeClipboardTerminal(frame: NSRect(x: 0, y: 0, width: 500, height: 350))
                view.store = model; view.paneID = pane.id; view.configure(TerminalSettings())
                model.terminalViews[pane.id] = view
                container.addSubview(view)
                return view
            }
            externalView = TranoView.makeClipboardTerminal(frame: NSRect(x: 500, y: 0, width: 300, height: 350))
            externalView.store = externalStore; externalView.paneID = externalID
            externalView.configure(TerminalSettings())
            if ownership != .unregistered { externalStore.terminalViews[externalID] = externalView }
            let captured = recorder
            externalView.setProcessInputHandler { bytes, origin, _ in
                if case .user = origin { captured.record(bytes) }
            }
            host.addSubview(externalView)
            window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 800, height: 600),
                styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            window.contentView = host; window.orderFrontRegardless()
            delegate.window = window; delegate.store = store; delegate.windows[window] = store
            delegate.observeSettings(store, window: window)
            XCTAssertTrue(window.makeFirstResponder(views[1]))
        }

        func key(flags: NSEvent.ModifierFlags, characters: String = "\t") throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: characters,
                charactersIgnoringModifiers: characters, isARepeat: false, keyCode: 48))
        }

        func drain() async {
            for _ in 0..<3 {
                await withCheckedContinuation { continuation in
                    store.queue.async { DispatchQueue.main.async { continuation.resume() } }
                }
            }
        }

        func assertNoJobs() throws {
            XCTAssertTrue((views + [externalView]).allSatisfy { !$0.started && !$0.process.running })
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.host.socketPath))
            XCTAssertFalse(FileManager.default.fileExists(atPath: externalStore.runtime.host.socketPath))
            XCTAssertEqual(try runtime.state().sessions, initialSessions)
        }

        func close() {
            for view in views + [externalView] {
                view.frameDriver.invalidate(); view.invalidateTerminalInteractions()
                view.setProcessInputHandler(nil); view.terminalDelegate = nil
            }
            store.terminalViews.removeAll(); externalStore.terminalViews.removeAll()
            delegate.windows.removeAll()
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
            if let foreignRoot { try? FileManager.default.removeItem(at: foreignRoot) }
        }
    }
}
