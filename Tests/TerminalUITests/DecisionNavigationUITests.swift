import AppKit
import Darwin
import SwiftUI
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class DecisionNavigationUITests: XCTestCase {
    // Implements: FR-DECISION-5
    @MainActor func testNativeGoOpensTheExactQuestionPaneIncludingAClosedWorkspaceWithoutAnswering() async throws {
        for closed in [false, true] {
            let f = try await fixture(closedTarget: closed)
            defer { dispose(f) }
            let before = try f.runtime.state().layout.tabs
            let pids = try identities(f)
            try await openQuestion(f)
            let go = try goButton(f)
            XCTAssertEqual(go.title, "Go to Session")
            XCTAssertTrue(go.target === go)
            XCTAssertTrue(go.isEnabled)
            go.performClick(nil)
            try await settle(f) {
                f.store.decisionPaneID == nil && f.store.state.layout.selectedWorkspaceID == f.alpha &&
                f.store.focusedID == f.panes[0] && f.store.terminalViews[f.panes[0]]?.process.running == true
            }
            XCTAssertEqual(f.store.selectedTab?.id, f.targetTab)
            XCTAssertTrue(f.store.terminalViews[f.panes[0]]?.window === f.window)
            let after = try f.runtime.state().layout.tabs
            XCTAssertEqual(after.map(\.id), before.map(\.id))
            XCTAssertEqual(after.map(\.workspaceID), before.map(\.workspaceID))
            XCTAssertEqual(after.map(\.tree), before.map(\.tree))
            XCTAssertFalse(try XCTUnwrap(try f.runtime.state().layout.workspaces.first { $0.id == f.alpha }).closed)
            try assertPendingAndJobs(f, pids: pids)
        }
    }

    // Implements: FR-DECISION-5, FR-INPUT-1
    @MainActor func testGoPreservesChoiceAndExactDraftAndRefusesMarkedText() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        try await openQuestion(f)
        try XCTUnwrap(region("decision-option-disk", in: f.hosting) as? NSButton).performClick(nil)
        let editor = try XCTUnwrap(answerEditor(in: f.hosting))
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        let text = "후속 설명\n" + "한글".decomposedStringWithCanonicalMapping + " 👩🏽‍💻"
        editor.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        try await settle(f) { editor.string == text }
        editor.setMarkedText("ㅎ", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange()
        try goButton(f).performClick(nil)
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(f.store.decisionPaneID, f.panes[0])
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.beta)
        editor.unmarkText()
        let committed = Data(editor.string.utf8)
        try await Task.sleep(for: .milliseconds(100))
        try goButton(f).performClick(nil)
        try await settle(f) { f.store.decisionPaneID == nil && f.store.focusedID == f.panes[0] }
        try await openQuestion(f)
        let restored = try XCTUnwrap(answerEditor(in: f.hosting))
        XCTAssertEqual(Data(restored.string.utf8), committed)
        XCTAssertEqual(try XCTUnwrap(region("decision-option-disk", in: f.hosting) as? NSButton).state, .on)
        XCTAssertEqual(try f.runtime.decisionInbox().first { $0.id == f.requestID }?.status, "pending")
    }

    // Implements: FR-DECISION-5, FR-INPUT-1
    @MainActor func testCompositionStartedDuringNavigationSurvivesTheCompletionCallback() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        try await openQuestion(f)
        let editor = try XCTUnwrap(answerEditor(in: f.hosting))
        XCTAssertTrue(f.window.makeFirstResponder(editor))
        editor.insertText("이동 중 입력 ", replacementRange: NSRange(location: 0, length: 0))
        let pids = try identities(f)
        f.store.queue.suspend()
        var suspended = true
        defer { if suspended { f.store.queue.resume() } }
        try goButton(f).performClick(nil)
        XCTAssertTrue(f.store.decisionSaving)
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange(), text = Data(editor.string.utf8)
        suspended = false
        f.store.queue.resume()
        try await settle(f) { !f.store.decisionSaving }
        XCTAssertEqual(f.store.decisionPaneID, f.panes[0])
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.beta)
        XCTAssertEqual(f.store.focusedID, f.panes[2])
        XCTAssertNotNil(region("decision-go-to-session", in: f.hosting))
        XCTAssertTrue(editor.window === f.window)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(Data(editor.string.utf8), text)
        try assertPendingAndJobs(f, pids: pids)
        guard f.store.decisionPaneID != nil else { return }
        editor.unmarkText()
        try goButton(f).performClick(nil)
        try await settle(f) { f.store.decisionPaneID == nil && f.store.focusedID == f.panes[0] }
        try assertPendingAndJobs(f, pids: pids)
    }

    // Implements: FR-DECISION-5
    @MainActor func testStaleGenerationFailsWithoutNavigatingOrRestartingJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        try await openQuestion(f)
        let go = try goButton(f), pids = try identities(f)
        f.store.queue.suspend()
        var suspended = true
        defer { if suspended { f.store.queue.resume() } }
        try f.runtime.update { state in
            let index = try XCTUnwrap(state.agentLaunches.firstIndex { $0.paneID == f.panes[0] })
            state.agentLaunches[index].id = UUID().uuidString.lowercased()
        }
        go.performClick(nil)
        suspended = false
        f.store.queue.resume()
        try await settle(f) { !f.store.decisionSaving && f.store.decisionError != nil }
        XCTAssertEqual(f.store.decisionPaneID, f.panes[0])
        XCTAssertEqual(f.store.state.layout.selectedWorkspaceID, f.beta)
        XCTAssertEqual(f.store.focusedID, f.panes[2])
        XCTAssertEqual(try identities(f), pids)
    }

    // Implements: FR-DECISION-5, FR-NAV-4
    @MainActor func testGoFocusesAnExistingFloatOwnerWithoutDuplicatingItsRenderer() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let owner = AppStore(runtime: f.runtime)
        let (window, _) = makeWindow(owner, delegate: f.delegate)
        f.extra.append((owner, window))
        try await settle(f) { !owner.loading }
        owner.selectWorkspace(f.alpha)
        try await settle(f) { owner.preferredWorkspaceID == f.alpha && owner.terminalViews[f.panes[0]]?.process.running == true }
        let terminal = try XCTUnwrap(owner.terminalViews[f.panes[0]])
        let client = terminal.process.shellPid
        owner.floatingPanes.toggle(f.panes[0])
        try await settle(f) { terminal.window != nil && terminal.window !== window }
        let panel = try XCTUnwrap(terminal.window)
        XCTAssertEqual(panel.level, .floating)
        let pids = try identities(f)
        try await openQuestion(f)
        try goButton(f).performClick(nil)
        try await settle(f) { f.store.decisionPaneID == nil && panel.isVisible && panel.firstResponder === terminal }
        XCTAssertEqual(f.store.preferredWorkspaceID, f.beta)
        XCTAssertNil(f.store.terminalViews[f.panes[0]])
        XCTAssertTrue(owner.terminalViews[f.panes[0]] === terminal)
        XCTAssertTrue(terminal.window === panel)
        XCTAssertEqual(terminal.process.shellPid, client)
        XCTAssertTrue(terminal.process.running)
        try assertPendingAndJobs(f, pids: pids)
    }

    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let hosting: NSHostingView<WorkspaceView>
        let delegate: ApplicationDelegate
        let panes: [String]
        let alpha: String
        let beta: String
        let targetTab: String
        let requestID: String
        var extra: [(AppStore, NSWindow)] = []
        init(root: URL, runtime: TerminalRuntime, store: AppStore, window: NSWindow, hosting: NSHostingView<WorkspaceView>, delegate: ApplicationDelegate, panes: [String], alpha: String, beta: String, targetTab: String, requestID: String) {
            self.root = root; self.runtime = runtime; self.store = store; self.window = window; self.hosting = hosting
            self.delegate = delegate; self.panes = panes; self.alpha = alpha; self.beta = beta; self.targetTab = targetTab; self.requestID = requestID
        }
    }

    @MainActor private func fixture(closedTarget: Bool = false) async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-decision-go-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        do {
            let panes = try (0..<3).map { try runtime.create(title: "Question pane \($0)", cwd: root.path, shell: "/bin/sleep", arguments: ["90"]).id }
            var alpha = "", beta = "", targetTab = ""
            try runtime.update { state in
                state.settings.automaticRestore = false
                alpha = state.layout.addWorkspace(title: "Alpha")
                targetTab = state.layout.addTab(paneID: panes[0])
                try state.layout.split(tabID: targetTab, paneID: panes[1], axis: .horizontal)
                beta = state.layout.addWorkspace(title: "Beta")
                state.layout.addTab(paneID: panes[2])
                if closedTarget { state.layout.closeWorkspace(alpha) }
            }
            var launch = try runtime.beginAgentLaunch(paneID: panes[0], provider: .codex, cwd: root.path, configurationRoot: root.appendingPathComponent("provider").path)
            launch.providerSessionID = UUID().uuidString.lowercased(); launch.providerPID = getpid()
            try runtime.update { $0.agentLaunches = [launch] }
            let id = UUID().uuidString.lowercased()
            let question: JSONValue = .object(["schema_version": .string("1.0"), "request_id": .string(id), "thread_id": .string(UUID().uuidString.lowercased()),
                "source": .object(["agent": .string("codex"), "session_id": .string(launch.providerSessionID!), "workspace": .string(root.path)]),
                "question": .string("Choose storage"), "options": .array([
                    .object(["id": .string("disk"), "label": .string("Disk"), "description": .string("Retain data")]),
                    .object(["id": .string("memory"), "label": .string("Memory"), "description": .string("Temporary data")])])])
            let response = try runtime.decisionAdapter(.object(["type": .string("submit"), "question": question, "trano_binding": .object(["pane_id": .string(panes[0]), "generation": .string(launch.id)])]))
            XCTAssertEqual(response["status"], .string("pending"))
            let store = AppStore(runtime: runtime), delegate = ApplicationDelegate()
            let (window, hosting) = makeWindow(store, delegate: delegate)
            delegate.store = store; delegate.window = window
            let f = Fixture(root: root, runtime: runtime, store: store, window: window, hosting: hosting, delegate: delegate, panes: panes, alpha: alpha, beta: beta, targetTab: targetTab, requestID: id)
            try await settle(f) { !store.loading && store.terminalViews[panes[2]]?.process.running == true && store.pendingDecisions.contains { $0.id == id } }
            return f
        } catch {
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            runtime.shutdownTestHost()
            try? FileManager.default.removeItem(at: root)
            throw error
        }
    }

    @MainActor private func makeWindow(_ store: AppStore, delegate: ApplicationDelegate) -> (NSWindow, NSHostingView<WorkspaceView>) {
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 720), contentView: hosting)
        window.delegate = delegate; delegate.windows[window] = store
        delegate.observeSettings(store, window: window); delegate.configureFloatingPanes(store)
        window.orderFrontRegardless()
        return (window, hosting)
    }

    @MainActor private func openQuestion(_ f: Fixture) async throws {
        f.store.openDecisions()
        try await settle(f) { f.store.decisionPaneID == f.panes[0] && self.region("decision-option-disk", in: f.hosting) != nil }
    }

    @MainActor private func goButton(_ f: Fixture) throws -> NSButton {
        try XCTUnwrap(region("decision-go-to-session", in: f.hosting) as? NSButton)
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id && !view.isHiddenOrHasHiddenAncestor && !view.visibleRect.isEmpty { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }

    @MainActor private func answerEditor(in view: NSView) -> NSTextView? {
        if let editor = view as? NSTextView, editor.isEditable, !editor.isFieldEditor, !editor.isHiddenOrHasHiddenAncestor, !editor.visibleRect.isEmpty { return editor }
        return view.subviews.lazy.compactMap { self.answerEditor(in: $0) }.first
    }

    @MainActor private func settle(_ f: Fixture, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            f.hosting.layoutSubtreeIfNeeded(); for (_, window) in f.extra { window.contentView?.layoutSubtreeIfNeeded() }
            if condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        XCTFail("Decision navigation did not settle: " + (f.store.decisionError ?? f.store.message ?? "no error"))
    }

    @MainActor private func identities(_ f: Fixture) throws -> [String: Int32] { Dictionary(uniqueKeysWithValues: try f.runtime.list().map { ($0.id, $0.pid) }) }

    @MainActor private func assertPendingAndJobs(_ f: Fixture, pids: [String: Int32], file: StaticString = #filePath, line: UInt = #line) throws {
        let entry = try XCTUnwrap(try f.runtime.decisionInbox().first { $0.id == f.requestID }, file: file, line: line)
        XCTAssertEqual(entry.status, "pending", file: file, line: line)
        XCTAssertNil(entry.resolution, file: file, line: line)
        XCTAssertFalse(entry.delivered, file: file, line: line)
        XCTAssertEqual(try identities(f), pids, file: file, line: line)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive), file: file, line: line)
    }

    @MainActor private func dispose(_ f: Fixture) {
        for (store, window) in [(f.store, f.window)] + f.extra {
            store.floatingPanes.closeAll(); for view in store.terminalViews.values { view.terminate() }; store.terminalViews.removeAll(); window.close()
        }
        for pane in (try? f.runtime.list()) ?? [] { try? f.runtime.terminate(pane.id) }
        f.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: f.root)
    }
}
