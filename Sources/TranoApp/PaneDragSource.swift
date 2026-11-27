import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PaneDragRegion: NSViewRepresentable {
    @ObservedObject var store: AppStore
    let paneID: String
    let title: String
    var regionID: String? = nil

    func makeNSView(context: Context) -> PaneDragView {
        let view = PaneDragView()
        update(view)
        return view
    }

    func updateNSView(_ view: PaneDragView, context: Context) { update(view) }

    private func update(_ view: PaneDragView) {
        view.store = store
        view.paneID = paneID
        view.title = title
        view.identifier = NSUserInterfaceItemIdentifier(regionID ?? "pane-drag-" + paneID)
    }
}

@MainActor final class PaneDragView: NSView, NSDraggingSource {
    weak var store: AppStore?
    var paneID = ""
    var title = ""
    var beginSession: (([NSDraggingItem], NSEvent, NSDraggingSource) -> Bool)?
    var finish: ((Data, NSWindow, NSPoint, NSDragOperation, Bool, Bool) -> Bool)?

    private struct Press {
        weak var store: AppStore?
        weak var window: NSWindow?
        let paneID: String
        let title: String
        let point: NSPoint
    }

    private struct ActiveDrag {
        let data: Data
        weak var window: NSWindow?
        var cancelled = false
        var released = false
    }

    private var press: Press?
    private var active: ActiveDrag?
    // Tab hovering can unmount the header before AppKit ends its drag.
    private var sessionOwner: PaneDragView?
    private var eventMonitor: Any?

    deinit {
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor) }
    }

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { pointerHitTest(point, event: NSApp.currentEvent) }

    func pointerHitTest(_ point: NSPoint, event: NSEvent?) -> NSView? {
        HeaderContextInteraction.accepts(event) ? nil : super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        press = nil
        guard active == nil, event.type == .leftMouseDown, !HeaderContextInteraction.accepts(event),
              let store, let window, allowsInput(store, window: window) else { return }
        press = Press(store: store, window: window, paneID: paneID, title: title, point: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard active == nil, let press, event.type == .leftMouseDragged,
              hypot(event.locationInWindow.x - press.point.x, event.locationInWindow.y - press.point.y) >= 4,
              let source = press.store, let origin = press.window,
              allowsInput(source, window: origin), let data = WorkspaceDrag.shared.panePayload(paneID: press.paneID, store: source) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.tranoPane.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = dragImage(title: press.title, store: source, paneID: press.paneID)
        let location = convert(event.locationInWindow, from: nil)
        dragging.setDraggingFrame(NSRect(x: location.x - 16, y: location.y - image.size.height / 2, width: image.size.width, height: image.size.height), contents: image)
        active = ActiveDrag(data: data, window: origin)
        sessionOwner = self
        self.press = nil
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseUp]) { [weak self] event in
            self?.observeDragEvent(event)
            return event
        }
        let started: Bool
        if let beginSession { started = beginSession([dragging], event, self) }
        else {
            let session = beginDraggingSession(with: [dragging], event: event, source: self)
            session.animatesToStartingPositionsOnCancelOrFail = false
            started = true
        }
        if !started { completeDrag(at: origin.convertPoint(toScreen: event.locationInWindow), operation: [], released: false, cancelled: true) }
    }

    override func mouseUp(with event: NSEvent) {
        guard event.type == .leftMouseUp else { return }
        if active != nil { observeDragEvent(event); return }
        defer { press = nil }
        guard let press, let source = press.store, let origin = press.window,
              allowsInput(source, window: origin) else { return }
        source.focus(press.paneID, in: origin)
    }

    func observeDragEvent(_ event: NSEvent) {
        guard active != nil else { return }
        if event.type == .keyDown && event.keyCode == 53 { active?.cancelled = true }
        if event.type == .leftMouseUp { active?.released = true }
    }

    func operationMask(for context: NSDraggingContext) -> NSDragOperation { context == .withinApplication ? .move : [] }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { operationMask(for: context) }
    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let current = NSApp.currentEvent
        let escaped = current.map { [.keyDown, .keyUp].contains($0.type) && $0.keyCode == 53 } ?? false
        let released = active?.released == true || current?.type == .leftMouseUp || (NSEvent.pressedMouseButtons & 1) == 0
        completeDrag(at: screenPoint, operation: operation, released: released, cancelled: escaped)
    }

    func completeDrag(at point: NSPoint, operation: NSDragOperation, released: Bool, cancelled: Bool) {
        guard let active else { sessionOwner = nil; return }
        defer { sessionOwner = nil }
        self.active = nil
        press = nil
        if let eventMonitor { NSEvent.removeMonitor(eventMonitor); self.eventMonitor = nil }
        guard let origin = active.window else { return }
        let wasCancelled = cancelled || active.cancelled
        let wasReleased = released || active.released
        if let finish { _ = finish(active.data, origin, point, operation, wasCancelled, wasReleased) }
        else { _ = WorkspaceDrag.shared.finishPaneDrag(active.data, from: origin, at: point, operation: operation, cancelled: wasCancelled, released: wasReleased) }
    }

    private func allowsInput(_ store: AppStore, window: NSWindow) -> Bool {
        !store.loading && window.isVisible && window.attachedSheet == nil && NSApp.modalWindow == nil &&
        (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }

    private func dragImage(title: String, store: AppStore, paneID: String) -> NSImage {
        let size = NSSize(width: 220, height: 28)
        let appearance = store.state.settings.resolvedAppearance(for: paneID)
        return NSImage(size: size, flipped: false) { rect in
            NSColor(hex: appearance.background).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byTruncatingTail
            (title as NSString).draw(in: NSRect(x: 10, y: 6, width: rect.width - 20, height: 16), withAttributes: [
                .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor(hex: appearance.appearance.foreground), .paragraphStyle: paragraph
            ])
            return true
        }
    }
}
