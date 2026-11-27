import AppKit
import XCTest
import SwiftUI
import TerminalCore
import Combine
@testable import TranoApp

@MainActor final class OutsideClickDismissalTests: XCTestCase {
    func testChromeSidebarFooterAndTerminalOutsideClicksInvokeTheSameCloseAction() throws {
        for point in [NSPoint(x: 20, y: 680), NSPoint(x: 20, y: 350), NSPoint(x: 500, y: 8), NSPoint(x: 400, y: 200)] {
            let f = Fixture(); defer { f.close() }
            var closeCount = 0
            f.registry.register(surface: f.panel, id: "activity", perform: { closeCount += 1 })
            XCTAssertTrue(f.registry.handle(try f.click(point)))
            XCTAssertEqual(closeCount, 1)
        }
    }
    func testClicksInsideTheSurfaceAndItsEditorRemainInteractive() throws {
        let f = Fixture(); defer { f.close() }
        let editor = NSTextField(frame: NSRect(x: 10, y: 10, width: 120, height: 24)); f.panel.addSubview(editor)
        var closed = false
        f.registry.register(surface: f.panel, id: "decisions", perform: { closed = true })
        XCTAssertFalse(f.registry.handle(try f.click(f.panel.convert(NSPoint(x: 20, y: 20), to: nil))))
        XCTAssertFalse(closed)
    }
    func testUnrelatedWindowKeyboardAndRightClickNeverCloseAnOwnerSurface() throws {
        let f = Fixture(), other = Fixture(); defer { f.close(); other.close() }
        var closed = false
        f.registry.register(surface: f.panel, id: "resume", perform: { closed = true })
        XCTAssertFalse(f.registry.handle(try other.click(.zero)))
        XCTAssertFalse(f.registry.handle(try f.click(.zero, type: .rightMouseDown)))
        let key = try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: f.window.windowNumber, context: nil, characters: "a", charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0))
        XCTAssertFalse(f.registry.handle(key)); XCTAssertFalse(closed)
    }
    func testHiddenDetachedRemovedAndReleasedSurfacesCannotDismiss() throws {
        let f = Fixture(); defer { f.close() }
        var count = 0
        f.registry.register(surface: f.panel, id: "queue", perform: { count += 1 })
        f.panel.isHidden = true
        XCTAssertFalse(f.registry.handle(try f.click(.zero)))
        f.panel.isHidden = false; f.panel.removeFromSuperview()
        XCTAssertFalse(f.registry.handle(try f.click(.zero)))
        f.window.contentView!.addSubview(f.panel)
        f.registry.remove(surface: f.panel)
        XCTAssertFalse(f.registry.handle(try f.click(.zero)))
        var released: NSView? = NSView(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        weak var weakSurface = released
        f.registry.register(surface: released!, id: "stale", perform: { count += 1 })
        released = nil
        XCTAssertNil(weakSurface); XCTAssertFalse(f.registry.handle(try f.click(.zero))); XCTAssertEqual(count, 0)
    }
    func testVisualTopmostSurfaceWinsEvenIfTheLowerOneWasRegisteredLast() throws {
        let f = Fixture(); defer { f.close() }
        let top = NSView(frame: NSRect(x: 400, y: 400, width: 200, height: 200))
        f.window.contentView!.addSubview(top)
        var closed: [String] = []
        f.registry.register(surface: top, id: "top", perform: { closed.append("top") })
        f.registry.register(surface: f.panel, id: "lower", perform: { closed.append("lower") })
        XCTAssertTrue(f.registry.handle(try f.click(.zero))); XCTAssertEqual(closed, ["top"])
        closed = []
        XCTAssertFalse(f.registry.handle(try f.click(NSPoint(x: 450, y: 450))))
        XCTAssertTrue(closed.isEmpty)
    }
    func testSavingOrMarkedInputConsumesOutsideClickWithoutCancellingOrFallingThrough() throws {
        let f = Fixture(); defer { f.close() }
        var protected = true, closed = false
        f.registry.register(surface: f.panel, id: "settings", canDismiss: { !protected }, perform: { closed = true })
        XCTAssertTrue(f.registry.handle(try f.click(.zero))); XCTAssertFalse(closed)
        protected = false
        XCTAssertTrue(f.registry.handle(try f.click(.zero))); XCTAssertTrue(closed)
    }
    func testSheetOwnerClickCancelsItsSheetButNestedDialogsProtectParent() throws {
        let f = Fixture(); defer { f.close() }
        let sheet = TestSheetWindow(contentRect: NSRect(x: -12000, y: -12000, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        sheet.isReleasedWhenClosed = false; sheet.simulatedParent = f.window
        sheet.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let surface = NSView(frame: sheet.contentView!.bounds); sheet.contentView!.addSubview(surface)
        defer { sheet.close() }
        var cancelled = false
        f.registry.register(surface: surface, id: "remote-hosts", perform: { cancelled = true })
        XCTAssertTrue(f.registry.handle(try f.click(.zero))); XCTAssertTrue(cancelled)
        cancelled = false
        XCTAssertFalse(f.registry.handle(try f.click(NSPoint(x: 100, y: 100), window: sheet)))
        sheet.simulatedChild = NSWindow()
        XCTAssertFalse(f.registry.handle(try f.click(.zero))); XCTAssertFalse(cancelled)
        sheet.simulatedChild = nil
        let nativeDialog = NSWindow()
        XCTAssertFalse(f.registry.handle(try f.click(.zero), modalWindow: nativeDialog)); XCTAssertFalse(cancelled)
    }
    func testUpdatedCallbackReplacesStaleClosureAndNativeZOrderCanChange() throws {
        let f = Fixture(); defer { f.close() }
        var result = ""
        f.registry.register(surface: f.panel, id: "old", perform: { result = "old" })
        f.registry.register(surface: f.panel, id: "current", perform: { result = "current" })
        XCTAssertTrue(f.registry.handle(try f.click(.zero))); XCTAssertEqual(result, "current")
    }

    func testApplicationEventRouteUsesRegisteredCloseBeforeTerminalRouting() throws {
        let f = Fixture(); defer { OutsideClickDismissalRegistry.shared.remove(surface: f.panel); f.close() }
        var closed = false
        OutsideClickDismissalRegistry.shared.register(surface: f.panel, id: "app-route", perform: { closed = true })
        XCTAssertTrue(ApplicationDelegate().handle(try f.click(.zero)))
        XCTAssertTrue(closed)
    }
    func testSwiftUISurfaceModifierRegistersActualPanelGeometry() throws {
        let f = Fixture(); defer { f.close() }
        var closed = false
        let host = NSHostingView(rootView: Color.gray.frame(width: 220, height: 140)
            .dismissOnOutsideClick("hosted", perform: { closed = true }))
        host.frame = NSRect(x: 400, y: 300, width: 220, height: 140)
        f.window.contentView!.addSubview(host); host.layoutSubtreeIfNeeded()
        XCTAssertFalse(OutsideClickDismissalRegistry.shared.handle(try f.click(NSPoint(x: 450, y: 350))))
        XCTAssertFalse(closed)
        XCTAssertTrue(OutsideClickDismissalRegistry.shared.handle(try f.click(.zero)))
        XCTAssertTrue(closed)
    }
    func testUnisessionOutsideClickUsesHeaderHideWithoutRemovingItsRenderer() throws {
        let f = Fixture(), renderer = NSView(); let presentation = UnisessionPresentation(renderer: renderer)
        defer { presentation.detach(); f.close() }
        var hides = 0
        presentation.onHide = { _ in hides += 1 }
        XCTAssertTrue(presentation.show(in: f.window, topInset: 40))
        XCTAssertTrue(ApplicationDelegate().handle(try f.click(.zero)))
        XCTAssertFalse(presentation.isPresented); XCTAssertEqual(hides, 1)
        XCTAssertTrue(presentation.surface.renderer === renderer); XCTAssertTrue(renderer.window === f.window)
    }

    func testOrganizationSheetOutsideClickPreservesNativeCancelMarkedTextGuard() async throws {
        let f = Fixture(); defer { f.close() }
        var cancelled = 0
        let draft = AccountOrganizationDraft(profileID: "outside-unit", state: nil, knownOrganizations: [],
            refresh: { _, _ in throw TerminalError.invalid("Unused fixture refresh") },
            save: { _, _, _ in }, cancel: { cancelled += 1 })
        let host = NSHostingView(rootView: AccountOrganizationEditorPresentation(draft: draft, close: {}))
        host.frame = NSRect(x: 400, y: 200, width: 480, height: 440)
        f.window.contentView!.addSubview(host); host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
        let editor = MarkedEditor(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
        f.window.contentView!.addSubview(editor); XCTAssertTrue(f.window.makeFirstResponder(editor))
        XCTAssertTrue(OutsideClickDismissalRegistry.shared.handle(try f.click(.zero)))
        XCTAssertFalse(draft.isClosed); XCTAssertEqual(cancelled, 0)
        editor.marked = false
        XCTAssertTrue(OutsideClickDismissalRegistry.shared.handle(try f.click(.zero)))
        XCTAssertTrue(draft.isClosed); XCTAssertEqual(cancelled, 1)
    }
    func testOrganizationTeardownCancelsImmediatelyWithoutPublishingIntoSwiftUIDestruction() async {
        var requests = 0, publications = 0
        let draft = AccountOrganizationDraft(profileID: "teardown-unit", state: nil, knownOrganizations: [],
            refresh: { _, _ in requests += 1; return nil }, save: { _, _, _ in requests += 1 })
        let controls = AccountOrganizationControlsView(draft: draft)
        let subscription = draft.objectWillChange.sink { publications += 1 }
        OrganizationSelectionControls.dismantleNSView(controls, coordinator: ())
        XCTAssertEqual(publications, 0)
        draft.refresh(); draft.save()
        for _ in 0..<8 { await Task.yield() }
        XCTAssertTrue(draft.isClosed); XCTAssertEqual(requests, 0)
        withExtendedLifetime(subscription) {}
    }
    private final class MarkedEditor: NSTextView {
        var marked = true
        override func hasMarkedText() -> Bool { marked }
    }

    private final class TestSheetWindow: NSWindow {
        weak var simulatedParent: NSWindow?
        var simulatedChild: NSWindow?
        override var sheetParent: NSWindow? { simulatedParent }
        override var attachedSheet: NSWindow? { simulatedChild }
    }
    @MainActor private final class Fixture {
        let registry = OutsideClickDismissalRegistry()
        let window: NSWindow
        let panel = NSView(frame: NSRect(x: 600, y: 200, width: 300, height: 420))
        init() {
            _ = NSApplication.shared
            window = NSWindow(contentRect: NSRect(x: -12000, y: -12000, width: 960, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.animationBehavior = .none
            window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 960, height: 700))
            window.contentView!.addSubview(panel)
        }
        func click(_ point: NSPoint, type: NSEvent.EventType = .leftMouseDown, window target: NSWindow? = nil) throws -> NSEvent {
            try XCTUnwrap(NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: (target ?? window).windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        func close() { window.close() }
    }
}
