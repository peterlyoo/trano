import Foundation

extension TerminalRuntime {
    public func terminalPreferences() throws -> TerminalPreferences {
        try transaction { try TerminalPreferenceStore(root: root).load() }
    }
    @discardableResult
    public func saveTerminalPreferences(_ draft: TerminalPreferences,
                                       from baseline: TerminalPreferences) throws -> TerminalPreferences {
        try transaction { try TerminalPreferenceStore(root: root).mergeAndSave(draft, from: baseline) }
    }
    public func recentTerminalPaths(hostID: String? = nil) throws -> [TerminalRecentPath] {
        try transaction {
            guard try terminalPreferences().showRecentPaths else { return [] }
            return try TerminalPathHistoryStore(root: root).load().recent(hostID: hostID)
        }
    }
    public func recordTerminalPath(_ path: String, hostID: String? = nil, at: Date = Date()) throws {
        try transaction {
            guard try terminalPreferences().showRecentPaths else { return }
            let store = TerminalPathHistoryStore(root: root)
            var history = try store.load()
            try history.record(path, hostID: hostID, at: at)
            try store.save(history)
        }
    }
    public func clearTerminalPaths(hostID: String? = nil) throws {
        try transaction {
            let store = TerminalPathHistoryStore(root: root)
            var retained = TerminalPathHistory()
            for entry in try store.load().entries where entry.hostID != hostID {
                try retained.record(entry.path, hostID: entry.hostID, at: entry.usedAt)
            }
            try store.save(retained)
        }
    }
    public func clearAllTerminalPaths() throws {
        try transaction { try TerminalPathHistoryStore(root: root).save(TerminalPathHistory()) }
    }
}
