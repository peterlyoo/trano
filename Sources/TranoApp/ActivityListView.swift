import SwiftUI
import TerminalCore

struct ActivityListView: View {
    @ObservedObject var store: AppStore

    private var visibleSessions: [TerminalSession] { store.activityRows }

    var body: some View {
        let presentedEvents = store.activityIndicatorEvents
        VStack(alignment: .leading, spacing: 0) {
            ToolPanelHeader("Activity", closeLabel: "Close Activity") { store.showActivity = false }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(store.activitySections) { section in sectionView(section) }
                        if visibleSessions.isEmpty {
                            Text(store.activityFilter.isEmpty ? "No processes are reporting activity" : "No matching activity").font(.system(size: ToolPanelMetrics.bodySize))
                                .foregroundStyle(store.toolPanelTheme.secondary).padding(.horizontal, 6)
                        }
                        PessimisticTwinActivitySection(store: store)
                        WorktreeCleanupSection(store: store)
                    }.padding(.horizontal, 8).padding(.vertical, 10)
                }
                .onAppear { if let id = store.selectedActivityID { proxy.scrollTo(id) } }
                .onChange(of: store.selectedActivityID) { id in
                    if let id { withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id) } }
                }
            }
            Divider()
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(store.toolPanelTheme.secondary)
                PickerSearchField(text: $store.activityFilter, placeholder: "Filter Activity", previewsMarkedText: true,
                                  identifier: ActivityKeyboardInput.filterIdentifier, focusesOnAppear: false, tabMovesSelection: true,
                                  keyInterceptor: { event, window in ActivityKeyboardInput.handle(event, store: store, in: window) },
                                  onMove: { store.moveActivitySelection($0) }, onSubmit: { store.activateActivitySelection() },
                                  onCancel: { store.showActivity = false })
                    .frame(maxWidth: .infinity).frame(height: 20)
            }.padding(.horizontal, ToolPanelMetrics.contentInset).padding(.vertical, 6)
        }.toolPanelSurface(store.toolPanelTheme)
            .background(ActivityKeyboardFocus(store: store))
            .onAppear { store.acknowledgeActivityInbox(presentedEvents) }
            .onChange(of: presentedEvents) { events in store.acknowledgeActivityInbox(events) }
    }

    private func sectionView(_ section: ActivityInbox.Section) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text(section.title).font(.system(size: ToolPanelMetrics.bodySize, weight: .semibold))
                if section.id == "attention" {
                    Circle().fill(Color.red.opacity(0.85)).frame(width: 5, height: 5)
                }
            }.foregroundStyle(store.toolPanelTheme.secondary)
                .padding(.horizontal, 6).padding(.bottom, 2)
                .background(WorkspaceRegion("activity-section-" + section.id, label: section.title))
            ForEach(section.sessions) { session in row(session).id(session.id) }
        }
    }

    private func subtitle(_ session: TerminalSession) -> String {
        let reason = session.activity.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if !reason.isEmpty { return reason.replacingOccurrences(of: "\n", with: " ") }
        let layout = store.state.layout
        if let workspaceID = layout.tabs.first(where: { $0.panes.contains(session.id) })?.workspaceID,
           let title = layout.workspaces.first(where: { $0.id == workspaceID })?.title, !title.isEmpty {
            return title
        }
        return URL(fileURLWithPath: session.cwd).lastPathComponent
    }

    private func row(_ session: TerminalSession) -> some View {
        let theme = store.toolPanelTheme
        let unread = ActivityInbox.isUnread(session, readAt: store.state.activityReadAt[session.id])
        let selected = store.selectedActivityID == session.id
        let title = session.displayTitle(preferGeneratedTitles: store.terminalPreferences.preferGeneratedTitles)
        return Button {
            store.openActivityPane(session.id)
        } label: {
            HStack(alignment: .center, spacing: 10) {
                AgentLogo(agent: session.agent).frame(width: 18, height: 18)
                    .overlay(alignment: .topTrailing) {
                        if unread {
                            Circle().fill(session.activity.state == .done ? Color.blue : Color.orange)
                                .frame(width: 8, height: 8)
                                .overlay { Circle().stroke(theme.background, lineWidth: 1.5) }
                                .background(WorkspaceRegion("activity-unread-" + session.id, label: "Needs attention"))
                                .offset(x: 3, y: -3)
                        }
                    }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(title).font(.system(size: ToolPanelMetrics.titleSize, weight: unread ? .semibold : .medium))
                            .foregroundStyle(theme.foreground).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 0)
                        if session.activity.state == .running {
                            Image(systemName: "ellipsis").font(.system(size: 10, weight: .bold))
                                .foregroundStyle(theme.secondary)
                        }
                    }
                    HStack(spacing: 6) {
                        Text(subtitle(session)).lineLimit(1).truncationMode(.tail)
                        Spacer(minLength: 4)
                        TimelineView(.periodic(from: .now, by: 30)) { context in
                            Text(ActivityRelativeTime.label(since: session.activity.updatedAt, now: context.date))
                                .monospacedDigit().lineLimit(1).fixedSize()
                        }
                    }.font(.system(size: ToolPanelMetrics.bodySize)).foregroundStyle(theme.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6).padding(.horizontal, 8)
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 9).fill(theme.accent.opacity(theme.isDark ? 0.42 : 0.32))
                        .overlay { RoundedRectangle(cornerRadius: 9).stroke(theme.accent.opacity(0.7), lineWidth: 1) }
                        .background(WorkspaceRegion("activity-selected-" + session.id))
                }
            }
            .help(title)
            .accessibilityValue(selected ? "Selected" : "")
            .accessibilityLabel(title + ", " + session.agent.rawValue + (unread ? ", needs attention" : ""))
    }
}

