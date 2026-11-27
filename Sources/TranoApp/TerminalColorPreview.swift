import AppKit
import ObjectiveC
import SwiftTerm
import TerminalCore

/// Shows a swatch for the hex color under the pointer (`#2da44e`), above the text it describes.
@MainActor final class TerminalColorPreviewController {
    weak var view: TranoView?
    private(set) var badge: TerminalColorPreviewBadge?
    private(set) var match: HexColorMatch?
    private var cell: (row: Int, column: Int)?

    init(view: TranoView) { self.view = view }

    func update(atWindowLocation location: NSPoint) {
        guard let view, let window = view.window, window.attachedSheet == nil, !view.hasMarkedText(), !view.urlHints.isActive else { hide(); return }
        let point = view.convert(location, from: nil)
        guard view.bounds.contains(point), let snapshot = view.terminalContentSnapshot(region: .viewport) else { hide(); return }
        let cols = snapshot.inputState.dimensions.cols, rows = snapshot.inputState.dimensions.rows
        guard cols > 0, rows > 0 else { hide(); return }
        var scrollerWidth: CGFloat = 0
        if let scroller = view.subviews.compactMap({ $0 as? NSScroller }).first, !scroller.isHidden, scroller.scrollerStyle == .legacy {
            scrollerWidth = scroller.frame.width
        }
        let grid = view.getOptimalFrameSize().size
        let size = NSSize(width: (grid.width - scrollerWidth) / CGFloat(cols), height: grid.height / CGFloat(rows))
        guard size.width > 0, size.height > 0 else { hide(); return }
        let row = Int((view.bounds.height - point.y) / size.height), column = Int(point.x / size.width)
        guard row >= 0, row < snapshot.rows.count, column >= 0, column < cols else { hide(); return }
        if let cell, cell == (row, column), badge != nil { return }
        cell = (row, column)
        let cells = snapshot.rows[row].cells.map { URLHintCell(text: $0.text, width: $0.width) }
        guard let found = HexColorMatcher.match(cells: cells, column: column) else { hide(); return }
        show(found, row: row, cellSize: size, in: view)
    }

    func hide() {
        badge?.removeFromSuperview(); badge = nil
        match = nil; cell = nil
    }

    private func show(_ found: HexColorMatch, row: Int, cellSize: NSSize, in view: TranoView) {
        let badge = self.badge ?? TerminalColorPreviewBadge()
        badge.configure(found)
        let size = badge.fittingSize
        let tokenTop = view.bounds.height - CGFloat(row) * cellSize.height
        let tokenBottom = tokenTop - cellSize.height
        let above = tokenTop + 4 + size.height <= view.bounds.height
        let x = min(max(0, CGFloat(found.columns.lowerBound) * cellSize.width), max(0, view.bounds.width - size.width))
        badge.frame = NSRect(x: x, y: above ? tokenTop + 4 : max(0, tokenBottom - 4 - size.height), width: size.width, height: size.height).integral
        if badge.superview !== view { view.addSubview(badge, positioned: .above, relativeTo: nil) }
        self.badge = badge
        match = found
    }
}

final class TerminalColorPreviewBadge: NSView {
    private let swatch = NSView()
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        identifier = NSUserInterfaceItemIdentifier("terminal-color-preview")
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 1
        swatch.wantsLayer = true
        swatch.layer?.cornerRadius = 3
        swatch.layer?.borderColor = NSColor.separatorColor.cgColor
        swatch.layer?.borderWidth = 1
        label.font = .monospacedSystemFont(ofSize: 11, weight: .medium)
        label.textColor = .labelColor
        for child in [swatch, label] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            swatch.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            swatch.centerYAnchor.constraint(equalTo: centerYAnchor),
            swatch.widthAnchor.constraint(equalToConstant: 14), swatch.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: swatch.trailingAnchor, constant: 6),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private(set) var color = NSColor.clear

    func configure(_ match: HexColorMatch) {
        color = NSColor(srgbRed: match.red, green: match.green, blue: match.blue, alpha: match.alpha)
        swatch.layer?.backgroundColor = color.cgColor
        label.stringValue = match.text.lowercased()
        setAccessibilityLabel("Color " + match.text)
    }
}

@MainActor private var colorPreviewAssociationKey: UInt8 = 0

extension TranoView {
    var colorPreview: TerminalColorPreviewController {
        if let controller = objc_getAssociatedObject(self, &colorPreviewAssociationKey) as? TerminalColorPreviewController { return controller }
        let controller = TerminalColorPreviewController(view: self)
        objc_setAssociatedObject(self, &colorPreviewAssociationKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }
}

@MainActor enum TerminalColorPreviewRouting {
    /// Pointer moves show the swatch for the renderer under the pointer; typing, clicks and scrolling dismiss it.
    static func handle(_ event: NSEvent, store: AppStore, in window: NSWindow) {
        switch event.type {
        case .mouseMoved:
            let target = TerminalPointerInput.primaryClickTarget(in: window, location: event.locationInWindow, store: store)
            for view in store.terminalViews.values where view !== target && view.window === window { view.colorPreview.hide() }
            target?.colorPreview.update(atWindowLocation: event.locationInWindow)
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            for view in store.terminalViews.values where view.window === window { view.colorPreview.hide() }
        default: break
        }
    }
}
