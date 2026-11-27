import Foundation
import XCTest
@testable import TerminalCore
final class AgentIntegrationContextTests: XCTestCase {
    private func runtime() throws -> TerminalRuntime {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-ctx-" + String(UUID().uuidString.prefix(12)))
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return try TerminalRuntime(root: root)
    }
    // Implements: FR-SET-1, FR-SET-2
    func testManagedAccountsReceiveBuiltInSkillLinkAlongsideCustomExtensions() throws {
        let runtime = try runtime(), account = try runtime.addAccount(provider: .codex, label: "Fixture")
        let plan = try runtime.extensionPlan(accountID: account.id, extensionIDs: [])
        let target = try XCTUnwrap(plan.links["skills/trano-terminal"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: target + "/SKILL.md"))
        try runtime.applyExtensions(plan)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: runtime.root.appendingPathComponent("accounts/" + account.id + "/skills/trano-terminal").path), target)
    }
    // Implements: FR-SET-1, FR-SET-2
    func testStandaloneClaudeLoadsOwnedPluginContainingSkillAndHooks() throws {
        let runtime = try runtime(), plan = AccountCommand(arguments: ["claude"], environment: [:], removeEnvironment: [])
        let command = try runtime.integratingAgentHooks(plan, provider: .claude)
        XCTAssertTrue(command.arguments.contains(runtime.root.appendingPathComponent("integration/agents/claude").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: runtime.root.appendingPathComponent("integration/agents/claude/skills/trano/SKILL.md").path))
    }
    // Implements: FR-SET-1, FR-SET-2
    func testCodexSessionStartContextRespectsNamingAndRootIdentity() throws {
        let runtime = try runtime(), paneID = UUID().uuidString.lowercased(), generation = UUID().uuidString.lowercased()
        var launch = AgentLaunch(paneID: paneID, provider: .codex, cwd: "/tmp", accountID: nil, configurationRoot: "/tmp/fixture", bootID: "fixture")
        launch.id = generation; launch.providerPID = 42
        try runtime.update { $0.agentLaunches.append(launch) }
        let data = Data(#"{"hook_event_name":"SessionStart"}"#.utf8)
        let first = try XCTUnwrap(runtime.integrationHookOutput(paneID: paneID, generation: generation, provider: .codex, data: data, originPID: 40, verifyAncestry: { _, _, _ in true }))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(first), as: UTF8.self).contains("agent.name-session"))
        let store = try SecureSettingsSidecar<IntegrationsPreferences>(root: runtime.root, filename: "integrations-settings.json")
        var enabled = try store.load(); let baseline = enabled; enabled.letAgentsNameSessions = true
        _ = try store.merge(baseline: baseline, edited: enabled)
        let named = try XCTUnwrap(runtime.integrationHookOutput(paneID: paneID, generation: generation, provider: .codex, data: data, originPID: 40, verifyAncestry: { _, _, _ in true }))
        XCTAssertTrue(String(decoding: try JSONEncoder().encode(named), as: UTF8.self).contains("agent.name-session"))
        XCTAssertNil(try runtime.integrationHookOutput(paneID: paneID, generation: generation, provider: .codex, data: data, originPID: 40, verifyAncestry: { _, _, _ in false }))
        XCTAssertNil(try runtime.integrationHookOutput(paneID: paneID, generation: "stale", provider: .codex, data: data, originPID: 40, verifyAncestry: { _, _, _ in true }))
    }
}
