import AppKit
import SwiftUI

struct DecisionInstructionEditor: NSViewRepresentable {
    @Binding var text: String
    let label: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = DecisionEditorScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = DecisionTextView(frame: .zero)
        editor.identifier = NSUserInterfaceItemIdentifier("decision-instruction")
        editor.setAccessibilityLabel(label)
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 12)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 3, height: 3)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        context.coordinator.editor = editor
        editor.delegate = context.coordinator
        editor.compositionChanged = { [weak coordinator = context.coordinator] in coordinator?.synchronize() }
        scroll.documentView = editor
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        guard let editor = scroll.documentView as? DecisionTextView else { return }
        editor.setAccessibilityLabel(label)
        let theme = context.environment.toolPanelTheme
        scroll.appearance = theme.appearance
        editor.textColor = theme.foregroundNS; editor.insertionPointColor = theme.foregroundNS
        guard !editor.hasMarkedText(), Data(editor.string.utf8) != Data(text.utf8) else { return }
        context.coordinator.applyingModel = true
        defer { context.coordinator.applyingModel = false }
        let selection = editor.selectedRange()
        editor.string = text
        let length = (editor.string as NSString).length
        let location = min(selection.location, length)
        editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        editor.undoManager?.removeAllActions()
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        let editor = scroll.documentView as? DecisionTextView
        editor?.delegate = nil
        editor?.compositionChanged = nil
        coordinator.editor = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        fileprivate weak var editor: DecisionTextView?
        var applyingModel = false
        init(text: Binding<String>) { self.text = text }
        func textDidChange(_ notification: Notification) { synchronize() }
        func synchronize() {
            guard !applyingModel, let editor, !editor.hasMarkedText(),
                  Data(text.wrappedValue.utf8) != Data(editor.string.utf8) else { return }
            text.wrappedValue = editor.string
        }
    }
}

private final class DecisionEditorScrollView: NSScrollView {
    override func layout() {
        super.layout()
        guard let editor = documentView as? NSTextView else { return }
        let size = contentSize
        editor.minSize = NSSize(width: 0, height: size.height)
        if editor.frame.width != size.width || editor.frame.height < size.height {
            editor.setFrameSize(NSSize(width: size.width, height: max(size.height, editor.frame.height)))
        }
    }
}

private final class DecisionTextView: NSTextView {
    var compositionChanged: (() -> Void)?
    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
        compositionChanged?()
    }
    override func unmarkText() {
        super.unmarkText()
        compositionChanged?()
    }
    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        compositionChanged?()
    }
}
