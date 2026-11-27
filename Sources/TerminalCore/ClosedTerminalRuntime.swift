import Foundation
import Darwin

extension TerminalRuntime {
    var closedTerminalStore: ClosedTerminalStore { ClosedTerminalStore(runtimeRoot: root) }

    public func isTerminalIntentionallyClosed(_ paneID: String) throws -> Bool {
        try transaction {
            let ledger = try closedTerminalStore.ledger()
            return ledger.retired.contains(paneID) || ledger.panes[paneID].map { $0.phase != .reopened } == true
        }
    }

    public func closedTerminalPaneSnapshot(_ paneID: String) throws -> ClosedPaneSnapshot? {
        try transaction { try closedTerminalStore.ledger().panes[paneID] }
    }

    func validateClosedTerminalLayoutMutation(from before: WorkspaceLayout, to after: WorkspaceLayout) throws {
        guard before != after else { return }
        for snapshot in try closedTerminalStore.ledger().panes.values where snapshot.phase == .closing || snapshot.phase == .restoring {
            let id = snapshot.pane.id
            guard let previous = before.tabs.first(where: { $0.panes.contains(id) }) else { continue }
            guard let next = after.tabs.first(where: { $0.panes.contains(id) }),
                  next.id == previous.id, next.workspaceID == previous.workspaceID,
                  before.workspaces.first(where: { $0.id == previous.workspaceID })?.closed == after.workspaces.first(where: { $0.id == next.workspaceID })?.closed else {
                throw TerminalError.invalid("This terminal is being closed or reopened. Retry after the operation finishes.")
            }
        }
    }

    func rememberTerminalShell(_ command: TerminalStartupCommand, paneID: String) throws {
        var ledger = try closedTerminalStore.ledger()
        ledger.shells[paneID] = command
        try closedTerminalStore.save(ledger)
    }

    func savedTerminalShell(_ id: String) throws -> TerminalStartupCommand? {
        try closedTerminalStore.ledger().shells[id]
    }

    public func closeTerminalPane(_ id: String, validate: ((RuntimeState) throws -> Void)? = nil) throws {
        try closeTerminals([.pane(id)], validate: validate)
    }

    public func closeTerminalTab(_ id: String, validate: ((RuntimeState) throws -> Void)? = nil) throws {
        try closeTerminals([.tab(id)], validate: validate)
    }

    public func closeOtherTerminalPanes(keeping id: String, validate: ((RuntimeState) throws -> Void)? = nil) throws {
        let targets = try transaction { () throws -> [TerminalCloseTarget] in
            let current = try state(); try validate?(current)
            guard let tab = current.layout.tabs.first(where: { $0.panes.contains(id) }) else { throw TerminalError.invalid("Pane is no longer attached") }
            return tab.panes.filter { $0 != id }.map(TerminalCloseTarget.pane)
        }
        try closeTerminals(targets, validate: validate)
    }

    public func closeOtherTerminalTabs(keeping id: String, validate: ((RuntimeState) throws -> Void)? = nil) throws {
        let targets = try transaction { () throws -> [TerminalCloseTarget] in
            let current = try state(); try validate?(current)
            guard let tab = current.layout.tabs.first(where: { $0.id == id }) else { throw TerminalError.invalid("Tab is no longer attached") }
            return current.layout.tabs.filter { $0.workspaceID == tab.workspaceID && $0.id != id }.map { .tab($0.id) }
        }
        try closeTerminals(targets, validate: validate)
    }

    public func closeTerminalTabs(beside id: String, side: TabSide, validate: ((RuntimeState) throws -> Void)? = nil) throws {
        let targets = try transaction { () throws -> [TerminalCloseTarget] in
            let current = try state(); try validate?(current)
            guard current.layout.tabs.contains(where: { $0.id == id }) else { throw TerminalError.invalid("Tab is no longer attached") }
            return current.layout.tabIDs(beside: id, side: side).map { .tab($0) }
        }
        try closeTerminals(targets, validate: validate)
    }

