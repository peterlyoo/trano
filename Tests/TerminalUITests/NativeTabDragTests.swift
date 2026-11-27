import AppKit
import SwiftUI
import UniformTypeIdentifiers
import XCTest
@testable import TerminalCore
@testable import TranoApp

final class NativeTabDragTests: XCTestCase {
    // Implements: FR-NAV-12
    @MainActor func testWorkspaceTabLabelOwnsNativeDragWithoutCoveringItsCloseControl() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let hosting = NSHostingView(rootView: WorkspaceView(store: f.store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), contentView: hosting)
        defer { window.close() }
        window.orderFrontRegardless()
        try await settle {
            hosting.layoutSubtreeIfNeeded()
            return self.descendants(in: hosting).contains { $0.identifier?.rawValue == "tab-drag-" + f.tabs[0] }
        }
        for redraw in 0..<2 {
            if redraw == 1 { f.store.showSessionsSidebar.toggle(); hosting.layoutSubtreeIfNeeded() }
            let drag = try XCTUnwrap(descendants(in: hosting).compactMap { $0 as? TabDragView }.first { $0.identifier?.rawValue == "tab-drag-" + f.tabs[0] })
            let frame = try XCTUnwrap(window.contentView?.superview)
            let midpoint = NSPoint(x: drag.bounds.midX, y: drag.bounds.midY)
            XCTAssertGreaterThan(drag.bounds.width, 20)
            XCTAssertTrue(frame.hitTest(drag.convert(midpoint, to: frame)) === drag)
            let close = try XCTUnwrap(descendants(in: hosting).first { $0.identifier?.rawValue == "tab-close-" + f.tabs[0] })
            let closeMidpoint = NSPoint(x: close.bounds.midX, y: close.bounds.midY)
            XCTAssertFalse(drag.bounds.contains(close.convert(closeMidpoint, to: drag)))
            XCTAssertFalse(frame.hitTest(close.convert(closeMidpoint, to: frame)) === drag)
            let context = try XCTUnwrap(descendants(in: hosting).first { $0.identifier?.rawValue == "tab-context-menu-" + f.tabs[0] } as? HeaderContextMenuView)
            XCTAssertNotNil(context.menu(for: try mouse(.rightMouseDown, in: context, at: .zero)))
        }
    }

    // Implements: FR-NAV-12
    @MainActor func testSubthresholdClickSelectsPressedTabDespiteRepresentableUpdateWithoutChangingJobs() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try backendPIDs(f)
        var starts = 0
        f.drag.beginSession = { _, _, _ in starts += 1; return true }
        f.store.showActivity = true
        f.store.followUpPaneID = f.panes[1]
        f.drag.mouseDown(with: try mouse(.leftMouseDown, in: f.drag, at: NSPoint(x: 10, y: 10)))
        f.drag.tabID = f.tabs[1]
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 13, y: 10)))
        f.drag.mouseUp(with: try mouse(.leftMouseUp, in: f.drag, at: NSPoint(x: 13, y: 10)))
        try await settle { !f.store.loading && f.store.selectedTab?.id == f.tabs[0] }
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(f.store.showActivity)
        XCTAssertEqual(f.store.followUpPaneID, f.panes[1])
        XCTAssertEqual(try backendPIDs(f), before)
        XCTAssertEqual(try f.runtime.state().layout.currentTabs.map(\.id), f.tabs)
    }

    // Implements: FR-NAV-12, FR-INPUT-1
    @MainActor func testMarkedTextAllowsTabClickThroughSelectionPipelineButBlocksDragging() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let hosting = NSHostingView(rootView: WorkspaceView(store: f.store))
        let window = WorkspaceWindow.make(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 700), contentView: hosting)
        defer { window.close() }
        window.orderFrontRegardless()
        try await settle {
            hosting.layoutSubtreeIfNeeded()
            return f.store.terminalViews[f.panes[1]]?.window === window &&
                self.descendants(in: hosting).contains { $0.identifier?.rawValue == "tab-drag-" + f.tabs[0] }
        }
        let drag = try XCTUnwrap(descendants(in: hosting).compactMap { $0 as? TabDragView }.first { $0.identifier?.rawValue == "tab-drag-" + f.tabs[0] })
        defer { drag.completeDrag(at: .zero, operation: [], released: false, cancelled: true) }
        let editor = NSTextView(frame: NSRect(x: 20, y: 20, width: 200, height: 40))
        hosting.addSubview(editor)
        defer { editor.unmarkText(); editor.removeFromSuperview() }
        XCTAssertTrue(window.makeFirstResponder(editor))
        editor.setMarkedText("한", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        let marked = editor.markedRange(), text = editor.string
        XCTAssertTrue(editor.hasMarkedText())
        let before = try backendPIDs(f)
        var starts = 0
        drag.beginSession = { _, _, _ in starts += 1; return true }
        let point = NSPoint(x: drag.bounds.midX, y: drag.bounds.midY)
        drag.mouseDown(with: try mouse(.leftMouseDown, in: drag, at: point))
        drag.mouseUp(with: try mouse(.leftMouseUp, in: drag, at: point))
        await withCheckedContinuation { continuation in
            f.store.queue.async { DispatchQueue.main.async { continuation.resume() } }
        }
        XCTAssertEqual(try f.runtime.state().layout.selectedTabID, f.tabs[0], "Label click must reach the same canonical selection pipeline as tab padding")
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[1], "Composition keeps the presenting tab until input permits navigation")
        drag.mouseDown(with: try mouse(.leftMouseDown, in: drag, at: point))
        drag.mouseDragged(with: try mouse(.leftMouseDragged, in: drag, at: NSPoint(x: point.x + 20, y: point.y)))
        XCTAssertEqual(starts, 0)
        XCTAssertTrue(window.firstResponder === editor)
        XCTAssertTrue(editor.hasMarkedText())
        XCTAssertEqual(editor.markedRange(), marked)
        XCTAssertEqual(editor.string, text)
        XCTAssertEqual(try backendPIDs(f), before)
    }

    // Implements: FR-NAV-12
    @MainActor func testFourPointDragCarriesOnlyPrivateTokenForPressedTabAndStartsOnce() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let before = try backendPIDs(f)
        var items: [NSDraggingItem] = []
        var starts = 0
        f.drag.beginSession = { captured, _, _ in items = captured; starts += 1; return true }
        f.drag.mouseDown(with: try mouse(.leftMouseDown, in: f.drag, at: NSPoint(x: 10, y: 10)))
        f.drag.tabID = f.tabs[1]
        f.drag.title = "Redrawn tab"
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 13.9, y: 10)))
        XCTAssertEqual(starts, 0)
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 14, y: 10)))
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(items.count, 1)
        let item = try XCTUnwrap(items.first?.item as? NSPasteboardItem)
        XCTAssertEqual(item.types, [NSPasteboard.PasteboardType(UTType.tranoTab.identifier)])
        let data = try XCTUnwrap(item.data(forType: NSPasteboard.PasteboardType(UTType.tranoTab.identifier)))
        XCTAssertEqual(data.count, 36)
        XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(String(data: data, encoding: .utf8))))
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[1])
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 40, y: 10)))
        XCTAssertEqual(starts, 1)
        XCTAssertTrue(WorkspaceDrag.shared.receive(data, in: f.store, tabID: nil))
        f.drag.completeDrag(at: f.window.frame.origin, operation: .move, released: true, cancelled: false)
        try await settle { !f.store.loading && f.store.state.layout.currentTabs.map(\.id) == Array(f.tabs.reversed()) }
        XCTAssertEqual(try f.runtime.state().layout.currentTabs.map(\.id), Array(f.tabs.reversed()))
        XCTAssertEqual(try backendPIDs(f), before)
    }

    // Implements: FR-NAV-12
    @MainActor func testContextClicksPassThroughAndCannotSelectOrStartDrag() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        let point = NSPoint(x: 10, y: 10)
        XCTAssertTrue(f.drag.pointerHitTest(point, event: try mouse(.leftMouseDown, in: f.drag, at: point)) === f.drag)
        XCTAssertFalse(f.drag.mouseDownCanMoveWindow)
        XCTAssertNil(f.drag.pointerHitTest(NSPoint(x: 301, y: 10), event: nil))
        var starts = 0
        f.drag.beginSession = { _, _, _ in starts += 1; return true }
        for (type, modifiers) in [(NSEvent.EventType.rightMouseDown, NSEvent.ModifierFlags()), (.leftMouseDown, .control)] {
            let event = try mouse(type, in: f.drag, at: point, modifiers: modifiers)
            XCTAssertNil(f.drag.pointerHitTest(point, event: event))
            f.drag.mouseDown(with: event)
            f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 50, y: 10)))
            f.drag.mouseUp(with: try mouse(.leftMouseUp, in: f.drag, at: point))
        }
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(f.store.selectedTab?.id, f.tabs[1])
    }

    // Implements: FR-NAV-12
    @MainActor func testPressCannotNavigateBackToAnOldWorkspaceAfterSelectionChanges() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        var other = ""
        try f.runtime.update { other = $0.layout.addWorkspace(title: "Other") }
        var starts = 0
        f.drag.beginSession = { _, _, _ in starts += 1; return true }
        f.drag.mouseDown(with: try mouse(.leftMouseDown, in: f.drag, at: NSPoint(x: 10, y: 10)))
        f.store.selectWorkspace(other)
        try await settle { !f.store.loading && f.store.preferredWorkspaceID == other }
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 60, y: 10)))
        f.drag.mouseUp(with: try mouse(.leftMouseUp, in: f.drag, at: NSPoint(x: 60, y: 10)))
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(starts, 0)
        XCTAssertEqual(f.store.preferredWorkspaceID, other)
        XCTAssertEqual(try f.runtime.state().layout.selectedWorkspaceID, other)
    }

    // Implements: FR-NAV-12
    @MainActor func testCompletionRetainsOriginAndTracksEscapeReleaseExactlyOnce() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        var payload: Data?
        f.drag.beginSession = { items, _, _ in
            payload = (items.first?.item as? NSPasteboardItem)?.data(forType: NSPasteboard.PasteboardType(UTType.tranoTab.identifier))
            return true
        }
        var completed: [(Data, NSWindow, NSPoint, NSDragOperation, Bool, Bool)] = []
        f.drag.finish = { data, origin, point, operation, cancelled, released in
            completed.append((data, origin, point, operation, cancelled, released)); return false
        }
        f.drag.mouseDown(with: try mouse(.leftMouseDown, in: f.drag, at: NSPoint(x: 10, y: 10)))
        f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 60, y: 10)))
        let escape = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        f.drag.observeDragEvent(escape)
        f.drag.observeDragEvent(try mouse(.leftMouseUp, in: f.drag, at: NSPoint(x: 60, y: 10)))
        f.drag.store = nil
        f.drag.tabID = f.tabs[1]
        f.drag.removeFromSuperview()
        let outside = NSPoint(x: f.window.frame.maxX + 100, y: f.window.frame.midY)
        f.drag.completeDrag(at: outside, operation: [], released: false, cancelled: false)
        f.drag.completeDrag(at: outside, operation: [], released: true, cancelled: false)
        XCTAssertEqual(completed.count, 1)
        XCTAssertEqual(completed.first?.0, payload)
        XCTAssertTrue(completed.first?.1 === f.window)
        XCTAssertEqual(completed.first?.2, outside)
        XCTAssertEqual(completed.first?.3, [])
        XCTAssertEqual(completed.first?.4, true)
        XCTAssertEqual(completed.first?.5, true)
    }

    // Implements: FR-NAV-12
    @MainActor func testEndHandlerResolvesHeldReleasedAndEscapeWithoutMonitorEvents() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        f.drag.beginSession = { _, _, _ in true }
        var completed: [(NSDragOperation, Bool, Bool)] = []
        f.drag.finish = { _, _, _, operation, cancelled, released in
            completed.append((operation, cancelled, released)); return false
        }
        let escapeDown = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        let escapeUp = try XCTUnwrap(NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
        let release = try mouse(.leftMouseUp, in: f.drag, at: NSPoint(x: 50, y: 10))
        let cases: [(event: NSEvent?, buttons: Int, operation: NSDragOperation, cancelled: Bool, released: Bool)] = [
            (nil, 1, [], false, false),
            (nil, 0, [], false, true),
            (release, 1, [], false, true),
            (escapeDown, 1, [], true, false),
            (escapeUp, 0, [], true, true),
            (nil, 0, .move, false, true)
        ]
        for (index, sample) in cases.enumerated() {
            f.drag.mouseDown(with: try mouse(.leftMouseDown, in: f.drag, at: NSPoint(x: 10, y: 10)))
            f.drag.mouseDragged(with: try mouse(.leftMouseDragged, in: f.drag, at: NSPoint(x: 50, y: 10)))
            f.drag.draggingEnded(at: .zero, operation: sample.operation, currentEvent: sample.event, pressedMouseButtons: sample.buttons)
            XCTAssertEqual(completed.count, index + 1)
            let end = try XCTUnwrap(completed.last)
            XCTAssertEqual(end.0, sample.operation, "Case \(index)")
            XCTAssertEqual(end.1, sample.cancelled, "Case \(index)")
            XCTAssertEqual(end.2, sample.released, "Case \(index)")
        }
    }

    // Implements: FR-NAV-12
    @MainActor func testPrivateTabPayloadOffersMoveOnlyWithinApplication() {
        let drag = TabDragView()
        XCTAssertEqual(drag.operationMask(for: .withinApplication), .move)
        XCTAssertEqual(drag.operationMask(for: .outsideApplication), [])
    }

    // Implements: FR-NAV-12
    @MainActor func testActiveDragSurvivesUnmountAndFailedStartDoesNotLeakSource() async throws {
        let f = try await fixture()
        defer { dispose(f) }
        weak var retained: TabDragView?
        try autoreleasepool {
            let drag = TabDragView(frame: NSRect(x: 0, y: 35, width: 300, height: 28))
            drag.store = f.store; drag.tabID = f.tabs[0]; drag.title = "Transient tab"
            drag.beginSession = { _, _, _ in true }
            f.container.addSubview(drag)
            retained = drag
            drag.mouseDown(with: try mouse(.leftMouseDown, in: drag, at: NSPoint(x: 10, y: 10)))
            drag.mouseDragged(with: try mouse(.leftMouseDragged, in: drag, at: NSPoint(x: 40, y: 10)))
            drag.removeFromSuperview()
        }
        XCTAssertNotNil(retained)
        autoreleasepool { retained?.completeDrag(at: .zero, operation: [], released: false, cancelled: true) }
        XCTAssertNil(retained)
        weak var failed: TabDragView?
        var failure: (Bool, Bool)?
        try autoreleasepool {
            let drag = TabDragView(frame: NSRect(x: 0, y: 35, width: 300, height: 28))
            drag.store = f.store; drag.tabID = f.tabs[0]; drag.title = "Failed tab"
            drag.beginSession = { _, _, _ in false }
            drag.finish = { _, _, _, _, cancelled, released in failure = (cancelled, released); return false }
            f.container.addSubview(drag)
            failed = drag
            drag.mouseDown(with: try mouse(.leftMouseDown, in: drag, at: NSPoint(x: 10, y: 10)))
            drag.mouseDragged(with: try mouse(.leftMouseDragged, in: drag, at: NSPoint(x: 40, y: 10)))
            drag.removeFromSuperview()
        }
        XCTAssertNil(failed)
        XCTAssertEqual(failure?.0, true)
        XCTAssertEqual(failure?.1, false)
    }

    private struct Fixture {
        let root: URL
        let runtime: TerminalRuntime
        let store: AppStore
        let window: NSWindow
        let container: NSView
        let drag: TabDragView
        let tabs: [String]
        let panes: [String]
    }

    @MainActor private func fixture() async throws -> Fixture {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("trano-tab-source-" + UUID().uuidString.prefix(8))
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
        let panes = try (0..<2).map { try runtime.create(title: "Tab \($0)", cwd: root.path, shell: "/bin/sleep", arguments: ["60"]).id }
        var tabs: [String] = []
        try runtime.update { state in
            state.settings.automaticRestore = false
            tabs = panes.map { state.layout.addTab(paneID: $0) }
        }
        let store = AppStore(runtime: runtime, recoverOnStartup: false)
        try await settle { !store.loading }
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 100), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        ownedWindow = window
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 100))
        window.contentView = container
        let drag = TabDragView(frame: NSRect(x: 0, y: 0, width: 300, height: 28))
        drag.store = store; drag.tabID = tabs[0]; drag.title = "Tab zero"
        container.addSubview(drag)
        window.orderFrontRegardless()
        initialized = true
        return Fixture(root: root, runtime: runtime, store: store, window: window, container: container, drag: drag, tabs: tabs, panes: panes)
    }

    @MainActor private func dispose(_ f: Fixture) {
        f.drag.completeDrag(at: .zero, operation: [], released: false, cancelled: true)
        for terminal in f.store.terminalViews.values { terminal.terminate() }
        f.store.terminalViews.removeAll()
        f.window.close()
        for pane in f.panes { try? f.runtime.terminate(pane) }
        try? FileManager.default.removeItem(at: f.root)
    }

    private func backendPIDs(_ f: Fixture) throws -> [String: Int32] {
        Dictionary(uniqueKeysWithValues: try f.runtime.list().map { ($0.id, $0.pid) })
    }

    @MainActor private func descendants(in view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants(in: $0) } }

    @MainActor private func mouse(_ type: NSEvent.EventType, in view: NSView, at point: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        let window = try XCTUnwrap(view.window)
        return try XCTUnwrap(NSEvent.mouseEvent(with: type, location: view.convert(point, to: nil), modifierFlags: modifiers, timestamp: 0, windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }

    @MainActor private func settle(until condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(4)
        while Date() < deadline {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Native tab drag fixture did not settle")
    }
}
