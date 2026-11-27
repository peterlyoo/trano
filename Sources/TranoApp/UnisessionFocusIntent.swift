import AppKit

@MainActor final class UnisessionFocusIntent {
    private weak var owner: NSWindow?
    private weak var responder: NSResponder?
    private let generation: UInt64
    init(owner: NSWindow, generation: UInt64) {
        self.owner = owner; responder = owner.firstResponder; self.generation = generation
    }
    func permitsFocus(in window: NSWindow, generation: UInt64) -> Bool {
        owner === window && self.generation == generation && window.firstResponder === responder
            && (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
            && window.attachedSheet == nil && NSApp.modalWindow == nil
    }
}

@MainActor enum UnisessionResponderOwnership {
    static func owns(_ responder: NSResponder?, in host: NSView) -> Bool {
        guard let view = responder as? NSView else { return false }
        return view === host || view.isDescendant(of: host)
    }
}
