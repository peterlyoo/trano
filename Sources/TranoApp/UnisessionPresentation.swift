import AppKit

@MainActor final class UnisessionSurfaceView: NSView {
    let header = NSView()
    let title = NSTextField(labelWithString: "Unisession")
    private(set) var renderer: NSView
    private let hideButton = NSButton()
    private let expandButton = NSButton()
    private let resizeHandle = UnisessionResizeHandle()
    private let headerSeparator = NSView()
    var onHide: () -> Void = {}
    var onExpand: () -> Void = {}
    var onResize: (NSSize) -> Void = { _ in }
    private let headerHeight = ToolPanelMetrics.headerHeight

    init(renderer: NSView) {
        self.renderer = renderer
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("unisession-surface")
        wantsLayer = true; layer?.cornerRadius = ToolPanelMetrics.cornerRadius; layer?.masksToBounds = true; layer?.borderWidth = 1
        header.wantsLayer = true; headerSeparator.wantsLayer = true
        header.identifier = NSUserInterfaceItemIdentifier("tool-panel-header")
        title.font = .systemFont(ofSize: ToolPanelMetrics.titleSize, weight: .semibold)
        for (button, symbol, tooltip) in [(hideButton, "xmark", "Hide Unisession"), (expandButton, "arrow.up.left.and.arrow.down.right", "Expand Unisession")] {
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
            button.isBordered = false; button.toolTip = tooltip; button.setAccessibilityLabel(tooltip)
            button.target = self
            header.addSubview(button)
        }
        hideButton.image = hideButton.image?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        hideButton.action = #selector(hideTerminal); expandButton.action = #selector(expandTerminal)
        header.addSubview(title); header.addSubview(headerSeparator)
        addSubview(renderer); addSubview(header); addSubview(resizeHandle)
        resizeHandle.onResize = { [weak self] size in self?.onResize(size) }
        apply(theme: .defaultDark)
    }
    required init?(coder: NSCoder) { nil }
    func setRenderer(_ view: NSView) {
        guard renderer !== view else { return }
        renderer.removeFromSuperview(); renderer = view; addSubview(view, positioned: .below, relativeTo: header); needsLayout = true
    }
    func apply(theme: ToolPanelTheme) {
        header.appearance = theme.appearance; resizeHandle.appearance = theme.appearance
        apply(background: theme.backgroundNS, foreground: theme.foregroundNS)
        layer?.borderColor = theme.borderNS.cgColor; headerSeparator.layer?.backgroundColor = theme.borderNS.cgColor
        title.textColor = theme.foregroundNS; expandButton.contentTintColor = theme.secondaryNS
        resizeHandle.color = theme.secondaryNS
    }
    func apply(background: NSColor, foreground: NSColor) {
        layer?.backgroundColor = NSColor.clear.cgColor; header.layer?.backgroundColor = background.cgColor
        layer?.borderColor = foreground.withAlphaComponent(0.12).cgColor
        headerSeparator.layer?.backgroundColor = foreground.withAlphaComponent(0.12).cgColor
        title.textColor = foreground
        hideButton.contentTintColor = foreground; expandButton.contentTintColor = foreground
        resizeHandle.color = foreground.withAlphaComponent(0.65)
    }
    func setExpanded(_ expanded: Bool) {
        let text = expanded ? "Restore Unisession" : "Expand Unisession"
        expandButton.image = NSImage(systemSymbolName: expanded ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right", accessibilityDescription: text)
        expandButton.toolTip = text; expandButton.setAccessibilityLabel(text)
        resizeHandle.isHidden = expanded
    }
    override func layout() {
        super.layout()
        header.frame = NSRect(x: 0, y: max(0, bounds.height - headerHeight), width: bounds.width, height: min(headerHeight, bounds.height))
        let inset = ToolPanelMetrics.contentInset, control = ToolPanelMetrics.closeControlSize
        title.frame = NSRect(x: inset, y: (headerHeight - 20) / 2, width: max(0, bounds.width - inset * 2 - control * 2 - 12), height: 20)
        hideButton.frame = NSRect(x: max(0, bounds.width - inset - control), y: (headerHeight - control) / 2, width: control, height: control)
        expandButton.frame = NSRect(x: max(0, hideButton.frame.minX - control - 4), y: (headerHeight - control) / 2, width: control, height: control)
        headerSeparator.frame = NSRect(x: 0, y: 0, width: bounds.width, height: 1)
        renderer.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(0, bounds.height - headerHeight))
        resizeHandle.frame = NSRect(x: 0, y: 0, width: 12, height: 12)
    }
    @objc private func hideTerminal() { onHide() }
    @objc private func expandTerminal() { onExpand() }
}

