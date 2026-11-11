import AppKit
import SwiftUI

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.identifier = NSUserInterfaceItemIdentifier(rawValue: "window-drag-region")
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class DragView: NSView {
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
