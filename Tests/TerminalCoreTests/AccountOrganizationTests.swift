import XCTest
@testable import TerminalCore

final class AccountOrganizationTests: XCTestCase {
    let firstID = "12345678-1234-4234-8234-123456789abc"
    let otherID = "87654321-4321-4321-8321-cba987654321"

    private func runtime() throws -> TerminalRuntime {
        try organizationFixtureRuntime(root: URL(fileURLWithPath: "/tmp/trano-org-" + UUID().uuidString.prefix(8)))
    }

    private func response(_ account: AccountProfile, root: URL, id: String?, name: String? = "Team", method: String = "claude.ai") throws -> AccountAuthenticationSnapshot {
        var payload: [String: Any] = ["loggedIn": true, "authMethod": method, "configDirectory": root.path,
                                      "email": "discard@example.test", "token": "never-store"]
        payload["orgId"] = id; payload["orgName"] = name
        return try AccountAuthenticationAdapter.claude(account: account, root: root, exitCode: 0,
                                                       data: JSONSerialization.data(withJSONObject: payload))
    }

    // Implements: FR-ORG-1
    func testUUIDValidationNormalizesAndRejectsUnboundedOrControlMetadata() throws {
        XCTAssertEqual(try ClaudeOrganizationSelection(uuid: firstID.uppercased(), name: "  작업  ").uuid, firstID)
        XCTAssertEqual(try ClaudeOrganizationSelection(uuid: firstID, name: "  작업  ").name, "작업")
        for invalid in ["", "not-a-uuid", firstID + "\n", " " + firstID] {
            XCTAssertThrowsError(try ClaudeOrganizationSelection(uuid: invalid, name: nil))
        }
        for name in ["bad\nname", "bad\u{0000}name", String(repeating: "a", count: 121), String(repeating: "한", count: 180)] {
            XCTAssertThrowsError(try ClaudeOrganizationSelection(uuid: firstID, name: name))
        }
    }

