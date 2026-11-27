import Foundation
import Darwin

public enum AgentLifecycle: String, Codable { case active, exited }
public enum RecoveryStatus: String, Codable { case live, restoring, restored, needsAttention = "needs_attention", failed }
public struct AgentLaunch: Codable, Identifiable, Equatable {
    public var id = UUID().uuidString.lowercased()
    public let paneID: String
    public let provider: AgentKind
    public var providerSessionID: String?
    public var cwd: String
    public let accountID: String?
    public let configurationRoot: String
    public var organizationBindingID: String? = nil
    public let bootID: String
    public var processID: Int32?
    public var providerPID: Int32?
    public var lifecycle = AgentLifecycle.active
    public var updatedAt = Date()
}
public struct RecoveryResult: Codable, Identifiable {
    public var id: String { paneID }
    public let paneID: String
    public var status: RecoveryStatus
    public var message: String
    public var updatedAt = Date()
}

// Mirrors Claude Code 2.1.331 API retry timing: min(32 s, 500 ms * 2^(attempt-1)) plus 0-25% proportional jitter, 10 retries.
public enum RecoveryResumeBackoff {
    public static let maximumRetries = 10
    public static let baseMilliseconds = 500.0
    public static let capMilliseconds = 32_000.0
    public static let jitterRatio = 0.25
    public static let failurePrefix = "Provider exited before confirming conversation resume"

    public static func delay(attempt: Int, random: () -> Double = { Double.random(in: 0..<1) }) -> TimeInterval {
        let exponent = Double(max(attempt, 1) - 1)
        let base = min(capMilliseconds, baseMilliseconds * pow(2, exponent))
        return (base + random() * jitterRatio * base).rounded() / 1000
    }
}

public enum AgentInvocation {
    public static func isInteractive(_ arguments: [String], provider: AgentKind) -> Bool {
        let commands: Set<String> = provider == .claude ? ["auth", "plugin", "plugins", "mcp", "doctor", "update", "install", "setup-token"] : ["exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server", "completion", "doctor", "debug", "features", "update"]
        let valued: Set<String> = ["--model", "-m", "--profile", "--settings", "--mcp-config", "--plugin-dir", "--config", "-c", "--resume", "-r", "--session-id", "--permission-mode", "--allowedTools", "--disallowedTools", "--tools", "--system-prompt", "--append-system-prompt", "--agent", "--effort", "--output-format", "--input-format", "--add-dir", "--sandbox", "-s", "--ask-for-approval", "-a", "--cd", "-C", "--image", "-i", "--enable", "--disable"]
        var args = arguments
        if args.first == provider.rawValue { args.removeFirst() }
        var index = 0
        while index < args.count {
            let arg = args[index]
            if arg == "--" { return true }
            if ["--help", "-h", "--version", "-v"].contains(arg) { return false }
            if provider == .claude && ["--print", "-p", "--bare"].contains(arg) { return false }
            if valued.contains(arg) { index += 2; continue }
            if arg.hasPrefix("-") { index += 1; continue }
            return !commands.contains(arg)
        }
        return true
    }
}

extension TerminalRuntime {
    public static func bootIdentity() throws -> String {
        var boot = timeval(), size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0 else { throw TerminalError.runtime("Cannot determine system boot identity") }
        return "\(boot.tv_sec).\(boot.tv_usec)"
    }