    private func closeTerminals(_ targets: [TerminalCloseTarget], validate: ((RuntimeState) throws -> Void)?) throws {
        try assertOutsideSharedTransaction()
        try closedTerminalStore.operation { try closeTerminalsUnderLease(targets, validate: validate) }
    }

    private func closeTerminalsUnderLease(_ targets: [TerminalCloseTarget], validate: ((RuntimeState) throws -> Void)?) throws {
        guard !targets.isEmpty else { return }
        try assertOutsideSharedTransaction()
        let operation = UUID().uuidString.lowercased()
        let before = try transaction { () throws -> RuntimeState in
            let current = try state(); try validate?(current)
            for target in targets { _ = try target.panes(in: current.layout) }
            return current
        }
        let ids = try targets.flatMap { try $0.panes(in: before.layout) }
        let previousLedger = try transaction { try closedTerminalStore.ledger() }
        var snapshots: [ClosedPaneSnapshot] = []
        var stopped: Set<String> = []
        var attempted: Set<String> = []
        do {
        for id in ids {
            let prepared = try transaction { try prepareLocalClose(id, operation: operation, before: before) }
            var snapshot = prepared
            if snapshot.pane.remote != nil, snapshot.remoteSnapshot == nil {
                snapshot.remoteSnapshot = try prepareRemoteTerminalClose(pane: snapshot.pane, operationID: snapshot.archiveID)
            }
            snapshots.append(snapshot)
        }
        try transaction {
            let current = try state(); try validate?(current)
            try validateCloseTargets(targets, before: before, current: current)
            for snapshot in snapshots { try validateClosingPane(snapshot, state: current) }
            var ledger = try closedTerminalStore.ledger()
            for snapshot in snapshots { ledger.panes[snapshot.pane.id] = snapshot; ledger.retired.remove(snapshot.pane.id) }
            try closedTerminalStore.save(ledger)
        }
            for snapshot in snapshots {
                var witnesses = snapshot.processWitnesses
                var processStopCompleted = false
                defer {
                    if stopped.contains(snapshot.pane.id), !processStopCompleted { try? ClosedTerminalProcesses.stop(witnesses) }
                }
                try transaction {
                    let current = try state(); try validate?(current)
                    try validateCloseTargets(targets, before: before, current: current)
                    try validateClosingPane(snapshot, state: current)
                }
                if let remote = snapshot.remoteSnapshot {
                    attempted.insert(snapshot.pane.id)
                    _ = try commitRemoteTerminalClose(pane: snapshot.pane, snapshot: remote)
                }
                try transaction {
                    let current = try state(); try validate?(current)
                    try validateCloseTargets(targets, before: before, current: current)
                    try validateClosingPane(snapshot, state: current)
                    for witness in try ClosedTerminalProcesses.captureVerified(pane: snapshot.pane, launch: snapshot.launch) where !witnesses.contains(witness) { witnesses.append(witness) }
                    var capturedLedger = try closedTerminalStore.ledger()
                    capturedLedger.panes[snapshot.pane.id]?.processWitnesses = witnesses
                    try closedTerminalStore.save(capturedLedger)
                    attempted.insert(snapshot.pane.id)
                    try stopClosedPaneBackend(snapshot)
                    stopped.insert(snapshot.pane.id)
                    var ledger = try closedTerminalStore.ledger()
                    ledger.panes[snapshot.pane.id]?.phase = .closed
                    try closedTerminalStore.save(ledger)
                    try update { state in
                        if let index = state.sessions.firstIndex(where: { $0.id == snapshot.pane.id }) {
                            state.sessions[index].alive = false
                        }
                        state.invalidateFollowUps(paneID: snapshot.pane.id, message: "This terminal was closed. Review queued input after reopening it.")
                        state.followUpTurns.removeAll { $0.paneID == snapshot.pane.id }
                        state.followUpPasteStates.removeAll { $0.paneID == snapshot.pane.id }
                    }
                }
                try ClosedTerminalProcesses.stop(witnesses)
                processStopCompleted = true
            }
            try update { state in
                try validateCloseTargets(targets, before: before, current: state)
                for snapshot in snapshots { try validateClosingPane(snapshot, state: state) }
                for target in targets { target.apply(to: &state.layout) }
            }
            try pruneClosedTerminalArchives()
        } catch {
            let failure = error
            var reconciliationErrors: [String] = []
            for snapshot in snapshots {
                guard let remote = snapshot.remoteSnapshot else { continue }
                do {
                    if !attempted.contains(snapshot.pane.id) { try discardRemotePreparedTerminal(pane: snapshot.pane, snapshot: remote) }
                    else if try reconcileRemoteClose(snapshot) { stopped.insert(snapshot.pane.id) }
                } catch { reconciliationErrors.append(error.localizedDescription) }
            }
            do { try transaction {
                var ledger = try closedTerminalStore.ledger()
                let live = try list()
                for snapshot in snapshots where !stopped.contains(snapshot.pane.id) {
                    let id = snapshot.pane.id
                    guard ledger.panes[id]?.archiveID == snapshot.archiveID else { continue }
                    if !attempted.contains(id) { ledger.panes[id] = previousLedger.panes[id] }
                    else if snapshot.pane.remote == nil, live.contains(where: { $0.id == id && $0.alive }) {
                        ledger.panes.removeValue(forKey: id)
                    }
                }
                try closedTerminalStore.save(ledger)
            } } catch { reconciliationErrors.append(error.localizedDescription) }
            // An earlier pane may already be stopped; keep its archive and undo entry.
            do { try update { state in
                for snapshot in snapshots where stopped.contains(snapshot.pane.id) {
                    guard let tab = state.layout.tabs.first(where: { $0.panes.contains(snapshot.pane.id) }),
                          tab.id == snapshot.tab.id, tab.workspaceID == snapshot.tab.workspaceID,
                          state.sessions.first(where: { $0.id == snapshot.pane.id })?.pid == snapshot.pane.pid else { continue }
                    state.layout.closePane(snapshot.pane.id)
                }
            } } catch { reconciliationErrors.append(error.localizedDescription) }
            if !reconciliationErrors.isEmpty {
                throw TerminalError.runtime(failure.localizedDescription + " Saved state was retained; reconciliation also failed: " + reconciliationErrors.joined(separator: "; "))
            }
            throw failure
        }
    }

