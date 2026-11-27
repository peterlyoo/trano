import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class TabTransferTests: XCTestCase {
    // Implements: FR-NAV-4, FR-NAV-12
    @MainActor func testRejectedAsynchronousDropRetiresItsTokenWithoutMovingJobs() async throws {
        let f = try await makeFixture()
        defer { dispose(f) }
        let original = WorkspaceDrag.shared.provider(tabID: f.sourceTab, store: f.source)
        let data = try await load(original, type: .tranoTab)
        let delayed = DeferredWorkspaceDrop()
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.tranoTab.identifier, visibility: .ownProcess) { completion in
            delayed.record(completion)
            return nil
        }
        let pids = Dictionary(uniqueKeysWithValues: try f.runtime.list().map { ($0.id, $0.pid) })
        XCTAssertTrue(WorkspaceDrag.shared.receive([provider], in: f.destination, tabID: nil))
        let loaded = Date().addingTimeInterval(2)
        while !delayed.ready && Date() < loaded { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(delayed.ready)
        XCTAssertFalse(WorkspaceDrag.shared.finishTabDrag(data, from: f.sourceWindow,
            at: NSPoint(x: f.sourceWindow.frame.maxX + 100, y: f.sourceWindow.frame.midY),
            operation: .move, cancelled: false, released: true))
        XCTAssertTrue(WorkspaceDrag.shared.hasActivePayload(in: f.source))
        f.destination.selectWorkspace(f.sourceWorkspace)
        try await settle(f) { f.destination.preferredWorkspaceID == f.sourceWorkspace }
        let before = try f.runtime.state().layout
        delayed.complete(data)
        let ended = Date().addingTimeInterval(1)
        while WorkspaceDrag.shared.hasActivePayload(in: f.source) && Date() < ended { try await Task.sleep(for: .milliseconds(10)) }

        XCTAssertFalse(WorkspaceDrag.shared.hasActivePayload(in: f.source))
        XCTAssertEqual(try f.runtime.state().layout, before)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try f.runtime.list().map { ($0.id, $0.pid) }), pids)
    }

    // Implements: FR-NAV-4, FR-NAV-12
    @MainActor func testQueuedTabAndPaneDropsCannotReopenAClosedSourceOrDestinationWorkspace() async throws {
        for sourceCloses in [false, true] {
            for paneOnly in [false, true] {
                let f = try await makeFixture()
                defer { dispose(f) }
                let before = Dictionary(uniqueKeysWithValues: try f.runtime.list().map { ($0.id, $0.pid) })
                let provider = paneOnly ? WorkspaceDrag.shared.provider(paneID: f.panes[1], store: f.source)
                    : WorkspaceDrag.shared.provider(tabID: f.sourceTab, store: f.source)
                let data = try await load(provider, type: paneOnly ? .tranoPane : .tranoTab)
                f.destination.queue.suspend()
                var suspended = true
                defer { if suspended { f.destination.queue.resume() } }
                XCTAssertTrue(WorkspaceDrag.shared.receive(data, in: f.destination, tabID: f.targetTab))
                try f.runtime.update { $0.layout.closeWorkspace(sourceCloses ? f.sourceWorkspace : f.destinationWorkspace) }
                let expected = try f.runtime.state().layout
                suspended = false
                f.destination.queue.resume()
                await withCheckedContinuation { continuation in
                    f.destination.queue.async { DispatchQueue.main.async { continuation.resume() } }
                }

                XCTAssertEqual(try f.runtime.state().layout, expected)
                XCTAssertEqual(Dictionary(uniqueKeysWithValues: try f.runtime.list().map { ($0.id, $0.pid) }), before)
                XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
            }
        }
    }

    // Implements: FR-NAV-4, U09, U11
    @MainActor func testTabDropMovesWholeSplitBetweenNativeWindowsAndKeepsJobs() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let before = try fixture.runtime.state()
        let original = try XCTUnwrap(before.layout.tabs.first { $0.id == fixture.sourceTab })
        let pids = Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) })
        let provider = WorkspaceDrag.shared.provider(tabID: fixture.sourceTab, store: fixture.source)
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.tranoTab.identifier))
        let data = try await load(provider, type: .tranoTab)
        let accepted = WorkspaceDrag.shared.receive([provider], in: fixture.destination, tabID: fixture.targetTab)
        XCTAssertTrue(accepted)
        guard accepted else { return }
        try await settle(fixture) {
            fixture.destination.state.layout.tabs.first { $0.id == fixture.sourceTab }?.workspaceID == fixture.destinationWorkspace && fixture.source.state.layout.currentTabs.isEmpty &&
            fixture.source.terminalViews[fixture.panes[0]] == nil && fixture.source.terminalViews[fixture.panes[1]] == nil &&
            fixture.destination.terminalViews[fixture.panes[0]]?.process.running == true && fixture.destination.terminalViews[fixture.panes[1]]?.process.running == true
        }
        let after = try fixture.runtime.state()
        let moved = try XCTUnwrap(after.layout.tabs.first { $0.id == fixture.sourceTab })
        XCTAssertEqual(moved.tree, original.tree)
        XCTAssertEqual(moved.focusedPaneID, original.focusedPaneID)
        XCTAssertEqual(moved.title, original.title)
        XCTAssertEqual(after.layout.tabs.filter { $0.id == fixture.sourceTab }.count, 1)
        XCTAssertTrue(fixture.source.state.layout.currentTabs.isEmpty)
        XCTAssertEqual(fixture.source.state.layout.selectedWorkspaceID, fixture.sourceWorkspace)
        XCTAssertEqual(fixture.destination.state.layout.selectedWorkspaceID, fixture.destinationWorkspace)
        XCTAssertEqual(fixture.destination.state.layout.currentTabs.map(\.id), [fixture.sourceTab, fixture.targetTab])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) }), pids)
        XCTAssertTrue(try fixture.runtime.list().allSatisfy(\.alive))
        XCTAssertNil(fixture.source.terminalViews[fixture.panes[0]])
        XCTAssertNil(fixture.source.terminalViews[fixture.panes[1]])
        XCTAssertTrue(fixture.sourceWindow !== fixture.destinationWindow)
        XCTAssertFalse(WorkspaceDrag.shared.receive(data, in: fixture.destination, tabID: nil), "Consumed drag cannot replay")
    }

    // Implements: FR-NAV-4, U09, U11
    @MainActor func testPaneDropIntoOtherWindowTabPreservesSourceSplitRemainder() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let paneID = fixture.panes[1]
        let pids = Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) })
        let provider = WorkspaceDrag.shared.provider(paneID: paneID, store: fixture.source)
        let unrelated = NSItemProvider(object: "Not a workspace drag" as NSString)
        XCTAssertTrue(WorkspaceDrag.shared.receive([unrelated, provider], in: fixture.destination, tabID: fixture.targetTab))
        try await settle(fixture) {
            fixture.destination.state.layout.tabs.first { $0.id == fixture.targetTab }?.panes.contains(paneID) == true &&
            fixture.source.focusedID == fixture.panes[0] && fixture.source.terminalViews[paneID] == nil &&
            fixture.destination.terminalViews[paneID]?.process.running == true
        }
        let layout = try fixture.runtime.state().layout
        XCTAssertEqual(layout.tabs.first { $0.id == fixture.sourceTab }?.panes, [fixture.panes[0]])
        XCTAssertEqual(layout.tabs.first { $0.id == fixture.targetTab }?.panes, [fixture.panes[2], paneID])
        XCTAssertEqual(layout.tabs.flatMap(\.panes).filter { $0 == paneID }.count, 1)
        XCTAssertEqual(fixture.source.focusedID, fixture.panes[0])
        XCTAssertNil(fixture.source.terminalViews[paneID])
        XCTAssertTrue(fixture.source.terminalViews[fixture.panes[0]]?.process.running == true)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) }), pids)
    }

    // Implements: FR-NAV-4, U09, U11
    @MainActor func testFinalPaneDropOnBlankStripCreatesDestinationTabWithoutNewProcess() async throws {
        let fixture = try await makeFixture(split: false)
        defer { dispose(fixture) }
        let pids = Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) })
        let provider = WorkspaceDrag.shared.provider(paneID: fixture.panes[0], store: fixture.source)
        let data = try await load(provider, type: .tranoPane)
        XCTAssertTrue(WorkspaceDrag.shared.receive(data, in: fixture.destination, tabID: nil))
        try await settle(fixture) {
            fixture.destination.state.layout.currentTabs.count == 2 && fixture.source.state.layout.currentTabs.isEmpty &&
            fixture.source.terminalViews[fixture.panes[0]] == nil && fixture.destination.terminalViews[fixture.panes[0]]?.process.running == true
        }
        XCTAssertNil(fixture.source.state.layout.selectedTabID)
        XCTAssertNil(fixture.source.focusedID)
        XCTAssertEqual(fixture.source.state.layout.selectedWorkspaceID, fixture.sourceWorkspace)
        XCTAssertEqual(fixture.destination.state.layout.currentTabs.last?.panes, [fixture.panes[0]])
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) }), pids)
    }

    // Implements: FR-NAV-4, U09, U11
    @MainActor func testPaneTransferRemovesAttachClientsFromEveryMirroredSourceWindow() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let mirror = AppStore(runtime: fixture.runtime)
        let mirrorWindow = makeWindow(mirror)
        defer {
            for view in mirror.terminalViews.values { view.terminate() }
            mirror.terminalViews.removeAll()
            mirrorWindow.close()
        }
        try await settle(fixture) { !mirror.loading }
        mirror.selectWorkspace(fixture.sourceWorkspace)
        try await settle(fixture) {
            mirrorWindow.contentView?.layoutSubtreeIfNeeded()
            return mirror.preferredWorkspaceID == fixture.sourceWorkspace &&
                mirror.terminalViews[fixture.panes[0]]?.process.running == true &&
                mirror.terminalViews[fixture.panes[1]]?.process.running == true
        }
        let movedPane = fixture.panes[1]
        let movedMirrorView = try XCTUnwrap(mirror.terminalViews[movedPane])
        let retainedMirrorView = try XCTUnwrap(mirror.terminalViews[fixture.panes[0]])
        XCTAssertGreaterThan(movedMirrorView.process.shellPid, 0)
        let pids = Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) })
        let provider = WorkspaceDrag.shared.provider(paneID: movedPane, store: fixture.source)
        XCTAssertTrue(WorkspaceDrag.shared.receive([provider], in: fixture.destination, tabID: fixture.targetTab))
        try await settle(fixture) {
            mirrorWindow.contentView?.layoutSubtreeIfNeeded()
            return fixture.source.terminalViews[movedPane] == nil &&
                fixture.destination.terminalViews[movedPane]?.process.running == true &&
                mirror.state.layout.tabs.first { $0.id == fixture.sourceTab }?.panes == [fixture.panes[0]]
        }
        XCTAssertNil(mirror.terminalViews[movedPane], "Every mirror must release the moved pane's hidden attach client")
        if mirror.terminalViews[movedPane] == nil {
            try await settle(fixture) { !movedMirrorView.process.running }
        }
        XCTAssertTrue(mirror.terminalViews[fixture.panes[0]] === retainedMirrorView)
        XCTAssertTrue(retainedMirrorView.process.running)
        XCTAssertEqual(mirror.preferredWorkspaceID, fixture.sourceWorkspace)
        XCTAssertEqual(mirror.state.layout.selectedWorkspaceID, fixture.sourceWorkspace)
        XCTAssertEqual(fixture.source.preferredWorkspaceID, fixture.sourceWorkspace)
        XCTAssertEqual(fixture.destination.preferredWorkspaceID, fixture.destinationWorkspace)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) }), pids)
        XCTAssertTrue(try fixture.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-4, U09, U11
    @MainActor func testAcceptedDropCleansSurvivingMirrorsAfterDestinationStoreCloses() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let mirror = AppStore(runtime: fixture.runtime)
        let mirrorWindow = makeWindow(mirror)
        defer {
            for view in mirror.terminalViews.values { view.terminate() }
            mirror.terminalViews.removeAll()
            mirrorWindow.close()
        }
        try await settle(fixture) { !mirror.loading }
        mirror.selectWorkspace(fixture.sourceWorkspace)
        try await settle(fixture) {
            mirrorWindow.contentView?.layoutSubtreeIfNeeded()
            return mirror.preferredWorkspaceID == fixture.sourceWorkspace &&
                mirror.terminalViews[fixture.panes[1]]?.process.running == true
        }

        var closingWorkspace = ""
        try fixture.runtime.update { state in closingWorkspace = state.layout.addWorkspace(title: "Closing destination") }
        var closingDestination: AppStore? = AppStore(runtime: fixture.runtime)
        var closingWindow = closingDestination.map { makeWindow($0) }
        weak var releasedDestination = closingDestination
        defer {
            closingWindow?.contentView = nil
            closingWindow?.close()
            closingWindow = nil
            closingDestination = nil
        }
        try await settle(fixture) {
            closingWindow?.contentView?.layoutSubtreeIfNeeded()
            return closingDestination?.loading == false && closingDestination?.preferredWorkspaceID == closingWorkspace
        }
        let destinationQueue = try XCTUnwrap(closingDestination?.queue)
        destinationQueue.suspend()
        var suspended = true
        defer { if suspended { destinationQueue.resume() } }

        let paneID = fixture.panes[1]
        let pids = Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) })
        let provider = WorkspaceDrag.shared.provider(paneID: paneID, store: fixture.source)
        let data = try await load(provider, type: .tranoPane)
        let accepted = {
            guard let destination = closingDestination else { return false }
            return WorkspaceDrag.shared.receive(data, in: destination, tabID: nil)
        }()
        XCTAssertTrue(accepted)
        autoreleasepool {
            closingWindow?.contentView = nil
            closingWindow?.close()
            closingWindow = nil
            closingDestination = nil
        }
        try await settle(fixture) { releasedDestination == nil }
        XCTAssertNil(releasedDestination, "Destination Store must deallocate before its queued transfer commits")
        destinationQueue.resume()
        suspended = false

        try await settle(fixture) {
            mirrorWindow.contentView?.layoutSubtreeIfNeeded()
            return fixture.source.state.layout.tabs.first { $0.panes.contains(paneID) }?.workspaceID == closingWorkspace &&
                mirror.state.layout.tabs.first { $0.id == fixture.sourceTab }?.panes == [fixture.panes[0]]
        }
        XCTAssertNil(fixture.source.terminalViews[paneID], "Closing the destination must not skip surviving source cleanup")
        XCTAssertNil(mirror.terminalViews[paneID], "Closing the destination must not skip surviving mirror cleanup")
        XCTAssertEqual(fixture.source.preferredWorkspaceID, fixture.sourceWorkspace)
        XCTAssertEqual(mirror.preferredWorkspaceID, fixture.sourceWorkspace)
        XCTAssertTrue(fixture.source.terminalViews[fixture.panes[0]]?.process.running == true)
        XCTAssertTrue(mirror.terminalViews[fixture.panes[0]]?.process.running == true)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) }), pids)
        XCTAssertTrue(try fixture.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-4
    @MainActor func testSameWorkspaceDropReordersSharedViewsAndSameTabPaneDropDoesNotSplit() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.destination.selectWorkspace(fixture.sourceWorkspace)
        try await settle(fixture) { fixture.destination.preferredWorkspaceID == fixture.sourceWorkspace }
        let secondTab = fixture.targetTab
        try fixture.runtime.update { state in
            let index = try XCTUnwrap(state.layout.tabs.firstIndex { $0.id == secondTab })
            state.layout.tabs[index].workspaceID = fixture.sourceWorkspace
            try state.layout.selectTab(secondTab)
        }
        fixture.source.refresh(); fixture.destination.refresh()
        try await settle(fixture) { fixture.destination.state.layout.currentTabs.count == 2 }
        let provider = WorkspaceDrag.shared.provider(tabID: secondTab, store: fixture.source)
        let tabData = try await load(provider, type: .tranoTab)
        XCTAssertTrue(WorkspaceDrag.shared.receive(tabData, in: fixture.destination, tabID: fixture.sourceTab))
        try await settle(fixture) { fixture.source.state.layout.currentTabs.first?.id == secondTab && fixture.destination.state.layout.currentTabs.first?.id == secondTab }
        XCTAssertEqual(fixture.destination.state.layout.currentTabs.map(\.id), fixture.source.state.layout.currentTabs.map(\.id))
        let original = try fixture.runtime.state().layout.tabs.first { $0.id == fixture.sourceTab }?.tree
        let paneProvider = WorkspaceDrag.shared.provider(paneID: fixture.panes[1], store: fixture.source)
        let paneData = try await load(paneProvider, type: .tranoPane)
        XCTAssertTrue(WorkspaceDrag.shared.receive(paneData, in: fixture.destination, tabID: fixture.sourceTab))
        try await settle(fixture) { fixture.destination.selectedTab?.id == fixture.sourceTab }
        XCTAssertEqual(try fixture.runtime.state().layout.tabs.first { $0.id == fixture.sourceTab }?.tree, original)
    }

    // Implements: FR-NAV-4
    @MainActor func testPaneDropIntoVisibleSidebarTabKeepsCrossWorkspaceTargeting() async throws {
        let fixture = try await makeFixture(split: false)
        defer { dispose(fixture) }
        var sidebarWorkspace = "", sidebarTab = ""
        try fixture.runtime.update { state in
            sidebarWorkspace = state.layout.addWorkspace(title: "Sidebar destination")
            sidebarTab = state.layout.addTab(paneID: fixture.panes[1])
            try state.layout.selectWorkspace(fixture.destinationWorkspace)
        }
        fixture.source.refresh(); fixture.destination.refresh()
        try await settle(fixture) { fixture.destination.state.layout.tabs.contains { $0.id == sidebarTab } }
        XCTAssertEqual(fixture.destination.preferredWorkspaceID, fixture.destinationWorkspace)
        XCTAssertFalse(fixture.destination.state.layout.currentTabs.contains { $0.id == sidebarTab })
        let provider = WorkspaceDrag.shared.provider(paneID: fixture.panes[0], store: fixture.source)
        XCTAssertTrue(WorkspaceDrag.shared.receive([provider], in: fixture.destination, tabID: sidebarTab))
        try await settle(fixture) {
            fixture.destination.preferredWorkspaceID == sidebarWorkspace &&
            fixture.destination.selectedTab?.panes == [fixture.panes[1], fixture.panes[0]] &&
            fixture.source.state.layout.currentTabs.isEmpty && fixture.source.terminalViews[fixture.panes[0]] == nil
        }
        XCTAssertEqual(fixture.destination.selectedTab?.id, sidebarTab)
        XCTAssertEqual(fixture.source.preferredWorkspaceID, fixture.sourceWorkspace)
        XCTAssertTrue(try fixture.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-4
    @MainActor func testForeignMalformedAndStaleDragPayloadsCannotMutateLayout() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let before = try fixture.runtime.state().layout
        XCTAssertFalse(WorkspaceDrag.shared.receive([NSItemProvider(object: "Unrelated text" as NSString)], in: fixture.destination, tabID: fixture.targetTab))
        for data in [Data(), Data(UUID().uuidString.utf8), Data(repeating: 97, count: 4096)] {
            XCTAssertFalse(WorkspaceDrag.shared.receive(data, in: fixture.destination, tabID: fixture.targetTab))
        }
        let otherRoot = FileManager.default.temporaryDirectory.appendingPathComponent("trano-foreign-" + UUID().uuidString.prefix(8))
        let otherRuntime = try TerminalRuntime(root: otherRoot)
        try otherRuntime.update { state in
            state.settings.automaticRestore = false
            state.layout.addWorkspace(title: "Foreign")
        }
        let other = AppStore(runtime: otherRuntime)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let provider = WorkspaceDrag.shared.provider(tabID: fixture.sourceTab, store: fixture.source)
        let data = try await load(provider, type: .tranoTab)
        try await settle(fixture) { !other.loading }
        XCTAssertFalse(WorkspaceDrag.shared.receive(data, in: other, tabID: nil))
        XCTAssertEqual(try fixture.runtime.state().layout, before)
        fixture.destination.selectWorkspace(fixture.sourceWorkspace)
        try await settle(fixture) { fixture.destination.preferredWorkspaceID == fixture.sourceWorkspace }
        XCTAssertFalse(WorkspaceDrag.shared.receive(data, in: fixture.destination, tabID: nil, expectedWorkspaceID: fixture.destinationWorkspace))
        fixture.destination.selectWorkspace(fixture.destinationWorkspace)
        try await settle(fixture) { fixture.destination.preferredWorkspaceID == fixture.destinationWorkspace }
        fixture.source.selectWorkspace(fixture.destinationWorkspace)
        try await settle(fixture) { fixture.source.preferredWorkspaceID == fixture.destinationWorkspace }
        XCTAssertFalse(WorkspaceDrag.shared.receive(data, in: fixture.destination, tabID: fixture.targetTab))
        XCTAssertEqual(try fixture.runtime.state().layout.tabs, before.tabs)
    }

    @MainActor private func load(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? TerminalError.invalid("No drag payload")) }
            }
        }
    }

    @MainActor private func settle(_ fixture: Fixture, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            fixture.sourceWindow.contentView?.layoutSubtreeIfNeeded()
            fixture.destinationWindow.contentView?.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        XCTFail("Window transfer did not settle; source: \(fixture.source.message ?? "none"), destination: \(fixture.destination.message ?? "none")")
    }

    @MainActor private func dispose(_ fixture: Fixture) {
        for store in [fixture.source, fixture.destination] {
            for view in store.terminalViews.values { view.terminate() }
            store.terminalViews.removeAll()
        }
        fixture.sourceWindow.close(); fixture.destinationWindow.close()
        for pane in (try? fixture.runtime.list()) ?? [] { try? fixture.runtime.terminate(pane.id) }
        fixture.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: fixture.root)
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let source: AppStore
        let destination: AppStore
        let sourceWindow: NSWindow
        let destinationWindow: NSWindow
        let sourceWorkspace: String
        let destinationWorkspace: String
        let sourceTab: String
        let targetTab: String
        let panes: [String]
    }

    @MainActor private func makeFixture(split: Bool = true) async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-transfer-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        var initialized = false
        var ownedStores: [AppStore] = []
        var ownedWindows: [NSWindow] = []
        defer {
            if !initialized {
                for store in ownedStores {
                    for view in store.terminalViews.values { view.terminate() }
                    store.terminalViews.removeAll()
                }
                for window in ownedWindows { window.close() }
                for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
                runtime.shutdownTestHost()
                try? FileManager.default.removeItem(at: root)
            }
        }
        var panes: [String] = []
        for index in 0..<3 { panes.append(try runtime.create(title: "Transfer \(index)", cwd: root.path, shell: "/bin/sleep", arguments: ["90"]).id) }
        var sourceWorkspace = "", destinationWorkspace = "", sourceTab = "", targetTab = ""
        try runtime.update { state in
            state.settings.automaticRestore = false
            sourceWorkspace = state.layout.addWorkspace(title: "Source")
            sourceTab = state.layout.addTab(paneID: panes[0])
            if split { try state.layout.split(tabID: sourceTab, paneID: panes[1], axis: .horizontal) }
            destinationWorkspace = state.layout.addWorkspace(title: "Destination")
            targetTab = state.layout.addTab(paneID: panes[2])
            try state.layout.selectWorkspace(sourceWorkspace)
        }
        let source = AppStore(runtime: runtime)
        ownedStores.append(source)
        let sourceWindow = makeWindow(source)
        ownedWindows.append(sourceWindow)
        let initialDeadline = Date().addingTimeInterval(5)
        while source.loading && Date() < initialDeadline { try await Task.sleep(for: .milliseconds(20)) }
        let destination = AppStore(runtime: runtime)
        ownedStores.append(destination)
        let destinationWindow = makeWindow(destination)
        ownedWindows.append(destinationWindow)
        while destination.loading && Date() < initialDeadline { try await Task.sleep(for: .milliseconds(20)) }
        destination.selectWorkspace(destinationWorkspace)
        let fixture = Fixture(root: root, runtime: runtime, source: source, destination: destination, sourceWindow: sourceWindow, destinationWindow: destinationWindow, sourceWorkspace: sourceWorkspace, destinationWorkspace: destinationWorkspace, sourceTab: sourceTab, targetTab: targetTab, panes: panes)
        try await settle(fixture) {
            destination.preferredWorkspaceID == destinationWorkspace && source.preferredWorkspaceID == sourceWorkspace &&
            source.terminalViews[panes[0]]?.process.running == true && destination.terminalViews[panes[2]]?.process.running == true
        }
        initialized = true
        return fixture
    }

    @MainActor private func makeWindow(_ store: AppStore) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), styleMask: [.titled, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: WorkspaceView(store: store))
        window.orderFrontRegardless()
        return window
    }
}

private final class DeferredWorkspaceDrop: @unchecked Sendable {
    private let lock = NSLock()
    private var completion: ((Data?, Error?) -> Void)?
    var ready: Bool { lock.lock(); defer { lock.unlock() }; return completion != nil }
    func record(_ completion: @escaping (Data?, Error?) -> Void) {
        lock.lock(); self.completion = completion; lock.unlock()
    }
    func complete(_ data: Data) {
        lock.lock(); let callback = completion; completion = nil; lock.unlock()
        callback?(data, nil)
    }
}
