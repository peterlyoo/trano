import AppKit
import TerminalCore

enum CloseConfirmation {
    struct Reason: Equatable {
        let title: String
        let detail: String
    }

    static func affectedPanes(_ action: ActionID, context: HeaderMenuContext, layout: WorkspaceLayout) -> [String] {
        let tab = layout.tabs.first { $0.id == context.tabID }
        switch action {
        case .closePane: return context.paneID.map { [$0] } ?? []
        case .closeTab: return tab?.panes ?? []
        case .closeOtherPanes: return (tab?.panes ?? []).filter { $0 != context.paneID }
        case .closeOtherTabs:
            return layout.tabs.filter { $0.workspaceID == context.workspaceID && $0.id != context.tabID }.flatMap(\.panes)
        case .closeTabsToLeft, .closeTabsToRight:
            guard let id = context.tabID else { return [] }
            let ids = Set(layout.tabIDs(beside: id, side: action == .closeTabsToLeft ? .left : .right))
            return layout.tabs.filter { ids.contains($0.id) }.flatMap(\.panes)
        default: return []
        }
    }

    static func reason(_ action: ActionID, context: HeaderMenuContext, state: RuntimeState, sessions: [TerminalSession],
                       preferGeneratedTitles: Bool) -> Reason? {
        let ids = affectedPanes(action, context: context, layout: state.layout)
        let affected = ids.compactMap { id in sessions.first { $0.id == id } }.filter { $0.agent != .shell || $0.activity.state != .idle }
        let working = affected.filter { [.running, .blocked].contains($0.activity.state) }
        let unread = affected.filter { $0.activity.state == .done && ActivityInbox.isUnread($0, readAt: state.activityReadAt[$0.id]) }
        guard let first = working.first ?? unread.first else { return nil }
        let noun: String
        switch action {
        case .closePane: noun = "pane"
        case .closeTab: noun = "tab"
        case .closeOtherPanes: noun = "other panes"
        case .closeTabsToLeft: noun = "other tabs to the left"
        case .closeTabsToRight: noun = "other tabs to the right"
        default: noun = "other tabs"
        }
        let name = first.agent == .shell ? "A program" : first.agent.rawValue.capitalized
        let title = first.displayTitle(preferGeneratedTitles: preferGeneratedTitles)
        let detail: String
        if !working.isEmpty {
            let state = first.activity.state == .blocked ? "is waiting for your input" : "is still working"
            detail = "\(name) \(state) in “\(title)”." + (working.count + unread.count > 1 ? " \(working.count + unread.count - 1) more will also close." : "")
        } else {
            detail = "\(name) just finished in “\(title)” and you haven't seen the result yet."
        }
        let heading = noun.hasPrefix("other") ? "Close \(noun)?" : "Close this \(noun)?"
        return Reason(title: heading, detail: detail)
    }

    @MainActor static func confirm(_ reason: Reason, runModal: (NSAlert) -> NSApplication.ModalResponse = { $0.runModal() }) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = reason.title
        alert.informativeText = reason.detail
        let close = alert.addButton(withTitle: "Close")
        close.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        return runModal(alert) == .alertFirstButtonReturn
    }
}
