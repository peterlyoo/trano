import XCTest
@testable import TerminalCore
@testable import TranoCLI

final class AccountOrganizationUsageSupervisorTests: XCTestCase {
    // Implements: FR-ORG-3, FR-ORG-4
    func testOldGenerationDoesNotUseCurrentOrganizationQuotaForAutomaticSwitch() throws {
        let runtime = try TerminalRuntime(root: URL(fileURLWithPath: "/tmp/trano-org-supervisor-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let account = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: "12345678-1234-4234-8234-123456789abc", name: nil))
        let old = try XCTUnwrap(runtime.state().accounts.first?.organization?.bindingID)
        try runtime.setAccountOrganization(account.id, selection: ClaudeOrganizationSelection(uuid: "87654321-4321-4321-8321-cba987654321", name: nil))
        let current = try XCTUnwrap(runtime.state().accounts.first?.organization?.bindingID)
        let pane = UUID().uuidString.lowercased()
        let launch = AgentLaunch(paneID: pane, provider: .claude, providerSessionID: UUID().uuidString.lowercased(), cwd: "/tmp", accountID: account.id,
                                 configurationRoot: try runtime.accountRoot(account.id).path, organizationBindingID: old, bootID: "synthetic", processID: nil)
        try runtime.update {
            $0.sessions.append(TerminalSession(id: pane, title: "Synthetic", cwd: "/tmp", pid: 0))
            $0.agentLaunches.append(launch)
            var monitor = AgentSupervision(generation: launch.id)
            monitor.atTurnBoundary = true; monitor.boundaryRevision = 1
            $0.supervision.append(monitor)
            $0.settings.automaticAccountSwitching = true
        }
        let snapshot = AccountUsageSnapshot(accountID: account.id, provider: .claude, status: .limited, observedAt: Date(), windows: [], source: "fixture", message: nil, organizationBindingID: current)
        try JSONEncoder().encode([snapshot]).write(to: runtime.root.appendingPathComponent("account-usage.json"))
        let before = try runtime.state().revision
        XCTAssertNil(try ProviderSupervisor(runtime: runtime, launch: launch).pendingSwitch())
        XCTAssertEqual(try runtime.state().revision, before)
        XCTAssertNil(try runtime.state().supervision.first?.message)
    }
}
