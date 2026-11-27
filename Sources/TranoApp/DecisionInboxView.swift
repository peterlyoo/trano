import AppKit
import SwiftUI
import TerminalCore

struct DecisionDraft {
    var selectionID: String?
    var instruction = ""
    var other = false
    var canSend: Bool { other ? !instruction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : selectionID != nil }
    mutating func select(_ id: String) { selectionID = id; other = false }
    mutating func selectOther() { selectionID = nil; other = true }
}

struct DecisionInboxOverlay: View {
    let entries: [DecisionInboxEntry]
    var saving = false
    var error: String?
    let onResolve: (DecisionInboxEntry, String, String?, String?, String?) -> Void
    let onDismiss: () -> Void
    var draftStore: Binding<[String: DecisionDraft]>?
    var preferredQuestionID: String?
    var canNavigate: (DecisionInboxEntry) -> Bool = { _ in true }
    var onGoToSession: ((DecisionInboxEntry, NSWindow?) -> Void)?

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topTrailing) {
                Color.black.opacity(0.14).contentShape(Rectangle()).onTapGesture(perform: onDismiss)
                DecisionInboxView(entries: entries, saving: saving, error: error, onResolve: onResolve, onDismiss: onDismiss,
                                  draftStore: draftStore, preferredQuestionID: preferredQuestionID, canNavigate: canNavigate, onGoToSession: onGoToSession)
                    .frame(width: min(440, max(0, geometry.size.width - 24)), height: min(560, max(0, geometry.size.height - 24)))
                    .background(WorkspaceRegion("decision-inbox-panel"))
                    .dismissOnOutsideClick("decisions", canDismiss: { !saving }, perform: onDismiss)
                    .padding(12)
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.clipped()
    }
}

struct DecisionInboxView: View {
    let entries: [DecisionInboxEntry]
    var saving = false
    var error: String?
    let onResolve: (DecisionInboxEntry, String, String?, String?, String?) -> Void
    let onDismiss: () -> Void
    var draftStore: Binding<[String: DecisionDraft]>?
    var preferredQuestionID: String?
    var canNavigate: (DecisionInboxEntry) -> Bool = { _ in true }
    var onGoToSession: ((DecisionInboxEntry, NSWindow?) -> Void)?
    @Environment(\.toolPanelTheme) private var theme
    @State private var selectedID: String?
    @State private var locale = Locale.preferredLanguages.first?.hasPrefix("ko") == true ? "ko" : "en"
    @State private var drafts: [String: DecisionDraft] = [:]