    public func beginAgentLaunch(paneID: String, provider: AgentKind, cwd: String, accountID: String? = nil,
                                 configurationRoot: String? = nil, resume: AgentLaunch? = nil,
                                 organizationAuthorization: AccountOrganizationAuthorization? = nil, twinTicket: TwinLaunchTicket? = nil) throws -> AgentLaunch {
        guard provider != .shell, cwd.hasPrefix("/"), !cwd.contains("\0"), !cwd.contains("\n") else { throw TerminalError.invalid("Invalid agent launch metadata") }
        if let organizationAuthorization { try revalidateAccountOrganizationAuthorization(organizationAuthorization, cwd: cwd) }
        let boot = try Self.bootIdentity()
        if let twinTicket { try validateTwinBootstrap(ticket: twinTicket, paneID: paneID, provider: provider, cwd: cwd) }
        let config = try twinTicket?.configurationRoot ?? accountID.map { try accountRoot($0).path } ?? configurationRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(provider == .claude ? ".claude" : ".codex").path
        return try transaction {
            let state = try state()
            guard state.sessions.contains(where: { $0.id == paneID && $0.remote == nil }) else { throw TerminalError.invalid("Unknown local pane") }
            guard !(try isTerminalIntentionallyClosed(paneID)) else { throw TerminalError.invalid("Reopen this closed terminal before launching an agent") }
            if let accountID, !state.accounts.contains(where: { $0.id == accountID && $0.provider == provider }) { throw TerminalError.invalid("Account provider does not match the agent") }
            if let accountID {
                if let organizationAuthorization {
                    guard organizationAuthorization.accountID == accountID else { throw TerminalError.invalid("Organization authorization belongs to another account") }
                    try validateAccountOrganizationAuthorization(organizationAuthorization, cwd: cwd)
                } else if state.accounts.first(where: { $0.id == accountID })?.organization?.selection != nil {
                    throw TerminalError.invalid("Verify this profile's organization before launching the agent")
                }
            }
            if let previous = state.agentLaunches.first(where: { $0.paneID == paneID }), previous.lifecycle == .active, previous.bootID == boot, let pid = previous.processID, kill(pid, 0) == 0 {
                throw TerminalError.invalid("This pane already has an active agent")
            }
            if let resume {
                guard let current = state.agentLaunches.first(where: { $0.id == resume.id && $0.paneID == paneID && $0.lifecycle == .active }),
                      ClosedAgentRecovery.sameIdentity(current, resume), provider == resume.provider,
                      accountID == resume.accountID, config == resume.configurationRoot,
                      ClosedAgentRecovery.sameDirectory(cwd, resume.cwd) else {
                    throw TerminalError.invalid("Recovery launch changed; refresh before retrying")
                }
                try validateAgentRecoveryIdentity(resume)
            }
            var launch = AgentLaunch(paneID: paneID, provider: provider, providerSessionID: resume?.providerSessionID, cwd: resume?.cwd ?? cwd,
                                     accountID: accountID, configurationRoot: config,
                                     organizationBindingID: state.accounts.first(where: { $0.id == accountID })?.organizationUsageBindingID,
                                     bootID: boot, processID: getpid())
            if let twinTicket { launch.id = twinTicket.generation }
            try update { state in
                state.agentLaunches.removeAll { $0.paneID == paneID }
                state.agentLaunches.append(launch)
                state.invalidateFollowUps(paneID: paneID, message: "The agent restarted. Edit this input to bind it to the current agent.")
                state.followUpTurns.removeAll { $0.paneID == paneID }
                state.followUpPasteStates.removeAll { $0.paneID == paneID }
                let active = Set(state.agentLaunches.map(\.id))
                state.supervision.removeAll { !active.contains($0.generation) }
                state.supervision.append(AgentSupervision(generation: launch.id))
                if let index = state.sessions.firstIndex(where: { $0.id == paneID }) { state.sessions[index].agentTasks = nil }
            }
            return launch
        }
    }

    public func recordDirectory(paneID: String, cwd: String, expectedPID: Int32? = nil) throws {
        guard cwd.hasPrefix("/"), !cwd.contains("\0"), !cwd.contains("\n"), !cwd.contains("\r") else { throw TerminalError.invalid("Invalid working directory") }
        try transaction {
            guard let pane = try state().sessions.first(where: { $0.id == paneID && $0.remote == nil }) else { throw TerminalError.invalid("Unknown local pane") }
            if let expectedPID, pane.pid != expectedPID { return }
            guard try !isTerminalIntentionallyClosed(paneID) else { return }
            if pane.cwd == cwd { return }
            try update { state in if let index = state.sessions.firstIndex(where: { $0.id == paneID }) { state.sessions[index].cwd = cwd } }
        }
    }

    public func recordAgentProcess(paneID: String, generation: String, pid: Int32) throws {
        try update { state in
            guard let index = state.agentLaunches.firstIndex(where: { $0.paneID == paneID && $0.id == generation }) else { throw TerminalError.invalid("Agent launch changed") }
            state.agentLaunches[index].providerPID = pid
        }
    }

