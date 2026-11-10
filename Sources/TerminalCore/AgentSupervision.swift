import Foundation

public struct AgentSupervision: Codable, Equatable {
    public let generation: String
    public var activeTools: Set<String> = []
    public var unknownToolCount = 0
    public var atTurnBoundary = false
    public var boundaryRevision = 0
    public var startedSessionID: String?
    public var targetAccountID: String?
    public var message: String?
    public var updatedAt = Date()
    public var safeToSwitch: Bool { atTurnBoundary && activeTools.isEmpty && unknownToolCount == 0 }
    public init(generation: String) { self.generation = generation }

    public mutating func observe(event: String, toolID: String?) {
        switch event {
        case "SessionStart", "Stop", "StopFailure": atTurnBoundary = true; boundaryRevision += 1
        case "UserPromptSubmit", "PreModelRequest", "PermissionRequest": atTurnBoundary = false
        case "PreToolUse":
            atTurnBoundary = false
            if let toolID, !toolID.isEmpty { activeTools.insert(toolID) }
            else { unknownToolCount += 1 }
        case "PostToolUse", "PostToolUseFailure":
            if let toolID { activeTools.remove(toolID) }
            else if unknownToolCount > 0 { unknownToolCount -= 1 }
        case "SessionEnd": atTurnBoundary = false
        default: break
        }
        updatedAt = Date()
    }
}

extension TerminalRuntime {
    public func restoreSwitchSource(_ source: AgentLaunch) throws {
        try transaction {
            let snapshot = try state()
            guard snapshot.sessions.contains(where: { $0.id == source.paneID }),
                  source.accountID != nil, source.providerSessionID != nil else { throw TerminalError.invalid("Source conversation is unavailable") }
            if let current = snapshot.agentLaunches.first(where: { $0.paneID == source.paneID }),
               let pid = current.providerPID, kill(pid, 0) == 0 { throw TerminalError.invalid("Stop the target provider before restoring the source mapping") }
            var restored = source
            restored.processID = nil; restored.providerPID = nil; restored.lifecycle = .active; restored.updatedAt = Date()
            try update { state in
                let generations = Set(state.agentLaunches.filter { $0.paneID == source.paneID }.map(\.id))
                state.agentLaunches.removeAll { $0.paneID == source.paneID }
                state.supervision.removeAll { generations.contains($0.generation) }
                state.agentLaunches.append(restored)
                var monitor = AgentSupervision(generation: restored.id)
                monitor.message = "The account switch failed. The original conversation is preserved."
                state.supervision.append(monitor)
            }
            try setRecovery(source.paneID, status: .needsAttention, message: "Target account did not resume; the original account and conversation ID are preserved")
            try report(source.paneID, state: .blocked, reason: "Account switch failed; original conversation preserved", agent: source.provider, source: "process")
        }
    }

    public func recordUsageHook(paneID: String, generation: String, data: Data, originPID: Int32) throws {
        guard data.count <= 1_048_576 else { throw TerminalError.invalid("Usage payload exceeds 1 MiB") }
        try transaction {
            guard let launch = try state().agentLaunches.first(where: { $0.paneID == paneID && $0.id == generation && $0.lifecycle == .active && $0.provider == .claude }),
                  let accountID = launch.accountID, let pid = launch.providerPID,
                  ProcessIdentity.isRootHook(originPID: originPID, providerPID: pid, provider: .claude) else { return }
            let payload = try JSONDecoder().decode([String: JSONValue].self, from: data)
            guard payload["session_id"]?.text == launch.providerSessionID else { return }
            _ = try recordClaudeAccountUsage(accountID: accountID, data: data)
        }
    }

    public func requestAccountSwitch(paneID: String, targetAccountID: String) throws -> AgentSupervision {
        try transaction {
            let state = try state()
            guard let launch = state.agentLaunches.first(where: { $0.paneID == paneID && $0.lifecycle == .active }),
                  let source = launch.accountID,
                  let target = state.accounts.first(where: { $0.id == targetAccountID && $0.provider == launch.provider && $0.enabled }),
                  target.id != source, let pid = launch.processID, kill(pid, 0) == 0 else {
                throw TerminalError.invalid("Choose a different enabled account for the running managed agent")
            }
            var monitor = state.supervision.first { $0.generation == launch.id } ?? AgentSupervision(generation: launch.id)
            monitor.targetAccountID = targetAccountID
            monitor.message = monitor.safeToSwitch ? "Switch queued" : "Waiting for the agent to finish its current turn"
            try update { value in value.supervision.removeAll { $0.generation == launch.id }; value.supervision.append(monitor) }
            return monitor
        }
    }

    public func recordSwitchMessage(generation: String, message: String, clearRequest: Bool = false) throws {
        try update { state in
            guard let index = state.supervision.firstIndex(where: { $0.generation == generation }) else { return }
            state.supervision[index].message = message
            if clearRequest { state.supervision[index].targetAccountID = nil }
        }
    }
}