    private var current: DecisionInboxEntry? { entries.first { $0.id == (selectedID ?? preferredQuestionID) } ?? entries.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ToolPanelHeader("Decision",
                            leading: AnyView(DecisionCountIcon(count: entries.filter { $0.status == "pending" }.count)
                                .frame(width: 28, height: 24)),
                            trailing: AnyView(Picker("Language", selection: $locale) {
                                Text("EN").tag("en"); Text("한국어").tag("ko")
                            }.labelsHidden().frame(width: 88)),
                            canClose: !saving, closeLabel: "Close Decisions", onClose: onDismiss)
            if entries.count > 1 {
                Picker("Question", selection: Binding(get: { current?.id ?? "" }, set: { selectedID = $0 })) {
                    ForEach(entries) { entry in Text(entry.question.question.text(locale: locale)).lineLimit(1).tag(entry.id) }
                }.padding(.horizontal, ToolPanelMetrics.contentInset).padding(.top, ToolPanelMetrics.sectionSpacing)
            }
            if let entry = current {
                question(entry)
            } else {
                VStack(spacing: ToolPanelMetrics.sectionSpacing) {
                    Image(systemName: "checkmark.bubble").font(.system(size: 22)).foregroundStyle(theme.secondary)
                    Text("No pending questions").font(.system(size: ToolPanelMetrics.bodySize)).foregroundStyle(theme.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .toolPanelSurface(theme)
        .accessibilityIdentifier("decision-inbox")
        .onChange(of: entries.map(\.id)) { _, ids in
            if let selectedID, !ids.contains(selectedID) { self.selectedID = nil }
        }
    }

    private func binding(_ entry: DecisionInboxEntry) -> Binding<DecisionDraft> {
        Binding(get: { (draftStore?.wrappedValue ?? drafts)[entry.id] ?? DecisionDraft() }, set: { draft in
            if let draftStore { draftStore.wrappedValue[entry.id] = draft }
            else { drafts[entry.id] = draft }
        })
    }

    private func question(_ entry: DecisionInboxEntry) -> some View {
        let draft = binding(entry)
        return VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: ToolPanelMetrics.sectionSpacing) {
                    HStack(spacing: 6) {
                        AgentLogo(agent: AgentKind(rawValue: entry.question.source.agent) ?? .shell)
                        Text(entry.question.source.agent.capitalized).font(.system(size: ToolPanelMetrics.captionSize, weight: .medium))
                        Text("·").foregroundStyle(theme.secondary)
                        Text(URL(fileURLWithPath: entry.question.source.workspace).lastPathComponent)
                            .font(.system(size: ToolPanelMetrics.captionSize)).foregroundStyle(theme.secondary).lineLimit(1)
                        Spacer()
                        if let onGoToSession {
                            DecisionSessionButton(enabled: !saving && canNavigate(entry)) { window in onGoToSession(entry, window) }
                                .frame(width: 112, height: 26)
                        }
                    }
                    Text(entry.question.question.text(locale: locale)).font(.system(size: ToolPanelMetrics.titleSize, weight: .medium))
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    ForEach(entry.question.options) { option in
                        optionRow(option, selected: draft.wrappedValue.selectionID == option.id) { draft.wrappedValue.select(option.id) }
                    }
                    if !TwinDecisionID.isReserved(entry.id) {
                    HStack(spacing: 8) {
                        DecisionActionButton(title: "Other", identifier: "decision-other", selected: draft.wrappedValue.other) { draft.wrappedValue.selectOther() }
                            .frame(width: 16, height: 18)
                        Text("Other").font(.system(size: ToolPanelMetrics.bodySize, weight: .medium))
                        Spacer()
                    }.padding(10).contentShape(Rectangle()).onTapGesture { draft.wrappedValue.selectOther() }
                    Text(draft.wrappedValue.other ? "Your answer" : "Additional instruction (optional)")
                        .font(.system(size: ToolPanelMetrics.captionSize, weight: .medium)).foregroundStyle(theme.secondary)
                    DecisionInstructionEditor(text: draft.instruction, label: draft.wrappedValue.other ? "Your answer" : "Additional instruction")
                        .id(entry.id)
                        .frame(minHeight: 58, maxHeight: 86)
                        .padding(5).background(theme.foreground.opacity(0.035)).clipShape(RoundedRectangle(cornerRadius: ToolPanelMetrics.cornerRadius))
                    }
                }.padding(ToolPanelMetrics.contentInset)
            }
            Divider().overlay(theme.border)
            if let error { Text(error).font(.system(size: ToolPanelMetrics.captionSize)).foregroundStyle(.orange).padding(.horizontal, ToolPanelMetrics.contentInset).padding(.top, 8) }
            HStack(spacing: 8) {
                DecisionActionButton(title: "Cancel Question", identifier: "decision-cancel", enabled: !saving) {
                    onResolve(entry, "cancel", nil, nil, nil)
                }
                Spacer()
                DecisionActionButton(title: "Send Answer", identifier: "decision-send", enabled: !saving && draft.wrappedValue.canSend && draft.wrappedValue.instruction.utf8.count <= 32_768) {
                    let value = draft.wrappedValue
                    onResolve(entry, value.other ? "revise" : "choose", value.selectionID, TwinDecisionID.isReserved(entry.id) ? nil : value.instruction, locale)
                }
                .disabled(saving || !draft.wrappedValue.canSend || draft.wrappedValue.instruction.utf8.count > 32_768)
            }.controlSize(.small).padding(ToolPanelMetrics.contentInset)
        }
    }

