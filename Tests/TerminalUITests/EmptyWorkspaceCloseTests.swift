import AppKit
import SwiftUI
import XCTest
@testable import SwiftTerm
@testable import TerminalCore
@testable import TranoApp

@MainActor final class EmptyWorkspaceCloseTests: XCTestCase {
    // Implements: FR-NAV-4, FR-NAV-6
    func testClosingEmptySessionAdvancesWithoutClosingWindowRegardlessOfName() async throws {
        for action in [ActionID.closePane, .closeTab] {
            for title in ["workspace", "Workspace", "amber-cedar"] {
                let f = try Fixture(title: title)
                defer { f.close() }
                f.store.execute(action)
                await drain(f.store)
                try await layout(f)
                let state = try f.runtime.state()
                XCTAssertTrue(try XCTUnwrap(state.layout.workspaces.first { $0.id == f.target }).closed)
                XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.successor)
                XCTAssertEqual(f.store.focusedID, f.sessions.last?.id)
                XCTAssertEqual(f.windowCloseCalls, 0)
                XCTAssertTrue(f.window.isVisible)
                XCTAssertTrue(f.views.last?.window === f.window)
                try f.assertSessionsUnchanged()
            }
        }
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testClosingLastEmptySessionKeepsWindowEmptyWithoutCreatingATerminal() async throws {
        let f = try Fixture(title: "workspace", includeSuccessor: false)
        defer { f.close() }
        f.store.execute(.closePane)
        await drain(f.store)
        XCTAssertTrue(try XCTUnwrap(try f.runtime.state().layout.workspaces.first).closed)
        XCTAssertNil(f.store.state.layout.selectedWorkspaceID)
        XCTAssertNil(f.store.selectedTab)
        XCTAssertEqual(f.windowCloseCalls, 0)
        XCTAssertTrue(f.window.isVisible)
        try f.assertSessionsUnchanged()

        f.store.execute(.closePane)
        XCTAssertEqual(f.windowCloseCalls, 1, "An already empty native window can still be explicitly closed")
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testQueuedRepeatedClosesCannotRetargetTheSuccessor() async throws {
        let f = try Fixture(title: "workspace")
        defer { f.close() }
        let gate = DispatchSemaphore(value: 0)
        f.store.queue.async { gate.wait() }
        f.store.execute(.closePane)
        f.store.execute(.closeTab)
        gate.signal()
        await drain(f.store)
        let layout = try f.runtime.state().layout
        XCTAssertTrue(try XCTUnwrap(layout.workspaces.first { $0.id == f.target }).closed)
        XCTAssertFalse(try XCTUnwrap(layout.workspaces.first { $0.id == f.successor }).closed)
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.successor)
        XCTAssertEqual(f.windowCloseCalls, 0)
        try f.assertSessionsUnchanged()
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testQueuedCloseRechecksNavigationBeforeMutation() async throws {
        let f = try Fixture(title: "workspace")
        defer { f.close() }
        let gate = DispatchSemaphore(value: 0)
        f.store.queue.async { gate.wait() }
        f.store.execute(.closePane)
        f.store.showSettings = true
        gate.signal()
        await drain(f.store)
        XCTAssertFalse(try XCTUnwrap(try f.runtime.state().layout.workspaces.first { $0.id == f.target }).closed)
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.target)
        XCTAssertEqual(f.windowCloseCalls, 0)
        try f.assertSessionsUnchanged()
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testNativeCommandWClosesEmptySessionWithoutClosingItsWindow() async throws {
        let f = try Fixture(title: "Workspace")
        defer { f.close() }
        let delegate = ApplicationDelegate()
        delegate.windows[f.window] = f.store
        delegate.observeSettings(f.store, window: f.window)
        XCTAssertTrue(delegate.handle(try closeKey(in: f.window)))
        await drain(f.store)
        XCTAssertTrue(try XCTUnwrap(try f.runtime.state().layout.workspaces.first { $0.id == f.target }).closed)
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.successor)
        XCTAssertEqual(f.windowCloseCalls, 0)
        XCTAssertTrue(f.window.isVisible)
        try f.assertSessionsUnchanged()
    }

