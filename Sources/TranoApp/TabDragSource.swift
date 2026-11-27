import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct TabDragRegion: NSViewRepresentable {
    @ObservedObject var store: AppStore
    let tabID: String
    let title: String

    func makeNSView(context: Context) -> TabDragView {
        let view = TabDragView()
        update(view)
        return view
    }

    func updateNSView(_ view: TabDragView, context: Context) { update(view) }

    private func update(_ view: TabDragView) {
        view.store = store
        view.tabID = tabID
        view.title = title
        view.identifier = NSUserInterfaceItemIdentifier("tab-drag-" + tabID)
    }
}

@MainActor final class TabDragView: NSView, NSDraggingSource {
    weak var store: AppStore?
    var tabID = ""
    var title = ""
    var beginSession: (([NSDraggingItem], NSEvent, NSDraggingSource) -> Bool)?
    var finish: ((Data, NSWindow, NSPoint, NSDragOperation, Bool, Bool) -> Bool)?

    private struct Press {
        weak var store: AppStore?
        weak var window: NSWindow?
        let workspaceID: String
        let tabID: String
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
    // Tab hover and transfer redraws can unmount the source before AppKit finishes.
    private var sessionOwner: TabDragView?
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
              let store, let window, allowsClick(store, window: window), let workspaceID = store.preferredWorkspaceID,
              store.state.layout.currentTabs.contains(where: { $0.id == tabID && $0.workspaceID == workspaceID }) else { return }
        press = Press(store: store, window: window, workspaceID: workspaceID, tabID: tabID, title: title, point: event.locationInWindow)
    }

    override func mouseDragged(with event: NSEvent) {
        guard active == nil, let press, event.type == .leftMouseDragged,
              hypot(event.locationInWindow.x - press.point.x, event.locationInWindow.y - press.point.y) >= 4,
              let source = press.store, let origin = press.window, window === origin,
              matches(press, source: source, window: origin), allowsDrag(source, window: origin),
              let data = WorkspaceDrag.shared.tabPayload(tabID: press.tabID, store: source) else { return }
        let item = NSPasteboardItem()
        item.setData(data, forType: NSPasteboard.PasteboardType(UTType.tranoTab.identifier))
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let image = dragImage(title: press.title, store: source, tabID: press.tabID)
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
        guard let press, let source = press.store, let origin = press.window, window === origin,
              matches(press, source: source, window: origin) else { return }
        source.showActivity = false
        source.zoomed = false
        source.commandKeyHints.cancel()
        if let tab = source.state.layout.currentTabs.first(where: { $0.id == press.tabID }),
           let pane = tab.focusedPaneID ?? tab.panes.first { source.acknowledgeActivity(pane) }
        source.perform(restoringContext: false, publishingSelectionBeforeObservation: true, restoringFocus: true, validateBeforeWork: { [weak source, weak origin] in
            guard let source, let origin else { return false }
            return self.matches(press, source: source, window: origin)
        }) { runtime in
            try runtime.update { state in
                guard state.layout.workspaces.contains(where: { $0.id == press.workspaceID && !$0.closed }),
                      state.layout.tabs.contains(where: { $0.id == press.tabID && $0.workspaceID == press.workspaceID }) else { return }
                try state.layout.selectTab(press.tabID)
            }
        }
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
        draggingEnded(at: screenPoint, operation: operation, currentEvent: NSApp.currentEvent, pressedMouseButtons: NSEvent.pressedMouseButtons)
    }

    func draggingEnded(at screenPoint: NSPoint, operation: NSDragOperation, currentEvent: NSEvent?, pressedMouseButtons: Int) {
        let escaped = currentEvent.map { [.keyDown, .keyUp].contains($0.type) && $0.keyCode == 53 } ?? false
        let released = active?.released == true || currentEvent?.type == .leftMouseUp || (pressedMouseButtons & 1) == 0
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
        else { _ = WorkspaceDrag.shared.finishTabDrag(active.data, from: origin, at: point, operation: operation, cancelled: wasCancelled, released: wasReleased) }
    }

    private func matches(_ press: Press, source: AppStore, window: NSWindow) -> Bool {
        allowsClick(source, window: window) && source.preferredWorkspaceID == press.workspaceID &&
        source.state.layout.workspaces.contains(where: { $0.id == press.workspaceID && !$0.closed }) &&
        source.state.layout.currentTabs.contains(where: { $0.id == press.tabID && $0.workspaceID == press.workspaceID })
    }

    private func allowsClick(_ store: AppStore, window: NSWindow) -> Bool {
        !store.loading && window.isVisible && window.attachedSheet == nil && NSApp.modalWindow == nil
    }

    private func allowsDrag(_ store: AppStore, window: NSWindow) -> Bool {
        allowsClick(store, window: window) && store.canDragWorkspace &&
        (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }

    private func dragImage(title: String, store: AppStore, tabID: String) -> NSImage {
        let tab = store.state.layout.currentTabs.first { $0.id == tabID }
        let paneID = tab?.focusedPaneID ?? tab?.panes.first ?? ""
        let appearance = store.state.settings.resolvedAppearance(for: paneID)
        return NSImage(size: NSSize(width: 220, height: 28), flipped: false) { rect in
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