    @discardableResult func reconcileRemoteClose(_ snapshot: ClosedPaneSnapshot) throws -> Bool {
        guard let remote = snapshot.remoteSnapshot else { return false }
        try assertOutsideSharedTransaction()
        let status = try remoteTerminalCloseStatus(pane: snapshot.pane, operationID: remote.operationID)
        if status.phase == "prepared" {
            try discardRemotePreparedTerminal(pane: snapshot.pane, snapshot: remote)
            try transaction {
                var ledger = try closedTerminalStore.ledger()
                if ledger.panes[snapshot.pane.id]?.archiveID == snapshot.archiveID { ledger.panes.removeValue(forKey: snapshot.pane.id) }
                try closedTerminalStore.save(ledger)
            }
            return false
        }
        guard ["closed", "reopening", "reopened"].contains(status.phase) else {
            throw TerminalError.invalid("Remote close is still pending; saved state was retained for retry")
        }
        try transaction {
            let current = try state()
            try validateClosingPane(snapshot, state: current)
            try stopClosedPaneBackend(snapshot)
            var ledger = try closedTerminalStore.ledger()
            ledger.panes[snapshot.pane.id]?.phase = .closed
            try closedTerminalStore.save(ledger)
            try update { state in
                if let index = state.sessions.firstIndex(where: { $0.id == snapshot.pane.id }) { state.sessions[index].alive = false }
            }
        }
        try ClosedTerminalProcesses.stop(snapshot.processWitnesses)
        return true
    }

