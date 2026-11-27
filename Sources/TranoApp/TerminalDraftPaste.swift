import AppKit

@MainActor final class TerminalDraftPaste {
    private let text: String
    private let ownership: DeferredTerminalInputOwnership
    private let history: (@escaping () -> Void) -> Bool
    private let bracketed: () -> Bool
    private let confirm: (String, Bool) -> String?
    private let report: (String) -> Void
    private let insert: (String) -> Void
    private let didInsert: () -> Void
    private var finished = false

    init(text: String, ownership: DeferredTerminalInputOwnership, history: @escaping (@escaping () -> Void) -> Bool,
         bracketed: @escaping () -> Bool, confirm: @escaping (String, Bool) -> String?, report: @escaping (String) -> Void,
         insert: @escaping (String) -> Void, didInsert: @escaping () -> Void = {}) {
        self.text = text; self.ownership = ownership; self.history = history; self.bracketed = bracketed
        self.confirm = confirm; self.report = report; self.insert = insert; self.didInsert = didInsert
    }
    func perform() {
        guard !finished else { return }
        guard ownership.isCurrent() else { finished = true; return }
        if history({ self.perform() }) { return }
        guard ownership.isCurrent() else { finished = true; return }
        guard text.utf8.count <= 1_048_576 else { finished = true; report("Paste is limited to 1 MiB."); return }
        var draft = text
        if text.contains("\n") || text.contains("\r") {
            let wasBracketed = bracketed()
            guard let edited = confirm(text, wasBracketed) else { finished = true; return }
            draft = edited
            guard ownership.isCurrent() else { finished = true; return }
            guard draft.utf8.count <= 1_048_576 else { finished = true; report("Paste is limited to 1 MiB."); return }
            guard bracketed() == wasBracketed else {
                finished = true; report("The receiving program changed. Paste cancelled."); return
            }
        }
        guard ownership.isCurrent() else { finished = true; return }
        finished = true
        insert(draft)
        didInsert()
    }
}

@MainActor protocol TerminalDraftPastePromptPresenting {
    func confirm(_ text: String) -> String?
    func confirm(_ text: String, bracketed: Bool) -> String?
}

extension TerminalDraftPastePromptPresenting {
    func confirm(_ text: String, bracketed: Bool) -> String? { confirm(text) }
}

@MainActor struct NativeTerminalDraftPastePromptPresenter: TerminalDraftPastePromptPresenting {
    var runModal: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }

    func confirm(_ text: String) -> String? { confirm(text, bracketed: true) }

    func confirm(_ text: String, bracketed: Bool) -> String? {
        let alert = NSAlert()
        alert.messageText = "Paste multiple lines?"
        alert.informativeText = bracketed
            ? "Press Return to paste. You can edit the preview below; Return in the editor adds a new line."
            : "This program has not enabled bracketed paste, so each line may run as soon as it arrives. Press Return to paste. You can edit the preview below; Return in the editor adds a new line."
        let preview = TerminalPastePreview(frame: NSRect(x: 0, y: 0, width: 480, height: 180))
        preview.string = text
        preview.isEditable = true
        preview.isSelectable = true
        preview.isRichText = false
        preview.allowsUndo = true
        preview.isAutomaticQuoteSubstitutionEnabled = false
        preview.isAutomaticDashSubstitutionEnabled = false
        preview.isAutomaticTextReplacementEnabled = false
        preview.isAutomaticSpellingCorrectionEnabled = false
        preview.setAccessibilityLabel("Paste preview")
        preview.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        let scroll = TerminalPasteConfirmationScrollView(frame: preview.frame)
        scroll.documentView = preview; scroll.hasVerticalScroller = true
        alert.accessoryView = scroll
        alert.addButton(withTitle: "Cancel").keyEquivalent = "\u{1b}"
        let paste = alert.addButton(withTitle: "Paste")
        paste.keyEquivalent = "\r"
        preview.pasteButton = paste
        scroll.pasteButton = paste
        alert.layout()
        alert.window.initialFirstResponder = scroll
        alert.window.makeFirstResponder(scroll)
        return runModal(alert) == .alertSecondButtonReturn ? preview.string : nil
    }
}

@MainActor private final class TerminalPasteConfirmationScrollView: NSScrollView {
    weak var pasteButton: NSButton?
    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { true }

    override func keyDown(with event: NSEvent) {
        if window?.firstResponder === self,
           [UInt16(36), 76].contains(event.keyCode),
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if !event.isARepeat { pasteButton?.performClick(nil) }
            return
        }
        super.keyDown(with: event)
    }
}

@MainActor private final class TerminalPastePreview: NSTextView {
    weak var pasteButton: NSButton?

    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        pasteButton?.keyEquivalent = ""
        window?.defaultButtonCell = nil
        return true
    }

    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        pasteButton?.keyEquivalent = "\r"
        window?.defaultButtonCell = pasteButton?.cell as? NSButtonCell
        return true
    }
}
