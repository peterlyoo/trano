import Foundation
import XCTest
@testable import TerminalCore

final class AgentIntegrationGateTests: XCTestCase {
    // Implements: FR-SET-1
    func testDisabledIntegrationLeavesProviderCommandAndCustomArgumentsUntouched() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-gate-" + String(UUID().uuidString.prefix(12)))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try SecureSettingsSidecar<IntegrationsPreferences>(root: root, filename: "integrations-settings.json")
        let baseline = try store.load(); var disabled = baseline; disabled.integrateWithAvailableAgents = false
        _ = try store.merge(baseline: baseline, edited: disabled)
        for provider in [AgentKind.claude, .codex] {
            let plan = AccountCommand(arguments: [provider.rawValue, "--model", "fixture-model"], environment: [:], removeEnvironment: [])
            let integrated = try runtime.integratingAgentHooks(plan, provider: provider)
            XCTAssertEqual(integrated.arguments, plan.arguments)
            XCTAssertEqual(integrated.environment, plan.environment)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("integration/claude").path))
        }
    }

    // Implements: FR-SET-1
    func testDisabledIntegrationOmitsBuiltInHooksButRetainsSelectedCustomHooks() throws {
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-gate-" + String(UUID().uuidString.prefix(12)))
        let runtime = try TerminalRuntime(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let account = try runtime.addAccount(provider: .claude, label: "Fixture")
        let custom = root.appendingPathComponent("custom-hook.json")
        try TerminalRuntime.atomicWrite(Data(#"{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo custom"}]}]}}"#.utf8), to: custom)
        let entry = try runtime.importExtension(name: "custom", kind: .hook, source: custom)
        let store = try SecureSettingsSidecar<IntegrationsPreferences>(root: root, filename: "integrations-settings.json")
        let baseline = try store.load(); var disabled = baseline; disabled.integrateWithAvailableAgents = false
        _ = try store.merge(baseline: baseline, edited: disabled)
        let plan = try runtime.extensionPlan(accountID: account.id, extensionIDs: [entry.id])
        let settings = try XCTUnwrap(plan.files["trano-settings.json"])
        XCTAssertTrue(settings.contains("echo custom"))
        XCTAssertFalse(settings.contains("TRANO_LAUNCH_ID"))
        XCTAssertFalse(settings.contains("usage-hook"))
    }
}