    public func recordAgentHook(paneID: String, generation: String, provider: AgentKind, data: Data, originPID: Int32? = nil) throws {
        guard data.count <= 1_048_576 else { throw TerminalError.invalid("Hook input exceeds 1 MiB") }
        let payload = try JSONDecoder().decode([String: JSONValue].self, from: data)
        guard let sessionID = payload["session_id"]?.text, UUID(uuidString: sessionID) != nil,
              let event = payload["hook_event_name"]?.text,
              ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PreModelRequest", "PostModelRequest", "PermissionRequest", "Notification", "Stop", "StopFailure", "SessionEnd", "SubagentStart", "SubagentStop"].contains(event),
              let cwd = payload["cwd"]?.text, cwd.hasPrefix("/"), !cwd.contains("\0"), !cwd.contains("\n") else { return }
        try transaction {
            let state = try state()
            guard let launch = state.agentLaunches.first(where: { $0.paneID == paneID && $0.id == generation && $0.provider == provider && $0.lifecycle == .active }) else { return }
            if let originPID {
                guard let pid = launch.providerPID, ProcessIdentity.isRootHook(originPID: originPID, providerPID: pid, provider: provider) else { return }
            }
            if payload["agent_id"] != nil && payload["agent_id"] != .null {
                guard launch.providerSessionID == sessionID, let taskID = payload["agent_id"]?.text,
                      let activity = AgentTaskActivity.hookState(event, provider: provider) else { return }
                try recordAgentTask(paneID: paneID, id: taskID, parentID: nil, name: payload["agent_type"]?.text,
                                    state: activity, agent: provider, source: "hook", generation: generation)
                return
            }
            guard event != "SubagentStart", event != "SubagentStop" else { return }
            let replacesSession = event == "SessionStart" && ["clear", "fork"].contains(payload["source"]?.text ?? "") && originPID != nil
            if let existing = launch.providerSessionID, existing != sessionID, !replacesSession { return }
            if launch.providerSessionID == nil || launch.cwd != cwd || replacesSession {
                try update { state in
                    guard let index = state.agentLaunches.firstIndex(where: { $0.id == generation }) else { return }
                    state.agentLaunches[index].providerSessionID = sessionID
                    state.agentLaunches[index].cwd = cwd
                    state.agentLaunches[index].updatedAt = Date()
                    if replacesSession, let paneIndex = state.sessions.firstIndex(where: { $0.id == paneID }) {
                        state.sessions[paneIndex].agentTasks = nil
                    }
                }
            }
            if provider == .claude, originPID != nil, let transcript = payload["transcript_path"]?.text {
                try? recordSessionLoadHookSource(launch: launch, providerSessionID: sessionID, transcriptPath: transcript)
            }
            if event == "SessionStart", try self.state().recoveryResults.contains(where: { $0.paneID == paneID && $0.status == .restoring }) {
                try setRecovery(paneID, status: .restored, message: "Agent conversation resumed")
            }
            if event == "Stop", try decisionGateReason(paneID: paneID, generation: generation) != nil {
                try report(paneID, state: .blocked, reason: Self.decisionWaitingReason, agent: provider, source: "hook")
                return
            }
            try update { state in
                if let index = state.supervision.firstIndex(where: { $0.generation == generation }) {
                    state.supervision[index].observe(event: event, toolID: payload["tool_use_id"]?.text ?? payload["call_id"]?.text)
                    if event == "SessionStart" { state.supervision[index].startedSessionID = sessionID }
                }
            }
            if let originPID {
                if replacesSession {
                    try update { state in
                        state.invalidateFollowUps(paneID: paneID, message: "The conversation changed. Edit this input to bind it to the current conversation.")
                        state.followUpTurns.removeAll { $0.paneID == paneID }
                    }
                }
                try observeFollowUpHook(paneID: paneID, generation: generation, event: event, originPID: originPID)
            }
            if event == "StopFailure", let accountID = launch.accountID {
                if payload["error"]?.text == "rate_limit" { try recordAccountLimit(accountID: accountID, source: "claude.StopFailure", organizationBindingID: launch.organizationBindingID) }
                if ["authentication_failed", "oauth_org_not_allowed", "account_on_hold"].contains(payload["error"]?.text ?? "") { try recordAccountFailure(accountID: accountID, authentication: true, organizationBindingID: launch.organizationBindingID) }
            }
            if event == "Notification", let pane = try self.state().sessions.first(where: { $0.id == paneID }),
               pane.activity.state == .blocked, !pane.activity.reason.isEmpty { return }
            if event == "PreToolUse", let pane = try self.state().sessions.first(where: { $0.id == paneID }),
               pane.activity.state == .blocked, pane.activity.reason == Self.decisionWaitingReason,
               try hasPendingDecision(paneID: paneID, generation: generation) { return }
            if let attention = AttentionSummary.activity(event: event, payload: payload) {
                try report(paneID, state: attention.state, reason: attention.reason, agent: provider, source: "hook")
                return
            }
            let activity: ActivityState?
            switch event {
            case "SessionStart": activity = .idle
            case "UserPromptSubmit", "PreToolUse": activity = .running
            case "PermissionRequest": activity = .blocked
            case "Stop": activity = .done
            case "StopFailure": activity = .blocked
            default: activity = nil
            }
            if let activity { try report(paneID, state: activity, agent: provider, source: "hook") }
            if event == "Stop", let originPID { try? observeWorktreeCompletion(paneID: paneID, generation: generation, originPID: originPID) }
        }
    }

