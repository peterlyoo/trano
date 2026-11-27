import AppKit
import SwiftUI

struct WindowDragRegion: NSViewRepresentable {
    var contextMenu: ((NSWindow?) -> NSMenu)? = nil
    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.identifier = NSUserInterfaceItemIdentifier(rawValue: "window-drag-region")
        view.contextMenu = contextMenu
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) { (nsView as? DragView)?.contextMenu = contextMenu }

    private final class DragView: NSView {
        var contextMenu: ((NSWindow?) -> NSMenu)?
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func menu(for event: NSEvent) -> NSMenu? {
            guard HeaderContextInteraction.accepts(event), window?.attachedSheet == nil else { return nil }
            return contextMenu?(window)
        }
        override func rightMouseDown(with event: NSEvent) { if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) } }
        override func mouseDown(with event: NSEvent) {
            if HeaderContextInteraction.accepts(event) {
                if let menu = menu(for: event) { NSMenu.popUpContextMenu(menu, with: event, for: self) }
            } else if event.clickCount == 2 {
                window?.performZoom(nil)
            } else { window?.performDrag(with: event) }
        }
    }
}
