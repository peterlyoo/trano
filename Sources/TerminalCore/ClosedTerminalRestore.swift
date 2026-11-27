import Foundation

extension TerminalRuntime {
    public func restoreClosedTerminal() throws {
        try assertOutsideSharedTransaction()
        try closedTerminalStore.operation { try restoreClosedTerminalUnderLease() }
    }

    private func restoreClosedTerminalUnderLease() throws {
        let plan = try transaction { () throws -> (WorkspaceLayout, WorkspaceLayout, [ClosedPaneSnapshot]) in
            let before = try state().layout
            var candidate = before
            let ledger = try closedTerminalStore.ledger()
            let pending = ledger.panes.values.filter { item in
                item.phase != .reopened && before.tabs.contains(where: { $0.panes.contains(item.pane.id) })
            }.max(by: { $0.closedAt < $1.closedAt })
            if let pending, before.closedTabs.last?.panes.contains(pending.pane.id) != true {
                try candidate.focusPane(pending.pane.id)
            } else { candidate.restoreTab() }
            let panes = candidate.tabs.first(where: { $0.id == candidate.selectedTabID })?.panes ?? []
            return (before, candidate, panes.compactMap { ledger.panes[$0] }.filter { $0.phase != .reopened })
        }
        if plan.0 == plan.1, plan.2.isEmpty { return }
        var failures: [String] = []
        for snapshot in plan.2 {
            do {
                let created = try restoreClosedPane(snapshot)
                if created, snapshot.pane.remote == nil, snapshot.launch != nil {
                    do { try scheduleClosedAgentResume(snapshot) }
                    catch { try setRecovery(snapshot.pane.id, status: .needsAttention, message: error.localizedDescription) }
                }
            } catch {
                failures.append(error.localizedDescription)
                try? setRecovery(snapshot.pane.id, status: .failed, message: error.localizedDescription)
            }
        }
        try update { state in
            guard state.layout == plan.0 else { throw TerminalError.invalid("Layout changed during reopen. Saved terminal state was retained; retry reopen.") }
            state.layout = plan.1
            if !failures.isEmpty { state.layout.closedTabs = plan.0.closedTabs }
        }
        if let failure = failures.first { throw TerminalError.runtime(failure) }
    }

    private func restoreClosedPane(_ snapshot: ClosedPaneSnapshot) throws -> Bool {
        let id = snapshot.pane.id
        if snapshot.pane.remote != nil, snapshot.phase == .closing {
            guard try reconcileRemoteClose(snapshot) else { return false }
        }
        let shouldRestore = try transaction { () throws -> Bool in
            var ledger = try closedTerminalStore.ledger()
            guard let current = ledger.panes[id], current.archiveID == snapshot.archiveID else { throw TerminalError.invalid("Saved terminal changed during reopen") }
            if current.phase == .reopened { return false }
            if let live = try list().first(where: { $0.id == id }), live.alive {
                guard current.phase == .restoring,
                      snapshot.processWitnesses.allSatisfy(ClosedAgentRecovery.processHasExited) else {
                    throw TerminalError.invalid("Original terminal is still stopping. Retry reopen after it exits.")
                }
                let marker = try host.environment(id, key: "TRANO_REOPEN_ARCHIVE")
                guard marker == snapshot.archiveID else {
                    throw TerminalError.invalid("A different terminal process already owns this pane")
                }
                ledger.panes[id]?.restoredPID = live.pid
                ledger.panes[id]?.restoredProcess = SupervisorProcessIdentity.read(live.pid)
                try closedTerminalStore.save(ledger)
                try update { state in
                    if let index = state.sessions.firstIndex(where: { $0.id == id }) { state.sessions[index].pid = live.pid; state.sessions[index].alive = true }
                }
                return true
            }
            guard snapshot.processWitnesses.allSatisfy(ClosedAgentRecovery.processHasExited) else {
                throw TerminalError.invalid("The previous terminal process is still exiting. Retry reopen shortly.")
            }
            _ = try closedTerminalStore.contents(id: snapshot.archiveID)
            ledger.panes[id]?.phase = .restoring
            try closedTerminalStore.save(ledger)
            return true
        }
        guard shouldRestore else { return false }
        var remoteSession: TerminalSession?
        if let remote = snapshot.remoteSnapshot {
            remoteSession = try reopenRemoteClosedTerminal(pane: snapshot.pane, snapshot: remote)
        }
        return try transaction {
            var ledger = try closedTerminalStore.ledger()
            guard let current = ledger.panes[id], current.archiveID == snapshot.archiveID,
                  current.phase == .restoring else { throw TerminalError.invalid("Reopen operation changed") }
            if let live = try list().first(where: { $0.id == id }), live.alive {
                guard current.restoredPID == live.pid else { throw TerminalError.invalid("A different terminal process owns this reopened pane") }
                ledger.panes[id]?.phase = .reopened
                try closedTerminalStore.save(ledger)
                return true
            }
            try host.kill(id)
            try update { state in
                if !state.sessions.contains(where: { $0.id == id }) { state.sessions.append(snapshot.pane) }
            }
            let pane: TerminalSession
            if let remote = snapshot.pane.remote, let remoteSession {
                guard remote.sessionID == remoteSession.id else { throw TerminalError.invalid("Remote helper returned a different terminal") }
                let host = try remoteHost(remote.hostID)
                pane = try create(title: snapshot.pane.title, cwd: FileManager.default.homeDirectoryForCurrentUser.path,
                    shell: "/usr/bin/ssh", arguments: RemoteClient(host: host).attachArguments(sessionID: remote.sessionID),
                    restoringID: id, closedArchiveID: snapshot.archiveID)
                try update { state in
                    if let index = state.sessions.firstIndex(where: { $0.id == id }) { state.sessions[index].cwd = remoteSession.cwd }
                }
            } else {
                let contents = try closedTerminalStore.contents(id: snapshot.archiveID)
                try ShellHistoryStore(runtimeRoot: root).restore(contents.history, paneID: id)
                pane = try create(title: snapshot.pane.title, cwd: snapshot.pane.cwd, shell: snapshot.shell.executable,
                    arguments: snapshot.shell.arguments, restoringID: id, closedArchiveID: snapshot.archiveID)
            }
            ledger = try closedTerminalStore.ledger()
            ledger.panes[id]?.phase = .reopened
            ledger.retired.remove(id)
            try closedTerminalStore.save(ledger)
            try update { state in
                if let index = state.sessions.firstIndex(where: { $0.id == id }) {
                    state.sessions[index].pid = pane.pid
                    state.sessions[index].alive = true
                    state.sessions[index].agent = .shell
                    state.sessions[index].activity = Activity()
                    state.sessions[index].agentTasks = nil
                    state.sessions[index].terminalTitle = nil
                    state.sessions[index].foregroundProgram = nil
                }
            }
            try setRecovery(id, status: .restored, message: "Terminal state restored in a new shell")
            return true
        }
    }
}