    public func endAgentLaunch(paneID: String, generation: String, normalExit: Bool) throws {
        try transaction {
            try update { state in
                guard let index = state.agentLaunches.firstIndex(where: { $0.paneID == paneID && $0.id == generation }) else { return }
                state.agentLaunches[index].processID = nil
                if normalExit { state.agentLaunches[index].lifecycle = .exited }
                state.agentLaunches[index].updatedAt = Date()
                state.invalidateFollowUps(paneID: paneID, message: "The agent exited. Start a managed agent and edit this input to requeue it.")
                state.followUpTurns.removeAll { $0.paneID == paneID }
                state.followUpPasteStates.removeAll { $0.paneID == paneID }
            }
            try abandonDecisions(paneID: paneID, generation: generation)
        }
    }

    public func recoveryCommand(_ launch: AgentLaunch) throws -> AccountCommand {
        try transaction {
            try validateAgentRecoveryIdentity(launch)
            guard let id = launch.providerSessionID else { throw TerminalError.invalid("No verified conversation ID") }
            let arguments = launch.provider == .claude ? ["--resume", id] : ["resume", id]
            if let accountID = launch.accountID { return try accountCommand(accountID, arguments: arguments) }
            let key = launch.provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
            return AccountCommand(arguments: [launch.provider.rawValue] + arguments, environment: [key: launch.configurationRoot], removeEnvironment: [])
        }
    }

    public func setRecovery(_ paneID: String, status: RecoveryStatus, message: String) throws {
        try update { state in
            state.recoveryResults.removeAll { $0.paneID == paneID }
            state.recoveryResults.append(RecoveryResult(paneID: paneID, status: status, message: message))
        }
    }

    /// Returns the launch to retry after a resume attempt failed before the provider confirmed the conversation.
    public func pendingResumeRetry(paneID: String, providerSessionID: String?) throws -> AgentLaunch? {
        let current = try state()
        guard let result = current.recoveryResults.first(where: { $0.paneID == paneID }), result.status == .failed,
              result.message.hasPrefix(RecoveryResumeBackoff.failurePrefix), !(try isTerminalIntentionallyClosed(paneID)) else { return nil }
        return current.agentLaunches.first {
            $0.paneID == paneID && $0.lifecycle == .active && $0.processID == nil && $0.providerSessionID != nil && $0.providerSessionID == providerSessionID
        }
    }

    public func retryRecovery(paneID: String) throws -> [RecoveryResult] {
        let snapshot = try state()
        guard let pane = snapshot.sessions.first(where: { $0.id == paneID }) else { throw TerminalError.invalid("Unknown recovery pane") }
        guard pane.remote == nil, try list().first(where: { $0.id == paneID })?.alive == true else { return try recoverSessions(paneID: paneID) }
        try transaction {
            let current = try state()
            guard !(try isTerminalIntentionallyClosed(paneID)), current.sessions.contains(where: { $0.id == paneID && $0.remote == nil }),
                  let result = current.recoveryResults.first(where: { $0.paneID == paneID }), [.failed, .needsAttention].contains(result.status) else {
                throw TerminalError.invalid("This pane has no failed recovery to retry")
            }
            guard let launch = current.agentLaunches.first(where: { $0.paneID == paneID && $0.lifecycle == .active }) else {
                throw TerminalError.invalid("No agent conversation is waiting to resume in this pane")
            }
            if let pid = launch.processID, kill(pid, 0) == 0 { throw TerminalError.invalid("This pane already has an active agent") }
            guard let live = try list().first(where: { $0.id == paneID }), live.alive,
                  ForegroundProgramProbe.shellOwnsForeground(pid: live.pid) else {
                throw TerminalError.invalid("Return this pane to its shell prompt before retrying")
            }
            do { _ = try recoveryCommand(launch) }
            catch {
                try setRecovery(paneID, status: .needsAttention, message: error.localizedDescription)
                throw error
            }
            guard let helperExecutable, FileManager.default.isExecutableFile(atPath: helperExecutable) else { throw TerminalError.runtime("The bundled trano CLI is required to resume an agent") }
            try setRecovery(paneID, status: .restoring, message: "Resuming " + launch.provider.rawValue + " conversation")
            try send(paneID, text: [helperExecutable, "recovery", "resume", paneID, launch.id].map(ShellQuote.quote).joined(separator: " "), enter: true)
        }
        return try state().recoveryResults.filter { $0.paneID == paneID }
    }

