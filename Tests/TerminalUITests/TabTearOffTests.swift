import AppKit
import Darwin
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class TabTearOffTests: XCTestCase {
    // Implements: FR-NAV-4, FR-NAV-10
    @MainActor func testOutsideReleaseMovesTheCompleteTabIntoOneNormalWindowAndReconcilesMirrors() async throws {
        let f = try await fixture(mirror: true)
        defer { f.dispose() }
        let before = try f.runtime.state()
        let original = try XCTUnwrap(before.layout.tabs.first { $0.id == f.tab })
        let jobs = try f.jobs()
        let retained = try XCTUnwrap(f.source.terminalViews[f.retainedPane!])
        let retainedClient = retained.process.shellPid
        let data = try XCTUnwrap(WorkspaceDrag.shared.tabPayload(tabID: f.tab, store: f.source))

        XCTAssertTrue(f.finish(data))
        try await f.settle {
            guard let model = f.detachedStore else { return false }
            return f.panes.allSatisfy { model.terminalViews[$0]?.process.running == true &&
                f.source.terminalViews[$0] == nil && f.mirror?.terminalViews[$0] == nil }
        }

        let model = try XCTUnwrap(f.detachedStore)
        let window = try XCTUnwrap(f.detached.first)
        let after = try f.runtime.state()
        let transferred = try XCTUnwrap(after.layout.tabs.first { $0.id == f.tab })
        XCTAssertEqual(f.detached.count, 1)
        XCTAssertFalse(window is NSPanel)
        XCTAssertEqual(window.level, .normal)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertNotEqual(model.preferredWorkspaceID, f.workspace)
        XCTAssertEqual(model.selectedTab?.id, original.id)
        XCTAssertEqual(model.state.layout.currentTabs.map(\.id), [original.id])
        XCTAssertEqual(model.focusedID, original.focusedPaneID)
        XCTAssertEqual(transferred.title, original.title)
        XCTAssertEqual(transferred.tree, original.tree)
        XCTAssertEqual(transferred.focusedPaneID, original.focusedPaneID)
        XCTAssertEqual(transferred.workspaceID, model.preferredWorkspaceID)
        XCTAssertEqual(after.layout.tabs.filter { $0.id == f.tab }.count, 1)
        XCTAssertEqual(f.source.state.layout.currentTabs.map(\.id), [f.retainedTab!])
        XCTAssertEqual(f.mirror?.state.layout.currentTabs.map(\.id), [f.retainedTab!])
        XCTAssertEqual(after.layout.workspaces.count, before.layout.workspaces.count + 1)
        XCTAssertEqual(after.sessions.map(\.id), before.sessions.map(\.id))
        XCTAssertEqual(after.agentLaunches.map(\.id), before.agentLaunches.map(\.id))
        XCTAssertEqual(try f.jobs(), jobs)
        XCTAssertTrue(f.source.terminalViews[f.retainedPane!] === retained)
        XCTAssertEqual(retained.process.shellPid, retainedClient)
        XCTAssertFalse(f.finish(data), "A completed tab drag cannot create another window")
        XCTAssertEqual(f.detached.count, 1)
    }

    // Implements: FR-NAV-4, FR-NAV-10
    @MainActor func testOnlyVisibleTabDetachesIntoANewWindowAndLeavesItsSourceWorkspaceOpenAndEmpty() async throws {
        let f = try await fixture(singleTab: true)
        defer { f.dispose() }
        let before = try f.runtime.state()
        let original = try XCTUnwrap(before.layout.tabs.first { $0.id == f.tab })
        let jobs = try f.jobs()
        let data = try XCTUnwrap(WorkspaceDrag.shared.tabPayload(tabID: f.tab, store: f.source))

        XCTAssertTrue(f.finish(data))
        try await f.settle {
            guard let model = f.detachedStore else { return false }
            return f.source.state.layout.currentTabs.isEmpty && f.panes.allSatisfy {
                model.terminalViews[$0]?.process.running == true && f.source.terminalViews[$0] == nil
            }
        }

        let model = try XCTUnwrap(f.detachedStore)
        let window = try XCTUnwrap(f.detached.first)
        let after = try f.runtime.state()
        let sourceWorkspace = try XCTUnwrap(after.layout.workspaces.first { $0.id == f.workspace })
        XCTAssertTrue(f.sourceWindow.isVisible)
        XCTAssertEqual(f.detached.count, 1)
        XCTAssertEqual(f.delegate.windows.count, 2)
        XCTAssertFalse(window is NSPanel)
        XCTAssertEqual(window.level, .normal)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertFalse(sourceWorkspace.closed)
        XCTAssertFalse(after.layout.tabs.contains { $0.workspaceID == f.workspace })
        XCTAssertEqual(f.source.preferredWorkspaceID, f.workspace)
        XCTAssertNil(f.source.selectedTab)
        XCTAssertNil(f.source.focusedID)
        XCTAssertNotEqual(model.preferredWorkspaceID, f.workspace)
        XCTAssertEqual(model.state.layout.currentTabs.map(\.id), [original.id])
        XCTAssertEqual(model.selectedTab?.tree, original.tree)
        XCTAssertEqual(model.selectedTab?.title, original.title)
        XCTAssertEqual(model.focusedID, original.focusedPaneID)
        XCTAssertEqual(after.layout.tabs.map(\.id), before.layout.tabs.map(\.id))
        XCTAssertEqual(after.layout.workspaces.count, before.layout.workspaces.count + 1)
        XCTAssertEqual(after.sessions.map(\.id), before.sessions.map(\.id))
        XCTAssertEqual(after.agentLaunches.map(\.id), before.agentLaunches.map(\.id))
        XCTAssertEqual(try f.jobs(), jobs)
        XCTAssertFalse(f.finish(data))
        XCTAssertEqual(f.detached.count, 1)
    }

    // Implements: FR-NAV-4, FR-NAV-10
    @MainActor func testDetachedTabWindowDoesNotRestoreAnUnrelatedDeadJob() async throws {
        let f = try await fixture()
        defer { f.dispose() }
        let liveJobs = try f.jobs()
        let unrelated = try f.runtime.create(title: "Retained dead job", cwd: f.root.path,
                                             shell: "/bin/sleep", arguments: ["180"])
        try f.runtime.update { state in
            _ = state.layout.addWorkspace(title: "Unrelated")
            state.layout.addTab(paneID: unrelated.id)
            try state.layout.selectWorkspace(f.workspace)
            try state.layout.selectTab(f.tab)
            state.settings.automaticRestore = true
        }
        try f.runtime.killPaneProcess(unrelated.id)
        XCTAssertFalse(try XCTUnwrap(f.runtime.list().first { $0.id == unrelated.id }).alive)
        let before = try f.runtime.state()
        let data = try XCTUnwrap(WorkspaceDrag.shared.tabPayload(tabID: f.tab, store: f.source))

        XCTAssertTrue(f.finish(data))
        try await f.settle {
            guard let model = f.detachedStore else { return false }
            return !model.loading && f.panes.allSatisfy { model.terminalViews[$0]?.process.running == true }
        }

        let after = try f.runtime.state()
        let sessions = try f.runtime.list()
        let dead = try XCTUnwrap(sessions.first { $0.id == unrelated.id })
        XCTAssertFalse(dead.alive)
        XCTAssertEqual(dead.pid, unrelated.pid)
        for (id, pid) in liveJobs {
            let job = try XCTUnwrap(sessions.first { $0.id == id })
            XCTAssertTrue(job.alive)
            XCTAssertEqual(job.pid, pid)
        }
        XCTAssertEqual(after.sessions.map(\.id), before.sessions.map(\.id))
        XCTAssertEqual(after.agentLaunches.map(\.id), before.agentLaunches.map(\.id))
        XCTAssertTrue(after.settings.automaticRestore)
        XCTAssertEqual(f.detached.count, 1)
    }

    // Implements: FR-NAV-4, FR-NAV-10
    @MainActor func testCancellationNoReleaseAndInsideReleaseNeverMoveOrDetach() async throws {
        for singleTab in [false, true] {
            let f = try await fixture(singleTab: singleTab)
            defer { f.dispose() }
            let layout = try f.runtime.state().layout
            let jobs = try f.jobs()
            let frame = f.sourceWindow.frame
            for (cancelled, released, inside) in [(true, true, false), (true, false, false), (false, false, false), (false, true, true)] {
                let data = try XCTUnwrap(WorkspaceDrag.shared.tabPayload(tabID: f.tab, store: f.source))
                let point = inside ? NSPoint(x: frame.midX, y: frame.midY) : f.outside
                XCTAssertFalse(WorkspaceDrag.shared.finishTabDrag(data, from: f.sourceWindow, at: point,
                                                                 operation: [], cancelled: cancelled, released: released))
            }
            XCTAssertFalse(f.finish(Data(UUID().uuidString.utf8)))
            await f.drain()
            XCTAssertEqual(f.detached.count, 0)
            XCTAssertEqual(f.sourceWindow.frame, frame)
            XCTAssertEqual(try f.runtime.state().layout, layout)
            XCTAssertEqual(try f.jobs(), jobs)
        }
    }

    // Implements: FR-NAV-4, FR-NAV-10
    @MainActor func testAcceptedMoveKeepsItsTokenForTheAsynchronousReceiver() async throws {
        let f = try await fixture(destination: true)
        defer { f.dispose() }
        let target = try XCTUnwrap(f.destination)
        let targetTab = try XCTUnwrap(target.selectedTab?.id)
        let original = try XCTUnwrap(f.source.selectedTab)
        let jobs = try f.jobs()
        let frame = f.sourceWindow.frame
        let provider = WorkspaceDrag.shared.provider(tabID: f.tab, store: f.source)
        let data = try await load(provider)

        XCTAssertFalse(WorkspaceDrag.shared.finishTabDrag(data, from: f.sourceWindow, at: f.outside,
                                                         operation: .move, cancelled: false, released: true))
        XCTAssertFalse(WorkspaceDrag.shared.finishTabDrag(data, from: f.sourceWindow, at: f.outside,
                                                         operation: .copy, cancelled: false, released: true))
        XCTAssertTrue(WorkspaceDrag.shared.receive([provider], in: target, tabID: targetTab))
        try await f.settle {
            target.selectedTab?.id == f.tab && f.panes.allSatisfy {
                target.terminalViews[$0]?.process.running == true && f.source.terminalViews[$0] == nil
            }
        }

        XCTAssertEqual(f.detached.count, 0)
        XCTAssertEqual(f.sourceWindow.frame, frame)
        XCTAssertEqual(target.selectedTab?.tree, original.tree)
        XCTAssertEqual(target.selectedTab?.title, original.title)
        XCTAssertEqual(target.focusedID, original.focusedPaneID)
        XCTAssertEqual(try f.runtime.state().layout.workspaces.count, 2)
        XCTAssertEqual(try f.jobs(), jobs)
        XCTAssertFalse(f.finish(data))
    }

    // Implements: FR-NAV-4, FR-NAV-10
    @MainActor func testQueuedRemovedTabClosedWorkspaceAndClosedWindowCannotDetach() async throws {
        for condition in ["removed-tab", "closed-workspace", "closed-window"] {
            let f = try await fixture()
            defer { f.dispose() }
            let jobs = try f.jobs()
            let frame = f.sourceWindow.frame
            let data = try XCTUnwrap(WorkspaceDrag.shared.tabPayload(tabID: f.tab, store: f.source))
            f.source.queue.suspend()
            var suspended = true
            defer { if suspended { f.source.queue.resume() } }
            XCTAssertTrue(f.finish(data))
            switch condition {
            case "removed-tab": try f.runtime.update { $0.layout.closeTab(f.tab) }
            case "closed-workspace": try f.runtime.update { $0.layout.closeWorkspace(f.workspace) }
            default: f.sourceWindow.close()
            }
            let expected = try f.runtime.state().layout
            suspended = false
            f.source.queue.resume()
            await f.drain()

            XCTAssertEqual(f.detached.count, 0, condition)
            XCTAssertEqual(f.sourceWindow.frame, frame, condition)
            XCTAssertEqual(try f.runtime.state().layout, expected, condition)
            XCTAssertEqual(try f.jobs(), jobs, condition)
            XCTAssertFalse(f.finish(data), condition)
        }
    }

    // Implements: FR-NAV-4, FR-NAV-10, FR-INPUT-1
    @MainActor func testNativeSheetOpenedBeforeQueuedCompletionPreservesTheOriginalTabAndWindow() async throws {
        let f = try await fixture()
        defer { f.dispose() }
        let before = try f.runtime.state().layout
        let jobs = try f.jobs()
        let frame = f.sourceWindow.frame
        let data = try XCTUnwrap(WorkspaceDrag.shared.tabPayload(tabID: f.tab, store: f.source))
        f.source.queue.suspend()
        var suspended = true
        defer { if suspended { f.source.queue.resume() } }
        XCTAssertTrue(f.finish(data))
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false
        f.sourceWindow.beginSheet(sheet, completionHandler: nil)
        defer { f.sourceWindow.endSheet(sheet); sheet.close() }
        XCTAssertTrue(f.sourceWindow.attachedSheet === sheet)
        suspended = false
        f.source.queue.resume()
        await f.drain()

        XCTAssertTrue(f.sourceWindow.attachedSheet === sheet)
        XCTAssertEqual(f.detached.count, 0)
        XCTAssertEqual(f.sourceWindow.frame, frame)
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertEqual(try f.jobs(), jobs)
        XCTAssertEqual(f.source.selectedTab?.id, f.tab)
    }

    private func load(_ provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.tranoTab.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? NSError(domain: "TabTearOff", code: 1)) }
            }
        }
    }

    @MainActor private func fixture(singleTab: Bool = false, mirror: Bool = false, destination: Bool = false) async throws -> Fixture {
        let f = try Fixture(singleTab: singleTab, destination: destination)
        do {
            try await f.settle { !f.source.loading && f.panes.allSatisfy { f.source.terminalViews[$0]?.process.running == true } }
            if let tab = f.retainedTab, let pane = f.retainedPane {
                f.source.selectTab(tab)
                try await f.settle { f.source.selectedTab?.id == tab && f.source.terminalViews[pane]?.process.running == true }
                f.source.selectTab(f.tab)
                try await f.settle { f.source.selectedTab?.id == f.tab && f.panes.allSatisfy { f.source.terminalViews[$0]?.process.running == true } }
            }
            if mirror {
                let model = AppStore(runtime: f.runtime, initialWorkspaceID: f.workspace)
                f.mirror = model
                _ = f.addWindow(model)
                try await f.settle { !model.loading && f.panes.allSatisfy { model.terminalViews[$0]?.process.running == true } }
            }
            if let model = f.destination, let pane = f.destinationPane {
                try await f.settle { !model.loading && model.terminalViews[pane]?.process.running == true }
            }
            return f
        } catch { f.dispose(); throw error }
    }

    @MainActor private final class Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let delegate = ApplicationDelegate()
        let source: AppStore
        let sourceWindow: NSWindow
        let workspace: String
        let tab: String
        let panes: [String]
        let retainedPane: String?
        let retainedTab: String?
        let previousEnvironment: [(String, String?)]
        var stores: [AppStore] = []
        var windows: [NSWindow] = []
        var mirror: AppStore?
        var destination: AppStore?
        var destinationPane: String?
        var detached: [NSWindow] = []
        var detachedStore: AppStore? { detached.first.flatMap { delegate.windows[$0] } }
        let outside = NSPoint(x: -20000, y: -20000)

        init(singleTab: Bool, destination: Bool) throws {
            _ = NSApplication.shared
            let base = URL(fileURLWithPath: "/tmp/trano-tab-" + UUID().uuidString.prefix(8))
            root = base
            let environment = [("TRANO_DATA_DIR", base.appendingPathComponent("runtime").path),
                               ("HOME", base.appendingPathComponent("home").path),
                               ("ZDOTDIR", base.appendingPathComponent("home").path),
                               ("CLAUDE_CONFIG_DIR", base.appendingPathComponent("claude").path),
                               ("CODEX_HOME", base.appendingPathComponent("codex").path)]
            let previous = environment.map { ($0.0, ProcessInfo.processInfo.environment[$0.0]) }
            previousEnvironment = previous
            var initialized = false
            defer { if !initialized { Self.restoreEnvironment(previous) } }
            for (key, path) in environment {
                try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
                setenv(key, path, 1)
            }
            runtime = try TerminalRuntime(root: base.appendingPathComponent("runtime"))
            runtime.setPaneEnvironment(environment.map { ($0.0, $0.1) })
            var ids: [String] = []
            for index in 0..<2 {
                let pane = try runtime.create(title: "Dragged pane \(index)", cwd: base.path,
                                              shell: "/bin/sleep", arguments: ["180"])
                ids.append(pane.id)
                try runtime.report(pane.id, state: .running, agent: index == 0 ? .claude : .codex)
            }
            panes = ids
            let retained = singleTab ? nil : try runtime.create(title: "Retained tab", cwd: base.path,
                                                               shell: "/bin/sleep", arguments: ["180"]).id
            retainedPane = retained
            let destinationID = destination ? try runtime.create(title: "Destination", cwd: base.path,
                                                                 shell: "/bin/sleep", arguments: ["180"]).id : nil
            var workspaceID = "", tabID = "", retainedID: String?, destinationWorkspace: String?
            try runtime.update { state in
                state.settings.automaticRestore = false
                workspaceID = state.layout.addWorkspace(title: "Source")
                tabID = state.layout.addTab(paneID: ids[0])
                try state.layout.split(tabID: tabID, paneID: ids[1], axis: .vertical)
                if let index = state.layout.tabs.firstIndex(where: { $0.id == tabID }) {
                    state.layout.tabs[index].title = "Whole split tab 한글"
                    if case .split(let id, _, _, _, _) = state.layout.tabs[index].tree {
                        try state.layout.resize(splitID: id, ratio: 0.37)
                    }
                }
                if let retained { retainedID = state.layout.addTab(paneID: retained) }
                if let pane = destinationID {
                    destinationWorkspace = state.layout.addWorkspace(title: "Destination")
                    state.layout.addTab(paneID: pane)
                }
                try state.layout.selectWorkspace(workspaceID)
                try state.layout.selectTab(tabID)
                try state.layout.focusPane(ids[1])
            }
            workspace = workspaceID; tab = tabID; retainedTab = retainedID
            source = AppStore(runtime: runtime, initialWorkspaceID: workspaceID)
            sourceWindow = Self.window(source)
            stores = [source]; windows = [sourceWindow]
            delegate.windows[sourceWindow] = source
            destinationPane = destinationID
            if let id = destinationWorkspace {
                let model = AppStore(runtime: runtime, initialWorkspaceID: id)
                self.destination = model
                _ = addWindow(model)
            }
            source.onPaneDetachedWindow = { [weak self] id, point in
                guard let self else { return }
                let window = self.delegate.makeDetachedPaneWindow(runtime: self.runtime, workspaceID: id, at: point)
                window.setFrameOrigin(NSPoint(x: -14000, y: -14000))
                self.detached.append(window)
                self.windows.append(window)
                if let model = self.delegate.windows[window] { self.stores.append(model) }
            }
            initialized = true
        }

        func finish(_ data: Data) -> Bool {
            WorkspaceDrag.shared.finishTabDrag(data, from: sourceWindow, at: outside,
                                               operation: [], cancelled: false, released: true)
        }

        @discardableResult func addWindow(_ model: AppStore) -> NSWindow {
            let window = Self.window(model)
            stores.append(model); windows.append(window)
            delegate.windows[window] = model
            return window
        }

        func jobs() throws -> [String: Int32] {
            let sessions = try runtime.list()
            XCTAssertTrue(sessions.allSatisfy(\.alive))
            return Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0.pid) })
        }

        func settle(_ condition: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(5)
            repeat {
                windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
                if condition() { return }
                try await Task.sleep(for: .milliseconds(20))
            } while Date() < deadline
            XCTFail("Tab drag did not settle: \(source.message ?? "none")")
        }

        func drain() async {
            await withCheckedContinuation { continuation in
                source.queue.async { DispatchQueue.main.async { continuation.resume() } }
            }
            try? await Task.sleep(for: .milliseconds(100))
            windows.forEach { $0.contentView?.layoutSubtreeIfNeeded() }
        }

        func dispose() {
            source.onPaneDetachedWindow = nil
            for store in stores {
                store.terminalViews.values.forEach { $0.terminate() }
                store.terminalViews.removeAll()
            }
            windows.forEach { $0.close() }
            delegate.windows.removeAll()
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            runtime.shutdownTestHost()
            try? FileManager.default.removeItem(at: root)
            Self.restoreEnvironment(previousEnvironment)
        }

        private static func restoreEnvironment(_ previous: [(String, String?)]) {
            for (key, value) in previous {
                if let value { setenv(key, value, 1) } else { unsetenv(key) }
            }
        }

        private static func window(_ model: AppStore) -> NSWindow {
            let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700),
                                              contentView: NSHostingView(rootView: WorkspaceView(store: model)))
            window.orderFrontRegardless()
            return window
        }
    }
}
