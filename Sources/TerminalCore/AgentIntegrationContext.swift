import Foundation
extension TerminalRuntime {
    public func integrationHookOutput(paneID: String, generation: String, provider: AgentKind, data: Data, originPID: Int32?, verifyAncestry: ((Int32, Int32, AgentKind) -> Bool)? = nil) throws -> JSONValue? {
        guard provider == .codex, data.count <= 1_048_576, let originPID,
              let payload = try? JSONDecoder().decode([String: JSONValue].self, from: data), payload["hook_event_name"] == .string("SessionStart"), payload["agent_id"] == nil || payload["agent_id"] == .null else { return nil }
        return try transaction {
            let preferences = try integrationsPreferences()
            guard preferences.integrateWithAvailableAgents,
                  let launch = try state().agentLaunches.first(where: { $0.paneID == paneID && $0.id == generation && $0.provider == provider && $0.lifecycle == .active }),
                  let pid = launch.providerPID,
                  verifyAncestry?(originPID, pid, provider) ?? ProcessIdentity.isRootHook(originPID: originPID, providerPID: pid, provider: provider) else { return nil }
            let plan = try ManagedAgentIntegration(root: root).plan(provider: provider, preferences: preferences)
            guard let skill = plan.files["codex/skills/trano/SKILL.md"] else { return nil }
            let identity = try JSONEncoder().encode(["paneID": paneID, "generation": generation])
            let context = String(decoding: skill, as: UTF8.self) + "\nCurrent immutable identity: " + String(decoding: identity, as: UTF8.self)
            return .object(["hookSpecificOutput": .object(["hookEventName": .string("SessionStart"), "additionalContext": .string(context)])])
        }
    }
}