enum ActivityRelativeTime {
    static func label(since date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "now" }
        if seconds < 3_600 { return "\(Int(seconds / 60))m" }
        if seconds < 86_400 { return "\(Int(seconds / 3_600))h" }
        return "\(Int(seconds / 86_400))d"
    }
}

private struct ActivityKeyboardFocus: NSViewRepresentable {
    let store: AppStore

    func makeNSView(context: Context) -> ActivityKeyboardFocusView {
        let view = ActivityKeyboardFocusView()
        view.store = store
        return view
    }

    func updateNSView(_ view: ActivityKeyboardFocusView, context: Context) {}

    static func dismantleNSView(_ view: ActivityKeyboardFocusView, coordinator: ()) {
        view.releaseFocus()
    }
}

@MainActor enum ActivityKeyboardInput {
    static let filterIdentifier = "activity-filter-field"

    static func ownsFieldEditor(_ responder: NSResponder?) -> Bool {
        guard let editor = responder as? NSTextView, editor.isFieldEditor else { return false }
        return (editor.delegate as? NSTextField)?.identifier?.rawValue == filterIdentifier
    }

    static func canFocus(store: AppStore, in window: NSWindow) -> Bool {
        store.showActivity && store.picker == nil && store.conversationResume == nil &&
        store.decisionPaneID == nil && store.followUpPaneID == nil &&
        !store.showSettings && !store.showVoice && !store.showRemoteHosts &&
        !store.showAccounts && !store.showExtensions && store.remotePathRequest == nil &&
        window.attachedSheet == nil && NSApp.modalWindow == nil &&
        (window.firstResponder as? NSTextInputClient)?.hasMarkedText() != true
    }

    /// Printable text without Command/Control routes to the filter field; navigation and control keys stay on the list.
    static func startsFilterText(_ event: NSEvent) -> Bool {
        guard event.type == .keyDown, event.modifierFlags.intersection([.command, .control]).isEmpty,
              let text = event.characters, !text.isEmpty else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            !(scalar.value < 0x20 || scalar.value == 0x7f || (0xF700...0xF8FF).contains(scalar.value))
        }
    }

    static func handle(_ event: NSEvent, store: AppStore, in window: NSWindow) -> Bool? {
        guard event.type == .keyDown, store.showActivity else { return nil }
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let tab = event.keyCode == 48 && modifiers.subtracting([.control, .shift]).isEmpty
        // Cmd may still be held right after Cmd+. opens Activity; treat Cmd+Up/Down as plain navigation.
        let arrow = [UInt16(125), 126].contains(event.keyCode) && modifiers.subtracting([.command]).isEmpty
        guard tab || arrow || modifiers.isEmpty && [UInt16(36), 76, 53].contains(event.keyCode) else { return nil }
        guard event.window == nil || event.window === window,
              canFocus(store: store, in: window),
              (window.firstResponder as? NSTextView)?.isFieldEditor != true || ownsFieldEditor(window.firstResponder) else { return false }
        if tab {
            store.moveActivitySelection(modifiers.contains(.shift) ? -1 : 1)
            return true
        }
        switch event.keyCode {
        case 125: store.moveActivitySelection(1)
        case 126: store.moveActivitySelection(-1)
        case 36, 76: if !event.isARepeat { store.activateActivitySelection() }
        case 53: store.showActivity = false
        default: return false
        }
        return true
    }
}

/// Owns navigation keys when Activity opens; the filter field takes over only on typed text or a click.
private final class ActivityKeyboardFocusView: NSView {
    weak var store: AppStore?
    private var focusRequest = UUID()

    override var acceptsFirstResponder: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func keyDown(with event: NSEvent) {
        if let store, let window, window.firstResponder === self {
            if ActivityKeyboardInput.handle(event, store: store, in: window) == true { return }
            if ActivityKeyboardInput.startsFilterText(event), ActivityKeyboardInput.canFocus(store: store, in: window),
               let field = filterField(), window.makeFirstResponder(field),
               let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
                editor.keyDown(with: event)
                return
            }
        }
        super.keyDown(with: event)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        focusRequest = UUID()
        guard let window else { return }
        if let store, ActivityKeyboardInput.canFocus(store: store, in: window), window.makeFirstResponder(self) { return }
        let request = focusRequest
        weak var previousResponder = window.firstResponder
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, let window, self.window === window, self.focusRequest == request,
                  let store = self.store, ActivityKeyboardInput.canFocus(store: store, in: window),
                  window.firstResponder === previousResponder,
                  !self.isHiddenOrHasHiddenAncestor else { return }
            window.makeFirstResponder(self)
        }
    }

    private func filterField() -> NSTextField? {
        func find(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.identifier?.rawValue == ActivityKeyboardInput.filterIdentifier,
               !field.isHiddenOrHasHiddenAncestor { return field }
            for child in view.subviews { if let field = find(child) { return field } }
            return nil
        }
        var root: NSView = self
        while let parent = root.superview { root = parent }
        return find(root)
    }

    func releaseFocus() {
        focusRequest = UUID()
        guard let store, !store.showActivity, let window,
              window.firstResponder === self || window.firstResponder === window ||
              ActivityKeyboardInput.ownsFieldEditor(window.firstResponder) else { return }
        window.makeFirstResponder(nil)
        store.restoreTerminalFocus(returningTo: window)
    }
}
