import AppKit
import SwiftUI

struct PickerSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    var previewsMarkedText = false
    var identifier = "picker-search-field"
    var focusesOnAppear = true
    var tabMovesSelection = false
    /// Gives the field its own field editor that offers each key to this handler first. Returning nil passes
    /// the key to normal editing; true consumes it; false drops it.
    var keyInterceptor: ((NSEvent, NSWindow) -> Bool?)?
    /// Receives the zero-based position for Command-1 through Command-9 while the field owns focus.
    var onQuickSelect: ((Int) -> Void)?
    let onMove: (Int) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> PickerSearchTextField {
        let field = PickerSearchTextField(frame: .zero)
        if keyInterceptor != nil {
            let cell = InterceptingFieldEditorCell(textCell: "")
            cell.isEditable = true; cell.isSelectable = true; cell.isScrollable = true
            cell.wraps = false; cell.usesSingleLineMode = true
            field.cell = cell
        }
        field.identifier = NSUserInterfaceItemIdentifier(identifier)
        field.delegate = field
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 13)
        field.textColor = .labelColor
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        updateNSView(field, context: context)
        return field
    }

    func updateNSView(_ field: PickerSearchTextField, context: Context) {
        field.placeholderString = placeholder
        field.setAccessibilityLabel(placeholder)
        field.onTextChange = { text = $0 }
        field.previewsMarkedText = previewsMarkedText
        field.onMove = onMove
        field.onSubmit = onSubmit
        field.onCancel = onCancel
        field.focusesOnAppear = focusesOnAppear
        field.tabMovesSelection = tabMovesSelection
        field.keyInterceptor = keyInterceptor
        field.onQuickSelect = onQuickSelect
        field.apply(theme: context.environment.toolPanelTheme)
        guard (field.currentEditor() as? NSTextView)?.hasMarkedText() != true,
              Data(field.stringValue.utf8) != Data(text.utf8) else { return }
        field.stringValue = text
    }

    static func dismantleNSView(_ field: PickerSearchTextField, coordinator: ()) {
        field.delegate = nil
        field.onTextChange = nil
        field.onMove = nil
        field.onSubmit = nil
        field.onCancel = nil
        field.keyInterceptor = nil
        field.onQuickSelect = nil
    }
}

final class InterceptingFieldEditor: NSTextView {
    weak var owner: PickerSearchTextField?

    override func keyDown(with event: NSEvent) {
        guard let window, window.firstResponder === self else { return }
        if !hasMarkedText(), let decision = owner?.keyInterceptor?(event, window) {
            if decision { return }
            if [UInt16(125), 126, 36, 76, 53, 48].contains(event.keyCode) { return }
        }
        super.keyDown(with: event)
    }
}

final class InterceptingFieldEditorCell: NSTextFieldCell {
    private var editor: InterceptingFieldEditor?

    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        let editor = self.editor ?? InterceptingFieldEditor(frame: .zero)
        editor.isFieldEditor = true
        editor.owner = controlView as? PickerSearchTextField
        self.editor = editor
        return editor
    }
}

final class PickerSearchTextField: NSTextField, NSTextFieldDelegate {
    func apply(theme: ToolPanelTheme) {
        appearance = theme.appearance
        if font?.pointSize != ToolPanelMetrics.bodySize { font = .systemFont(ofSize: ToolPanelMetrics.bodySize) }
        textColor = theme.foregroundNS
        if let placeholderString {
            placeholderAttributedString = NSAttributedString(string: placeholderString, attributes: [.foregroundColor: theme.secondaryNS])
        }
        if let editor = currentEditor() as? NSTextView {
            editor.textColor = theme.foregroundNS; editor.insertionPointColor = theme.foregroundNS
        }
    }
    var onTextChange: ((String) -> Void)?
    var previewsMarkedText = false
    var onMove: ((Int) -> Void)?
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    var focusesOnAppear = true
    var tabMovesSelection = false
    var keyInterceptor: ((NSEvent, NSWindow) -> Bool?)?
    var onQuickSelect: ((Int) -> Void)?
    private var focusScheduled = false

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let onQuickSelect, event.type == .keyDown, !event.isARepeat, let editor = currentEditor() as? NSTextView,
           window?.firstResponder === editor, !editor.hasMarkedText(),
           event.modifierFlags.intersection([.command, .control, .option, .shift]) == .command,
           let key = event.charactersIgnoringModifiers, key.count == 1, let digit = Int(key), (1...9).contains(digit) {
            onQuickSelect(digit - 1)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusesOnAppear, let window, !focusScheduled else { return }
        focusScheduled = true
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window else { return }
            window.makeFirstResponder(self)
        }
    }

    func controlTextDidChange(_ notification: Notification) {
        if let editor = currentEditor() as? NSTextView, editor.hasMarkedText() {
            if previewsMarkedText { onTextChange?(editor.string) }
            return
        }
        onTextChange?(stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)): onMove?(1)
        case #selector(NSResponder.moveUp(_:)): onMove?(-1)
        case #selector(NSResponder.insertNewline(_:)): onSubmit?()
        case #selector(NSResponder.cancelOperation(_:)): onCancel?()
        case #selector(NSResponder.insertTab(_:)), #selector(NSResponder.insertTabIgnoringFieldEditor(_:)):
            guard tabMovesSelection else { return false }
            onMove?(NSApp.currentEvent?.modifierFlags.contains(.shift) == true ? -1 : 1)
        case #selector(NSResponder.insertBacktab(_:)):
            guard tabMovesSelection else { return false }
            onMove?(-1)
        default: return false
        }
        return true
    }
}
