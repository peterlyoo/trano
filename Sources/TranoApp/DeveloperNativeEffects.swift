import AppKit
import TerminalCore

@MainActor final class DeveloperTerminalContainer: NSView {
    let terminal: NSView
    let cursorOverlay = DeveloperCursorOverlay(frame: .zero)
    var anchoring = DeveloperTerminalAnchoring.top { didSet { if oldValue != anchoring { needsLayout = true } } }
    var rowHeight: () -> CGFloat
    var backgroundColor = NSColor.clear { didSet { needsDisplay = true } }

    init(terminal: NSView, rowHeight: @escaping () -> CGFloat) {
        self.terminal = terminal; self.rowHeight = rowHeight
        super.init(frame: .zero)
        for case let overlay as DeveloperCursorOverlay in terminal.subviews {
            overlay.stop(); overlay.removeFromSuperview()
        }
        addSubview(terminal)
        terminal.addSubview(cursorOverlay)
    }
    required init?(coder: NSCoder) { return nil }
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { backgroundColor.alphaComponent == 1 }

    override func layout() {
        super.layout()
        let proposed = TerminalAnchoringLayout.frame(bounds: bounds, rowHeight: rowHeight(), anchoring: anchoring, flipped: isFlipped)
        if terminal.frame != proposed { terminal.frame = proposed }
        cursorOverlay.frame = terminal.bounds
    }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        let gaps = NSBezierPath(rect: bounds)
        let child = terminal.frame.intersection(bounds)
        if !child.isEmpty { gaps.appendRect(child) }
        gaps.windingRule = .evenOdd
        gaps.addClip()
        backgroundColor.setFill()
        dirtyRect.fill()
    }
}

@MainActor final class DeveloperCursorOverlay: NSView {
    var style = DeveloperCursorEffect.none { didSet { if oldValue != style { stop(); reconcileTimer() } } }
    var caretFrame: () -> CGRect = { .zero }
    var color = NSColor.controlAccentColor
    var reducesMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var active: () -> Bool = { true }
    private(set) var renderedPoints: [CursorEffectPoint] = []
    var hasActiveTimer: Bool { timer != nil }
    private var timer: Timer?
    private var previousCaret: CGRect?
    private var movementStart: CGRect?
    private var movementEnd: CGRect?
    private var movedAt: TimeInterval = 0
    private var dirtyBounds: CGRect = .null
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []

    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        removeObservers()
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                let observer = center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reconcileTimer() }
                }
                observers.append((center, observer))
            }
            let workspace = NSWorkspace.shared.notificationCenter
            let observer = workspace.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reconcileTimer() }
            }
            observers.append((workspace, observer))
        }
        reconcileTimer()
    }

    override func viewDidHide() { super.viewDidHide(); stop() }
    override func viewDidUnhide() { super.viewDidUnhide(); reconcileTimer() }

    func reconcileTimer() {
        guard style != .none, !reducesMotion(), window?.isKeyWindow == true,
              !isHiddenOrHasHiddenAncestor, active() else { stop(); return }
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sample(at: ProcessInfo.processInfo.systemUptime,
                            active: self.window?.isKeyWindow == true && !self.isHiddenOrHasHiddenAncestor && self.active())
            }
        }
        timer.tolerance = 0.002
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func sample(at timestamp: TimeInterval, active: Bool) {
        guard active, style != .none, !reducesMotion(), timestamp.isFinite else { stop(); return }
        let current = caretFrame()
        guard current.width > 0, current.height > 0, bounds.intersects(current) else { clearTrail(); previousCaret = nil; return }
        if let previousCaret, previousCaret != current {
            movementStart = previousCaret; movementEnd = current; movedAt = timestamp
        }
        previousCaret = current
        guard let start = movementStart, let end = movementEnd else { return }
        let points = CursorEffectGeometry.points(style: style, previous: start, current: end, elapsed: timestamp - movedAt, reduceMotion: false)
        let nextDirty = points.reduce(CGRect.null) { result, point in
            result.union(CGRect(x: point.center.x - point.radius - 2, y: point.center.y - point.radius - 2,
                                width: (point.radius + 2) * 2, height: (point.radius + 2) * 2))
        }.intersection(bounds)
        let invalidated = dirtyBounds.union(nextDirty)
        renderedPoints = points; dirtyBounds = nextDirty
        if !invalidated.isNull { setNeedsDisplay(invalidated) }
        if points.isEmpty { movementStart = nil; movementEnd = nil }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        previousCaret = nil
        clearTrail()
    }

    private func clearTrail() {
        renderedPoints = []; movementStart = nil; movementEnd = nil
        if !dirtyBounds.isNull { setNeedsDisplay(dirtyBounds) }
        dirtyBounds = .null
    }

    override func draw(_ dirtyRect: NSRect) {
        for point in renderedPoints {
            let rect = NSRect(x: point.center.x - point.radius, y: point.center.y - point.radius, width: point.radius * 2, height: point.radius * 2)
            guard rect.intersects(dirtyRect) else { continue }
            let tint = style == .blaze ? color.blended(withFraction: 0.32, of: .systemOrange) ?? color : color
            tint.withAlphaComponent(point.opacity).set()
            let path = NSBezierPath(ovalIn: rect)
            if style == .warp { path.lineWidth = 1.2; path.stroke() }
            else { path.fill() }
        }
    }

    private func removeObservers() {
        for (center, observer) in observers { center.removeObserver(observer) }
        observers = []
    }

    deinit {
        timer?.invalidate()
        for (center, observer) in observers { center.removeObserver(observer) }
    }
}
