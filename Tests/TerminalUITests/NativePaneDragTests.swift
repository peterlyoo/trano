import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class NativePaneDragTests: XCTestCase {
    // Implements: FR-NAV-10, FR-NAV-12
    @MainActor func testPrivatePanePayloadOnlyAdvertisesMoveWithinTheApplication() {
        let view = PaneDragView()
        XCTAssertEqual(view.operationMask(for: .withinApplication), .move)
        XCTAssertTrue(view.operationMask(for: .outsideApplication).isEmpty)
    }

    // Implements: FR-NAV-10
    @MainActor func testActiveDragOwnsItsUnmountedSourceUntilCompletionThenReleasesIt() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        weak var retainedSource: PaneDragView?
        try autoreleasepool {
            let source = PaneDragView(frame: NSRect(x: 0, y: 40, width: 300, height: 28))
            source.store = f.store
            source.paneID = f.panes[0]
            source.title = "Temporary header"
            source.beginSession = { _, _, _ in true }
            f.container.addSubview(source)
            retainedSource = source
            source.mouseDown(with: try mouse(.leftMouseDown, in: source, at: NSPoint(x: 10, y: 10)))
            source.mouseDragged(with: try mouse(.leftMouseDragged, in: source, at: NSPoint(x: 50, y: 10)))
            source.removeFromSuperview()
        }
        XCTAssertNotNil(retainedSource, "The active native drag must own its source after the header unmounts")
        autoreleasepool {
            retainedSource?.completeDrag(at: .zero, operation: [], released: false, cancelled: true)
        }
        XCTAssertNil(retainedSource, "Completing or canceling the drag must release its source")
        weak var failedSource: PaneDragView?
        try autoreleasepool {
            let source = PaneDragView(frame: NSRect(x: 0, y: 40, width: 300, height: 28))
            source.store = f.store
            source.paneID = f.panes[0]
            source.title = "Failed drag"
            source.beginSession = { _, _, _ in false }
            f.container.addSubview(source)
            failedSource = source
            source.mouseDown(with: try mouse(.leftMouseDown, in: source, at: NSPoint(x: 10, y: 10)))
            source.mouseDragged(with: try mouse(.leftMouseDragged, in: source, at: NSPoint(x: 50, y: 10)))
            source.removeFromSuperview()
        }
        XCTAssertNil(failedSource, "A failed native drag start must not retain its source")
    }

    // Implements: FR-NAV-10
    @MainActor func testWorkspaceHeaderRoutesNativeDragIntoAnotherTabAndKeepsQueuedInputClickable() async throws {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-drag-ui-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        var store: AppStore?
        var window: NSWindow?
        defer {
            if let store {
                for terminal in store.terminalViews.values { terminal.terminate() }
                store.terminalViews.removeAll()
            }
            window?.close()
            for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
            runtime.shutdownTestHost()
            try? FileManager.default.removeItem(at: root)
        }
        let panes = try (0..<3).map { index in try runtime.create(title: "Pane \(index)", cwd: root.path, shell: "/bin/sleep", arguments: ["60"]).id }
        var sourceTab = "", destinationTab = ""
        try runtime.update {
            $0.settings.automaticRestore = false
            sourceTab = $0.layout.addTab(paneID: panes[0])
            try $0.layout.split(tabID: sourceTab, paneID: panes[1], axis: .horizontal)
            destinationTab = $0.layout.addTab(paneID: panes[2])
            try $0.layout.selectTab(sourceTab)
        }
        let model = AppStore(runtime: runtime)
        store = model
        let hosting = NSHostingView(rootView: WorkspaceView(store: model))
        let owner = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), contentView: hosting)
        window = owner
        owner.orderFrontRegardless()
        try await settle {
            hosting.layoutSubtreeIfNeeded()
            return !model.loading && panes.prefix(2).allSatisfy { model.terminalViews[$0]?.process.running == true }
        }
        let before = Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) })
        let drag = try XCTUnwrap(descendants(in: hosting).compactMap { $0 as? PaneDragView }.first { $0.identifier?.rawValue == "pane-drag-" + panes[0] })
        XCTAssertEqual(drag.bounds.height, 28, accuracy: 0.5)
        let frame = try XCTUnwrap(owner.contentView?.superview)
        let midpoint = NSPoint(x: drag.bounds.midX, y: drag.bounds.midY)
        XCTAssertTrue(frame.hitTest(drag.convert(midpoint, to: frame)) === drag)
        let button = try XCTUnwrap(descendants(in: hosting).first { $0.identifier?.rawValue == "queued-input-button-" + panes[0] } as? QueuedInputNativeButton)
        let buttonMidpoint = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
        XCTAssertTrue(frame.hitTest(button.convert(buttonMidpoint, to: frame)) === button)
        XCTAssertFalse(drag.bounds.contains(button.convert(buttonMidpoint, to: drag)))
        let status = try XCTUnwrap(descendants(in: hosting).compactMap { $0 as? PaneDragView }.first { $0.identifier?.rawValue == "pane-status-drag-" + panes[0] })
        XCTAssertGreaterThan(status.bounds.width, 0)
        let statusMidpoint = NSPoint(x: status.bounds.midX, y: status.bounds.midY)
        XCTAssertTrue(frame.hitTest(status.convert(statusMidpoint, to: frame)) === status)
        status.mouseDown(with: try mouse(.leftMouseDown, in: status, at: statusMidpoint))
        status.mouseUp(with: try mouse(.leftMouseUp, in: status, at: statusMidpoint))
        try await settle { model.focusedID == panes[0] }
        var payload: Data?
        drag.beginSession = { items, _, _ in
            payload = (items.first?.item as? NSPasteboardItem)?.data(forType: NSPasteboard.PasteboardType(UTType.tranoPane.identifier))
            return true
        }
        drag.mouseDown(with: try mouse(.leftMouseDown, in: drag, at: midpoint))
        drag.mouseDragged(with: try mouse(.leftMouseDragged, in: drag, at: NSPoint(x: midpoint.x + 18, y: midpoint.y)))
        let data = try XCTUnwrap(payload)
        XCTAssertTrue(WorkspaceDrag.shared.receive(data, in: model, tabID: destinationTab))
        drag.completeDrag(at: owner.frame.origin, operation: .move, released: true, cancelled: false)
        try await settle {
            hosting.layoutSubtreeIfNeeded()
            return model.state.layout.tabs.first { $0.id == sourceTab }?.panes == [panes[1]] &&
                model.state.layout.tabs.first { $0.id == destinationTab }?.panes.contains(panes[0]) == true &&
                model.terminalViews[panes[0]]?.process.running == true
        }
        let layout = try runtime.state().layout
        XCTAssertEqual(layout.tabs.first { $0.id == sourceTab }?.panes, [panes[1]])
        XCTAssertEqual(layout.tabs.first { $0.id == destinationTab }?.panes, [panes[2], panes[0]])
        XCTAssertEqual(layout.tabs.flatMap(\.panes).filter { $0 == panes[0] }.count, 1)
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: try runtime.list().map { ($0.id, $0.pid) }), before)
    }

    // Implements: FR-NAV-10
    @MainActor func testNativePrefixHitTestingLeavesControlAndContextClicksAvailable() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let point = NSPoint(x: 20, y: 14)
        XCTAssertTrue(f.drag.pointerHitTest(point, event: try mouse(.leftMouseDown, in: f.drag, at: point)) === f.drag)
        XCTAssertNil(f.drag.pointerHitTest(point, event: try mouse(.rightMouseDown, in: f.drag, at: point)))
        XCTAssertNil(f.drag.pointerHitTest(point, event: try mouse(.leftMouseDown, in: f.drag, at: point, modifiers: .control)))
        XCTAssertNil(f.drag.pointerHitTest(NSPoint(x: 301, y: 14), event: nil))
        XCTAssertFalse(f.drag.mouseDownCanMoveWindow)
        XCTAssertTrue(f.container.hitTest(NSPoint(x: 330, y: 14)) === f.button)
    }

    // Implements: FR-NAV-10
    @MainActor func testClickFocusesTheClickedPaneWithoutStartingADragOrChangingJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        f.store.followUpPaneID = f.panes[1]
        let pids = try backendPIDs(f)
        let initial = try f.runtime.state().layout.tabs
        var starts = 0
        f.drag.beginSession = { _, _, _ in starts += 1; return true }
        f.drag.mouseDown(with: try mouse(.leftMouseDown, in: f.drag, at: NSPoint(x: 20, y: 14)))
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 21, y: 14)))
        XCTAssertEqual(starts, 0)
        f.drag.mouseUp(with: try mouse(.leftMouseUp, in: f.drag, at: NSPoint(x: 21, y: 14)))
        try await settle { f.store.focusedID == f.panes[0] }
        XCTAssertEqual(f.store.focusedID, f.panes[0])
        XCTAssertEqual(f.store.followUpPaneID, f.panes[1])
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(try backendPIDs(f), pids)
        XCTAssertEqual(try f.runtime.state().layout.tabs.map(\.tree), initial.map(\.tree))
    }

    // Implements: FR-NAV-10
    @MainActor func testDragMotionCreatesPrivatePanePayloadAndDoesNotFocusOrCreateProcesses() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let pids = try backendPIDs(f)
        let priorFocus = f.store.focusedID
        var items: [NSDraggingItem] = []
        f.drag.beginSession = { captured, _, _ in items = captured; return true }
        f.drag.mouseDown(with: try mouse(.leftMouseDown, in: f.drag, at: NSPoint(x: 20, y: 14)))
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 35, y: 18)))
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first?.item as? NSPasteboardItem)
        let data = try XCTUnwrap(item.data(forType: NSPasteboard.PasteboardType(UTType.tranoPane.identifier)))
        XCTAssertEqual(data.count, 36)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(String(data: data, encoding: .utf8))))
        XCTAssertFalse(item.types.contains(.string))
        XCTAssertEqual(f.store.focusedID, priorFocus)
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 55, y: 20)))
        XCTAssertEqual(items.count, 1)
        f.drag.completeDrag(at: .zero, operation: .move, released: true, cancelled: false)
        XCTAssertEqual(try backendPIDs(f), pids)
    }

    // Implements: FR-NAV-10
    @MainActor func testContextClicksCannotStartOrFocusPaneDrag() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let focus = f.store.focusedID
        var starts = 0
        f.drag.beginSession = { _, _, _ in starts += 1; return true }
        for (type, modifiers) in [(NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()), (.leftMouseDown, .control)] {
            f.drag.mouseDown(with: try mouse(type, in: f.drag, at: NSPoint(x: 10, y: 10), modifiers: modifiers))
            f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 80, y: 20)))
            f.drag.mouseUp(with: try mouse(.leftMouseUp, in: f.drag, at: NSPoint(x: 80, y: 20)))
        }
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(f.store.focusedID, focus)
    }

    // Implements: FR-NAV-10
    @MainActor func testEndUsesCapturedPayloadAndOriginAfterHeaderUnmountOrUpdate() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        var payload: Data?
        f.drag.beginSession = { items, _, _ in
            payload = (items.first?.item as? NSPasteboardItem)?.data(forType: NSPasteboard.PasteboardType(UTType.tranoPane.identifier))
            return true
        }
        var completed: [(Data, NSWindow, NSPoint, NSDragOperation, Bool, Bool)] = []
        f.drag.finish = { data, origin, point, operation, cancelled, released in
            completed.append((data, origin, point, operation, cancelled, released))
            return false
        }
        f.drag.mouseDown(with: try mouse(.leftMouseDown, in: f.drag, at: NSPoint(x: 10, y: 10)))
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 50, y: 10)))
        f.drag.paneID = f.panes[1]
        f.drag.removeFromSuperview()
        let outside = NSPoint(x: f.window.frame.maxX + 100, y: f.window.frame.midY)
        f.drag.completeDrag(at: outside, operation: [], released: true, cancelled: false)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.0, payload)
        XCTAssertTrue(completed.first?.1 === f.window)
        XCTAssertEqual(completed.first?.2, outside)
        XCTAssertEqual(completed.first?.3, [])
        XCTAssertEqual(completed.first?.4, false)
        XCTAssertEqual(completed.first?.5, true)
        f.drag.completeDrag(at: outside, operation: [], released: true, cancelled: false)
        XCTAssertEqual(completed.count, 1)
    }

    // Implements: FR-NAV-10
    @MainActor func testEscapeAndHeldMouseAreNotReportedAsAnOutsideRelease() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        f.drag.beginSession = { _, _, _ in true }
        var endings: [(Bool, Bool)] = []
        f.drag.finish = { _, _, _, _, cancelled, released in endings.append((cancelled, released)); return false }
        f.drag.mouseDown(with: try mouse(.leftMouseDown, in: f.drag, at: NSPoint(x: 10, y: 10)))
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 60, y: 10)))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        f.drag.observeDragEvent(escape)
        f.drag.completeDrag(at: .zero, operation: [], released: true, cancelled: false)
        XCTAssertEqual(endings.count, 1)
        XCTAssertTrue(endings[0].0)
        f.drag.mouseDown(with: try mouse(.leftMouseDown, in: f.drag, at: NSPoint(x: 10, y: 10)))
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 60, y: 10)))
        f.drag.completeDrag(at: .zero, operation: [], released: false, cancelled: false)
        XCTAssertEqual(endings.count, 2)
        XCTAssertFalse(endings[1].1)
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let container: NSView
        let drag: PaneDragView
        let button: NSButton
        let panes: [String]
    }

    @MainActor private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = URL(fileURLWithPath: "/tmp/trano-drag-src-" + UUID().uuidString.prefix(8))
        let runtime = try TerminalRuntime(root: root)
        var initialized = false
        var ownedWindow: NSWindow?
        defer {
            if !initialized {
                ownedWindow?.close()
                for pane in (try? runtime.list()) ?? [] { try? runtime.terminate(pane.id) }
                runtime.shutdownTestHost()
                try? FileManager.default.removeItem(at: root)
            }
        }
        let panes = try (0..<2).map { index in try runtime.create(title: "Pane \(index)", cwd: root.path, shell: "/bin/sleep", arguments: ["60"]).id }
        try runtime.update {
            $0.settings.automaticRestore = false
            let tab = $0.layout.addTab(paneID: panes[0])
            try $0.layout.split(tabID: tab, paneID: panes[1], axis: .horizontal)
            try $0.layout.focusPane(panes[1])
        }
        let store = AppStore(runtime: runtime)
        try await settle { !store.loading }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        ownedWindow = window
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        window.contentView = container
        let drag = PaneDragView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        drag.store = store; drag.paneID = panes[0]; drag.title = "Pane zero"
        container.addSubview(drag)
        let button = NSButton(frame: NSRect(x: 310, y: 0, width: 30, height: 28))
        container.addSubview(button)
        window.orderFrontRegardless()
        initialized = true
        return Fixture(root: root, runtime: runtime, store: store, window: window, container: container, drag: drag, button: button, panes: panes)
    }

    @MainActor private func dispose(_ f: Fixture) {
        f.drag.completeDrag(at: .zero, operation: [], released: false, cancelled: true)
        f.window.close()
        for pane in f.panes { try? f.runtime.terminate(pane) }
        f.runtime.shutdownTestHost()
        try? FileManager.default.removeItem(at: f.root)
    }

    private func backendPIDs(_ f: Fixture) throws -> [String: Int32] {
        Dictionary(uniqueKeysWithValues: try f.runtime.list().map { ($0.id, $0.pid) })
    }

    @MainActor private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    @MainActor private func mouse(_ type: NSEvent.EventType, in view: NSView, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @MainActor private func settle(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native pane drag fixture did not settle")
    }
}
