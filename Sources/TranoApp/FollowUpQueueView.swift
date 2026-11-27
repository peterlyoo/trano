import AppKit
import SwiftUI
import TerminalCore

struct FollowUpQueueView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolPanelHeader("Queued Input", symbol: "text.badge.plus",
                            trailing: AnyView(Text("\(store.followUpItems.count)")
                                .font(.system(size: ToolPanelMetrics.captionSize, design: .monospaced))
                                .foregroundStyle(store.toolPanelTheme.secondary)),
                            canClose: !store.followUpSaving && !store.followUpComposing,
                            closeLabel: "Close Queued Input", onClose: store.dismissFollowUps)
            VStack(alignment: .leading, spacing: ToolPanelMetrics.sectionSpacing) {
                Text(store.followUpPaneTitle).font(.system(size: ToolPanelMetrics.captionSize)).foregroundStyle(store.toolPanelTheme.secondary).lineLimit(1)
                Divider().overlay(store.toolPanelTheme.border)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if store.followUpItems.isEmpty {
                            Text("No queued inputs").font(.system(size: ToolPanelMetrics.bodySize)).foregroundStyle(store.toolPanelTheme.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, ToolPanelMetrics.contentInset)
                        }
                        ForEach(Array(store.followUpItems.enumerated()), id: \.element.id) { index, item in
                            queueRow(item, index: index)
                            Divider().overlay(store.toolPanelTheme.border)
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider().overlay(store.toolPanelTheme.border)
                Text(store.followUpEditingID == nil ? "New input" : "Edit input").font(.system(size: ToolPanelMetrics.captionSize, weight: .medium))
                FollowUpDraftEditor(store: store)
                    .frame(height: 112)
                    .background(store.toolPanelTheme.foreground.opacity(0.035))
                    .clipShape(RoundedRectangle(cornerRadius: ToolPanelMetrics.cornerRadius))
                    .overlay { RoundedRectangle(cornerRadius: ToolPanelMetrics.cornerRadius).stroke(store.toolPanelTheme.border, lineWidth: 1).allowsHitTesting(false) }
                if let error = store.followUpError {
                    Text(error).font(.system(size: ToolPanelMetrics.captionSize)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    FollowUpActionButton(title: "Cancel", id: "follow-up-cancel", enabled: !store.followUpSaving && !store.followUpComposing, action: store.cancelFollowUpDraft)
                        .frame(width: 64, height: 26)
                    Spacer(minLength: 8)
                    if store.followUpSaving { ProgressView().controlSize(.small).frame(width: 16, height: 16) }
                    FollowUpActionButton(title: store.followUpEditingID == nil ? "Add" : "Save", id: "follow-up-save", enabled: store.canSaveFollowUpDraft, action: store.saveFollowUpDraft)
                        .frame(width: 64, height: 26)
                        .background(FollowUpRegion("follow-up-add"))
                }
            }.padding(ToolPanelMetrics.contentInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .toolPanelSurface(store.toolPanelTheme)
        .background(WorkspaceRegion("follow-up-panel", label: "Queued Input"))
        .onAppear { store.focusFollowUpEditor() }
    }

    private func queueRow(_ item: FollowUpInput, index: Int) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .top, spacing: 8) {
                Text("\(index + 1)").font(.system(size: ToolPanelMetrics.captionSize, design: .monospaced)).foregroundStyle(store.toolPanelTheme.secondary).frame(width: 18, alignment: .leading)
                Text(item.text).font(.system(size: ToolPanelMetrics.bodySize)).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
            }
            if let message = item.message, !message.isEmpty {
                Text(message).font(.system(size: ToolPanelMetrics.captionSize)).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text(status(item.status)).font(.system(size: ToolPanelMetrics.captionSize)).foregroundStyle(item.status == .needsReview ? .orange : store.toolPanelTheme.secondary)
                Spacer(minLength: 0)
                if item.status == .needsReview {
                    FollowUpActionButton(title: "Resume next turn", id: "follow-up-review-" + item.id, enabled: !store.followUpSaving && !store.followUpComposing) { store.resumeReviewedFollowUp(item) }
                        .frame(width: 112, height: 24)
                        .help("Review the pane and submit your next prompt manually. The queue resumes after that turn finishes.")
                }
                FollowUpActionButton(title: "Edit", id: "follow-up-edit-" + item.id, enabled: item.status != .sending && !store.followUpSaving && !store.followUpComposing) { store.editFollowUp(item) }
                    .frame(width: 48, height: 24)
                FollowUpActionButton(title: "Delete", id: "follow-up-delete-" + item.id, enabled: item.status != .sending && !store.followUpSaving && !store.followUpComposing) { store.removeFollowUp(item) }
                    .frame(width: 58, height: 24)
            }
        }.padding(.vertical, 10)
    }

    private func status(_ value: FollowUpStatus) -> String {
        switch value {
        case .pending: return "Queued"
        case .sending: return "Sending"
        case .needsReview: return "Review required"
        }
    }
}