    private func prepareLocalClose(_ id: String, operation: String, before: RuntimeState) throws -> ClosedPaneSnapshot {
        guard let original = before.sessions.first(where: { $0.id == id }),
              let tab = before.layout.tabs.first(where: { $0.panes.contains(id) }) else { throw TerminalError.invalid("Terminal is no longer attached") }
        if let existing = try closedTerminalPaneSnapshot(id), existing.phase == .closed || existing.phase == .closing { return existing }
        let current = try state()
        guard current.sessions.contains(where: { $0.id == id && $0.pid == original.pid && $0.remote == original.remote }) else { throw TerminalError.invalid("Terminal changed before close") }
        var pane = try list().first(where: { $0.id == id }) ?? original
        let launch = current.agentLaunches.first { $0.paneID == id && $0.lifecycle == .active }
        let shell: TerminalStartupCommand
        let screen: String
        let history: ShellHistoryArchive
        if pane.remote == nil {
            shell = try closedShellSelection(pane)
            if pane.alive {
                pane.cwd = try workingDirectory(id)
                var lines = try host.capture(id, lines: 10_000, escapes: true).split(separator: "\n", omittingEmptySubsequences: false)
                var count = lines.reduce(0) { $0 + $1.utf8.count + 1 }
                while count > ScrollbackStore.maximumBytes, !lines.isEmpty { count -= lines.removeFirst().utf8.count + 1 }
                screen = lines.joined(separator: "\n")
            } else { screen = try ScrollbackStore(runtimeRoot: root).replay(paneID: id) }
            history = try ShellHistoryStore(runtimeRoot: root).capture(paneID: id, command: shell)
        } else {
            shell = TerminalStartupCommand(executable: "/usr/bin/ssh")
            screen = ""
            history = try ShellHistoryStore(runtimeRoot: root, home: root).capture(paneID: id, command: shell)
        }
        let archiveID = UUID().uuidString.lowercased()
        try closedTerminalStore.save(ClosedPaneContents(screen: ClosedTerminalScreen.sanitized(screen), history: history), id: archiveID)
        return ClosedPaneSnapshot(pane: pane, shell: shell, launch: launch,
            processWitnesses: try ClosedTerminalProcesses.captureVerified(pane: pane, launch: launch), archiveID: archiveID,
            operationID: operation, phase: .closing, tab: tab,
            workspace: before.layout.workspaces.first { $0.id == tab.workspaceID }, closedAt: Date(), remoteSnapshot: nil)
    }

    private func validateCloseTargets(_ targets: [TerminalCloseTarget], before: RuntimeState, current: RuntimeState) throws {
        for target in targets {
            let ids = try target.panes(in: before.layout)
            guard try ids == target.panes(in: current.layout) else { throw TerminalError.invalid("Terminal layout changed before close") }
            for id in ids {
                guard let original = before.layout.tabs.first(where: { $0.panes.contains(id) }),
                      let now = current.layout.tabs.first(where: { $0.panes.contains(id) }),
                      original.id == now.id, original.workspaceID == now.workspaceID else {
                    throw TerminalError.invalid("Terminal moved before close")
                }
            }
        }
    }

    private func validateClosingPane(_ snapshot: ClosedPaneSnapshot, state: RuntimeState) throws {
        let id = snapshot.pane.id
        guard let current = state.sessions.first(where: { $0.id == id }), current.remote == snapshot.pane.remote,
              current.pid == snapshot.pane.pid else { throw TerminalError.invalid("Terminal process changed before close") }
        if let live = try list().first(where: { $0.id == id }), live.alive, live.pid != snapshot.pane.pid {
            throw TerminalError.invalid("Terminal process changed before close")
        }
        let launch = state.agentLaunches.first { $0.paneID == id && $0.lifecycle == .active }
        if let launch {
            guard let captured = snapshot.launch, launch.id == captured.id,
                  ClosedAgentRecovery.sameIdentity(launch, captured) else { throw TerminalError.invalid("Agent conversation changed before close") }
        }
        for witness in snapshot.processWitnesses {
            if let current = SupervisorProcessIdentity.read(witness.pid), current != witness { throw TerminalError.invalid("Process identity changed before close") }
        }
    }

