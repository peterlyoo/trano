import AppKit
import Combine
import SwiftUI
import XCTest
@testable import SwiftTerm
@testable import TerminalCore
@testable import TranoApp

@MainActor final class SplitPaneFocusTests: XCTestCase {
    // Implements: FR-NAV-2, FR-NAV-5
    func testSplitRightFocusesNewTerminalInMountedWorkspace() async throws {
        try await checkSplit(.horizontal)
    }

    // Implements: FR-NAV-2, FR-NAV-5
    func testSplitDownFocusesNewTerminalInMountedWorkspace() async throws {
        try await checkSplit(.vertical)
    }

    // Implements: FR-NAV-2, FR-NAV-5
    func testCommandDFocusesTheNewSplitThroughNativeShortcutDispatch() async throws {
        try await checkSplit(.horizontal, shortcut: true)
    }

    // Implements: FR-NAV-2, FR-NAV-5
    func testCommandShiftDFocusesTheNewSplitThroughNativeShortcutDispatch() async throws {
        try await checkSplit(.vertical, shortcut: true)
    }

    // Implements: FR-NAV-2, FR-NAV-5
    func testSplitFocusSurvivesRendererReparentingDuringLayout() async throws {
        for axis in [SplitAxis.horizontal, .vertical] {
            let f = try Fixture(); defer { f.close() }
            f.store.interfacePreferences.animationStyle = .off
            await f.layout()
            let view = try await f.splitWithShortcut(axis)
            await f.layout()
            XCTAssertTrue(f.window.firstResponder === view)
            let parent = try XCTUnwrap(view.superview)
            view.removeFromSuperview()
            XCTAssertFalse(f.window.firstResponder === view)
            parent.addSubview(view)
            await f.layout()
            XCTAssertTrue(f.window.firstResponder === view,
                          "Split layout reparenting must retain the selected terminal's input focus")
            XCTAssertEqual(f.store.focusedID, view.paneID)
            try f.assertFirstKeyReaches(view)
            XCTAssertTrue(f.views.allSatisfy { !$0.started && !$0.process.running })
            XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
        }
    }

    // Implements: FR-NAV-2, FR-INPUT-1
    func testLayoutReattachmentDoesNotStealNewNativeEditorFocus() async throws {
        let f = try Fixture(); defer { f.close() }
        await f.layout()
        let view = try await f.splitWithShortcut(.horizontal)
        await f.layout()
        let parent = try XCTUnwrap(view.superview)
        view.removeFromSuperview()
        parent.addSubview(view)
        let editor = NSTextView(frame: NSRect(x: 10, y: 10, width: 100, height: 30))
        f.host.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        await f.layout()
        XCTAssertTrue(f.window.firstResponder === editor)
    }

    // Implements: FR-NAV-2
    func testLayoutReattachmentDoesNotOverrideANewerPaneSelection() async throws {
        let f = try Fixture(); defer { f.close() }
        await f.layout()
        let view = try await f.splitWithShortcut(.vertical)
        await f.layout()
        let parent = try XCTUnwrap(view.superview)
        view.removeFromSuperview()
        var snapshot = f.store.state
        try snapshot.layout.focusPane(f.views[0].paneID)
        f.store.applyCapturedNavigation(snapshot, sessions: f.store.sessions)
        parent.addSubview(view)
        await f.layout()
        XCTAssertTrue(f.window.firstResponder === f.views[0])
        XCTAssertEqual(f.store.focusedID, f.views[0].paneID)
    }

