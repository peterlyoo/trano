import AppKit
import TerminalCore

@MainActor final class TerminalKeySequenceOverlay: NSView {
    private weak var owner: NSWindow?

    init(owner: NSWindow) {
        self.owner = owner
        super.init(frame: .zero)
        autoresizingMask = [.minXMargin, .maxYMargin]
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityLabel("Next keyboard sequence keys")
    }
    required init?(coder: NSCoder) { nil }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func present(_ hints: [TerminalKeySequenceHint], in host: NSView, bounds: NSRect) {
        guard !hints.isEmpty, let owner, host.window === owner else { dismiss(); return }
        let available = host.bounds.intersection(bounds).insetBy(dx: 10, dy: 10)
        guard available.width >= 80, available.height >= 44 else { dismiss(); return }
        subviews.forEach { $0.removeFromSuperview() }
        let capacity = max(1, Int((available.height - 20) / 22))
        let visible = Array(hints.prefix(capacity))
        let width = min(360, available.width)
        let height = min(available.height, CGFloat(visible.count) * 22 + 20)
        frame = NSRect(x: available.maxX - width, y: available.minY, width: width, height: height)
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.96).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        for (index, hint) in visible.enumerated() {
            let more = hints.count > capacity && index == capacity - 1
            let label = NSTextField(labelWithString: more ? "\(hints.count - index) more sequences" : KeyBindingMap.display(hint.binding).replacingOccurrences(of: ",", with: ", ") + "  " + hint.title)
            label.font = .systemFont(ofSize: 12)
            label.lineBreakMode = .byTruncatingTail
            label.frame = NSRect(x: 12, y: height - 30 - CGFloat(index) * 22, width: width - 24, height: 20)
            addSubview(label)
        }
        setAccessibilityValue(hints.map { KeyBindingMap.display($0.binding) + " " + $0.title }.joined(separator: ", "))
        if superview !== host { removeFromSuperview(); host.addSubview(self, positioned: .above, relativeTo: nil) }
    }

    override func resize(withOldSuperviewSize oldSize: NSSize) {
        super.resize(withOldSuperviewSize: oldSize)
        guard let host = superview else { return }
        let available = host.bounds.insetBy(dx: 10, dy: 10)
        guard available.width >= 80, available.height >= 44 else { dismiss(); return }
        frame = NSRect(x: available.maxX - min(frame.width, available.width), y: available.minY,
                       width: min(frame.width, available.width), height: min(frame.height, available.height))
        for (index, label) in subviews.enumerated() {
            label.frame = NSRect(x: 12, y: frame.height - 30 - CGFloat(index) * 22,
                                 width: max(0, frame.width - 24), height: 20)
            label.isHidden = label.frame.minY < 8
        }
    }

    func dismiss() { removeFromSuperview(); subviews.forEach { $0.removeFromSuperview() } }
}
