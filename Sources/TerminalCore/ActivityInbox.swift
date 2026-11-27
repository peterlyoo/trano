import Foundation

public enum ActivityInbox {
    public struct Section: Identifiable {
        public let id: String
        public let title: String
        public let sessions: [TerminalSession]
    }

    /// Section names follow Rex's program activity statuses: Blocked, Error, Done, Working, and idle processes.
    public static func sections(_ sessions: [TerminalSession], readAt: [String: Date] = [:]) -> [Section] {
        let groups: [(String, String, (TerminalSession) -> Bool)] = [
            ("attention", "Blocked", { $0.activity.state == .blocked }),
            ("error", "Error", { $0.activity.state == .error }),
            ("done", "Done", { $0.activity.state == .done }),
            ("working", "Working", { $0.activity.state == .running }),
            ("idle", "Idle", { [.idle, .unknown].contains($0.activity.state) })
        ]
        let built = groups.enumerated().compactMap { order, group -> (order: Int, newest: Date?, section: Section)? in
            let (id, title, matches) = group
            let rows = sessions.filter(matches).sorted {
                let left = needsAttention($0, readAt: readAt[$0.id]), right = needsAttention($1, readAt: readAt[$1.id])
                if left != right { return left }
                return $0.activity.updatedAt == $1.activity.updatedAt ? $0.id < $1.id : $0.activity.updatedAt > $1.activity.updatedAt
            }
            let newest = rows.filter { needsAttention($0, readAt: readAt[$0.id]) }.map(\.activity.updatedAt).max()
            return rows.isEmpty ? nil : (order, newest, Section(id: id, title: title, sessions: rows))
        }
        // The newest item that still needs attention leads the list; sections without one keep the status order.
        return built.sorted { left, right in
            switch (left.newest, right.newest) {
            case let (l?, r?): return l == r ? left.order < right.order : l > r
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return left.order < right.order
            }
        }.map(\.section)
    }

    /// Keeps rows whose title, detail or status matches the query, including Hangul typed on a Latin layout.
    public static func filter(_ sections: [Section], query: String, describe: (TerminalSession) -> (title: String, detail: String)) -> [Section] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return sections }
        let search = KeyboardLayoutSearch(query: trimmed)
        return sections.compactMap { section in
            let rows = section.sessions.filter { session in
                let text = describe(session)
                return search.match(title: text.title, detail: text.detail + " " + section.title + " " + session.agent.rawValue) != nil
            }
            return rows.isEmpty ? nil : Section(id: section.id, title: section.title, sessions: rows)
        }
    }

    public static func needsAttention(_ session: TerminalSession, readAt: Date?) -> Bool {
        switch session.activity.state {
        case .blocked, .error: return true
        case .done: return readAt.map { $0 < session.activity.updatedAt } ?? true
        default: return false
        }
    }

    public static func isUnread(_ session: TerminalSession, readAt: Date?) -> Bool {
        guard [.done, .blocked, .error].contains(session.activity.state) else { return false }
        return readAt.map { $0 < session.activity.updatedAt } ?? true
    }
}

extension TerminalRuntime {
    public func acknowledgeActivity(_ id: String, updatedAt: Date) throws {
        _ = try acknowledgeActivities([id: updatedAt])
    }

    public func acknowledgeActivities(_ events: [String: Date]) throws -> [String: Date] {
        try transaction {
            let snapshot = try state()
            var acknowledged: [String: Date] = [:]
            for pane in snapshot.sessions where events[pane.id] == pane.activity.updatedAt &&
                ActivityInbox.isUnread(pane, readAt: snapshot.activityReadAt[pane.id]) {
                acknowledged[pane.id] = pane.activity.updatedAt
            }
            guard !acknowledged.isEmpty else { return [:] }
            try update { state in
                let ids = Set(state.sessions.map(\.id))
                state.activityReadAt = state.activityReadAt.filter { ids.contains($0.key) }
                state.activityReadAt.merge(acknowledged, uniquingKeysWith: max)
            }
            return acknowledged
        }
    }
}