    public func recoverSessions(automatic: Bool = false, paneID: String? = nil) throws -> [RecoveryResult] {
        let snapshot = try state()
        if let paneID, !snapshot.sessions.contains(where: { $0.id == paneID }) { throw TerminalError.invalid("Unknown recovery pane") }
        if automatic && !snapshot.settings.automaticRestore { return snapshot.recoveryResults }
        let live = try list()
        let reservation = detachedPaneReservations()
        let attached = Set((snapshot.layout.tabs + snapshot.layout.closedTabs).flatMap(\.panes))
        var results: [RecoveryResult] = []
        for pane in snapshot.sessions where (paneID == nil || pane.id == paneID) && reservation.permitsGenericRecovery(pane.id, attachedPaneIDs: attached) {
            if try isTerminalIntentionallyClosed(pane.id) { continue }
            if live.first(where: { $0.id == pane.id })?.alive == true {
                results.append(snapshot.recoveryResults.first(where: { $0.paneID == pane.id }) ?? RecoveryResult(paneID: pane.id, status: .live, message: "Existing process preserved"))
                continue
            }
            do {
                if pane.remote != nil {
                    try restoreRemoteBridge(pane.id)
                    try transaction {
                        guard !(try isTerminalIntentionallyClosed(pane.id)),
                              try state().sessions.contains(where: { $0.id == pane.id && $0.remote == pane.remote }) else { return }
                        try setRecovery(pane.id, status: .restored, message: "Reconnected to the same remote session")
                    }
                } else {
                    try transaction {
                        let current = try state()
                        guard !(try isTerminalIntentionallyClosed(pane.id)),
                              let local = current.sessions.first(where: { $0.id == pane.id && $0.remote == nil }) else { return }
                        if try list().first(where: { $0.id == pane.id })?.alive == true { return }
                        let launch = current.agentLaunches.first { $0.paneID == pane.id && $0.lifecycle == .active }
                        if let launch {
                            do { _ = try recoveryCommand(launch) }
                            catch {
                                try restoreLocalShell(pane.id, cwd: local.cwd)
                                try setRecovery(pane.id, status: .needsAttention, message: error.localizedDescription)
                                return
                            }
                            guard let helperExecutable, FileManager.default.isExecutableFile(atPath: helperExecutable) else { throw TerminalError.runtime("The bundled trano CLI is required to resume an agent") }
                            try setRecovery(pane.id, status: .restoring, message: "Resuming " + launch.provider.rawValue + " conversation")
                            try update { state in if let index = state.agentLaunches.firstIndex(where: { $0.id == launch.id }) { state.agentLaunches[index].processID = nil } }
                            try restoreLocalShell(pane.id, cwd: launch.cwd)
                            try send(pane.id, text: [helperExecutable, "recovery", "resume", pane.id, launch.id].map(ShellQuote.quote).joined(separator: " "), enter: true)
                        } else {
                            try restoreLocalShell(pane.id, cwd: local.cwd)
                            try setRecovery(pane.id, status: .restored, message: "Shell restored; previously exited agents remain closed")
                        }
                    }
                }
            } catch {
                try transaction {
                    guard !(try isTerminalIntentionallyClosed(pane.id)),
                          try state().sessions.contains(where: { $0.id == pane.id }) else { return }
                    try setRecovery(pane.id, status: .failed, message: error.localizedDescription)
                }
            }
            if let result = try state().recoveryResults.first(where: { $0.paneID == pane.id }) { results.append(result) }
        }
        return results
    }
}