    // Implements: FR-NAV-2
    func testLayoutFocusReturnDoesNotFollowATerminalIntoAnotherWindow() async throws {
        let f = try Fixture(); defer { f.close() }
        await f.layout()
        let view = try await f.splitWithShortcut(.horizontal)
        await f.layout()
        let other = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 500, height: 400),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false; other.animationBehavior = .none
        defer { other.contentView = nil; other.close() }
        other.orderFrontRegardless()
        view.removeFromSuperview()
        try XCTUnwrap(other.contentView).addSubview(view)
        XCTAssertTrue(other.makeFirstResponder(other))
        await f.layout()
        XCTAssertFalse(other.firstResponder === view)
    }

    private func checkSplit(_ axis: SplitAxis, shortcut: Bool = false) async throws {
        let f = try Fixture(); defer { f.close() }
        await f.layout()
        XCTAssertTrue(f.window.makeFirstResponder(f.views[0]))
        for _ in 0..<2 {
            let view: TranoView
            if shortcut { view = try await f.splitWithShortcut(axis) }
            else { view = try f.split(axis) }
            await f.layout()
            XCTAssertTrue(view.window === f.window)
            XCTAssertGreaterThan(view.bounds.width, 0)
            XCTAssertGreaterThan(view.bounds.height, 0)
            XCTAssertEqual(f.store.focusedID, view.paneID)
            XCTAssertTrue(f.window.firstResponder === view,
                          "New split must own native input after SwiftUI finishes mounting")
            try f.assertFirstKeyReaches(view)
        }
        XCTAssertTrue(f.views.allSatisfy { !$0.started && !$0.process.running })
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.runtime.host.socketPath))
        XCTAssertEqual(try f.runtime.state().sessions.count, shortcut ? 3 : 1)
        XCTAssertNil(f.store.message)
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()
        var bytes: Data { lock.lock(); defer { lock.unlock() }; return stored }
        func record(_ bytes: [UInt8]) { lock.lock(); defer { lock.unlock() }; stored.append(contentsOf: bytes) }
    }

    @MainActor private final class Fixture {
        let root: URL
        let backend = FakePaneBackend()
        let runtime: TerminalRuntime
        let store: AppStore
        let host: NSHostingView<WorkspaceView>
        let window: NSWindow
        var views: [TranoView] = []
        var stateObservation: AnyCancellable?

        init() throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/t-split-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            backend.allowSpawn = true
            backend.workingDirectoryPath = root.path
            runtime.host = backend
            store = AppStore(runtime: runtime, startServices: false)
            var state = RuntimeState()
            state.settings.automaticRestore = false
            state.layout.addWorkspace(title: "split-fixture")
            let id = UUID().uuidString.lowercased()
            state.sessions = [TerminalSession(id: id, title: "Original", cwd: root.path, pid: 0, alive: false)]
            state.layout.addTab(paneID: id)
            try runtime.update { $0 = state }
            let view = TranoView.makeClipboardTerminal(frame: .zero)
            view.store = store; view.paneID = id
            views.append(view); store.terminalViews[id] = view
            store.applyCapturedNavigation(state, sessions: state.sessions)
            host = NSHostingView(rootView: WorkspaceView(store: store))
            window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 1100, height: 800), contentView: host)
            window.animationBehavior = .none
            window.orderFrontRegardless()
            stateObservation = store.$state.sink { [weak self] state in
                guard let self else { return }
                for session in state.sessions where self.store.terminalViews[session.id] == nil {
                    let view = TranoView.makeClipboardTerminal(frame: .zero)
                    view.store = self.store; view.paneID = session.id
                    self.views.append(view); self.store.terminalViews[session.id] = view
                }
            }
        }

        func splitWithShortcut(_ axis: SplitAxis) async throws -> TranoView {
            let delegate = ApplicationDelegate()
            delegate.windows[window] = store
            delegate.observeSettings(store, window: window)
            let shifted = axis == .vertical
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: shifted ? [.command, .shift] : .command, timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: shifted ? "D" : "d",
                charactersIgnoringModifiers: shifted ? "D" : "d", isARepeat: false, keyCode: 2))
            let oldID = store.focusedID
            XCTAssertTrue(delegate.handle(key))
            await withCheckedContinuation { continuation in
                store.queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
            XCTAssertNil(store.message)
            XCTAssertNotEqual(store.focusedID, oldID)
            return try XCTUnwrap(store.focusedID.flatMap { store.terminalViews[$0] })
        }

        func split(_ axis: SplitAxis) throws -> TranoView {
            var snapshot = store.state
            let id = UUID().uuidString.lowercased()
            snapshot.sessions.append(TerminalSession(id: id, title: "Split", cwd: root.path, pid: 0, alive: false))
            try snapshot.layout.split(tabID: XCTUnwrap(snapshot.layout.selectedTabID), paneID: id, axis: axis)
            let view = TranoView.makeClipboardTerminal(frame: .zero)
            view.store = store; view.paneID = id
            views.append(view); store.terminalViews[id] = view
            store.applyCapturedNavigation(snapshot, sessions: snapshot.sessions)
            return view
        }

        func layout() async {
            for _ in 0..<8 {
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: .milliseconds(30))
            }
        }

        func assertFirstKeyReaches(_ target: TranoView) throws {
            let recorders = views.map { view in
                let recorder = Recorder()
                view.setProcessInputHandler { bytes, origin, _ in
                    if case .user = origin { recorder.record(bytes) }
                }
                return recorder
            }
            let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: 0, windowNumber: window.windowNumber, context: nil, characters: "a",
                charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
            window.firstResponder?.keyDown(with: key)
            for (view, recorder) in zip(views, recorders) {
                XCTAssertEqual(recorder.bytes, view === target ? Data("a".utf8) : Data())
            }
        }

        func close() {
            stateObservation?.cancel()
            views.forEach { $0.frameDriver.invalidate() }
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }
}
