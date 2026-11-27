import AppKit
import XCTest
@testable import SwiftTerm
@testable import TerminalCore
@testable import TranoApp

@MainActor private final class ClosedTerminalInputWindow: NSWindow {
    override var isVisible: Bool { true }
    override var isKeyWindow: Bool { true }
}

@MainActor private final class ClosedTerminalInputPanel: NSPanel {
    override var isKeyWindow: Bool { true }
}

@MainActor final class ClosedTerminalLifecycleUITests: XCTestCase {
    // Implements: FR-CLOSE-5
    func testFloatingPaneCloseShortcutCapturesAndStopsItsBackend() async throws {
        let f = try Fixture(); defer { f.close() }
        let pane = f.panes[1], sibling = f.panes[0]
        let panel = try await f.floatPane(1)
        XCTAssertEqual(f.store.floatingPanes.paneID(in: panel), pane.id)
        XCTAssertTrue(f.delegate.floatingWindows[panel] === f.store)
        XCTAssertTrue(f.delegate.handle(try f.shortcut(.closePane, window: panel)))
        await f.drain()
        let operations = try f.operations()
        XCTAssertLessThan(try XCTUnwrap(operations.firstIndex { $0.hasPrefix("capture ") }),
                          try XCTUnwrap(operations.firstIndex { $0.hasPrefix("kill ") }))
        XCTAssertEqual(try f.killedIDs(), [pane.id])
        XCTAssertNotNil(try f.runtime.closedTerminalPaneSnapshot(pane.id))
        let state = try f.runtime.state()
        XCTAssertEqual(state.layout.tabs.first { $0.id == f.tabs[0] }?.panes, [sibling.id])
        XCTAssertEqual(state.sessions.first { $0.id == sibling.id }, sibling)
        XCTAssertNil(f.store.floatingPanes.paneID(in: panel))
        XCTAssertNil(f.delegate.floatingWindows[panel])
        XCTAssertNil(f.store.message)
        f.assertNoJobs()
    }

    // Implements: FR-CLOSE-5
    func testFloatingNativeWindowCloseOnlyReturnsPane() async throws {
        let f = try Fixture(); defer { f.close() }
        let before = try f.runtime.state().layout
        let panel = try await f.floatPane(1)
        panel.close()
        await f.drain()
        XCTAssertNil(f.store.floatingPanes.paneID(in: panel))
        XCTAssertNil(f.delegate.floatingWindows[panel])
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertEqual(try f.runtime.state().sessions, f.panes)
        XCTAssertFalse(try f.operations().contains { $0.hasPrefix("capture ") || $0.hasPrefix("kill ") })
        f.assertNoJobs()
    }

    // Implements: FR-CLOSE-5
    func testNativeCloseShortcutsPreserveLayoutWhenCaptureFails() async throws {
        for action in [ActionID.closePane, .closeTab] {
            let f = try Fixture(); defer { f.close() }
            f.backend.failCapture = true
            let before = try f.runtime.state().layout
            XCTAssertTrue(f.delegate.handle(try f.shortcut(action)))
            await f.drain()
            XCTAssertEqual(try f.runtime.state().layout, before)
            XCTAssertTrue(f.store.message?.contains("fixture capture denied") == true)
            XCTAssertTrue(try f.operations().contains { $0.hasPrefix("capture ") })
            XCTAssertFalse(try f.operations().contains { $0.hasPrefix("kill ") })
            f.assertNoJobs()
        }
    }

