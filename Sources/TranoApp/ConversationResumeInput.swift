import AppKit

@MainActor enum ConversationResumeInput {
    static func handle(_ event: NSEvent, composing: Bool, terminalIsResponder: Bool,
                       toggle: Bool, dismiss: () -> Void) -> Bool {
        guard event.type == .keyDown, !composing else { return false }
        if event.keyCode == 53 || toggle {
            if !event.isARepeat { dismiss() }
            return true
        }
        return terminalIsResponder
    }
}
