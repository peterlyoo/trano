import Foundation

public enum NotificationActivityProjection {
    public static func rows(layout: WorkspaceLayout, sessions: [TerminalSession], preferences: NotificationPreferences) -> [TerminalSession] {
        // Closed tabs and closed workspaces keep their jobs, but Activity must not present or reattach them.
        let retained = layout.closedPaneIDs
        let eligible = sessions.filter {
            (preferences.includeIdleProcesses || ![.idle, .unknown].contains($0.activity.state)) && !retained.contains($0.id)
        }
        guard !preferences.showEachProcessInTabs else { return eligible }
        let byID = Dictionary(eligible.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var grouped = Set<String>()
        var rows: [TerminalSession] = []
        for tab in layout.openTabs {
            let panes = tab.panes.compactMap { id in grouped.contains(id) ? nil : byID[id] }.sorted(by: precedes)
            guard var target = panes.first else { continue }
            grouped.formUnion(panes.map(\.id))
            if !tab.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { target.title = tab.title }
            rows.append(target)
        }
        rows.append(contentsOf: eligible.filter { !grouped.contains($0.id) })
        return rows
    }
    public static func indicatorState(tab: TerminalTab, sessions: [TerminalSession], readAt: [String: Date], preferences: NotificationPreferences) -> ActivityState? {
        guard preferences.showActivityInTabs else { return nil }
        let ids = Set(tab.panes)
        return sessions.filter { session in
            guard session.activity.state != .running, ids.contains(session.id),
                  let policy = preferences.channels(for: session.activity.state), policy.enabled, policy.tabIndicator else { return false }
            if session.activity.state == .done { return readAt[session.id].map { $0 < session.activity.updatedAt } ?? true }
            return true
        }.sorted(by: precedes).first?.activity.state
    }
    private static func precedes(_ lhs: TerminalSession, _ rhs: TerminalSession) -> Bool {
        func rank(_ state: ActivityState) -> Int {
            switch state {
            case .error: return 0
            case .blocked: return 1
            case .running: return 2
            case .done: return 3
            case .idle: return 4
            case .unknown: return 5
            }
        }
        let left = rank(lhs.activity.state), right = rank(rhs.activity.state)
        if left != right { return left < right }
        if lhs.activity.updatedAt != rhs.activity.updatedAt { return lhs.activity.updatedAt > rhs.activity.updatedAt }
        return lhs.id < rhs.id
    }
}
