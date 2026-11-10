import Foundation
import Darwin

public enum AgentLifecycle: String, Codable { case active, exited }
public enum RecoveryStatus: String, Codable { case live, restoring, restored, needsAttention = "needs_attention", failed }
public struct AgentLaunch: Codable, Identifiable {
    public var id = UUID().uuidString.lowercased()
    public let paneID: String
    public let provider: AgentKind
    public var providerSessionID: String?
    public var cwd: String
    public let accountID: String?
    public let configurationRoot: String
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
                                 configurationRoot: String? = nil, resume: AgentLaunch? = nil) throws -> AgentLaunch {
        guard provider != .shell, cwd.hasPrefix("/"), !cwd.contains("\0"), !cwd.contains("\n") else { throw TerminalError.invalid("Invalid agent launch metadata") }
        let boot = try Self.bootIdentity()
        let config = try accountID.map { try accountRoot($0).path } ?? configurationRoot ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(provider == .claude ? ".claude" : ".codex").path
        return try transaction {
            let state = try state()
            guard state.sessions.contains(where: { $0.id == paneID && $0.remote == nil }) else { throw TerminalError.invalid("Unknown local pane") }
            if let accountID, !state.accounts.contains(where: { $0.id == accountID && $0.provider == provider }) { throw TerminalError.invalid("Account provider does not match the agent") }
            if let previous = state.agentLaunches.first(where: { $0.paneID == paneID }), previous.lifecycle == .active, previous.bootID == boot, let pid = previous.processID, kill(pid, 0) == 0 {
                throw TerminalError.invalid("This pane already has an active agent")
            }
            if let resume {
                guard state.agentLaunches.contains(where: { $0.id == resume.id && $0.paneID == paneID && $0.lifecycle == .active }) else { throw TerminalError.invalid("Recovery launch changed; refresh before retrying") }
            }
            let launch = AgentLaunch(paneID: paneID, provider: provider, providerSessionID: resume?.providerSessionID, cwd: cwd,
                                     accountID: accountID, configurationRoot: config, bootID: boot, processID: getpid())
            try update { state in
                state.agentLaunches.removeAll { $0.paneID == paneID }
                state.agentLaunches.append(launch)
                let active = Set(state.agentLaunches.map(\.id))
                state.supervision.removeAll { !active.contains($0.generation) }
                state.supervision.append(AgentSupervision(generation: launch.id))
                if let index = state.sessions.firstIndex(where: { $0.id == paneID }) { state.sessions[index].agentTasks = nil }
            }
            return launch
        }
    }

    public func recordDirectory(paneID: String, cwd: String) throws {
        guard cwd.hasPrefix("/"), !cwd.contains("\0"), !cwd.contains("\n"), !cwd.contains("\r") else { throw TerminalError.invalid("Invalid working directory") }
        try transaction {
            guard let pane = try state().sessions.first(where: { $0.id == paneID && $0.remote == nil }) else { throw TerminalError.invalid("Unknown local pane") }
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
              ["SessionStart", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure", "PreModelRequest", "PostModelRequest", "PermissionRequest", "Stop", "StopFailure", "SessionEnd", "SubagentStart", "SubagentStop"].contains(event),
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
            if event == "SessionStart", try self.state().recoveryResults.contains(where: { $0.paneID == paneID && $0.status == .restoring }) {
                try setRecovery(paneID, status: .restored, message: "Agent conversation resumed")
            }
            try update { state in
                if let index = state.supervision.firstIndex(where: { $0.generation == generation }) {
                    state.supervision[index].observe(event: event, toolID: payload["tool_use_id"]?.text ?? payload["call_id"]?.text)
                    if event == "SessionStart" { state.supervision[index].startedSessionID = sessionID }
                }
            }
            if event == "StopFailure", let accountID = launch.accountID {
                if payload["error"]?.text == "rate_limit" { try recordAccountLimit(accountID: accountID, source: "claude.StopFailure") }
                if ["authentication_failed", "oauth_org_not_allowed", "account_on_hold"].contains(payload["error"]?.text ?? "") { try recordAccountFailure(accountID: accountID, authentication: true) }
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
        }
    }

    public func endAgentLaunch(paneID: String, generation: String, normalExit: Bool) throws {
        try update { state in
            guard let index = state.agentLaunches.firstIndex(where: { $0.paneID == paneID && $0.id == generation }) else { return }
            state.agentLaunches[index].processID = nil
            if normalExit { state.agentLaunches[index].lifecycle = .exited }
            state.agentLaunches[index].updatedAt = Date()
        }
    }

    public func recoveryCommand(_ launch: AgentLaunch) throws -> AccountCommand {
        guard let id = launch.providerSessionID, UUID(uuidString: id) != nil else { throw TerminalError.invalid("No verified conversation ID. Review the Trano hook in the provider before the next launch.") }
        var directory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: launch.cwd, isDirectory: &directory), directory.boolValue else { throw TerminalError.invalid("Original working directory is missing: " + launch.cwd) }
        guard FileManager.default.fileExists(atPath: launch.configurationRoot, isDirectory: &directory), directory.boolValue else { throw TerminalError.invalid("Original agent configuration directory is missing") }
        let arguments = launch.provider == .claude ? ["--resume", id] : ["resume", id]
        if let accountID = launch.accountID { return try accountCommand(accountID, arguments: arguments) }
        let key = launch.provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"
        return AccountCommand(arguments: [launch.provider.rawValue] + arguments, environment: [key: launch.configurationRoot], removeEnvironment: [])
    }

    public func setRecovery(_ paneID: String, status: RecoveryStatus, message: String) throws {
        try update { state in
            state.recoveryResults.removeAll { $0.paneID == paneID }
            state.recoveryResults.append(RecoveryResult(paneID: paneID, status: status, message: message))
        }
    }

    public func recoverSessions(automatic: Bool = false, paneID: String? = nil) throws -> [RecoveryResult] {
        let snapshot = try state()
        if let paneID, !snapshot.sessions.contains(where: { $0.id == paneID }) { throw TerminalError.invalid("Unknown recovery pane") }
        if automatic && !snapshot.settings.automaticRestore { return snapshot.recoveryResults }
        let live = try list()
        var results: [RecoveryResult] = []
        for pane in snapshot.sessions where paneID == nil || pane.id == paneID {
            if live.first(where: { $0.id == pane.id })?.alive == true {
                results.append(snapshot.recoveryResults.first(where: { $0.paneID == pane.id }) ?? RecoveryResult(paneID: pane.id, status: .live, message: "Existing process preserved"))
                continue
            }
            do {
                if pane.remote != nil {
                    try restoreRemoteBridge(pane.id)
                    try transaction {
                        guard try state().sessions.contains(where: { $0.id == pane.id && $0.remote == pane.remote }) else { return }
                        try setRecovery(pane.id, status: .restored, message: "Reconnected to the same remote session")
                    }
                } else {
                    try transaction {
                        let current = try state()
                        guard let local = current.sessions.first(where: { $0.id == pane.id && $0.remote == nil }) else { return }
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
                    guard try state().sessions.contains(where: { $0.id == pane.id }) else { return }
                    try setRecovery(pane.id, status: .failed, message: error.localizedDescription)
                }
            }
            if let result = try state().recoveryResults.first(where: { $0.paneID == pane.id }) { results.append(result) }
        }
        return results
    }
}