    // Implements: FR-CLOSE-5
    func testNativeHeaderCloseTerminatesOnlyTheCapturedInactiveTab() async throws {
        let f = try Fixture(); defer { f.close() }
        let menu = f.store.headerContextMenu(tabID: f.tabs[1], sourceWindow: f.window)
        let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "header-close-tab" })
        XCTAssertEqual(item.title, "Close Tab")
        XCTAssertTrue(item.isEnabled)
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        await f.drain()
        XCTAssertEqual(try f.killedIDs(), [f.panes[2].id])
        let layout = try f.runtime.state().layout
        XCTAssertTrue(layout.tabs.contains { $0.id == f.tabs[0] })
        XCTAssertFalse(layout.tabs.contains { $0.id == f.tabs[1] })
        XCTAssertTrue(layout.tabs.contains { $0.id == f.tabs[2] })
        XCTAssertNil(f.store.message)
        f.assertNoJobs()
    }

    // Implements: FR-CLOSE-5
    func testTabCloseButtonRouteCapturesBeforeStoppingTheNamedTab() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.closeTab(f.tabs[1], sourceWindow: f.window)
        await f.drain()
        let operations = try f.operations()
        let capture = try XCTUnwrap(operations.firstIndex { $0.hasPrefix("capture ") })
        let kill = try XCTUnwrap(operations.firstIndex { $0.hasPrefix("kill ") })
        XCTAssertLessThan(capture, kill)
        XCTAssertEqual(try f.killedIDs(), [f.panes[2].id])
        XCTAssertNil(f.store.message)
        f.assertNoJobs()
    }

    // Implements: FR-CLOSE-5
    func testCloseOthersKeepsTheCapturedTargetAfterGlobalSelectionChanges() async throws {
        for action in [ActionID.closeOtherPanes, .closeOtherTabs] {
            let f = try Fixture(); defer { f.close() }
            let gate = f.pauseQueue()
            f.store.execute(action)
            try f.runtime.update { try $0.layout.selectTab(f.tabs[1]) }
            gate.signal()
            await f.drain()
            let expected = action == .closeOtherPanes ? [f.panes[0].id] : [f.panes[2].id]
            XCTAssertEqual(try f.killedIDs(), expected)
            let layout = try f.runtime.state().layout
            XCTAssertTrue(layout.tabs.contains { $0.id == f.tabs[0] && $0.panes.contains(f.panes[1].id) })
            XCTAssertTrue(layout.tabs.contains { $0.id == f.tabs[2] })
            XCTAssertNil(f.store.message)
            f.assertNoJobs()
        }
    }

    // Implements: FR-CLOSE-5
    func testAllQueuedCloseActionsYieldToNewComposition() async throws {
        for action in [ActionID.closePane, .closeTab, .closeOtherPanes, .closeOtherTabs] {
            let f = try Fixture(); defer { f.close() }
            let before = try f.runtime.state().layout
            let gate = f.pauseQueue()
            f.store.execute(action)
            f.views[1].setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                                     replacementRange: NSRange(location: NSNotFound, length: 0))
            gate.signal()
            await f.drain()
            XCTAssertEqual(try f.runtime.state().layout, before, action.rawValue)
            XCTAssertTrue(f.views[1].hasMarkedText())
            XCTAssertFalse(try f.operations().contains { $0.hasPrefix("capture ") || $0.hasPrefix("kill ") })
            f.views[1].unmarkText()
            f.assertNoJobs()
        }
    }

    // Implements: FR-CLOSE-5
    func testHeaderCloseTabsToTheLeftAndRightCloseOnlyThatSideOfTheWorkspace() async throws {
        for (tabIndex, identifier, killed) in [(0, "header-close-tabs-right", [2]), (1, "header-close-tabs-left", [0, 1])] {
            let f = try Fixture(); defer { f.close() }
            let menu = f.store.headerContextMenu(tabID: f.tabs[tabIndex], sourceWindow: f.window)
            func entry(_ id: String) throws -> NSMenuItem { try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == id }, id) }
            XCTAssertTrue(try entry("header-close-other-tabs").isEnabled)
            XCTAssertEqual(try entry("header-close-tabs-right").isEnabled, tabIndex == 0)
            XCTAssertEqual(try entry("header-close-tabs-left").isEnabled, tabIndex == 1)
            let item = try entry(identifier)
            XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
            await f.drain()
            XCTAssertEqual(Set(try f.killedIDs()), Set(killed.map { f.panes[$0].id }), identifier)
            let layout = try f.runtime.state().layout
            XCTAssertTrue(layout.tabs.contains { $0.id == f.tabs[tabIndex] })
            XCTAssertTrue(layout.tabs.contains { $0.id == f.tabs[2] }, "Tabs of another workspace must stay")
            XCTAssertNil(f.store.message)
            f.assertNoJobs()
        }
    }

    // Implements: FR-CLOSE-5
    func testQueuedHeaderCloseYieldsToNewComposition() async throws {
        let f = try Fixture(); defer { f.close() }
        let before = try f.runtime.state().layout
        let menu = f.store.headerContextMenu(tabID: f.tabs[1], sourceWindow: f.window)
        let item = try XCTUnwrap(menu.items.first { $0.identifier?.rawValue == "header-close-tab" })
        let gate = f.pauseQueue()
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item))
        f.views[1].setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                                 replacementRange: NSRange(location: NSNotFound, length: 0))
        gate.signal()
        await f.drain()
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertFalse(try f.operations().contains { $0.hasPrefix("capture ") || $0.hasPrefix("kill ") })
        f.views[1].unmarkText()
        f.assertNoJobs()
    }

    // Implements: FR-CLOSE-5
    func testQueuedCloseOthersCannotFollowATabIntoAnotherWorkspace() async throws {
        for action in [ActionID.closeOtherPanes, .closeOtherTabs] {
            let f = try Fixture(); defer { f.close() }
            let gate = f.pauseQueue()
            f.store.execute(action)
            try f.runtime.update { try $0.layout.transferTab(f.tabs[0], from: f.workspaces[0], to: f.workspaces[1]) }
            let before = try f.runtime.state().layout
            gate.signal()
            await f.drain()
            XCTAssertEqual(try f.runtime.state().layout, before)
            XCTAssertTrue(try f.killedIDs().isEmpty)
            f.assertNoJobs()
        }
    }

    // Implements: FR-CLOSE-5
    func testNativeReopenCreatesFreshShellAndRestoresTheSplitTree() async throws {
        let f = try Fixture(); defer { f.close() }
        let original = try XCTUnwrap(f.store.selectedTab)
        XCTAssertTrue(f.delegate.handle(try f.shortcut(.closePane)))
        await f.drain()
        XCTAssertEqual(try f.killedIDs(), [f.panes[1].id])
        XCTAssertTrue(f.window.makeFirstResponder(f.views[0]))
        XCTAssertTrue(f.delegate.handle(try f.shortcut(.restoreTab)))
        await f.drain()
        let restored = try f.runtime.state()
        XCTAssertEqual(restored.layout.tabs.first { $0.id == original.id }?.tree, original.tree)
        XCTAssertEqual(restored.layout.focusedPaneID, f.panes[1].id)
        XCTAssertEqual(try f.operations().filter { $0.hasPrefix("create ") }.count, 1)
        XCTAssertNotEqual(restored.sessions.first { $0.id == f.panes[1].id }?.pid, f.panes[1].pid)
        XCTAssertEqual(restored.sessions.first { $0.id == f.panes[0].id }?.pid, f.panes[0].pid)
        XCTAssertNil(f.store.message)
        f.assertNoJobs()
    }

    // Implements: FR-CLOSE-5
    func testWorkspaceAndNativeWindowClosePreserveBackendJobs() async throws {
        let f = try Fixture(); defer { f.close() }
        f.store.closeWorkspace(f.workspaces[0])
        await f.drain()
        XCTAssertTrue(try XCTUnwrap(f.runtime.state().layout.workspaces.first { $0.id == f.workspaces[0] }).closed)
        XCTAssertTrue(try f.killedIDs().isEmpty)
        f.delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: f.window))
        XCTAssertTrue(try f.killedIDs().isEmpty)
        XCTAssertEqual(try f.runtime.state().sessions, f.panes)
        XCTAssertFalse(try f.operations().contains { $0.hasPrefix("capture ") || $0.hasPrefix("create ") })
        f.assertNoJobs()
    }

    @MainActor private final class Fixture {
        let root: URL
        let backend = ClosedUIPaneBackend()
        let runtime: TerminalRuntime
        let store: AppStore
        let window: ClosedTerminalInputWindow
        let delegate: ApplicationDelegate
        let panes: [TerminalSession]
        let tabs: [String]
        let workspaces: [String]
        let views: [TranoView]

        init() throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/t-close-ui-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            let directory = root.path
            panes = (0..<4).map { TerminalSession(id: UUID().uuidString.lowercased(), title: "Pane \($0)", cwd: directory, pid: Int32(800001 + $0), alive: true) }
            backend.workingDirectoryPath = directory
            backend.panes = panes.map { FakePaneBackend.pane(id: $0.id, pid: $0.pid, argv: ["/bin/zsh"]) }
            runtime.host = backend
            var state = RuntimeState()
            state.settings.automaticRestore = false
            state.sessions = panes
            let alpha = state.layout.addWorkspace(title: "first")
            let first = state.layout.addTab(paneID: panes[0].id)
            try state.layout.split(tabID: first, paneID: panes[1].id, axis: .horizontal)
            let second = state.layout.addTab(paneID: panes[2].id)
            let beta = state.layout.addWorkspace(title: "second")
            let third = state.layout.addTab(paneID: panes[3].id)
            try state.layout.selectTab(first)
            try state.layout.focusPane(panes[1].id)
            tabs = [first, second, third]; workspaces = [alpha, beta]
            let fixtureRuntime = runtime, fixtureRoot = root, fixturePanes = panes
            try fixtureRuntime.transaction {
                try fixtureRuntime.update { $0 = state }
                let command = TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"])
                for pane in fixturePanes {
                    _ = try ShellHistoryStore(runtimeRoot: fixtureRoot, home: fixtureRoot, environment: [:])
                        .prepareJournal(paneID: pane.id, command: command, restoring: false, seedEmpty: true)
                    try fixtureRuntime.rememberTerminalShell(command, paneID: pane.id)
                }
            }
            let model = AppStore(runtime: runtime, startServices: false)
            store = model
            let host = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 600))
            window = ClosedTerminalInputWindow(contentRect: NSRect(x: -12000, y: -12000, width: 900, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none; window.contentView = host
            views = panes.enumerated().map { index, pane in
                let view = TranoView.makeClipboardTerminal(frame: NSRect(x: CGFloat(index) * 200, y: 0, width: 200, height: 500))
                view.store = model; view.paneID = pane.id
                model.terminalViews[pane.id] = view
                host.addSubview(view)
                return view
            }
            model.applyCapturedNavigation(state, sessions: panes)
            XCTAssertTrue(window.makeFirstResponder(views[1]))
            delegate = ApplicationDelegate()
            delegate.windows[window] = model
            delegate.observeSettings(model, window: window)
        }

        func floatPane(_ index: Int) async throws -> NSPanel {
            delegate.configureFloatingPanes(store)
            store.floatingPanes.panelFactory = {
                ClosedTerminalInputPanel(contentRect: $0, styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView], backing: .buffered, defer: false)
            }
            let view = views[index]
            store.floatingPanes.toggle(view.paneID)
            view.removeFromSuperview()
            store.floatingPanes.rendererDetached(view)
            await drain()
            let panel = try XCTUnwrap(view.window as? ClosedTerminalInputPanel)
            XCTAssertTrue(panel.makeFirstResponder(view))
            assertNoJobs()
            return panel
        }

        func shortcut(_ action: ActionID, window target: NSWindow? = nil) throws -> NSEvent {
            let restore = action == .restoreTab
            return try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: action == .closePane ? .command : [.command, .shift], timestamp: 0,
                windowNumber: (target ?? window).windowNumber, context: nil, characters: restore ? "t" : "w",
                charactersIgnoringModifiers: restore ? "t" : "w", isARepeat: false, keyCode: restore ? 17 : 13))
        }

        func pauseQueue() -> DispatchSemaphore {
            let gate = DispatchSemaphore(value: 0)
            store.queue.async { gate.wait() }
            return gate
        }

        func drain() async {
            for _ in 0..<3 {
                await withCheckedContinuation { continuation in
                    store.queue.async { DispatchQueue.main.async { continuation.resume() } }
                }
            }
        }

        func operations() throws -> [String] { backend.operations }

        func killedIDs() throws -> [String] {
            try operations().filter { $0.hasPrefix("kill ") }.map { String($0.dropFirst("kill ".count)) }
        }

        func assertNoJobs(file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.host.socketPath), file: file, line: line)
            XCTAssertTrue(views.allSatisfy { !$0.started && !$0.process.running }, file: file, line: line)
        }

        func close() {
            store.floatingPanes.closeAll()
            delegate.floatingWindows.removeAll()
            delegate.windows.removeAll()
            views.forEach { $0.frameDriver.invalidate() }
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}

