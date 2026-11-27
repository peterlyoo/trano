import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class PaneTearOffTests: XCTestCase {
    // Implements: FR-NAV-10
    @MainActor func testOutsideDropOpensOneNormalWindowAndPreservesPaneJobsAndMirrors() async throws {
        let f = try await fixture(mirror: true)
        defer { f.dispose() }
        let moved = f.panes[1]
        let before = try f.runtime.state()
        let jobs = try f.jobs()
        let retained = try XCTUnwrap(f.source.terminalViews[f.panes[0]])
        let retainedClient = retained.process.shellPid
        let data = try XCTUnwrap(WorkspaceDrag.shared.panePayload(paneID: moved, store: f.source))

        XCTAssertTrue(f.finish(data))
        try await f.settle {
            guard let model = f.detachedStore else { return false }
            return model.terminalViews[moved]?.process.running == true &&
                f.source.terminalViews[moved] == nil && f.mirror?.terminalViews[moved] == nil
        }

        let model = try XCTUnwrap(f.detachedStore)
        let window = try XCTUnwrap(f.detached.first)
        let layout = try f.runtime.state().layout
        XCTAssertEqual(f.detached.count, 1)
        XCTAssertFalse(window is NSPanel)
        XCTAssertEqual(window.level, .normal)
        XCTAssertTrue(window.styleMask.contains(.titled))
        XCTAssertTrue(window.styleMask.contains(.closable))
        XCTAssertEqual(model.state.layout.currentTabs.count, 1)
        XCTAssertEqual(model.selectedTab?.panes, [moved])
        XCTAssertEqual(model.focusedID, moved)
        XCTAssertNotEqual(model.preferredWorkspaceID, f.workspace)
        XCTAssertEqual(layout.tabs.first { $0.id == f.tab }?.panes, [f.panes[0]])
        XCTAssertEqual(layout.tabs.flatMap(\.panes).filter { $0 == moved }.count, 1)
        XCTAssertEqual(layout.workspaces.count, before.layout.workspaces.count + 1)
        XCTAssertEqual(try f.runtime.state().sessions.count, before.sessions.count)
        XCTAssertEqual(try f.runtime.state().agentLaunches.map(\.id), before.agentLaunches.map(\.id))
        XCTAssertEqual(try f.jobs(), jobs)
        XCTAssertTrue(f.source.terminalViews[f.panes[0]] === retained)
        XCTAssertEqual(retained.process.shellPid, retainedClient)
        let originalSession = try XCTUnwrap(before.sessions.first { $0.id == moved })
        let currentSession = try XCTUnwrap(f.runtime.list().first { $0.id == moved })
        XCTAssertEqual(currentSession.agent, originalSession.agent)
        XCTAssertEqual(currentSession.cwd, originalSession.cwd)
        XCTAssertFalse(f.finish(data), "A completed drag must not detach twice")
        XCTAssertEqual(f.detached.count, 1)
    }

    // Implements: FR-NAV-10
    @MainActor func testLastPaneMovesToNewWindowWithoutBootstrappingAnotherShell() async throws {
        let f = try await fixture(split: false)
        defer { f.dispose() }
        let jobs = try f.jobs()
        let data = try XCTUnwrap(WorkspaceDrag.shared.panePayload(paneID: f.panes[0], store: f.source))
        XCTAssertTrue(f.finish(data))
        try await f.settle {
            f.source.state.layout.currentTabs.isEmpty && f.detachedStore?.terminalViews[f.panes[0]]?.process.running == true
        }
        XCTAssertNil(f.source.focusedID)
        XCTAssertNil(f.source.selectedTab)
        XCTAssertEqual(f.source.preferredWorkspaceID, f.workspace)
        XCTAssertEqual(f.detachedStore?.selectedTab?.panes, [f.panes[0]])
        XCTAssertEqual(try f.runtime.list().count, 1)
        XCTAssertEqual(try f.jobs(), jobs)
    }

    // Implements: FR-NAV-10
    @MainActor func testDetachedWindowDoesNotRestoreAnUnrelatedDeadSession() async throws {
        let f = try await fixture()
        defer { f.dispose() }
        let unrelated = try f.runtime.create(title: "Unrelated retained pane", cwd: f.root.path,
                                             shell: "/bin/sleep", arguments: ["90"])
        try f.runtime.update { state in
            _ = state.layout.addWorkspace(title: "Unrelated")
            state.layout.addTab(paneID: unrelated.id)
            try state.layout.selectWorkspace(f.workspace)
            try state.layout.selectTab(f.tab)
        }
        try f.runtime.killPaneProcess(unrelated.id)
        let dead = try XCTUnwrap(f.runtime.list().first { $0.id == unrelated.id })
        XCTAssertFalse(dead.alive)
        XCTAssertEqual(dead.pid, unrelated.pid)
        try f.runtime.update { $0.settings.automaticRestore = true }
        let before = try f.runtime.state()
        let moved = f.panes[1]
        let movedPID = try XCTUnwrap(f.runtime.list().first { $0.id == moved }?.pid)
        let data = try XCTUnwrap(WorkspaceDrag.shared.panePayload(paneID: moved, store: f.source))

        XCTAssertTrue(f.finish(data))
        try await f.settle {
            guard let model = f.detachedStore else { return false }
            return !model.loading && model.terminalViews[moved]?.process.running == true
        }

        let after = try f.runtime.state()
        let sessions = try f.runtime.list()
        let retained = try XCTUnwrap(sessions.first { $0.id == unrelated.id })
        XCTAssertEqual(retained.pid, unrelated.pid)
        XCTAssertFalse(retained.alive)
        XCTAssertEqual(sessions.first { $0.id == moved }?.pid, movedPID)
        XCTAssertTrue(sessions.first { $0.id == moved }?.alive == true)
        XCTAssertEqual(after.sessions.map(\.id), before.sessions.map(\.id))
        XCTAssertEqual(after.agentLaunches.map(\.id), before.agentLaunches.map(\.id))
        XCTAssertTrue(after.settings.automaticRestore)
        XCTAssertEqual(f.detached.count, 1)
    }

    // Implements: FR-NAV-10
    @MainActor func testCancellationAndOriginBoundaryControlDetachment() async throws {
        let f = try await fixture(destination: true)
        defer { f.dispose() }
        let layout = try f.runtime.state().layout
        let jobs = try f.jobs()
        for (cancelled, released, inside) in [(true, true, false), (false, false, false), (false, true, true)] {
            let data = try XCTUnwrap(WorkspaceDrag.shared.panePayload(paneID: f.panes[1], store: f.source))
            let point = inside ? NSPoint(x: f.sourceWindow.frame.midX, y: f.sourceWindow.frame.midY) : f.outside
            XCTAssertFalse(WorkspaceDrag.shared.finishPaneDrag(data, from: f.sourceWindow, at: point,
                                                             operation: [], cancelled: cancelled, released: released))
        }
        await f.drain()
        XCTAssertEqual(f.detached.count, 0)
        XCTAssertEqual(try f.runtime.state().layout, layout)
        XCTAssertEqual(try f.jobs(), jobs)
        let other = try XCTUnwrap(f.windows.first { $0 !== f.sourceWindow })
        other.setFrameOrigin(NSPoint(x: f.sourceWindow.frame.maxX + 100, y: f.sourceWindow.frame.minY))
        let outsideOrigin = NSPoint(x: other.frame.midX, y: other.frame.midY)
        XCTAssertFalse(f.sourceWindow.frame.contains(outsideOrigin))
        XCTAssertTrue(other.frame.contains(outsideOrigin))
        let data = try XCTUnwrap(WorkspaceDrag.shared.panePayload(paneID: f.panes[1], store: f.source))
        let accepted = WorkspaceDrag.shared.finishPaneDrag(data, from: f.sourceWindow, at: outsideOrigin,
                                                          operation: [], cancelled: false, released: true)
        XCTAssertTrue(accepted)
        if accepted { try await f.settle { f.detached.count == 1 && f.detachedStore?.terminalViews[f.panes[1]]?.process.running == true } }
        XCTAssertEqual(try f.jobs(), jobs)
    }

    // Implements: FR-NAV-10
    @MainActor func testAcceptedAsynchronousTabDropCannotAlsoCreateANewWindow() async throws {
        let f = try await fixture(destination: true)
        defer { f.dispose() }
        let target = try XCTUnwrap(f.destination)
        let targetTab = try XCTUnwrap(target.selectedTab?.id)
        let moved = f.panes[1]
        let jobs = try f.jobs()
        let provider = WorkspaceDrag.shared.provider(paneID: moved, store: f.source)
        let data = try await load(provider)
        XCTAssertTrue(WorkspaceDrag.shared.receive([provider], in: target, tabID: targetTab))
        XCTAssertFalse(WorkspaceDrag.shared.finishPaneDrag(data, from: f.sourceWindow, at: f.outside,
                                                         operation: .move, cancelled: false, released: true))
        XCTAssertFalse(WorkspaceDrag.shared.finishPaneDrag(data, from: f.sourceWindow, at: f.outside,
                                                         operation: .copy, cancelled: false, released: true))
        try await f.settle {
            target.state.layout.tabs.first { $0.id == targetTab }?.panes.contains(moved) == true &&
                f.source.terminalViews[moved] == nil && target.terminalViews[moved]?.process.running == true
        }
        XCTAssertEqual(f.detached.count, 0)
        XCTAssertEqual(try f.runtime.state().layout.workspaces.count, 2)
        XCTAssertEqual(try f.jobs(), jobs)
        XCTAssertFalse(f.finish(data))
    }

    // Implements: FR-NAV-10
    @MainActor func testQueuedStalePaneClosedWorkspaceAndClosedWindowDoNotDetach() async throws {
        for condition in ["removed-pane", "closed-workspace", "closed-window"] {
            let f = try await fixture()
            defer { f.dispose() }
            let data = try XCTUnwrap(WorkspaceDrag.shared.panePayload(paneID: f.panes[1], store: f.source))
            let jobs = try f.jobs()
            let entered = DispatchSemaphore(value: 0)
            let release = DispatchSemaphore(value: 0)
            f.source.queue.async { entered.signal(); release.wait() }
            XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
            defer { release.signal() }
            XCTAssertTrue(f.finish(data))
            switch condition {
            case "removed-pane": try f.runtime.update { $0.layout.detach(f.panes[1]) }
            case "closed-workspace": try f.runtime.update { $0.layout.closeWorkspace(f.workspace) }
            default: f.sourceWindow.close()
            }
            let expected = try f.runtime.state().layout
            release.signal()
            await f.drain()
            XCTAssertEqual(f.detached.count, 0, condition)
            XCTAssertEqual(try f.runtime.state().layout, expected, condition)
            XCTAssertEqual(try f.jobs(), jobs, condition)
        }
    }

    // Implements: FR-NAV-10
    @MainActor func testSeededWindowKeepsItsWorkspaceWhenGlobalSelectionChangesBeforeFirstRead() async throws {
        let f = try await fixture()
        defer { f.dispose() }
        let jobs = try f.jobs()
        var other = ""
        try f.runtime.update { other = $0.layout.addWorkspace(title: "Other") }
        let seeded = try f.runtime.transaction {
            try f.runtime.update { try $0.layout.selectWorkspace(f.workspace) }
            let model = AppStore(runtime: f.runtime, initialWorkspaceID: f.workspace)
            try f.runtime.update { try $0.layout.selectWorkspace(other) }
            return model
        }
        _ = f.addWindow(seeded)
        try await f.settle { !seeded.loading && seeded.terminalViews[f.panes[0]]?.process.running == true }
        XCTAssertEqual(seeded.preferredWorkspaceID, f.workspace)
        XCTAssertEqual(seeded.selectedTab?.id, f.tab)
        XCTAssertEqual(try f.runtime.state().layout.selectedWorkspaceID, other)
        XCTAssertEqual(try f.jobs(), jobs)
    }

    private func load(_ provider: NSItemProvider) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.tranoPane.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? NSError(domain: "PaneTearOff", code: 1)) }
            }
        }
    }

    @MainActor private func fixture(split: Bool = true, mirror: Bool = false, destination: Bool = false) async throws -> Fixture {
        let f = try Fixture(split: split, destination: destination)
        do {
            try await f.settle {
                !f.source.loading && f.source.terminalViews[f.panes[0]]?.process.running == true &&
                    (!split || f.source.terminalViews[f.panes[1]]?.process.running == true)
            }
            if mirror {
                let model = AppStore(runtime: f.runtime, initialWorkspaceID: f.workspace)
                f.mirror = model
                _ = f.addWindow(model)
                try await f.settle { !model.loading && model.terminalViews[f.panes[1]]?.process.running == true }
            }
            if let model = f.destination {
                try await f.settle { !model.loading && model.terminalViews[f.destinationPane!]?.process.running == true }
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
        var stores: [AppStore] = []
        var windows: [NSWindow] = []
        var mirror: AppStore?
        var destination: AppStore?
        var destinationPane: String?
        var detached: [NSWindow] = []
        var detachedStore: AppStore? { detached.first.flatMap { delegate.windows[$0] } }
        let outside = NSPoint(x: -20000, y: -20000)

        init(split: Bool, destination: Bool) throws {
            _ = NSApplication.shared
            root = URL(fileURLWithPath: "/tmp/trano-out-" + UUID().uuidString.prefix(8))
            runtime = try TerminalRuntime(root: root)
            runtime.isolatePaneHome(root)
            var ids: [String] = []
            for index in 0..<(split ? 2 : 1) {
                let pane = try runtime.create(title: "Pane \(index)", cwd: root.path, shell: "/bin/sleep", arguments: ["90"])
                ids.append(pane.id)
                try runtime.report(pane.id, state: .running, agent: index == 0 ? .claude : .codex)
            }
            panes = ids
            var workspaceID = "", tabID = "", destinationWorkspace: String?
            let destinationID = destination ? try runtime.create(title: "Destination", cwd: root.path, shell: "/bin/sleep", arguments: ["90"]).id : nil
            try runtime.update { state in
                state.settings.automaticRestore = false
                workspaceID = state.layout.addWorkspace(title: "Source")
                tabID = state.layout.addTab(paneID: ids[0])
                if split { try state.layout.split(tabID: tabID, paneID: ids[1], axis: .horizontal) }
                if let pane = destinationID {
                    destinationWorkspace = state.layout.addWorkspace(title: "Destination")
                    state.layout.addTab(paneID: pane)
                }
                try state.layout.selectWorkspace(workspaceID)
            }
            workspace = workspaceID; tab = tabID
            source = AppStore(runtime: runtime, initialWorkspaceID: workspaceID)
            sourceWindow = Self.window(source)
            destinationPane = destinationID
            stores = [source]; windows = [sourceWindow]
            delegate.windows[sourceWindow] = source
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
        }

        func finish(_ data: Data) -> Bool {
            WorkspaceDrag.shared.finishPaneDrag(data, from: sourceWindow, at: outside,
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
            XCTFail("Pane drag did not settle: \(source.message ?? "none")")
        }

        func drain() async {
            let done = DispatchGroup(); done.enter()
            source.queue.async { done.leave() }
            let deadline = Date().addingTimeInterval(3)
            while done.wait(timeout: .now()) != .success && Date() < deadline { try? await Task.sleep(for: .milliseconds(20)) }
            XCTAssertEqual(done.wait(timeout: .now()), .success)
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
        }

        private static func window(_ model: AppStore) -> NSWindow {
            let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700),
                                              contentView: NSHostingView(rootView: WorkspaceView(store: model)))
            window.orderFrontRegardless()
            return window
        }
    }
}
