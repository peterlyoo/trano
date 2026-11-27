import AppKit
import TerminalCore

enum TerminalSelectionIntent { case dragging, userCompleted, programmatic }
typealias TerminalCopyFeedbackExpiration = @MainActor @Sendable () -> Void

@MainActor private final class TerminalCopyFeedbackView: NSView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor final class TerminalCopyFeedback {
    private(set) var feedbackView: NSView?
    private(set) var usesAnimation = false
    private let reduceMotion: () -> Bool
    private let schedule: (TimeInterval, @escaping TerminalCopyFeedbackExpiration) -> Void
    private var generation = UUID()

    init(reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
         schedule: @escaping (TimeInterval, @escaping TerminalCopyFeedbackExpiration) -> Void = { delay, action in
             DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
         }) {
        self.reduceMotion = reduceMotion
        self.schedule = schedule
    }

    func show(in host: NSView) {
        cancel()
        let token = generation
        let width = min(84, max(0, host.bounds.width - 16))
        guard width >= 48, host.bounds.height >= 40 else { return }
        let view = TerminalCopyFeedbackView(frame: NSRect(x: host.bounds.maxX - width - 8,
                                                          y: host.isFlipped ? host.bounds.minY + 8 : host.bounds.maxY - 36,
                                                          width: width, height: 28))
        view.autoresizingMask = host.isFlipped ? [.minXMargin, .maxYMargin] : [.minXMargin, .minYMargin]
        view.wantsLayer = true
        view.layer?.cornerRadius = 6
        view.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.94).cgColor
        view.setAccessibilityElement(false)
        let label = NSTextField(labelWithString: "Copied")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.alignment = .center
        label.frame = NSRect(x: 4, y: 6, width: width - 8, height: 16)
        label.autoresizingMask = [.width]
        label.setAccessibilityElement(false)
        view.addSubview(label)
        host.addSubview(view)
        feedbackView = view
        usesAnimation = !reduceMotion()
        if usesAnimation {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                view.animator().alphaValue = 1
            }
        }
        schedule(0.75) { [weak self] in
            guard let self, self.generation == token else { return }
            self.cancel()
        }
    }

    func cancel() {
        generation = UUID()
        feedbackView?.removeFromSuperview()
        feedbackView = nil
        usesAnimation = false
    }
}

@MainActor final class TerminalSelectionController {
    private let pasteboard: NSPasteboard
    private let preferences: () -> TerminalPreferences
    private let owner: () -> TerminalInteractionOwner?
    private let feedback: TerminalCopyFeedback
    private var lastCopy: (owner: TerminalInteractionOwner, text: String, changeCount: Int)?

    init(pasteboard: NSPasteboard, preferences: @escaping () -> TerminalPreferences,
         owner: @escaping () -> TerminalInteractionOwner?, feedback: TerminalCopyFeedback? = nil) {
        self.pasteboard = pasteboard
        self.preferences = preferences
        self.owner = owner
        self.feedback = feedback ?? TerminalCopyFeedback()
    }

    @discardableResult
    func selectionChanged(text: String, intent: TerminalSelectionIntent, isComposing: Bool,
                          hostView: NSView) -> Bool {
        guard intent == .userCompleted else { return false }
        return performCopy(text: text, automatic: true, isComposing: isComposing, hostView: hostView)
    }

    @discardableResult
    func copy(text: String, isComposing: Bool, hostView: NSView) -> Bool {
        performCopy(text: text, automatic: false, isComposing: isComposing, hostView: hostView)
    }

    func ownerDidChange() {
        lastCopy = nil
        feedback.cancel()
    }

    func preferencesDidChange() {
        if !preferences().animateCopy { feedback.cancel() }
    }

    private func performCopy(text: String, automatic: Bool, isComposing: Bool, hostView: NSView) -> Bool {
        guard !isComposing, !text.isEmpty, let capturedOwner = owner() else { return false }
        let settings = preferences()
        guard !automatic || settings.copyOnSelection, owner() == capturedOwner else { return false }
        let duplicate = lastCopy.map {
            $0.owner == capturedOwner && $0.text.utf8.elementsEqual(text.utf8)
                && $0.changeCount == pasteboard.changeCount
        } ?? false
        if duplicate, automatic { return false }
        if !duplicate {
            let item = NSPasteboardItem()
            guard item.setString(text, forType: .string), owner() == capturedOwner else { return false }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([item]) else { return false }
            lastCopy = (capturedOwner, text, pasteboard.changeCount)
        }
        guard owner() == capturedOwner else { return false }
        if settings.animateCopy { feedback.show(in: hostView) }
        else { feedback.cancel() }
        return true
    }
}
