import AppKit
import CoreGraphics
import SwiftUI
import XCTest
import TerminalCore
@testable import TranoApp

final class FloatingPaneTests: XCTestCase {
    // Implements: FR-NAV-4, U09
    @MainActor func testFloatAndNativeReturnKeepRendererAttachAndExactSplit() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let action = try XCTUnwrap(ActionID(rawValue: "pane.float"))
        let terminal = try XCTUnwrap(fixture.store.terminalViews[fixture.panes[0]])
        let attachPID = terminal.process.shellPid
        let before = try fixture.runtime.state().layout
        let pids = Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) })
        fixture.store.execute(action)
        try await settle(fixture) { self.floatingWindow(fixture.panes[0]) != nil && terminal.window !== fixture.window }
        let panel = try XCTUnwrap(floatingWindow(fixture.panes[0]))
        XCTAssertEqual(panel.level, .floating)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertTrue(terminal.window === panel)
        XCTAssertTrue(terminal.process.running)
        XCTAssertEqual(terminal.process.shellPid, attachPID)
        XCTAssertTrue(fixture.store.terminalViews[fixture.panes[0]] === terminal)
        XCTAssertNotNil(region("floating-pane-placeholder-" + fixture.panes[0], in: fixture.hosting))
        XCTAssertEqual(try fixture.runtime.state().layout, before)
        let button = try XCTUnwrap(region("floating-pane-return", in: try XCTUnwrap(panel.contentView)) as? NSButton)
        XCTAssertTrue(button.target === button)
        button.performClick(nil)
        try await settle(fixture) { terminal.window === fixture.window && self.floatingWindow(fixture.panes[0]) == nil }
        XCTAssertTrue(terminal.process.running)
        XCTAssertEqual(terminal.process.shellPid, attachPID)
        XCTAssertTrue(fixture.store.terminalViews[fixture.panes[0]] === terminal)
        XCTAssertEqual(try fixture.runtime.state().layout, before)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) }), pids)
    }

    // Implements: FR-NAV-4, U09
    @MainActor func testClosingFloatingWindowReturnsItsPaneWithoutTerminatingJobs() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let action = try XCTUnwrap(ActionID(rawValue: "pane.float"))
        let terminal = try XCTUnwrap(fixture.store.terminalViews[fixture.panes[0]])
        let attachPID = terminal.process.shellPid
        let pids = Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) })
        fixture.store.execute(action)
        try await settle(fixture) { self.floatingWindow(fixture.panes[0]) != nil }
        try XCTUnwrap(floatingWindow(fixture.panes[0])).close()
        try await settle(fixture) { terminal.window === fixture.window && self.floatingWindow(fixture.panes[0]) == nil }
        XCTAssertTrue(terminal.process.running)
        XCTAssertEqual(terminal.process.shellPid, attachPID)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) }), pids)
        XCTAssertTrue(try fixture.runtime.list().allSatisfy(\.alive))
    }

    // Implements: FR-CLOSE-5, FR-NAV-2, U09
    @MainActor func testFloatingPaneCloseShortcutTerminatesItsPaneAndPreservesSibling() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let action = try XCTUnwrap(ActionID(rawValue: "pane.float"))
        let sibling = try XCTUnwrap(fixture.store.terminalViews[fixture.panes[1]])
        let siblingClient = sibling.process.shellPid
        fixture.store.execute(action)
        try await settle(fixture) { self.floatingWindow(fixture.panes[0]) != nil }
        let panel = try XCTUnwrap(floatingWindow(fixture.panes[0]))
        XCTAssertTrue(fixture.delegate.floatingWindows[panel] === fixture.store)
        let close = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "w", charactersIgnoringModifiers: "w", isARepeat: false, keyCode: 13))
        XCTAssertTrue(fixture.delegate.handle(close))
        try await settle(fixture) {
            self.floatingWindow(fixture.panes[0]) == nil && fixture.store.selectedTab?.panes == [fixture.panes[1]]
        }
        XCTAssertNil(fixture.delegate.floatingWindows[panel])
        XCTAssertTrue(sibling.process.running)
        XCTAssertEqual(sibling.process.shellPid, siblingClient)
        XCTAssertFalse(try XCTUnwrap(fixture.runtime.list().first { $0.id == fixture.panes[0] }).alive)
        XCTAssertNotNil(try fixture.runtime.closedTerminalPaneSnapshot(fixture.panes[0]))
    }

    // Implements: FR-CLOSE-5, FR-NAV-2, U09
    @MainActor func testClosePaneMenuTerminatesFloatWithoutStoppingSibling() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.store.execute(try XCTUnwrap(ActionID(rawValue: "pane.float")))
        try await settle(fixture) { self.floatingWindow(fixture.panes[0]) != nil }
        let panel = try XCTUnwrap(floatingWindow(fixture.panes[0]))
        let sibling = try XCTUnwrap(fixture.store.terminalViews[fixture.panes[1]])
        let client = sibling.process.shellPid
        fixture.delegate.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: panel))
        let menu = NSMenuItem(title: "Close Pane", action: #selector(ApplicationDelegate.performMenuAction(_:)), keyEquivalent: "w")
        menu.identifier = NSUserInterfaceItemIdentifier(ActionID.closePane.rawValue)
        fixture.delegate.performMenuAction(menu)
        try await settle(fixture) {
            self.floatingWindow(fixture.panes[0]) == nil && fixture.store.selectedTab?.panes == [fixture.panes[1]]
        }
        XCTAssertFalse(try XCTUnwrap(fixture.runtime.list().first { $0.id == fixture.panes[0] }).alive)
        XCTAssertNotNil(try fixture.runtime.closedTerminalPaneSnapshot(fixture.panes[0]))
        XCTAssertTrue(sibling.process.running)
        XCTAssertEqual(sibling.process.shellPid, client)
    }

    // Implements: FR-NAV-4, U09
    @MainActor func testRapidFloatCancellationLeavesSwiftUIRendererAttached() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let action = try XCTUnwrap(ActionID(rawValue: "pane.float"))
        let terminal = try XCTUnwrap(fixture.store.terminalViews[fixture.panes[0]])
        let client = terminal.process.shellPid
        fixture.store.execute(action)
        fixture.store.execute(action)
        try await Task.sleep(for: .milliseconds(150))
        fixture.hosting.layoutSubtreeIfNeeded()
        XCTAssertTrue(terminal.window === fixture.window)
        XCTAssertNil(floatingWindow(fixture.panes[0]))
        XCTAssertTrue(terminal.process.running)
        XCTAssertEqual(terminal.process.shellPid, client)
    }

    // Implements: FR-NAV-4, FR-QUEUE-4, FR-NAV-2
    @MainActor func testFloatOriginPaletteAndQueueAppearAboveFloatWithoutMovingRenderer() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        fixture.store.execute(try XCTUnwrap(ActionID(rawValue: "pane.float")))
        try await settle(fixture) { self.floatingWindow(fixture.panes[0]) != nil }
        let panel = try XCTUnwrap(floatingWindow(fixture.panes[0]))
        let terminal = try XCTUnwrap(fixture.store.terminalViews[fixture.panes[0]])
        let client = terminal.process.shellPid
        let frame = panel.frame
        let palette = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "P", charactersIgnoringModifiers: "p", isARepeat: false, keyCode: 35))
        XCTAssertTrue(fixture.delegate.handle(palette))
        try await settle(fixture) { panel.level == .normal && self.region("picker-search-field", in: fixture.hosting) != nil }
        XCTAssertEqual(panel.level, .normal)
        assertOwnerInputUnobscured(fixture, panel: panel)
        let search = try XCTUnwrap(region("picker-search-field", in: fixture.hosting) as? NSTextField)
        XCTAssertTrue(search.window === fixture.window)
        XCTAssertTrue(fixture.window.makeFirstResponder(search))
        XCTAssertNotNil(search.currentEditor())
        XCTAssertTrue(terminal.window === panel)
        XCTAssertEqual(terminal.process.shellPid, client)
        fixture.store.dismissPicker()
        try await settle(fixture) { panel.level == .floating && panel.isVisible }
        XCTAssertEqual(panel.frame, frame)

        let queue = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: panel.windowNumber, context: nil, characters: "U", charactersIgnoringModifiers: "u", isARepeat: false, keyCode: 32))
        XCTAssertTrue(fixture.delegate.handle(queue))
        try await settle(fixture) { panel.level == .normal && self.region("follow-up-panel", in: fixture.hosting) != nil }
        XCTAssertEqual(panel.level, .normal)
        assertOwnerInputUnobscured(fixture, panel: panel)
        XCTAssertTrue(fixture.store.followUpEditor?.window === fixture.window)
        XCTAssertTrue(terminal.window === panel)
        XCTAssertEqual(terminal.process.shellPid, client)
        fixture.store.dismissFollowUps()
        try await settle(fixture) { panel.level == .floating && panel.isVisible }
        XCTAssertEqual(panel.frame, frame)
    }

    // Implements: FR-NAV-4, U05
    @MainActor func testFloatingBackgroundKeepsWallpaperAndUpdatesResolvedAppearanceInPlace() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<2 { for y in 0..<2 { bitmap.setColor(.red, atX: x, y: y) } }
        let path = fixture.root.appendingPathComponent("fixture-wallpaper.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: path)
        XCTAssertNotNil(BackgroundImageStore.load(path: path.path))
        try fixture.runtime.update { state in
            state.settings.appearance.backgroundImagePath = path.path
            state.settings.appearance.backgroundImageOpacity = 0.2
        }
        fixture.store.refresh()
        try await settle(fixture) { fixture.store.state.settings.appearance.backgroundImagePath == path.path }
        fixture.store.execute(try XCTUnwrap(ActionID(rawValue: "pane.float")))
        try await settle(fixture) { self.floatingWindow(fixture.panes[0]) != nil }
        let panel = try XCTUnwrap(floatingWindow(fixture.panes[0]))
        let terminal = try XCTUnwrap(fixture.store.terminalViews[fixture.panes[0]])
        let background = try XCTUnwrap(region("floating-pane-background", in: try XCTUnwrap(panel.contentView)) as? NSHostingView<TerminalBackgroundView>)
        XCTAssertEqual(background.rootView.settings.appearance.backgroundImagePath, path.path)
        XCTAssertEqual(background.rootView.settings.appearance.backgroundImageOpacity, 0.2)
        XCTAssertTrue(background.window === panel)
        XCTAssertEqual(background.frame, terminal.frame)
        XCTAssertEqual(terminal.nativeBackgroundColor.alphaComponent, 0, accuracy: 0.01)
        try fixture.runtime.update { state in
            state.settings.appearance.backgroundImagePath = nil
            state.settings.appearance.opacity = 0.72
        }
        fixture.store.refresh()
        try await settle(fixture) { background.rootView.settings.appearance.backgroundImagePath == nil }
        XCTAssertTrue(region("floating-pane-background", in: try XCTUnwrap(panel.contentView)) === background)
        XCTAssertEqual(background.rootView.settings.appearance.opacity, 0.72)
        XCTAssertEqual(terminal.nativeBackgroundColor.alphaComponent, 0.72, accuracy: 0.01)
    }

    // Implements: FR-NAV-4, U09, U11
    @MainActor func testMirroredStoreCannotDuplicateFloatOrTransferItsPaneAndTab() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let mirror = AppStore(runtime: fixture.runtime)
        let mirrorWindow = makeAuxiliaryWindow(store: mirror)
        defer {
            for panel in NSApp.windows where panel.identifier?.rawValue == "floating-pane-" + fixture.panes[0] { panel.close() }
            for view in mirror.terminalViews.values { view.terminate() }
            mirror.terminalViews.removeAll()
            mirrorWindow.close()
        }
        try await settle(fixture) { !mirror.loading && mirror.terminalViews[fixture.panes[0]]?.process.running == true }
        let tabID = try XCTUnwrap(mirror.selectedTab?.id)
        let paneData = try await loadDrag(WorkspaceDrag.shared.provider(paneID: fixture.panes[0], store: mirror), type: "app.trano.pane")
        let tabData = try await loadDrag(WorkspaceDrag.shared.provider(tabID: tabID, store: mirror), type: "app.trano.tab")
        let extra = try fixture.runtime.create(title: "Target", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["90"])
        var destinationWorkspace = ""
        try fixture.runtime.update { state in
            destinationWorkspace = state.layout.addWorkspace(title: "Destination")
            state.layout.addTab(paneID: extra.id)
        }
        let destination = AppStore(runtime: fixture.runtime)
        let destinationWindow = makeAuxiliaryWindow(store: destination)
        defer {
            for view in destination.terminalViews.values { view.terminate() }
            destination.terminalViews.removeAll()
            destinationWindow.close()
            try? fixture.runtime.terminate(extra.id)
        }
        try await settle(fixture) { !destination.loading && destination.preferredWorkspaceID == destinationWorkspace }
        let action = try XCTUnwrap(ActionID(rawValue: "pane.float"))
        fixture.store.execute(action)
        try await settle(fixture) { self.floatingWindow(fixture.panes[0]) != nil }
        let terminal = try XCTUnwrap(fixture.store.terminalViews[fixture.panes[0]])
        let client = terminal.process.shellPid
        mirror.execute(action)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(NSApp.windows.filter { $0.isVisible && $0.identifier?.rawValue == "floating-pane-" + fixture.panes[0] }.count, 1)
        XCTAssertTrue(mirror.floatingPaneIDs.isEmpty)
        let before = try fixture.runtime.state().layout
        let paneAccepted = WorkspaceDrag.shared.receive(paneData, in: destination, tabID: destination.selectedTab?.id)
        XCTAssertFalse(paneAccepted)
        guard !paneAccepted else { return }
        XCTAssertFalse(WorkspaceDrag.shared.receive(tabData, in: destination, tabID: nil))
        XCTAssertEqual(try fixture.runtime.state().layout, before)
        XCTAssertEqual(terminal.process.shellPid, client)
        XCTAssertTrue(terminal.window === floatingWindow(fixture.panes[0]))
    }

    @MainActor private func makeAuxiliaryWindow(store: AppStore) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = NSHostingView(rootView: WorkspaceView(store: store))
        window.orderFrontRegardless()
        return window
    }

    private func loadDrag(_ provider: NSItemProvider, type: String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadDataRepresentation(forTypeIdentifier: type) { data, error in
                if let error { continuation.resume(throwing: error) }
                else if let data { continuation.resume(returning: data) }
                else { continuation.resume(throwing: NSError(domain: "TranoFloatFixture", code: 1)) }
            }
        }
    }

    @MainActor private func assertOwnerInputUnobscured(_ fixture: Fixture, panel: NSWindow) {
        XCTAssertTrue(fixture.window.isVisible)
        XCTAssertFalse(panel.isVisible)
    }

    // Implements: FR-NAV-2
    @MainActor func testClosingANestedSplitPaneReturnsItsSpaceToTheSurvivingPane() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let survivor = fixture.panes[1]
        let terminal = try XCTUnwrap(fixture.store.terminalViews[survivor])
        func height() -> CGFloat { terminal.convert(terminal.bounds, to: fixture.hosting).height }
        try await settle(fixture) { terminal.window === fixture.window && height() > 100 }
        let fullHeight = height(), fullRows = terminal.terminalDimensions.rows
        for round in 0..<2 {
            let added = try fixture.runtime.create(title: "Float extra \(round)", cwd: fixture.root.path, shell: "/bin/sleep", arguments: ["90"]).id
            defer { try? fixture.runtime.terminate(added) }
            let tabID = try XCTUnwrap(fixture.store.selectedTab?.id)
            try fixture.runtime.update {
                try $0.layout.focusPane(survivor)
                try $0.layout.split(tabID: tabID, paneID: added, axis: .vertical)
            }
            fixture.store.refresh()
            try await settle(fixture) {
                fixture.store.terminalViews[added]?.process.running == true
                    && height() < fullHeight * 0.6 && terminal.terminalDimensions.rows < fullRows - 3
            }
            try fixture.runtime.update { $0.layout.closePane(added) }
            fixture.store.refresh()
            try await settle(fixture) {
                fixture.store.selectedTab?.panes.count == 2 && abs(height() - fullHeight) < 1
                    && terminal.terminalDimensions.rows == fullRows
            }
            XCTAssertEqual(height(), fullHeight, accuracy: 1, "round \(round)")
            XCTAssertEqual(terminal.terminalDimensions.rows, fullRows, "round \(round)")
            XCTAssertTrue(fixture.store.terminalViews[survivor] === terminal)
        }
    }

    // Implements: FR-NAV-2, FR-NAV-4, U09
    @MainActor func testCommandShiftEnterTogglesMaximizationAndPreservesAttachClients() async throws {
        let fixture = try await makeFixture()
        defer { dispose(fixture) }
        let terminal = try XCTUnwrap(fixture.store.terminalViews[fixture.panes[0]])
        let other = try XCTUnwrap(fixture.store.terminalViews[fixture.panes[1]])
        let attachPIDs = [terminal.process.shellPid, other.process.shellPid]
        let original = terminal.convert(terminal.bounds, to: fixture.hosting)
        let tree = fixture.store.selectedTab?.tree
        let pids = Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) })
        let event = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .shift], timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36))
        for _ in 0..<3 {
            XCTAssertTrue(fixture.delegate.handle(event))
            XCTAssertTrue(fixture.store.zoomed)
            try await settle(fixture) { terminal.bounds.width > original.width + 100 }
            XCTAssertTrue(fixture.store.terminalViews[fixture.panes[0]] === terminal)
            XCTAssertTrue(fixture.store.terminalViews[fixture.panes[1]] === other)
            XCTAssertTrue(fixture.delegate.handle(event))
            XCTAssertFalse(fixture.store.zoomed)
            try await settle(fixture) { abs(terminal.bounds.width - original.width) < 1 }
            XCTAssertTrue(terminal.process.running)
            XCTAssertTrue(other.process.running)
            XCTAssertEqual([terminal.process.shellPid, other.process.shellPid], attachPIDs)
            XCTAssertEqual(fixture.store.selectedTab?.tree, tree)
        }
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try fixture.runtime.list().map { ($0.id, $0.pid) }), pids)
    }

    @MainActor private func floatingWindow(_ paneID: String) -> NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue == "floating-pane-" + paneID && $0.isVisible }
    }

    @MainActor private func region(_ id: String, in view: NSView) -> NSView? {
        if view.identifier?.rawValue == id { return view }
        return view.subviews.lazy.compactMap { self.region(id, in: $0) }.first
    }

    @MainActor private func settle(_ fixture: Fixture, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            fixture.hosting.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        } while Date() < deadline
        XCTFail("Floating pane did not settle: " + (fixture.store.message ?? "no error"))
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let hosting: NSHostingView<WorkspaceView>
        let delegate: ApplicationDelegate
        let panes: [String]
    }

    @MainActor private func makeFixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-float-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        let panes = try (0..<2).map { try runtime.create(title: "Float \($0)", cwd: root.path, shell: "/bin/sleep", arguments: ["90"]).id }
        try runtime.update { state in
            state.settings.automaticRestore = false
            let tab = state.layout.addTab(paneID: panes[0])
            try state.layout.split(tabID: tab, paneID: panes[1], axis: .horizontal)
            try state.layout.focusPane(panes[0])
        }
        let store = AppStore(runtime: runtime)
        let hosting = NSHostingView(rootView: WorkspaceView(store: store))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentView = hosting
        window.orderFrontRegardless()
        let delegate = ApplicationDelegate()
        delegate.windows[window] = store
        delegate.window = window
        delegate.store = store
        delegate.observeSettings(store, window: window)
        delegate.configureFloatingPanes(store)
        let fixture = Fixture(root: root, runtime: runtime, store: store, window: window, hosting: hosting, delegate: delegate, panes: panes)
        try await settle(fixture) { !store.loading && panes.allSatisfy { store.terminalViews[$0]?.process.running == true } }
        return fixture
    }

    @MainActor private func dispose(_ fixture: Fixture) {
        fixture.store.floatingPanes.closeAll()
        for view in fixture.store.terminalViews.values { view.terminate() }
        fixture.store.terminalViews.removeAll()
        fixture.window.close()
        for pane in fixture.panes { try? fixture.runtime.terminate(pane) }
        try? FileManager.default.removeItem(at: fixture.root)
    }
}
