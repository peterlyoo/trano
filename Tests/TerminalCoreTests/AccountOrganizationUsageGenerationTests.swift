import XCTest
@testable import TerminalCore

final class AccountOrganizationUsageGenerationTests: XCTestCase {
    private let org = "12345678-1234-4234-8234-123456789abc"
    private let other = "87654321-4321-4321-8321-cba987654321"
    private func fixture() throws -> (TerminalRuntime, AccountProfile) {
        let runtime = try organizationFixtureRuntime(root: URL(fileURLWithPath: "/tmp/trano-org-usage-" + UUID().uuidString.prefix(8)))
        let account = try runtime.addAccount(provider: .claude, label: "Same login", organization: ClaudeOrganizationSelection(uuid: org, name: "First"))
        return (runtime, account)
    }
    private func launch(_ runtime: TerminalRuntime, _ account: AccountProfile) throws -> AgentLaunch {
        let proof = try runtime.preflightAccountOrganization(accountID: account.id, cwd: "/tmp", authenticate: { profile, root in
            let data = try JSONSerialization.data(withJSONObject: ["loggedIn": true, "authMethod": "claude.ai", "configDirectory": root.path, "orgId": self.org])
            return try AccountAuthenticationAdapter.claude(account: profile, root: root, exitCode: 0, data: data)
        })
        let pane = UUID().uuidString.lowercased()
        try runtime.update { $0.sessions.append(TerminalSession(id: pane, title: "Synthetic", cwd: "/tmp", pid: 0)) }
        return try runtime.beginAgentLaunch(paneID: pane, provider: .claude, cwd: "/tmp", accountID: account.id, organizationAuthorization: proof)
    }
    private func encodedScope(_ launch: AgentLaunch) throws -> String? {
        (try JSONSerialization.jsonObject(with: JSONEncoder().encode(launch)) as? [String: Any])?["organizationBindingID"] as? String
    }
    private func failHook(_ runtime: TerminalRuntime, _ launch: AgentLaunch) throws {
        let data = try JSONSerialization.data(withJSONObject: ["session_id": UUID().uuidString.lowercased(), "hook_event_name": "StopFailure", "cwd": "/tmp", "error": "rate_limit"])
        try runtime.recordAgentHook(paneID: launch.paneID, generation: launch.id, provider: .claude, data: data)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testLaunchFreezesBindingAndLegacyDecodeDoesNotInventCurrentScope() throws {
        let (runtime, account) = try fixture(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let value = try launch(runtime, account)
        let binding = try XCTUnwrap(runtime.state().accounts.first?.organization?.bindingID)
        XCTAssertEqual(try encodedScope(value), binding)
        var raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        raw.removeValue(forKey: "organizationBindingID")
        let old = try JSONDecoder().decode(AgentLaunch.self, from: JSONSerialization.data(withJSONObject: raw))
        XCTAssertNil(try encodedScope(old))
        XCTAssertEqual(old.id, value.id)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testOldStillRunningGenerationCannotPublishQuotaAfterRebind() throws {
        let (runtime, account) = try fixture(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let value = try launch(runtime, account)
        try runtime.setAccountOrganization(account.id, selection: ClaudeOrganizationSelection(uuid: other, name: "Second"))
        try failHook(runtime, value)
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.root.appendingPathComponent("account-usage.json").path))
        let state = try runtime.state()
        XCTAssertEqual(state.agentLaunches.first?.id, value.id)
        XCTAssertEqual(state.agentLaunches.first?.lifecycle, .active)
        XCTAssertEqual(state.agentLaunches.first?.processID, value.processID)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testCurrentGenerationPublishesItsExactQuotaScope() throws {
        let (runtime, account) = try fixture(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let value = try launch(runtime, account)
        try failHook(runtime, value)
        let observation = try XCTUnwrap(runtime.accountUsage().first)
        XCTAssertEqual(observation.status, .limited)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(observation)) as? [String: Any])
        XCTAssertEqual(raw["organizationBindingID"] as? String, try encodedScope(value))
        XCTAssertNotNil(raw["organizationBindingID"])
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testLegacyCooldownCannotContaminateTrackedOrganizationOrClear() throws {
        let (runtime, account) = try fixture(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let deadline = Date().addingTimeInterval(300)
        try runtime.update { $0.accounts[0].unavailableUntil = deadline }
        XCTAssertNil(try runtime.state().accounts.first?.unavailableUntil)
        try runtime.setAccountOrganization(account.id, selection: nil)
        try runtime.update { $0.accounts[0].unavailableUntil = deadline }
        XCTAssertNil(try runtime.state().accounts.first?.unavailableUntil)
        XCTAssertNotEqual(try runtime.state().accounts.first?.organization?.bindingID, "")
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testScopedFailedResumeCooldownSurvivesRefreshAndCannotCrossRebind() throws {
        let (runtime, account) = try fixture(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let binding = try XCTUnwrap(runtime.state().accounts.first?.organizationUsageBindingID)
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        try runtime.recordAccountSwitchFailure(accountID: account.id, organizationBindingID: binding, until: deadline)
        XCTAssertEqual(try runtime.state().accounts.first?.unavailableUntil, deadline)
        XCTAssertEqual(try runtime.accountUsage().first?.status, .unavailable)
        _ = try launch(runtime, account)
        XCTAssertEqual(try runtime.state().accounts.first?.unavailableUntil, deadline)
        try runtime.setAccountOrganization(account.id, selection: ClaudeOrganizationSelection(uuid: other, name: "Second"))
        XCTAssertNil(try runtime.state().accounts.first?.unavailableUntil)
        let before = try Data(contentsOf: runtime.root.appendingPathComponent("account-usage.json"))
        try runtime.recordAccountSwitchFailure(accountID: account.id, organizationBindingID: binding, until: deadline)
        XCTAssertNil(try runtime.state().accounts.first?.unavailableUntil)
        XCTAssertEqual(try Data(contentsOf: runtime.root.appendingPathComponent("account-usage.json")), before)
        let current = try XCTUnwrap(runtime.state().accounts.first?.organizationUsageBindingID)
        try runtime.setAccountCooldown(account.id, until: deadline, organizationBindingID: current)
        XCTAssertEqual(try runtime.state().accounts.first?.unavailableUntil, deadline)
        try runtime.setAccountCooldown(account.id, until: nil)
        XCTAssertNil(try runtime.state().accounts.first?.unavailableUntil)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testInvalidFailedResumeDeadlineDoesNotWriteFailureOrCooldown() throws {
        let (runtime, account) = try fixture(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let binding = try XCTUnwrap(runtime.state().accounts.first?.organizationUsageBindingID)
        let before = try runtime.state().revision
        XCTAssertThrowsError(try runtime.recordAccountSwitchFailure(accountID: account.id, organizationBindingID: binding, until: Date(timeIntervalSince1970: .nan)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.root.appendingPathComponent("account-usage.json").path))
        XCTAssertEqual(try runtime.state().revision, before)
        XCTAssertNil(try runtime.state().accounts.first?.unavailableUntil)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testLegacyNeverBoundAndCodexCooldownsRemainAvailable() throws {
        let runtime = try organizationFixtureRuntime(root: URL(fileURLWithPath: "/tmp/trano-org-legacy-" + UUID().uuidString.prefix(8)))
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let deadline = Date(timeIntervalSince1970: 2_000_000_000)
        for provider in [AgentKind.claude, .codex] {
            let account = try runtime.addAccount(provider: provider, label: "Legacy")
            try runtime.setAccountCooldown(account.id, until: deadline)
            XCTAssertEqual(try runtime.state().accounts.first { $0.id == account.id }?.unavailableUntil, deadline)
        }
    }
}