@MainActor private final class UnisessionResizeHandle: NSView {
    var onResize: (NSSize) -> Void = { _ in }
    var color = ToolPanelTheme.defaultDark.secondaryNS { didSet { needsDisplay = true } }
    private var initialPoint = NSPoint.zero
    private var initialSize = NSSize.zero
    override func draw(_ dirtyRect: NSRect) {
        color.withAlphaComponent(0.5).setStroke()
        for offset in [CGFloat(4), 8] {
            let path = NSBezierPath(); path.move(to: NSPoint(x: 2, y: offset)); path.line(to: NSPoint(x: offset, y: 2)); path.stroke()
        }
    }
    override func mouseDown(with event: NSEvent) { initialPoint = event.locationInWindow; initialSize = superview?.bounds.size ?? .zero }
    override func mouseDragged(with event: NSEvent) {
        onResize(NSSize(width: initialSize.width - (event.locationInWindow.x - initialPoint.x), height: initialSize.height - (event.locationInWindow.y - initialPoint.y)))
    }
}

@MainActor final class UnisessionAnchorHost: NSView {
    var onLayout: () -> Void = {}
    override func layout() { super.layout(); onLayout() }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); onLayout() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

@MainActor final class UnisessionPresentation {
    let host = UnisessionAnchorHost()
    let surface: UnisessionSurfaceView
    private(set) weak var owner: NSWindow?
    private(set) var isPresented = false
    private(set) var expanded = false
    private var preferredSize = NSSize(width: 500, height: 310)
    private var topInset: CGFloat = 40
    private let canMove: () -> Bool
    var onHide: (Bool) -> Void = { _ in }
    var onLayout: () -> Void = {}

    init(renderer: NSView, canMove: @escaping () -> Bool = { true }) {
        self.canMove = canMove
        surface = UnisessionSurfaceView(renderer: renderer)
        host.autoresizingMask = [.width, .height]
        host.addSubview(surface)
        host.onLayout = { [weak self] in self?.layout() }
        surface.onHide = { [weak self] in
            guard let self else { return }
            let owned = self.ownsInputFocus
            if self.hide() { self.onHide(owned) }
        }
        surface.onExpand = { [weak self] in self?.toggleExpanded() }
        surface.onResize = { [weak self] size in self?.resize(to: size) }
    }
    @discardableResult func show(in window: NSWindow, topInset: CGFloat, anchorFrame: NSRect? = nil) -> Bool {
        guard let content = window.contentView else { return false }
        if let owner, owner !== window, !canMove() { return false }
        if host.superview !== content {
            host.removeFromSuperview()
            content.addSubview(host, positioned: .above, relativeTo: nil)
        }
        host.frame = anchorFrame ?? content.bounds
        owner = window; self.topInset = topInset
        isPresented = true; host.isHidden = false; layout()
        OutsideClickDismissalRegistry.shared.register(surface: surface, id: "unisession", canDismiss: { [weak self] in self?.canMove() == true }, perform: { [weak self] in self?.surface.onHide() })
        return true
    }
    @discardableResult func hide() -> Bool {
        guard canMove() else { return false }
        isPresented = false; host.isHidden = true
        OutsideClickDismissalRegistry.shared.remove(surface: surface)
        releaseInputFocus()
        return true
    }
    var ownsInputFocus: Bool {
        UnisessionResponderOwnership.owns(owner?.firstResponder, in: surface.renderer)
    }
    func releaseInputFocus() {
        if ownsInputFocus { owner?.makeFirstResponder(nil) }
    }
    func detach() { OutsideClickDismissalRegistry.shared.remove(surface: surface); releaseInputFocus(); host.removeFromSuperview(); owner = nil; isPresented = false }
    func toggleExpanded() { expanded.toggle(); surface.setExpanded(expanded); layout() }
    func resize(to size: NSSize) {
        guard size.width.isFinite, size.height.isFinite else { return }
        preferredSize = NSSize(width: max(240, size.width), height: max(140, size.height)); layout()
    }
    private func layout() {
        let available = NSSize(width: max(0, host.bounds.width - 16), height: max(0, host.bounds.height - topInset - 16))
        let size = expanded ? available : NSSize(width: min(preferredSize.width, available.width), height: min(preferredSize.height, available.height))
        surface.frame = NSRect(x: max(0, host.bounds.maxX - 8 - size.width), y: max(0, host.bounds.maxY - topInset - 8 - size.height), width: size.width, height: size.height)
        surface.layoutSubtreeIfNeeded(); onLayout()
    }
}
