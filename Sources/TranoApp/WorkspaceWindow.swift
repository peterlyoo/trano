import AppKit
import TerminalCore

@MainActor enum WorkspaceWindow {
    nonisolated static let headerHeight: CGFloat = 40

    static func applyInterface(_ plan: InterfacePresentation, to window: NSWindow) {
        guard let window = window as? HeaderAlignedWindow else { return }
        window.interfaceToolbarLayout = plan.toolbarLayout
        window.interfaceSidebarWidth = plan.sidebarWidth
        window.alignControls()
    }

    static func make(contentRect: NSRect, contentView: NSView) -> NSWindow {
        let window = HeaderAlignedWindow(contentRect: contentRect, styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "Trano"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = false
        window.backgroundColor = .clear
        window.isOpaque = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.contentView = contentView
        window.minSize = NSSize(width: 900, height: 620)
        window.alignControls()
        return window
    }
}

@MainActor private final class HeaderAlignedWindow: NSWindow {
    var interfaceToolbarLayout = InterfaceToolbarLayout.above
    var interfaceSidebarWidth: CGFloat = 216
    override func update() {
        super.update()
        alignControls()
    }

    override func setFrame(_ frameRect: NSRect, display flag: Bool) {
        super.setFrame(frameRect, display: flag)
        alignControls()
    }

    func alignControls() {
        guard !styleMask.contains(.fullScreen), let content = contentView, let frame = content.superview else { return }
        let contentRect = content.convert(content.bounds, to: frame)
        let centerY = frame.isFlipped ? contentRect.minY + WorkspaceWindow.headerHeight / 2 : contentRect.maxY - WorkspaceWindow.headerHeight / 2
        for (index, kind) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = standardWindowButton(kind), button.window === self, let parent = button.superview else { continue }
            let leading = interfaceToolbarLayout == .right ? max(0, contentRect.width - interfaceSidebarWidth) : 0
            let rect = NSRect(x: contentRect.minX + leading + 9 + CGFloat(index) * 23, y: centerY - 7, width: 14, height: 14)
            let target = parent.convert(rect, from: frame)
            if button.frame != target { button.frame = target }
        }
    }
}
