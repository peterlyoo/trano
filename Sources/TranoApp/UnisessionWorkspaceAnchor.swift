import AppKit
import SwiftUI

struct UnisessionWorkspaceAnchor: NSViewRepresentable {
    let register: (NSView) -> Void
    func makeNSView(context: Context) -> Anchor {
        let view = Anchor(); view.register = register; return view
    }
    func updateNSView(_ view: Anchor, context: Context) { view.register = register; view.report() }
    final class Anchor: NSView {
        var register: (NSView) -> Void = { _ in }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); report() }
        override func layout() { super.layout(); report() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        func report() {
            guard window != nil else { return }
            DispatchQueue.main.async { [weak self] in if let self, self.window != nil { self.register(self) } }
        }
    }
}