    // Implements: FR-NAV-4, FR-NAV-6, FR-INPUT-1
    func testNativeQueuedClosePreservesCompositionInAnEmptyWorkspace() async throws {
        let f = try Fixture(title: "Workspace")
        defer { f.close() }
        let editor = NSTextView(frame: NSRect(x: 10, y: 80, width: 200, height: 60))
        f.host.addSubview(editor)
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        let delegate = ApplicationDelegate()
        delegate.windows[f.window] = f.store
        delegate.observeSettings(f.store, window: f.window)
        let gate = DispatchSemaphore(value: 0)
        f.store.queue.async { gate.wait() }
        XCTAssertTrue(delegate.handle(try closeKey(in: f.window)))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        gate.signal()
        await drain(f.store)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertFalse(try XCTUnwrap(try f.runtime.state().layout.workspaces.first { $0.id == f.target }).closed)
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.target)
        XCTAssertEqual(f.windowCloseCalls, 0)
        XCTAssertTrue(f.window.isVisible)
        try f.assertSessionsUnchanged()
    }

    // Implements: FR-NAV-4, FR-NAV-6
    func testNativeHeaderCloseRetiresTheNamedSessionViewAndKeepsTheSuccessor() async throws {
        let f = try Fixture(title: "workspace", populatedTarget: true)
        defer { f.close() }
        for _ in 0..<3 { f.host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
        let button = try XCTUnwrap(region("header-workspace-close-" + f.target, in: f.host) as? NSButton)
        button.performClick(nil)
        await drain(f.store)
        try await layout(f)
        XCTAssertTrue(try XCTUnwrap(try f.runtime.state().layout.workspaces.first { $0.id == f.target }).closed)
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.successor)
        XCTAssertNil(f.store.terminalViews[f.sessions[0].id])
        XCTAssertTrue(f.store.terminalViews[f.sessions[1].id] === f.views[1])
        XCTAssertTrue(f.views[1].window === f.window)
        XCTAssertEqual(f.windowCloseCalls, 0)
        XCTAssertTrue(f.window.isVisible)
        try f.assertSessionsUnchanged()
    }

    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let target: String
        let successor: String?
        let sessions: [TerminalSession]
        let views: [TranoView]
        let host: NSHostingView<WorkspaceView>
        let window: NSWindow
        var windowCloseCalls = 0

        init(title: String, includeSuccessor: Bool = true, populatedTarget: Bool = false) throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/t-close-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            var state = RuntimeState()
            state.settings.automaticRestore = false
            target = state.layout.addWorkspace(title: title)
            if populatedTarget {
                var pane = TerminalSession(id: UUID().uuidString, title: "Closing", cwd: root.path, pid: 4711)
                pane.alive = false
                state.sessions.append(pane)
                state.layout.addTab(paneID: pane.id)
            }
            if includeSuccessor {
                successor = state.layout.addWorkspace(title: "next-session")
                var pane = TerminalSession(id: UUID().uuidString, title: "Retained", cwd: root.path, pid: 4712)
                pane.alive = false
                state.sessions.append(pane)
                state.layout.addTab(paneID: pane.id)
            } else { successor = nil }
            try state.layout.selectWorkspace(target)
            try runtime.update { $0 = state }
            sessions = state.sessions
            let model = AppStore(runtime: runtime, startServices: false)
            store = model
            model.interfacePreferences.animationStyle = .off
            views = sessions.map { session in
                let view = TranoView.makeClipboardTerminal(frame: .zero)
                view.store = model; view.paneID = session.id
                model.terminalViews[session.id] = view
                return view
            }
            store.applyCapturedNavigation(state, sessions: sessions)
            host = NSHostingView(rootView: WorkspaceView(store: store))
            window = WorkspaceWindow.make(contentRect: NSRect(x: -12000, y: -12000, width: 900, height: 600), contentView: host)
            window.animationBehavior = .none
            window.orderFrontRegardless()
            store.onCloseWindow = { [weak self] in
                self?.windowCloseCalls += 1
                self?.window.close()
            }
        }

        func assertSessionsUnchanged(file: StaticString = #filePath, line: UInt = #line) throws {
            XCTAssertEqual(try runtime.state().sessions, sessions, file: file, line: line)
            XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.host.socketPath), file: file, line: line)
            XCTAssertTrue(views.allSatisfy { !$0.started && !$0.process.running }, file: file, line: line)
            XCTAssertNil(store.message, file: file, line: line)
        }

        func close() {
            views.forEach { $0.frameDriver.invalidate() }
            window.contentView = nil; window.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func drain(_ store: AppStore) async {
        await withCheckedContinuation { continuation in
            store.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
    }

    private func layout(_ f: Fixture) async throws {
        for _ in 0..<3 { f.host.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(20)) }
    }

    private func closeKey(in window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
            windowNumber: window.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
    }

    private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }
}