    func stopClosedPaneBackend(_ snapshot: ClosedPaneSnapshot) throws {
        try host.kill(snapshot.pane.id)
        guard try host.pane(snapshot.pane.id) == nil else { throw TerminalError.runtime("Terminal did not stop; its saved state was retained") }
    }

    private func closedShellSelection(_ pane: TerminalSession) throws -> TerminalStartupCommand {
        if let saved = try savedTerminalShell(pane.id), ClosedTerminalShell.isShell(saved.executable) { return ClosedTerminalShell.safe(saved) }
        if pane.alive {
            var buffer = [CChar](repeating: 0, count: 4096)
            if proc_pidpath(pane.pid, &buffer, UInt32(buffer.count)) > 0 {
                let path = String(cString: buffer)
                if ClosedTerminalShell.isShell(path) { return TerminalStartupCommand(executable: path, arguments: ["-l"]) }
            }
            let words = try host.pane(pane.id)?.argv ?? []
            if let path = words.first, ClosedTerminalShell.isShell(path) { return ClosedTerminalShell.safe(TerminalStartupCommand(executable: path, arguments: Array(words.dropFirst()))) }
            throw TerminalError.invalid("Cannot identify this terminal's original shell; close was cancelled")
        }
        let words = (try? host.pane(pane.id)?.argv) ?? []
        if let path = words.first, ClosedTerminalShell.isShell(path) { return ClosedTerminalShell.safe(TerminalStartupCommand(executable: path, arguments: Array(words.dropFirst()))) }
        throw TerminalError.invalid("The original shell is unavailable; close was cancelled to preserve this terminal's state")
    }

    func pruneClosedTerminalArchives() throws {
        try transaction {
            let layout = try state().layout
            let retained = Set((layout.tabs + layout.closedTabs).flatMap(\.panes))
            var ledger = try closedTerminalStore.ledger()
            for (id, snapshot) in ledger.panes where !retained.contains(id) && (snapshot.phase == .closed || snapshot.phase == .reopened) {
                if snapshot.phase == .closed { ledger.retired.insert(id) }
                ledger.panes.removeValue(forKey: id)
            }
            try closedTerminalStore.save(ledger)
            try closedTerminalStore.prune(retaining: Set(ledger.panes.values.map(\.archiveID)))
        }
    }
}

private enum TerminalCloseTarget {
    case pane(String), tab(String)
    func panes(in layout: WorkspaceLayout) throws -> [String] {
        switch self {
        case .pane(let id):
            guard layout.tabs.contains(where: { $0.panes.contains(id) }) else { throw TerminalError.invalid("Pane is no longer attached") }
            return [id]
        case .tab(let id):
            guard let tab = layout.tabs.first(where: { $0.id == id }) else { throw TerminalError.invalid("Tab is no longer attached") }
            return tab.panes
        }
    }
    func apply(to layout: inout WorkspaceLayout) {
        switch self { case .pane(let id): layout.closePane(id); case .tab(let id): layout.closeTab(id) }
    }
}

public enum ClosedTerminalShell {
    public static func isShell(_ path: String) -> Bool {
        path.hasPrefix("/") && ["zsh", "bash", "fish", "sh", "dash", "ksh", "tcsh", "csh"].contains(URL(fileURLWithPath: path).lastPathComponent)
    }
    public static func safe(_ command: TerminalStartupCommand) -> TerminalStartupCommand {
        guard isShell(command.executable) else { return TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"]) }
        let flags = Set(["-l", "-i", "-il", "-li", "--login", "--interactive"])
        return TerminalStartupCommand(executable: command.executable, arguments: command.arguments.allSatisfy(flags.contains) ? command.arguments : ["-l"])
    }
}
