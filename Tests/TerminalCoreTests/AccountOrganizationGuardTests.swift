import XCTest
@testable import TerminalCore

final class AccountOrganizationGuardTests: XCTestCase {
    let organizationID = "12345678-1234-4234-8234-123456789abc"
    let changedID = "87654321-4321-4321-8321-cba987654321"

    private func runtime() throws -> TerminalRuntime {
        try organizationFixtureRuntime(root: URL(fileURLWithPath: "/tmp/trano-og-" + UUID().uuidString.prefix(8)))
    }
    private func proof(_ runtime: TerminalRuntime, accountID: String) throws -> AccountOrganizationAuthorization {
        try runtime.preflightAccountOrganization(accountID: accountID, cwd: "/tmp", authenticate: { account, root in
            let payload: [String: Any] = ["loggedIn": true, "authMethod": "claude.ai", "configDirectory": root.path,
                                          "orgId": self.organizationID, "orgName": "Team"]
            return try AccountAuthenticationAdapter.claude(account: account, root: root, exitCode: 0,
                                                            data: JSONSerialization.data(withJSONObject: payload))
        })
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testGenerationRequiresFreshExactProfileAuthorizationAndRejectsChangedBinding() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let account = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: organizationID, name: nil))
        let pane = UUID().uuidString.lowercased()
        try runtime.update { $0.sessions.append(TerminalSession(id: pane, title: "Synthetic", cwd: "/tmp", pid: 0)) }
        XCTAssertThrowsError(try runtime.beginAgentLaunch(paneID: pane, provider: .claude, cwd: "/tmp", accountID: account.id))
        let authorization = try proof(runtime, accountID: account.id)
        let launch = try runtime.beginAgentLaunch(paneID: pane, provider: .claude, cwd: "/tmp", accountID: account.id,
                                                 organizationAuthorization: authorization)
        XCTAssertEqual(launch.accountID, account.id)
        XCTAssertEqual(launch.configurationRoot, try runtime.accountRoot(account.id).path)
        let second = UUID().uuidString.lowercased()
        try runtime.update { $0.sessions.append(TerminalSession(id: second, title: "Synthetic", cwd: "/tmp", pid: 0)) }
        try runtime.setAccountOrganization(account.id, selection: ClaudeOrganizationSelection(uuid: changedID, name: nil))
        XCTAssertThrowsError(try runtime.beginAgentLaunch(paneID: second, provider: .claude, cwd: "/tmp", accountID: account.id,
                                                        organizationAuthorization: authorization))
        XCTAssertFalse(try runtime.state().agentLaunches.contains { $0.paneID == second })
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testSwitchRevalidatesTargetOrganizationBeforeTransferWithoutProviderQueriesInsideLock() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let source = try runtime.addAccount(provider: .claude, label: "Same account")
        let target = try runtime.addAccount(provider: .claude, label: "Same account", organization: ClaudeOrganizationSelection(uuid: organizationID, name: "Team"))
        let sourceRoot = try runtime.accountRoot(source.id)
        let targetRoot = try runtime.accountRoot(target.id)
        let pane = UUID().uuidString.lowercased(), session = UUID().uuidString.lowercased()
        let folder = sourceRoot.appendingPathComponent("projects/-tmp-work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = Data("{\"sessionId\":\"\(session)\",\"cwd\":\"/tmp\",\"type\":\"user\",\"message\":{\"content\":\"synthetic\"}}\n".utf8)
        try data.write(to: folder.appendingPathComponent(session + ".jsonl"))
        let launch = AgentLaunch(paneID: pane, provider: .claude, providerSessionID: session, cwd: "/tmp", accountID: source.id,
                                 configurationRoot: sourceRoot.path, bootID: try TerminalRuntime.bootIdentity(), processID: nil, providerPID: nil)
        try runtime.update { $0.sessions.append(TerminalSession(id: pane, title: "Synthetic", cwd: "/tmp", pid: 0)); $0.agentLaunches.append(launch) }
        let authorization = try proof(runtime, accountID: target.id)
        let plan = try runtime.prepareAccountSwitch(paneID: pane, targetAccountID: target.id, expectedGeneration: launch.id,
                                                    toolsInFlight: false, safeTurnBoundary: true, organizationAuthorization: authorization)
        try runtime.transaction { XCTAssertNoThrow(try runtime.validateAccountSwitch(plan)) }
        try runtime.setAccountOrganization(target.id, selection: ClaudeOrganizationSelection(uuid: changedID, name: nil))
        try runtime.transaction { XCTAssertThrowsError(try runtime.validateAccountSwitch(plan)) }
        XCTAssertThrowsError(try runtime.transferAccountSession(plan))
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(session + ".jsonl")), data)
        XCTAssertFalse(FileManager.default.fileExists(atPath: targetRoot.appendingPathComponent("projects/-tmp-work/" + session + ".jsonl").path))
    }

    // Implements: FR-ORG-1, FR-ORG-4
    func testAPIRoutesAddReuseAndClearOrganizationWithoutStartingServiceOrProvider() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let api = APIService(runtime: runtime)
        let result = api.route(APIRequest(method: "accounts.add", params: ["provider": .string("claude"), "label": .string("Same login"),
            "organizationUUID": .string(organizationID), "organizationName": .string("Team")]))
        XCTAssertNil(result.error)
        let account = try XCTUnwrap(runtime.state().accounts.first)
        XCTAssertEqual(account.organization?.selection?.uuid, organizationID)
        let known = api.route(APIRequest(method: "accounts.organizations"))
        XCTAssertNil(known.error)
        XCTAssertEqual(known.result, .array([.object(["uuid": .string(organizationID), "name": .string("Team")])]))
        let stale = api.route(APIRequest(method: "accounts.organization.set", params: ["id": .string(account.id),
            "organizationUUID": .null, "expectedBindingID": .string("")]))
        XCTAssertNotNil(stale.error)
        let cleared = api.route(APIRequest(method: "accounts.organization.set", params: ["id": .string(account.id),
            "organizationUUID": .null, "expectedBindingID": .string(account.organization?.bindingID ?? "")]))
        XCTAssertNil(cleared.error)
        XCTAssertNil(try runtime.state().accounts.first?.organization?.selection)
    }

    // Implements: FR-ORG-1, FR-ORG-3
    func testAPIRejectsWrongTypesAndClaudeOnlyBindingWithoutCreatingProfile() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let api = APIService(runtime: runtime)
        for params in [
            ["provider": JSONValue.string("claude"), "label": .string("Bad"), "organizationUUID": .number(7)],
            ["provider": JSONValue.string("codex"), "label": .string("Bad"), "organizationUUID": .string(organizationID)],
            ["provider": JSONValue.string("claude"), "label": .string("Bad"), "organizationName": .string("Missing UUID")]
        ] {
            XCTAssertNotNil(api.route(APIRequest(method: "accounts.add", params: params)).error)
        }
        XCTAssertTrue(try runtime.state().accounts.isEmpty)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testClearingBindingInvalidatesAuthorizationBeforeGenerationCommit() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let account = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: organizationID, name: nil))
        let authorization = try proof(runtime, accountID: account.id)
        try runtime.setAccountOrganization(account.id, selection: nil)
        let pane = UUID().uuidString.lowercased()
        try runtime.update { $0.sessions.append(TerminalSession(id: pane, title: "Synthetic", cwd: "/tmp", pid: 0)) }
        XCTAssertThrowsError(try runtime.beginAgentLaunch(paneID: pane, provider: .claude, cwd: "/tmp", accountID: account.id,
                                                        organizationAuthorization: authorization))
        XCTAssertFalse(try runtime.state().agentLaunches.contains { $0.paneID == pane })
    }
}
