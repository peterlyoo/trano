import AppKit
import SwiftUI

/// Reports pointer enter/exit through an AppKit tracking area without taking part in hit testing,
/// so drag, click and context-menu regions layered on the same view keep working.
struct HoverTrackingRegion: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> HoverTrackingView {
        let view = HoverTrackingView(frame: .zero)
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: HoverTrackingView, context: Context) { view.onChange = onChange }

    static func dismantleNSView(_ view: HoverTrackingView, coordinator: ()) { view.onChange = nil }
}

@MainActor final class HoverTrackingView: NSView {
    var onChange: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?
    private(set) var hovering = false

    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateTrackingAreas() {
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
        super.updateTrackingAreas()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { set(false) }
    }

    override func mouseEntered(with event: NSEvent) { set(contains(event)) }
    override func mouseMoved(with event: NSEvent) { set(contains(event)) }
    override func mouseExited(with event: NSEvent) { set(false) }
    private func contains(_ event: NSEvent) -> Bool { clippedVisibleBounds.contains(convert(event.locationInWindow, from: nil)) }

    private func set(_ value: Bool) {
        guard hovering != value else { return }
        hovering = value
        onChange?(value)
    }
}

extension NSView {
    // Inside SwiftUI scroll views visibleRect spans the whole viewport, not just this view.
    var clippedVisibleBounds: NSRect { bounds.intersection(visibleRect) }
}