private struct FollowUpActionButton: NSViewRepresentable {
    let title: String
    let id: String
    let enabled: Bool
    let action: () -> Void

    func makeNSView(context: Context) -> FollowUpNativeButton {
        let button = FollowUpNativeButton()
        button.target = button
        button.action = #selector(FollowUpNativeButton.invokeFollowUpAction(_:))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: ToolPanelMetrics.captionSize)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: FollowUpNativeButton, context: Context) {
        let theme = context.environment.toolPanelTheme
        button.appearance = theme.appearance
        button.contentTintColor = theme.foregroundNS
        button.title = title
        button.identifier = NSUserInterfaceItemIdentifier(id)
        button.setAccessibilityLabel(title)
        button.isEnabled = enabled
        button.onAction = action
    }
}

private final class FollowUpNativeButton: NSButton {
    var onAction: (() -> Void)?
    @objc func invokeFollowUpAction(_ sender: NSButton) { onAction?() }
}

private struct FollowUpDraftEditor: NSViewRepresentable {
    @ObservedObject var store: AppStore

    func makeCoordinator() -> Coordinator { Coordinator(store: store) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = FollowUpEditorScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        let editor = FollowUpTextView(frame: .zero)
        editor.identifier = NSUserInterfaceItemIdentifier("follow-up-editor")
        editor.setAccessibilityLabel("Queued Input")
        editor.isRichText = false
        editor.importsGraphics = false
        editor.allowsUndo = true
        editor.drawsBackground = false
        editor.font = .monospacedSystemFont(ofSize: ToolPanelMetrics.bodySize, weight: .regular)
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.isAutomaticSpellingCorrectionEnabled = false
        editor.isContinuousSpellCheckingEnabled = false
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.minSize = .zero
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.string = store.followUpDraft
        context.coordinator.editor = editor
        editor.delegate = context.coordinator
        editor.compositionChanged = { [weak coordinator = context.coordinator] in coordinator?.synchronize() }
        scroll.documentView = editor
        applyTheme(store.toolPanelTheme, to: scroll, editor: editor)
        store.followUpEditor = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let editor = scroll.documentView as? FollowUpTextView else { return }
        context.coordinator.applyingModel = true
        defer { context.coordinator.applyingModel = false }
        applyTheme(store.toolPanelTheme, to: scroll, editor: editor)
        store.followUpEditor = editor
        editor.isEditable = !store.followUpSaving
        guard !editor.hasMarkedText(), Data(editor.string.utf8) != Data(store.followUpDraft.utf8) else { return }
        let selection = editor.selectedRange()
        editor.string = store.followUpDraft
        let length = (editor.string as NSString).length
        let location = min(selection.location, length)
        editor.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
        editor.undoManager?.removeAllActions()
    }
    private func applyTheme(_ theme: ToolPanelTheme, to scroll: NSScrollView, editor: NSTextView) {
        scroll.appearance = theme.appearance
        scroll.backgroundColor = theme.backgroundNS
        scroll.contentView.appearance = theme.appearance
        scroll.contentView.drawsBackground = false
        editor.appearance = theme.appearance
        editor.backgroundColor = theme.backgroundNS
        editor.textColor = theme.foregroundNS
        editor.insertionPointColor = theme.foregroundNS
        editor.selectedTextAttributes = [.backgroundColor: theme.accentNS.withAlphaComponent(0.3), .foregroundColor: theme.foregroundNS]
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        let editor = scroll.documentView as? FollowUpTextView
        editor?.delegate = nil
        editor?.compositionChanged = nil
        coordinator.editor = nil
        if coordinator.store.followUpEditor === scroll.documentView {
            coordinator.store.followUpEditor = nil
        }
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let store: AppStore
        weak var editor: FollowUpTextView?
        var applyingModel = false
        init(store: AppStore) { self.store = store }
        func textDidChange(_ notification: Notification) { synchronize() }
        func synchronize() {
            guard !applyingModel, let editor, store.followUpEditor === editor else { return }
            if store.followUpComposing != editor.hasMarkedText() { store.followUpComposing = editor.hasMarkedText() }
            if !editor.hasMarkedText(), Data(store.followUpDraft.utf8) != Data(editor.string.utf8) {
                store.followUpDraft = editor.string
            }
        }
    }
}

private final class FollowUpEditorScrollView: NSScrollView {
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

private final class FollowUpTextView: NSTextView {
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

private struct FollowUpRegion: NSViewRepresentable {
    let id: String
    init(_ id: String) { self.id = id }
    func makeNSView(context: Context) -> NSView {
        let view = Region()
        view.identifier = NSUserInterfaceItemIdentifier(id)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {}
    private final class Region: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
