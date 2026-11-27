import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class WorkspaceDropTests: XCTestCase {
    // Implements: FR-NAV-4, FR-NAV-12, U09, U11
    @MainActor func testPaneDropOnAnotherWorkspaceCreatesATabWithoutPreselectingOrRestarting() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let pids = try backendPIDs(f)
        let provider = WorkspaceDrag.shared.provider(paneID: f.panes[1], store: f.store)
        XCTAssertEqual(f.store.preferredWorkspaceID, f.sourceWorkspace)
        let accepted = WorkspaceDrag.shared.receive([provider], in: f.store, tabID: nil, workspaceID: f.destinationWorkspace)
        XCTAssertTrue(accepted)
        guard accepted else { return }
        try await settle {
            f.window.contentView?.layoutSubtreeIfNeeded()
            return f.store.preferredWorkspaceID == f.destinationWorkspace &&
                f.store.state.layout.currentTabs.count == 2 &&
                f.store.terminalViews[f.panes[1]]?.process.running == true
        }
        let layout = try f.runtime.state().layout
        XCTAssertEqual(layout.tabs.first { $0.id == f.sourceTab }?.panes, [f.panes[0]])
        XCTAssertEqual(layout.tabs.first { $0.id == f.destinationTab }?.panes, [f.panes[2]])
        let moved = try XCTUnwrap(layout.tabs.first { $0.id != f.sourceTab && $0.panes.contains(f.panes[1]) })
        XCTAssertEqual(moved.workspaceID, f.destinationWorkspace)
        XCTAssertEqual(moved.panes, [f.panes[1]])
        XCTAssertEqual(layout.tabs.flatMap(\.panes).filter { $0 == f.panes[1] }.count, 1)
        XCTAssertEqual(try backendPIDs(f), pids)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-4, FR-NAV-12, U09, U11
    @MainActor func testTabDropOnWorkspaceWithoutATargetTabPreservesWholeSplitIdentity() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let pids = try backendPIDs(f)
        let before = try XCTUnwrap(try f.runtime.state().layout.tabs.first { $0.id == f.sourceTab })
        let provider = WorkspaceDrag.shared.provider(tabID: f.sourceTab, store: f.store)
        let data = try await payload(provider, type: .tranoTab)
        XCTAssertEqual(f.store.preferredWorkspaceID, f.sourceWorkspace)
        let accepted = WorkspaceDrag.shared.receive(data, in: f.store, tabID: nil, workspaceID: f.destinationWorkspace)
        XCTAssertTrue(accepted)
        guard accepted else { return }
        try await settle {
            f.window.contentView?.layoutSubtreeIfNeeded()
            return f.store.preferredWorkspaceID == f.destinationWorkspace && f.store.selectedTab?.id == f.sourceTab &&
                f.panes.prefix(2).allSatisfy { f.store.terminalViews[$0]?.process.running == true }
        }
        let layout = try f.runtime.state().layout
        let moved = try XCTUnwrap(layout.tabs.first { $0.id == f.sourceTab })
        XCTAssertEqual(moved.workspaceID, f.destinationWorkspace)
        XCTAssertEqual(moved.id, before.id)
        XCTAssertEqual(moved.tree, before.tree)
        XCTAssertEqual(moved.focusedPaneID, before.focusedPaneID)
        XCTAssertEqual(moved.title, before.title)
        XCTAssertEqual(layout.tabs.filter { $0.id == f.sourceTab }.count, 1)
        XCTAssertEqual(layout.tabs.filter { $0.workspaceID == f.destinationWorkspace }.map(\.id), [f.destinationTab, f.sourceTab])
        XCTAssertEqual(try backendPIDs(f), pids)
        XCTAssertFalse(WorkspaceDrag.shared.receive(data, in: f.store, tabID: nil, workspaceID: f.destinationWorkspace))
    }

    // Implements: FR-NAV-4, FR-NAV-12, U09, U11
    @MainActor func testPaneAndTabDropsIntoAnEmptyOpenWorkspaceRestoreSelectionAndRenderExistingJobs() async throws {
        for paneOnly in [true, false] {
            let f = try await fixture()
            defer { dispose(f) }
            try f.runtime.update { $0.layout.detach(f.panes[2]) }
            f.store.refresh()
            try await settle {
                !f.store.loading && !f.store.state.layout.tabs.contains { $0.workspaceID == f.destinationWorkspace }
            }
            XCTAssertEqual(f.store.state.layout.workspaces.first { $0.id == f.destinationWorkspace }?.closed, false)
            XCTAssertEqual(f.store.preferredWorkspaceID, f.sourceWorkspace)
            let before = try XCTUnwrap(try f.runtime.state().layout.tabs.first { $0.id == f.sourceTab })
            let pids = try backendPIDs(f)
            let provider = paneOnly ? WorkspaceDrag.shared.provider(paneID: f.panes[1], store: f.store)
                : WorkspaceDrag.shared.provider(tabID: f.sourceTab, store: f.store)
            let accepted = WorkspaceDrag.shared.receive([provider], in: f.store, tabID: nil, workspaceID: f.destinationWorkspace)
            XCTAssertTrue(accepted)
            guard accepted else { continue }
            let movedPanes = paneOnly ? [f.panes[1]] : Array(f.panes.prefix(2))
            try await settle {
                f.window.contentView?.layoutSubtreeIfNeeded()
                return !f.store.loading && f.store.preferredWorkspaceID == f.destinationWorkspace &&
                    f.store.state.layout.currentTabs.count == 1 && f.store.selectedTab?.panes == movedPanes &&
                    movedPanes.allSatisfy {
                        f.store.terminalViews[$0]?.window === f.window && f.store.terminalViews[$0]?.process.running == true
                    }
            }
            let layout = try f.runtime.state().layout
            let moved = try XCTUnwrap(layout.tabs.first { $0.workspaceID == f.destinationWorkspace })
            XCTAssertEqual(moved.tree, paneOnly ? .pane(f.panes[1]) : before.tree)
            XCTAssertEqual(moved.focusedPaneID, paneOnly ? f.panes[1] : before.focusedPaneID)
            XCTAssertEqual(layout.selectedTabID, moved.id)
            XCTAssertEqual(layout.focusedPaneID, moved.focusedPaneID)
            XCTAssertEqual(f.store.selectedTab?.id, moved.id)
            XCTAssertEqual(f.store.focusedID, moved.focusedPaneID)
            XCTAssertEqual(layout.workspaces.first { $0.id == f.destinationWorkspace }?.closed, false)
            if paneOnly {
                XCTAssertNotEqual(moved.id, f.sourceTab)
                XCTAssertEqual(layout.tabs.first { $0.id == f.sourceTab }?.tree, .pane(f.panes[0]))
            } else {
                XCTAssertEqual(moved.id, f.sourceTab)
                XCTAssertEqual(moved.title, before.title)
                XCTAssertEqual(layout.tabs.filter { $0.id == f.sourceTab }.count, 1)
            }
            XCTAssertEqual(try backendPIDs(f), pids)
            XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
        }
    }

    // Implements: FR-NAV-4, FR-NAV-12, U09, U11
    @MainActor func testSameWorkspaceRowAppendsExistingTabThenCreatesNewPaneTabWithoutRestartingJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        try f.runtime.update { state in
            try state.layout.transferTab(f.destinationTab, from: f.destinationWorkspace, to: f.sourceWorkspace)
            try state.layout.selectTab(f.sourceTab)
        }
        f.store.refresh()
        try await settle {
            !f.store.loading && f.store.state.layout.currentTabs.map(\.id) == [f.sourceTab, f.destinationTab]
        }
        let before = try XCTUnwrap(try f.runtime.state().layout.tabs.first { $0.id == f.sourceTab })
        let pids = try backendPIDs(f)
        let tabToken = try XCTUnwrap(WorkspaceDrag.shared.tabPayload(tabID: f.sourceTab, store: f.store))
        XCTAssertTrue(WorkspaceDrag.shared.receive(tabToken, in: f.store, tabID: nil, workspaceID: f.sourceWorkspace))
        try await settle {
            f.window.contentView?.layoutSubtreeIfNeeded()
            return !f.store.loading && f.store.state.layout.currentTabs.map(\.id) == [f.destinationTab, f.sourceTab] &&
                f.store.selectedTab?.id == f.sourceTab
        }
        let reordered = try f.runtime.state().layout
        XCTAssertEqual(reordered.tabs.filter { $0.id == f.sourceTab }.count, 1)
        XCTAssertEqual(reordered.tabs.first { $0.id == f.sourceTab }?.tree, before.tree)
        XCTAssertEqual(reordered.tabs.first { $0.id == f.sourceTab }?.focusedPaneID, before.focusedPaneID)
        XCTAssertEqual(reordered.tabs.first { $0.id == f.sourceTab }?.title, before.title)

        let paneToken = try XCTUnwrap(WorkspaceDrag.shared.panePayload(paneID: f.panes[1], store: f.store))
        XCTAssertTrue(WorkspaceDrag.shared.receive(paneToken, in: f.store, tabID: nil, workspaceID: f.sourceWorkspace))
        try await settle {
            f.window.contentView?.layoutSubtreeIfNeeded()
            return !f.store.loading && f.store.state.layout.currentTabs.count == 3 &&
                f.store.selectedTab?.panes == [f.panes[1]] && f.store.selectedTab?.id != f.sourceTab &&
                f.store.terminalViews[f.panes[1]]?.window === f.window &&
                f.store.terminalViews[f.panes[1]]?.process.running == true
        }
        let layout = try f.runtime.state().layout
        let newTab = try XCTUnwrap(layout.tabs.first { $0.panes == [f.panes[1]] })
        XCTAssertNotEqual(newTab.id, f.sourceTab)
        XCTAssertNotEqual(newTab.id, f.destinationTab)
        XCTAssertEqual(newTab.workspaceID, f.sourceWorkspace)
        XCTAssertEqual(newTab.tree, .pane(f.panes[1]))
        XCTAssertEqual(newTab.focusedPaneID, f.panes[1])
        XCTAssertEqual(layout.tabs.filter { $0.workspaceID == f.sourceWorkspace }.map(\.id), [f.destinationTab, f.sourceTab, newTab.id])
        XCTAssertEqual(layout.tabs.first { $0.id == f.sourceTab }?.tree, .pane(f.panes[0]))
        XCTAssertEqual(layout.tabs.first { $0.id == f.destinationTab }?.tree, .pane(f.panes[2]))
        XCTAssertEqual(layout.tabs.flatMap(\.panes).filter { $0 == f.panes[1] }.count, 1)
        XCTAssertEqual(f.store.preferredWorkspaceID, f.sourceWorkspace)
        XCTAssertEqual(f.store.focusedID, f.panes[1])
        XCTAssertEqual(try backendPIDs(f), pids)
        XCTAssertTrue(try f.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-NAV-4, FR-NAV-12
    @MainActor func testExplicitWorkspaceDropRejectsUnknownClosedBlockedAndChangedSourceTargets() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let provider = WorkspaceDrag.shared.provider(paneID: f.panes[1], store: f.store)
        let data = try await payload(provider, type: .tranoPane)
        let before = try f.runtime.state().layout
        let pids = try backendPIDs(f)
        XCTAssertFalse(WorkspaceDrag.shared.receive(Data(UUID().uuidString.utf8), in: f.store, tabID: nil, workspaceID: f.destinationWorkspace))
        XCTAssertFalse(WorkspaceDrag.shared.receive(data, in: f.store, tabID: nil, workspaceID: UUID().uuidString))
        f.store.showSettings = true
        XCTAssertFalse(WorkspaceDrag.shared.receive(data, in: f.store, tabID: nil, workspaceID: f.destinationWorkspace))
        f.store.showSettings = false
        XCTAssertEqual(try f.runtime.state().layout, before)

        f.store.selectWorkspace(f.destinationWorkspace)
        try await settle { !f.store.loading && f.store.preferredWorkspaceID == f.destinationWorkspace }
        let afterNavigation = try f.runtime.state().layout
        XCTAssertFalse(WorkspaceDrag.shared.receive(data, in: f.store, tabID: nil, workspaceID: f.destinationWorkspace))
        XCTAssertEqual(try f.runtime.state().layout, afterNavigation)
        f.store.selectWorkspace(f.sourceWorkspace)
        try await settle { !f.store.loading && f.store.preferredWorkspaceID == f.sourceWorkspace }
        try f.runtime.update { $0.layout.closeWorkspace(f.destinationWorkspace) }
        f.store.refresh()
        try await settle { f.store.state.layout.workspaces.first { $0.id == f.destinationWorkspace }?.closed == true }
        let closed = try f.runtime.state().layout
        XCTAssertFalse(WorkspaceDrag.shared.receive(data, in: f.store, tabID: nil, workspaceID: f.destinationWorkspace))
        XCTAssertEqual(try f.runtime.state().layout, closed)
        XCTAssertEqual(try backendPIDs(f), pids)
    }

    // Implements: FR-NAV-4, FR-NAV-12
    @MainActor func testWorkspaceViewHostsExplicitSidebarRowsAndChooserOnExistingSwitcher() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        f.store.showSessionsSidebar = true
        let content = try XCTUnwrap(f.window.contentView)
        try await settle {
            content.layoutSubtreeIfNeeded()
            return self.descendants(in: content).contains { $0.identifier?.rawValue == "sidebar-workspace-" + f.destinationWorkspace }
        }
        let regions = descendants(in: content)
        for workspace in [f.sourceWorkspace, f.destinationWorkspace] {
            let target = try XCTUnwrap(regions.first { $0.identifier?.rawValue == "workspace-drop-" + workspace })
            XCTAssertGreaterThan(target.bounds.width, 100)
            XCTAssertGreaterThan(target.bounds.height, 15)
        }
        let switcher = try XCTUnwrap(regions.first { $0.identifier?.rawValue == "workspace-switcher" })
        let chooser = try XCTUnwrap(regions.first { $0.identifier?.rawValue == "workspace-drag-chooser" })
        XCTAssertEqual(chooser.convert(chooser.bounds, to: content).midX, switcher.convert(switcher.bounds, to: content).midX, accuracy: 1)
        XCTAssertEqual(chooser.convert(chooser.bounds, to: content).midY, switcher.convert(switcher.bounds, to: content).midY, accuracy: 1)
        XCTAssertEqual(chooser.bounds.width, switcher.bounds.width, accuracy: 1)
        XCTAssertEqual(chooser.bounds.height, switcher.bounds.height, accuracy: 1)
        XCTAssertNil(f.store.picker)
        XCTAssertEqual(f.store.preferredWorkspaceID, f.sourceWorkspace)
    }

    // Implements: FR-NAV-4, FR-NAV-12, U07, U21
    @MainActor func testActivePaneChooserRendersInsideItsWindowBelowHeaderWithoutResizingTerminal() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let interaction = WorkspaceDragChooserState()
        defer { interaction.dismiss() }
        let host = try chooserHost(f, interaction: interaction)
        let terminal = try XCTUnwrap(f.store.terminalViews[f.panes[1]])
        try await settle {
            host.layoutSubtreeIfNeeded()
            return terminal.window === f.window && terminal.bounds.width > 800 && terminal.bounds.height > 500
        }
        let before = terminal.convert(terminal.bounds, to: host)
        let pids = try backendPIDs(f)
        let paneToken = try XCTUnwrap(WorkspaceDrag.shared.panePayload(paneID: f.panes[1], store: f.store))
        interaction.enter(in: f.store)
        try await settle {
            host.layoutSubtreeIfNeeded()
            return self.descendants(in: host).contains { $0.identifier?.rawValue == "workspace-drag-destinations" }
        }
        let panel = try XCTUnwrap(descendants(in: host).first { $0.identifier?.rawValue == "workspace-drag-destinations" })
        let header = try XCTUnwrap(descendants(in: host).first { $0.identifier?.rawValue == "chooser-host-header" })
        let panelBounds = panel.convert(panel.bounds, to: host)
        let headerBounds = header.convert(header.bounds, to: host)
        XCTAssertTrue(interaction.presented)
        XCTAssertTrue(panel.window === f.window)
        XCTAssertTrue(host.bounds.insetBy(dx: -0.5, dy: -0.5).contains(panelBounds))
        XCTAssertGreaterThan(panelBounds.width, 200)
        XCTAssertGreaterThan(panelBounds.height, 50)
        if host.isFlipped { XCTAssertGreaterThanOrEqual(panelBounds.minY, headerBounds.maxY - 0.5) }
        else { XCTAssertLessThanOrEqual(panelBounds.maxY, headerBounds.minY + 0.5) }
        for workspace in [f.sourceWorkspace, f.destinationWorkspace] {
            let row = try XCTUnwrap(descendants(in: host).first { $0.identifier?.rawValue == "workspace-drop-" + workspace })
            XCTAssertTrue(row.window === f.window)
            XCTAssertTrue(panelBounds.insetBy(dx: -0.5, dy: -0.5).contains(row.convert(row.bounds, to: host)))
        }
        let after = terminal.convert(terminal.bounds, to: host)
        XCTAssertEqual(after.width, before.width, accuracy: 1)
        XCTAssertEqual(after.height, before.height, accuracy: 1)
        XCTAssertEqual(f.store.preferredWorkspaceID, f.sourceWorkspace)
        XCTAssertNil(f.store.picker)
        XCTAssertEqual(try backendPIDs(f), pids)
        if let path = ProcessInfo.processInfo.environment["TRANO_WORKSPACE_DROP_PREVIEW"],
           let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let png = bitmap.representation(using: .png, properties: [:]) { try png.write(to: URL(fileURLWithPath: path)) }
        }
        _ = WorkspaceDrag.shared.finishPaneDrag(paneToken, from: f.window, at: f.window.frame.origin,
                                               operation: [], cancelled: true, released: false)
    }

    // Implements: FR-NAV-4, FR-NAV-12
    @MainActor func testHostedChooserRejectsMissingTokensAndDismissesOnExitEscapeCancelAndCompletion() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let interaction = WorkspaceDragChooserState()
        defer { interaction.dismiss() }
        let host = try chooserHost(f, interaction: interaction)
        interaction.enter(in: f.store)
        XCTAssertFalse(interaction.presented)
        let token = try XCTUnwrap(WorkspaceDrag.shared.panePayload(paneID: f.panes[1], store: f.store))
        interaction.enter(in: f.store)
        XCTAssertTrue(interaction.presented)
        interaction.leave()
        try await settle { !interaction.presented }

        interaction.enter(in: f.store)
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: f.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        XCTAssertNotNil(interaction.handle(escape))
        XCTAssertFalse(interaction.presented)

        interaction.enter(in: f.store)
        _ = WorkspaceDrag.shared.finishPaneDrag(token, from: f.window, at: f.window.frame.origin,
                                               operation: [], cancelled: true, released: false)
        try await settle {
            host.layoutSubtreeIfNeeded()
            return !interaction.presented && !self.descendants(in: host).contains { $0.identifier?.rawValue == "workspace-drag-destinations" }
        }
        interaction.enter(in: f.store)
        XCTAssertFalse(interaction.presented)

        let acceptedToken = try XCTUnwrap(WorkspaceDrag.shared.panePayload(paneID: f.panes[1], store: f.store))
        interaction.enter(in: f.store)
        XCTAssertTrue(interaction.presented)
        XCTAssertTrue(WorkspaceDrag.shared.receive(acceptedToken, in: f.store, tabID: nil, workspaceID: f.destinationWorkspace))
        try await settle { !interaction.presented && f.store.preferredWorkspaceID == f.destinationWorkspace }
        interaction.enter(in: f.store)
        XCTAssertFalse(interaction.presented)
        XCTAssertNil(f.store.picker)
    }

    private struct ChooserHost: View {
        @ObservedObject var store: AppStore
        let interaction: WorkspaceDragChooserState
        let paneID: String

        var body: some View {
            VStack(spacing: 0) {
                HStack(spacing: 4) {
                    Button { store.picker = .sessions } label: {
                        HStack(spacing: 7) {
                            Image(systemName: "square.stack.3d.up")
                            Text("Source").font(.system(size: 12, weight: .semibold))
                            Image(systemName: "chevron.down").font(.system(size: 8))
                        }.padding(.horizontal, 6).frame(height: 40)
                    }.buttonStyle(.plain)
                        .modifier(WorkspaceDragChooser(store: store, interaction: interaction))
                    Spacer(minLength: 0)
                }
                .padding(.leading, 72)
                .background(Color(NSColor(hex: "#141416")))
                .background(WorkspaceRegion("chooser-host-header"))
                .zIndex(1)
                TerminalPane(store: store, id: paneID).id(paneID)
            }
            .frame(width: 900, height: 620)
            .preferredColorScheme(.dark)
        }
    }

    @MainActor private func chooserHost(_ f: Fixture, interaction: WorkspaceDragChooserState) throws -> NSHostingView<ChooserHost> {
        f.window.contentView = nil
        let host = NSHostingView(rootView: ChooserHost(store: f.store, interaction: interaction, paneID: f.panes[1]))
        f.window.setContentSize(NSSize(width: 900, height: 620))
        f.window.contentView = host
        host.frame = NSRect(x: 0, y: 0, width: 900, height: 620)
        host.layoutSubtreeIfNeeded()
        return host
    }

    @MainActor private func payload(_ provider: NSItemProvider, type: UTType) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            _ = provider.loadDataRepresentation(forTypeIdentifier: type.identifier) { data, error in
                if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: error ?? TerminalError.invalid("Missing workspace drop payload")) }
            }
        }
    }

    @MainActor private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    @MainActor private func backendPIDs(_ f: Fixture) throws -> [String: Int32] {
        Dictionary(uniqueKeysWithValues: try f.runtime.list().map { ($0.id, $0.pid) })
    }

    @MainActor private func settle(_ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        } while Date() < deadline
        XCTFail("Workspace drop did not settle")
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let panes: [String]
        let sourceWorkspace: String
        let destinationWorkspace: String
        let sourceTab: String
        let destinationTab: String
    }

    @MainActor private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-workspace-drop-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        runtime.isolatePaneHome(root)
        var store: AppStore?
        var window: NSWindow?
        var succeeded = false
        defer {
            if !succeeded {
                for view in store?.terminalViews.values.map({ $0 }) ?? [] { view.terminate() }
                store?.terminalViews.removeAll()
                window?.close()
                for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
                runtime.shutdownTestHost()
                try? FileManager.default.removeItem(at: root)
            }
        }
        let panes = try (0..<3).map { try runtime.create(title: "Workspace drop \($0)", cwd: root.path, shell: "/bin/sleep", arguments: ["90"]).id }
        var sourceWorkspace = "", destinationWorkspace = "", sourceTab = "", destinationTab = ""
        try runtime.update { state in
            state.settings.automaticRestore = false
            sourceWorkspace = state.layout.addWorkspace(title: "Source")
            sourceTab = state.layout.addTab(paneID: panes[0])
            try state.layout.split(tabID: sourceTab, paneID: panes[1], axis: .horizontal)
            destinationWorkspace = state.layout.addWorkspace(title: "Destination")
            destinationTab = state.layout.addTab(paneID: panes[2])
            try state.layout.selectWorkspace(sourceWorkspace)
        }
        let model = AppStore(runtime: runtime)
        store = model
        let hosting = NSHostingView(rootView: WorkspaceView(store: model))
        let owner = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), contentView: hosting)
        window = owner
        owner.orderFrontRegardless()
        try await settle {
            hosting.layoutSubtreeIfNeeded()
            return !model.loading && model.preferredWorkspaceID == sourceWorkspace &&
                panes.prefix(2).allSatisfy { model.terminalViews[$0]?.process.running == true }
        }
        succeeded = true
        return Fixture(root: root, runtime: runtime, store: model, window: owner, panes: panes, sourceWorkspace: sourceWorkspace,
                       destinationWorkspace: destinationWorkspace, sourceTab: sourceTab, destinationTab: destinationTab)
    }

    @MainActor private func dispose(_ f: Fixture) {
        for terminal in f.store.terminalViews.values { terminal.terminate() }
        f.store.terminalViews.removeAll()
        f.window.close()
        for pane in (try? f.runtime.list()) ?? [] { try? f.runtime.terminate(pane.id) }
        f.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: f.root)
    }
}
