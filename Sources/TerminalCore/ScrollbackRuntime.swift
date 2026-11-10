import Foundation

extension TerminalRuntime {
    public func snapshotScrollback(_ paneID: String, expectedPID: Int32? = nil) throws {
        let state = try state()
        guard state.settings.persistScrollback, state.sessions.contains(where: { $0.id == paneID && $0.remote == nil }) else { return }
        if let expectedPID, state.sessions.first(where: { $0.id == paneID })?.pid != expectedPID { return }
        let captured = try capture(paneID, lines: min(10_000, state.settings.scrollbackLines))
        try transaction {
            let current = try self.state()
            guard current.settings.persistScrollback, current.sessions.contains(where: { $0.id == paneID }) else { return }
            if let expectedPID, current.sessions.first(where: { $0.id == paneID })?.pid != expectedPID { return }
            try ScrollbackStore(runtimeRoot: root).save(paneID: paneID, text: captured)
        }
    }

    public func setScrollbackPersistence(_ enabled: Bool) throws {
        try transaction {
            try update { $0.settings.persistScrollback = enabled }
            if !enabled { try ScrollbackStore(runtimeRoot: root).removeAll() }
        }
    }

    public func replayScrollback(_ paneID: String) throws -> String {
        try transaction {
            let state = try state()
            guard state.settings.persistScrollback, state.sessions.contains(where: { $0.id == paneID }) else { return "" }
            return try ScrollbackStore(runtimeRoot: root).replay(paneID: paneID)
        }
    }

    public func scrollbackMetadata() throws -> [ScrollbackMetadata] {
        try state().sessions.compactMap { try ScrollbackStore(runtimeRoot: root).metadata(paneID: $0.id) }
    }
}