/// In-memory pane host for closed-terminal UI fixtures: logs operations in order and never starts a job.
final class ClosedUIPaneBackend: PaneBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [String] = []
    private var rows: [PaneHostPane] = []
    private var captureFailure = false
    var workingDirectoryPath = "/"
    let socketPath = "/nonexistent/trano-closed-ui-pty.sock"

    var operations: [String] { lock.withLock { log } }
    var panes: [PaneHostPane] {
        get { lock.withLock { rows } }
        set { lock.withLock { rows = newValue } }
    }
    var failCapture: Bool {
        get { lock.withLock { captureFailure } }
        set { lock.withLock { captureFailure = newValue } }
    }
    private func record(_ line: String) { lock.withLock { log.append(line) } }

    func isRunning() -> Bool { true }
    func create(id: String, argv: [String], environment: [String], cwd: String, cols: Int, rows: Int) throws -> Int32 {
        record("create " + id)
        lock.withLock { self.rows.append(FakePaneBackend.pane(id: id, pid: 900001, argv: argv)) }
        return 900001
    }
    func respawn(id: String, argv: [String], environment: [String]?, cwd: String?) throws -> Int32 {
        record("respawn " + id); throw TerminalError.runtime("Fixture refuses to respawn")
    }
    func list() throws -> [PaneHostPane] { record("list"); return panes }
    func write(_ id: String, _ data: Data) throws { record("write " + id) }
    func capture(_ id: String, lines: Int, escapes: Bool) throws -> String {
        record("capture " + id)
        if failCapture { throw TerminalError.runtime("fixture capture denied") }
        return "saved fixture output\n"
    }
    func workingDirectory(_ id: String) throws -> String { workingDirectoryPath }
    func kill(_ id: String) throws { record("kill " + id); lock.withLock { rows.removeAll { $0.id == id } } }
    func pipe(_ id: String, command: String) throws { record("pipe " + id) }
    func setOption(_ id: String, key: String, value: String) throws { record("option " + id) }
    func environment(_ id: String, key: String) throws -> String? { nil }
    func attachArguments(_ id: String) -> [String] { ["pty-attach", id] }
}
