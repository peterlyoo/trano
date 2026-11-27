import Foundation
import Darwin

enum ClosedAgentRecovery {
    static func sameIdentity(_ lhs: AgentLaunch, _ rhs: AgentLaunch) -> Bool {
        lhs.paneID == rhs.paneID && lhs.provider == rhs.provider && lhs.providerSessionID == rhs.providerSessionID &&
        lhs.cwd == rhs.cwd && lhs.accountID == rhs.accountID && lhs.configurationRoot == rhs.configurationRoot &&
        lhs.organizationBindingID == rhs.organizationBindingID
    }

    static func sameDirectory(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.contains("\0"), !rhs.contains("\0") else { return false }
        var first = stat(), second = stat()
        guard stat(lhs, &first) == 0, stat(rhs, &second) == 0,
              first.st_mode & S_IFMT == S_IFDIR, second.st_mode & S_IFMT == S_IFDIR else { return false }
        return first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    static func seed(source: AgentLaunch, launches: [AgentLaunch], bootID: String) throws -> AgentLaunch? {
        guard source.provider != .shell, let conversation = source.providerSessionID,
              UUID(uuidString: conversation) != nil else {
            throw TerminalError.invalid("The closed terminal has no verified agent conversation to resume")
        }
        guard !launches.contains(where: {
            $0.paneID != source.paneID && $0.provider == source.provider &&
            $0.providerSessionID == conversation && $0.lifecycle == .active
        }) else { throw TerminalError.invalid("This conversation is already bound to another pane") }
        let current = launches.filter { $0.paneID == source.paneID }
        guard current.count <= 1 else { throw TerminalError.invalid("The reopened pane has ambiguous agent identity") }
        if let current = current.first {
            guard sameIdentity(current, source) else { throw TerminalError.invalid("The pane's agent conversation changed before reopen") }
            if current.id != source.id { return nil }
        }
        return AgentLaunch(paneID: source.paneID, provider: source.provider, providerSessionID: conversation,
            cwd: source.cwd, accountID: source.accountID, configurationRoot: source.configurationRoot,
            organizationBindingID: source.organizationBindingID, bootID: bootID, processID: nil, providerPID: nil)
    }

    static func processHasExited(_ expected: SupervisorProcessIdentity) -> Bool {
        guard expected.pid > 1, expected.ownerUID == getuid(), expected.startedAtSeconds > 0,
              expected.startedAtMicroseconds < 1_000_000 else { return false }
        var info = proc_bsdinfo()
        errno = 0
        let count = proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if count <= 0 { return errno == ESRCH }
        guard count == MemoryLayout<proc_bsdinfo>.size, info.pbi_pid == UInt32(expected.pid) else { return false }
        if info.pbi_start_tvsec != expected.startedAtSeconds || info.pbi_start_tvusec != expected.startedAtMicroseconds { return true }
        return info.pbi_uid == expected.ownerUID && info.pbi_status == 5
    }
}

extension TerminalRuntime {
    func validateAgentRecoveryIdentity(_ launch: AgentLaunch) throws {
        guard launch.provider != .shell, let id = launch.providerSessionID, UUID(uuidString: id) != nil else {
            throw TerminalError.invalid("No verified conversation ID. Review the Trano hook in the provider before the next launch.")
        }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: launch.cwd, isDirectory: &directory), directory.boolValue else {
            throw TerminalError.invalid("Original working directory is missing: " + launch.cwd)
        }
        guard FileManager.default.fileExists(atPath: launch.configurationRoot, isDirectory: &directory), directory.boolValue else {
            throw TerminalError.invalid("Original agent configuration directory is missing")
        }
        if let accountID = launch.accountID {
            guard let account = try state().accounts.first(where: { $0.id == accountID }), account.enabled,
                  account.provider == launch.provider else { throw TerminalError.invalid("The original agent account is unavailable or changed") }
            guard try accountRoot(accountID).path == launch.configurationRoot else {
                throw TerminalError.invalid("The original agent account storage changed")
            }
            guard account.organizationUsageBindingID == launch.organizationBindingID else {
                throw TerminalError.invalid("The original agent account's organization changed")
            }
        } else if launch.organizationBindingID != nil {
            throw TerminalError.invalid("The original organization has no managed account binding")
        }
    }

    public func scheduleClosedAgentResume(_ snapshot: ClosedPaneSnapshot) throws {
        guard let source = snapshot.launch else { return }
        try transaction {
            guard let retained = try closedTerminalPaneSnapshot(snapshot.pane.id),
                  retained.archiveID == snapshot.archiveID, retained.phase == .reopened,
                  retained.launch == source, source.paneID == snapshot.pane.id,
                  !(try isTerminalIntentionallyClosed(snapshot.pane.id)) else {
                throw TerminalError.invalid("The closed terminal changed before agent resume")
            }
            guard retained.processWitnesses.allSatisfy(ClosedAgentRecovery.processHasExited) else {
                throw TerminalError.invalid("The original terminal's processes are still exiting. Retry reopen after they stop.")
            }
            let state = try state()
            guard let pane = state.sessions.first(where: { $0.id == source.paneID && $0.remote == nil }),
                  let live = try list().first(where: { $0.id == pane.id }), live.alive, live.pid == pane.pid else {
                throw TerminalError.invalid("The reopened shell changed before agent resume")
            }
            try validateAgentRecoveryIdentity(source)
            guard let seed = try ClosedAgentRecovery.seed(source: source, launches: state.agentLaunches,
                                                         bootID: Self.bootIdentity()) else { return }
            guard let helperExecutable, FileManager.default.isExecutableFile(atPath: helperExecutable) else {
                throw TerminalError.runtime("The bundled trano CLI is required to resume an agent")
            }
            try update { state in
                state.agentLaunches.removeAll { $0.paneID == pane.id }
                state.agentLaunches.append(seed)
                state.recoveryResults.removeAll { $0.paneID == pane.id }
                state.recoveryResults.append(RecoveryResult(paneID: pane.id, status: .restoring,
                    message: "Resuming " + seed.provider.rawValue + " conversation"))
            }
            do {
                try send(pane.id, text: [helperExecutable, "recovery", "resume", pane.id, seed.id]
                    .map(ShellQuote.quote).joined(separator: " "), enter: true)
            } catch {
                try? setRecovery(pane.id, status: .failed,
                    message: "The saved conversation was not confirmed. Review the reopened shell before retrying. " + error.localizedDescription)
                throw error
            }
        }
    }
}
