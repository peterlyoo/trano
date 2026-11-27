import TerminalCore

enum ProviderLaunchCommit {
    static func perform<Value>(runtime: TerminalRuntime, sessionID: String?, launch: AgentLaunch?,
                               agent: AgentKind, commit: () throws -> Value) throws -> Value {
        do { return try commit() }
        catch {
            if let sessionID, let launch, launch.paneID == sessionID, launch.provider == agent {
                try? runtime.transaction {
                    let state = try runtime.state()
                    let active = state.agentLaunches.filter { $0.paneID == sessionID && $0.lifecycle == .active }
                    guard state.sessions.contains(where: { $0.id == sessionID && $0.remote == nil }),
                          active.count == 1, let current = active.first,
                          current.id == launch.id, current.provider == agent else { return }
                    try? runtime.endAgentLaunch(paneID: sessionID, generation: launch.id, normalExit: true)
                    try? runtime.report(sessionID, state: .error, reason: "Launch failed", agent: agent, source: "process")
                }
            }
            throw error
        }
    }
}