    private func optionRow(_ option: DecisionOption, selected: Bool, action: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 8) {
            DecisionActionButton(title: option.label.text(locale: locale), identifier: "decision-option-" + option.id, selected: selected, action: action)
                .frame(width: 16, height: 18)
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(option.label.text(locale: locale)).font(.system(size: ToolPanelMetrics.bodySize, weight: .semibold))
                    if option.recommended { Image(systemName: "star.fill").font(.system(size: 9)).foregroundStyle(theme.accent) }
                }
                Text(option.description.text(locale: locale)).font(.system(size: ToolPanelMetrics.captionSize)).foregroundStyle(theme.secondary)
            }.fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }.padding(10).frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            .onTapGesture(perform: action)
            .background(theme.foreground.opacity(selected ? 0.08 : 0.025))
            .clipShape(RoundedRectangle(cornerRadius: ToolPanelMetrics.cornerRadius))
    }
}

private struct DecisionActionButton: NSViewRepresentable {
    let title: String
    let identifier: String
    var enabled = true
    var selected: Bool? = nil
    let action: () -> Void

    func makeNSView(context: Context) -> DecisionNativeButton {
        let button = DecisionNativeButton()
        button.target = button
        button.action = #selector(DecisionNativeButton.invokeDecisionAction(_:))
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: ToolPanelMetrics.captionSize)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: DecisionNativeButton, context: Context) {
        let theme = context.environment.toolPanelTheme
        button.appearance = theme.appearance
        button.contentTintColor = theme.foregroundNS
        button.setButtonType(selected == nil ? .momentaryPushIn : .radio)
        button.title = selected == nil ? title : ""
        button.state = selected == true ? .on : .off
        button.isEnabled = enabled && context.environment.isEnabled
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.setAccessibilityLabel(title)
        button.onAction = action
        button.onNavigate = nil
    }
}

private struct DecisionSessionButton: NSViewRepresentable {
    let enabled: Bool
    let navigate: (NSWindow?) -> Void

    func makeNSView(context: Context) -> DecisionNativeButton {
        let button = DecisionNativeButton()
        button.target = button
        button.action = #selector(DecisionNativeButton.invokeDecisionAction(_:))
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.font = .systemFont(ofSize: ToolPanelMetrics.captionSize)
        updateNSView(button, context: context)
        return button
    }

    func updateNSView(_ button: DecisionNativeButton, context: Context) {
        let theme = context.environment.toolPanelTheme
        button.appearance = theme.appearance
        button.contentTintColor = theme.foregroundNS
        button.title = "Go to Session"
        button.identifier = NSUserInterfaceItemIdentifier("decision-go-to-session")
        button.setAccessibilityLabel("Go to Session")
        button.toolTip = "Go to the session that asked this question"
        button.isEnabled = enabled && context.environment.isEnabled
        button.onNavigate = navigate
    }
}

private final class DecisionNativeButton: NSButton {
    var onAction: (() -> Void)?
    var onNavigate: ((NSWindow?) -> Void)?
    @objc func invokeDecisionAction(_ sender: NSButton) {
        let composing = window?.firstResponder as? NSTextInputClient
        if let onNavigate {
            guard composing?.hasMarkedText() != true else { return }
            onNavigate(window); return
        }
        guard let composing, composing.hasMarkedText() else { onAction?(); return }
        // A click does not end IME composition, so commit the last syllable and answer once the draft has it.
        composing.unmarkText()
        DispatchQueue.main.async { [weak self] in
            guard let self, (self.window?.firstResponder as? NSTextInputClient)?.hasMarkedText() != true else { return }
            self.onAction?()
        }
    }
}
