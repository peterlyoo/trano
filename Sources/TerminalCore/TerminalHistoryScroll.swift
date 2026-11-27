import Foundation

extension TerminalRuntime {
    public func scrollTerminalHistory(_ id: String, expectedPID: Int32, lines: Int) throws {
        guard UUID(uuidString: id) != nil, expectedPID > 0, (-1000...1000).contains(lines) else {
            throw TerminalError.invalid("Invalid terminal history scroll")
        }
        guard lines != 0 else { return }
        _ = try updateTerminalHistory(id, expectedPID: expectedPID, remoteLines: lines)
    }
    @discardableResult public func cancelTerminalHistory(_ id: String, expectedPID: Int32) throws -> Bool {
        try updateTerminalHistory(id, expectedPID: expectedPID, requiresInputReady: true)
    }
    private func updateTerminalHistory(_ id: String, expectedPID: Int32, requiresInputReady: Bool = false, remoteLines: Int? = nil) throws -> Bool {
        guard UUID(uuidString: id) != nil, expectedPID > 0 else { throw TerminalError.invalid("Invalid terminal history target") }
        let remote = try transaction { () -> RemoteTerminalHistoryTarget? in
            let snapshot = try state()
            guard let session = snapshot.sessions.first(where: { $0.id == id }), session.pid == expectedPID,
                  let reference = session.remote else { return nil }
            guard let host = snapshot.remoteHosts.first(where: { $0.id == reference.hostID }) else {
                throw TerminalError.invalid("Unknown remote history host")
            }
            return RemoteTerminalHistoryTarget(localID: id, localPID: expectedPID, reference: reference, host: host)
        }
        if let remote {
            try assertOutsideSharedTransaction()
            return try terminalHistoryRemoteCoordinator.update(remote, lines: requiresInputReady ? nil : remoteLines) {
                try self.transaction {
                    let snapshot = try self.state()
                    guard let session = snapshot.sessions.first(where: { $0.id == id }) else { return false }
                    return session.pid == remote.localPID && session.remote == remote.reference &&
                        snapshot.remoteHosts.first(where: { $0.id == remote.host.id }) == remote.host
                }
            }
        }
        if requiresInputReady { terminalHistoryRemoteCoordinator.discard(localID: id, expectedPID: expectedPID) }
        return try transaction {
            guard let session = try state().sessions.first(where: { $0.id == id }), session.remote == nil,
                  session.pid == expectedPID else { return false }
            // Local panes attach directly to their PTY, so the attached view owns scrollback; only identity remains to check.
            guard let pane = try host.pane(id), pane.alive, pane.pid == expectedPID else { return false }
            return requiresInputReady
        }
    }
}