    // Implements: FR-ORG-1, FR-ORG-2
    func testSameAccountLabelAllowsIndependentOrganizationsRootsAndQuotaIdentity() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let a = try runtime.addAccount(provider: .claude, label: "Same login", organization: ClaudeOrganizationSelection(uuid: firstID, name: "One"))
        let b = try runtime.addAccount(provider: .claude, label: "Same login", organization: ClaudeOrganizationSelection(uuid: otherID, name: "Two"))
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertNotEqual(try runtime.accountRoot(a.id), try runtime.accountRoot(b.id))
        XCTAssertEqual(try runtime.state().accounts.map(\.id), [a.id, b.id])
        XCTAssertEqual(try runtime.state().accounts.map { $0.organization?.selection?.uuid }, [firstID, otherID])
        XCTAssertEqual(Set(try runtime.accountUsage().map(\.accountID)), Set([a.id, b.id]))
        XCTAssertThrowsError(try runtime.addAccount(provider: .codex, label: "Wrong provider", organization: ClaudeOrganizationSelection(uuid: firstID, name: nil)))
        XCTAssertEqual(try runtime.state().accounts.count, 2)
    }

    // Implements: FR-ORG-1, FR-ORG-3
    func testLegacyPrimaryRewriteCannotEraseBoundOrganizationOrObservedIdentity() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let profile = try runtime.addAccount(provider: .claude, label: "Work")
        XCTAssertNil(try runtime.state().accounts.first?.organization)
        let oldPrimary = try Data(contentsOf: runtime.root.appendingPathComponent("state.json"))
        try runtime.setAccountOrganization(profile.id, selection: ClaudeOrganizationSelection(uuid: firstID, name: "Work"))
        _ = try runtime.preflightAccountOrganization(accountID: profile.id, cwd: "/tmp", authenticate: { account, root in try self.response(account, root: root, id: self.firstID) })
        try TerminalRuntime.atomicWrite(oldPrimary, to: runtime.root.appendingPathComponent("state.json"))
        let reopened = try organizationFixtureRuntime(root: runtime.root)
        let value = try XCTUnwrap(reopened.state().accounts.first?.organization)
        XCTAssertEqual(value.selection?.uuid, firstID)
        XCTAssertEqual(value.observed?.uuid, firstID)
        XCTAssertEqual(value.verification, .verified)
        let raw = try String(contentsOf: runtime.root.appendingPathComponent("account-organizations-v1.json"), encoding: .utf8)
        XCTAssertFalse(raw.contains("discard@example.test")); XCTAssertFalse(raw.contains("never-store"))
    }

    // Implements: FR-ORG-2
    func testLoginPreselectionMergesOnlyOwnedSettingsAndDoesNotInventCLIFlag() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let profile = try runtime.addAccount(provider: .claude, label: "Work")
        let directory = try runtime.accountRoot(profile.id)
        let settings = directory.appendingPathComponent("settings.json")
        let untouched = Data(#"{"hooks":{"Stop":[{"matcher":"*"}]},"mcpServers":{"keep":{}},"theme":"dark","custom":7}"#.utf8)
        try TerminalRuntime.atomicWrite(untouched, to: settings)
        let mcp = try Data(contentsOf: directory.appendingPathComponent("trano-mcp.json"))
        try runtime.setAccountOrganization(profile.id, selection: ClaudeOrganizationSelection(uuid: firstID, name: "Team"))
        let command = try runtime.accountCommand(profile.id, login: true)
        XCTAssertEqual(command.arguments, ["claude", "auth", "login", "--claudeai"])
        XCTAssertEqual(command.environment["CLAUDE_CONFIG_DIR"], directory.path)
        let merged = try AccountUsageAdapter.object(AccountFile.read(settings, limit: 1_048_576))
        XCTAssertEqual(merged["forceLoginOrgUUID"] as? String, firstID)
        XCTAssertEqual(merged["forceLoginMethod"] as? String, "claudeai")
        XCTAssertEqual(merged["custom"] as? Int, 7); XCTAssertNotNil(merged["hooks"]); XCTAssertNotNil(merged["mcpServers"])
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("trano-mcp.json")), mcp)
        try runtime.setAccountOrganization(profile.id, selection: nil)
        let cleared = try AccountUsageAdapter.object(AccountFile.read(settings, limit: 1_048_576))
        XCTAssertNil(cleared["forceLoginOrgUUID"]); XCTAssertNil(cleared["forceLoginMethod"])
        XCTAssertNotNil(cleared["hooks"]); XCTAssertEqual(cleared["custom"] as? Int, 7)
    }

    // Implements: FR-ORG-3
    func testBoundAuthenticationRequiresMatchingProviderReportedOrganizationAndRoot() throws {
        var profile = AccountProfile(provider: .claude, label: "Work")
        profile.organization = AccountOrganizationState(selection: try ClaudeOrganizationSelection(uuid: firstID, name: nil), bindingID: UUID().uuidString.lowercased())
        let root = URL(fileURLWithPath: "/tmp/trano-org-auth")
        XCTAssertEqual(try response(profile, root: root, id: firstID).organizationVerification, .verified)
        XCTAssertEqual(try response(profile, root: root, id: otherID).organizationVerification, .mismatch)
        XCTAssertEqual(try response(profile, root: root, id: nil).organizationVerification, .missing)
        XCTAssertEqual(try response(profile, root: root, id: firstID, method: "api_key").organizationVerification, .unavailable)
        let wrongRoot = Data("{\"loggedIn\":true,\"authMethod\":\"claude.ai\",\"configDirectory\":\"/tmp/another\",\"orgId\":\"\(firstID)\"}".utf8)
        let mismatch = try AccountAuthenticationAdapter.claude(account: profile, root: root, exitCode: 0, data: wrongRoot)
        XCTAssertEqual(mismatch.status, .unknown); XCTAssertNil(mismatch.organization)
        XCTAssertEqual(mismatch.organizationVerification, .unavailable)
    }

    // Implements: FR-ORG-3
    func testInvalidProviderMetadataCannotVerifyOrLeakIntoSnapshots() throws {
        var profile = AccountProfile(provider: .claude, label: "Work")
        profile.organization = AccountOrganizationState(selection: try ClaudeOrganizationSelection(uuid: firstID, name: nil), bindingID: UUID().uuidString.lowercased())
        let root = URL(fileURLWithPath: "/tmp/trano-org-auth")
        XCTAssertNotEqual(try response(profile, root: root, id: firstID, name: "bad\nname").organizationVerification, .verified)
        XCTAssertNotEqual(try response(profile, root: root, id: firstID, name: String(repeating: "a", count: 1000)).organizationVerification, .verified)
        XCTAssertEqual(try response(profile, root: root, id: "invalid").organizationVerification, .missing)
        XCTAssertThrowsError(try AccountAuthenticationAdapter.claude(account: profile, root: root, exitCode: 0, data: Data(repeating: 32, count: 65_537)))
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testPreflightRunsOutsideLockAndRevalidatesBindingBeforeCommit() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let profile = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: firstID, name: nil))
        let changed = expectation(description: "Independent state mutation completed during fake provider query")
        XCTAssertThrowsError(try runtime.preflightAccountOrganization(accountID: profile.id, cwd: "/tmp", authenticate: { account, root in
            DispatchQueue.global().async { try? runtime.updateAccount(profile.id, pinned: true); changed.fulfill() }
            self.wait(for: [changed], timeout: 2)
            try runtime.setAccountOrganization(profile.id, selection: ClaudeOrganizationSelection(uuid: self.otherID, name: nil))
            return try self.response(account, root: root, id: self.firstID)
        }))
        XCTAssertEqual(try runtime.state().accounts.first?.organization?.selection?.uuid, otherID)
        XCTAssertEqual(try runtime.state().accounts.first?.organization?.verification, .unverified)
    }

    // Implements: FR-ORG-3
    func testProviderQueryIsRefusedBeforeRunnerWhenCallerHoldsTransaction() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let profile = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: firstID, name: nil))
        var calls = 0
        try runtime.transaction {
            XCTAssertThrowsError(try runtime.preflightAccountOrganization(accountID: profile.id, cwd: "/tmp", authenticate: { account, root in
                calls += 1; return try self.response(account, root: root, id: self.firstID)
            }))
        }
        XCTAssertEqual(calls, 0)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testMatchingProofExpiresAndCannotSurviveBindingChangesOrWrongRoot() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let profile = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: firstID, name: nil))
        let proof = try runtime.preflightAccountOrganization(accountID: profile.id, cwd: "/tmp", authenticate: { account, root in try self.response(account, root: root, id: self.firstID) })
        XCTAssertNoThrow(try runtime.validateAccountOrganizationAuthorization(proof))
        XCTAssertThrowsError(try runtime.validateAccountOrganizationAuthorization(proof, now: Date().addingTimeInterval(61)))
        var wrongRoot = proof; wrongRoot.configurationRoot = "/tmp/another"
        XCTAssertThrowsError(try runtime.validateAccountOrganizationAuthorization(wrongRoot))
        try runtime.setAccountOrganization(profile.id, selection: ClaudeOrganizationSelection(uuid: otherID, name: nil))
        XCTAssertThrowsError(try runtime.validateAccountOrganizationAuthorization(proof))
    }

    // Implements: FR-ORG-1, FR-ORG-3
    func testUnboundAndCodexProfilesNeverInvokeClaudeOrganizationProbe() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        for provider in [AgentKind.claude, .codex] {
            let profile = try runtime.addAccount(provider: provider, label: "Legacy")
            let proof = try runtime.preflightAccountOrganization(accountID: profile.id, cwd: "/tmp", authenticate: { _, _ in XCTFail("Unexpected provider query"); throw TerminalError.invalid("Unexpected") })
            XCTAssertNoThrow(try runtime.validateAccountOrganizationAuthorization(proof))
            XCTAssertNoThrow(try runtime.accountCommand(profile.id))
        }
    }

    // Implements: FR-ORG-3
    func testMismatchAndMissingBlockPreflightAndPersistExplicitState() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let profile = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: firstID, name: nil))
        XCTAssertThrowsError(try runtime.preflightAccountOrganization(accountID: profile.id, cwd: "/tmp", authenticate: { account, root in try self.response(account, root: root, id: self.otherID) }))
        XCTAssertEqual(try runtime.state().accounts.first?.organization?.verification, .mismatch)
        XCTAssertThrowsError(try runtime.preflightAccountOrganization(accountID: profile.id, cwd: "/tmp", authenticate: { account, root in try self.response(account, root: root, id: nil) }))
        XCTAssertEqual(try runtime.state().accounts.first?.organization?.verification, .missing)
    }

    // Implements: FR-ORG-1, FR-ORG-4
    func testStaleEditCannotOverwriteNewBindingAndKnownChoicesReuseUUID() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let a = try runtime.addAccount(provider: .claude, label: "A")
        let b = try runtime.addAccount(provider: .claude, label: "B")
        let selection = try ClaudeOrganizationSelection(uuid: firstID, name: "Team")
        try runtime.setAccountOrganization(a.id, selection: selection, expectedBindingID: "")
        XCTAssertThrowsError(try runtime.setAccountOrganization(a.id, selection: nil, expectedBindingID: ""))
        try runtime.setAccountOrganization(b.id, selection: selection)
        XCTAssertEqual(try runtime.knownAccountOrganizations().map(\.uuid), [firstID])
        XCTAssertEqual(try runtime.state().accounts.count, 2)
    }

    // Implements: FR-ORG-3
    func testSidecarSymlinkAndInvalidVersionRefuseHydration() throws {
        let runtime = try runtime(); defer { try? FileManager.default.removeItem(at: runtime.root) }
        let profile = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: firstID, name: nil))
        _ = profile
        let sidecar = runtime.root.appendingPathComponent("account-organizations-v1.json")
        try TerminalRuntime.atomicWrite(Data(#"{"schemaVersion":99,"profiles":{}}"#.utf8), to: sidecar)
        XCTAssertThrowsError(try runtime.state())
        try FileManager.default.removeItem(at: sidecar)
        let target = runtime.root.appendingPathComponent("do-not-read")
        try TerminalRuntime.atomicWrite(Data(#"{"schemaVersion":1,"profiles":{}}"#.utf8), to: target)
        try FileManager.default.createSymbolicLink(at: sidecar, withDestinationURL: target)
        XCTAssertThrowsError(try runtime.state())
    }
}
