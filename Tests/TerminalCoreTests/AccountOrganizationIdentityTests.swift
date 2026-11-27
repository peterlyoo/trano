import XCTest
@testable import TerminalCore

final class AccountOrganizationIdentityTests: XCTestCase {
    private let org = "12345678-1234-4234-8234-123456789abc"
    private let other = "87654321-4321-4321-8321-cba987654321"
    private struct Fixture {
        let runtime: TerminalRuntime
        let profile: AccountProfile
        let root: URL
        let identity: OrganizationAuthenticationIdentityFixture
    }

    private func fixture() throws -> Fixture {
        let runtime = try TerminalRuntime(root: URL(fileURLWithPath: "/tmp/trano-ai-" + UUID().uuidString.prefix(8)))
        let identity = OrganizationAuthenticationIdentityFixture()
        runtime.accountAuthenticationIdentityReader = identity.reader()
        let account = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: org, name: "Team"))
        let root = try runtime.accountRoot(account.id)
        try write(["claudeAiOauth": ["accessToken": "fixture-alpha", "refreshToken": "fixture-refresh"]], root.appendingPathComponent(".credentials.json"))
        let global: [String: Any] = ["oauthAccount": ["accountUuid": "account-fixture", "organizationUuid": org], "numStartups": 1]
        try write(global, root.appendingPathComponent(".claude.json"))
        try write(global, root.appendingPathComponent(".config.json"))
        return Fixture(runtime: runtime, profile: account, root: root, identity: identity)
    }
    private func write(_ value: [String: Any], _ file: URL) throws {
        try TerminalRuntime.atomicWrite(JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), to: file)
    }
    private func response(_ account: AccountProfile, _ root: URL) throws -> AccountAuthenticationSnapshot {
        let data = try JSONSerialization.data(withJSONObject: ["loggedIn": true, "authMethod": "claude.ai", "configDirectory": root.path, "orgId": org, "orgName": "Team"])
        return try AccountAuthenticationAdapter.claude(account: account, root: root, exitCode: 0, data: data)
    }
    private func proof(_ fixture: Fixture) throws -> AccountOrganizationAuthorization {
        try fixture.runtime.preflightAccountOrganization(accountID: fixture.profile.id, cwd: "/tmp", authenticate: response)
    }
    private func mutate(_ kind: String, _ fixture: Fixture) throws {
        switch kind {
        case "credential": try write(["claudeAiOauth": ["accessToken": "fixture-beta"]], fixture.root.appendingPathComponent(".credentials.json"))
        case "settings":
            var data = try AccountUsageAdapter.object(Data(contentsOf: fixture.root.appendingPathComponent("settings.json")))
            data["forceLoginMethod"] = "console"
            try write(data, fixture.root.appendingPathComponent("settings.json"))
        case "global": try write(["oauthAccount": ["organizationUuid": other]], fixture.root.appendingPathComponent(".claude.json"))
        default: fixture.identity.keychainRevision += 1
        }
    }

    // Implements: FR-ORG-3
    func testCredentialConfigOrKeychainMutationDuringProbeCannotPersistVerifiedIdentity() throws {
        for kind in ["credential", "settings", "global", "keychain"] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            XCTAssertThrowsError(try fixture.runtime.preflightAccountOrganization(accountID: fixture.profile.id, cwd: "/tmp", authenticate: { account, root in
                try self.mutate(kind, fixture)
                return try self.response(account, root)
            }), kind)
            let state = try XCTUnwrap(fixture.runtime.state().accounts.first?.organization)
            XCTAssertNotEqual(state.verification, .verified, kind)
            XCTAssertNil(state.authenticationFingerprint, kind)
        }
    }

    // Implements: FR-ORG-3
    func testUnknownKeychainOrExecutableStorageStopsBeforeProviderProbe() throws {
        for keychain in [false, true] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            fixture.identity.denyKeychain = keychain
            fixture.identity.denyExecutable = !keychain
            var probes = 0
            XCTAssertThrowsError(try fixture.runtime.preflightAccountOrganization(accountID: fixture.profile.id, cwd: "/tmp", authenticate: { account, root in
                probes += 1; return try self.response(account, root)
            }))
            XCTAssertEqual(probes, 0)
            XCTAssertNotEqual(try fixture.runtime.state().accounts.first?.organization?.verification, .verified)
        }
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testCredentialConfigAndKeychainRotationBeforeGenerationCannotCreateActiveLaunch() throws {
        for kind in ["credential", "settings", "global", "keychain"] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            let proof = try proof(fixture)
            XCTAssertNotNil(proof.authenticationFingerprint)
            try mutate(kind, fixture)
            let pane = UUID().uuidString.lowercased()
            try fixture.runtime.update { $0.sessions.append(TerminalSession(id: pane, title: "Synthetic", cwd: "/tmp", pid: 0)) }
            XCTAssertThrowsError(try fixture.runtime.beginAgentLaunch(paneID: pane, provider: .claude, cwd: "/tmp", accountID: fixture.profile.id,
                                                                      organizationAuthorization: proof), kind)
            XCTAssertFalse(try fixture.runtime.state().agentLaunches.contains { $0.paneID == pane }, kind)
        }
    }

    // Implements: FR-ORG-3
    func testPureCommitInsideTransactionNeverQueriesKeychainOrExecutableVersion() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let proof = try proof(fixture)
        let reads = fixture.identity.keychainQueries, versions = fixture.identity.executableQueries
        try fixture.runtime.transaction { XCTAssertNoThrow(try fixture.runtime.validateAccountOrganizationAuthorization(proof)) }
        XCTAssertEqual(fixture.identity.keychainQueries, reads)
        XCTAssertEqual(fixture.identity.executableQueries, versions)
        try mutate("credential", fixture)
        try fixture.runtime.transaction { XCTAssertThrowsError(try fixture.runtime.validateAccountOrganizationAuthorization(proof)) }
        XCTAssertEqual(fixture.identity.keychainQueries, reads)
        XCTAssertEqual(fixture.identity.executableQueries, versions)
    }

    // Implements: FR-ORG-3
    func testUnrelatedProjectCountersAndHookWritesDoNotInvalidateAuthenticationProof() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let proof = try proof(fixture)
        for name in [".claude.json", ".config.json"] {
            var value = try AccountUsageAdapter.object(Data(contentsOf: fixture.root.appendingPathComponent(name)))
            value["numStartups"] = 900; value["projects"] = ["/tmp": ["lastSessionId": "unrelated"]]
            value["cachedGrowthBookFeatures"] = ["unrelated": true]
            try write(value, fixture.root.appendingPathComponent(name))
        }
        var settings = try AccountUsageAdapter.object(Data(contentsOf: fixture.root.appendingPathComponent("settings.json")))
        settings["hooks"] = ["Stop": []]; settings["theme"] = "dark"
        try write(settings, fixture.root.appendingPathComponent("settings.json"))
        _ = try fixture.runtime.accountCommand(fixture.profile.id)
        XCTAssertNoThrow(try fixture.runtime.revalidateAccountOrganizationAuthorization(proof))
        let encoded = String(decoding: try JSONEncoder().encode(proof), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-alpha")); XCTAssertFalse(encoded.contains("fixture-refresh"))
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testChangedIdentityRefusesSwitchBeforeTransferAndPureValidationChecksLocalMutation() throws {
        for keychain in [false, true] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            let source = try fixture.runtime.addAccount(provider: .claude, label: "Source")
            let sourceRoot = try fixture.runtime.accountRoot(source.id)
            let pane = UUID().uuidString.lowercased(), session = UUID().uuidString.lowercased()
            let transcript = try AccountSessionFiles.path("projects/-tmp/" + session + ".jsonl", beneath: sourceRoot, createParents: true)
            try TerminalRuntime.atomicWrite(Data("{\"sessionId\":\"\(session)\",\"cwd\":\"/tmp\",\"type\":\"user\",\"message\":{\"content\":\"synthetic\"}}\n".utf8), to: transcript)
            let launch = AgentLaunch(paneID: pane, provider: .claude, providerSessionID: session, cwd: "/tmp", accountID: source.id,
                configurationRoot: sourceRoot.path, bootID: try TerminalRuntime.bootIdentity(), processID: nil, providerPID: nil)
            try fixture.runtime.update { $0.sessions.append(TerminalSession(id: pane, title: "Synthetic", cwd: "/tmp", pid: 0)); $0.agentLaunches.append(launch) }
            let proof = try proof(fixture)
            let plan = try fixture.runtime.prepareAccountSwitch(paneID: pane, targetAccountID: fixture.profile.id, expectedGeneration: launch.id,
                toolsInFlight: false, safeTurnBoundary: true, organizationAuthorization: proof)
            try mutate(keychain ? "keychain" : "credential", fixture)
            XCTAssertThrowsError(try fixture.runtime.prepareAccountSwitch(paneID: pane, targetAccountID: fixture.profile.id, expectedGeneration: launch.id,
                toolsInFlight: false, safeTurnBoundary: true, organizationAuthorization: proof))
            if !keychain {
                let reads = fixture.identity.keychainQueries
                try fixture.runtime.transaction { XCTAssertThrowsError(try fixture.runtime.validateAccountSwitch(plan)) }
                XCTAssertEqual(fixture.identity.keychainQueries, reads)
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.runtime.root.appendingPathComponent("account-transfers").path))
        }
    }

    // Implements: FR-ORG-3
    func testSymlinkAndOversizedCredentialSourcesAreUnavailableWithoutProviderProbe() throws {
        for symlink in [false, true] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            let file = fixture.root.appendingPathComponent(".credentials.json")
            if symlink {
                try FileManager.default.moveItem(at: file, to: fixture.root.appendingPathComponent("retained.json"))
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: fixture.root.appendingPathComponent("retained.json"))
            } else { try TerminalRuntime.atomicWrite(Data(repeating: 32, count: 1_048_577), to: file) }
            var probes = 0
            XCTAssertThrowsError(try fixture.runtime.preflightAccountOrganization(accountID: fixture.profile.id, cwd: "/tmp", authenticate: { account, root in
                probes += 1; return try self.response(account, root)
            }))
            XCTAssertEqual(probes, 0)
        }
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testBoundLaunchOverridesAreRejectedBeforeAuthenticationOrGeneration() throws {
        for arguments in [["--settings", "/tmp/unowned-settings.json"], ["--settings={\"apiKeyHelper\":\"synthetic\"}"],
                          ["--setting-sources", "project"], ["--setting-sources=project"]] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            let command = try fixture.runtime.accountCommand(fixture.profile.id, arguments: arguments)
            var probes = 0
            XCTAssertThrowsError(try fixture.runtime.preflightAccountOrganization(accountID: fixture.profile.id, cwd: "/tmp", command: command,
                authenticate: { account, root in probes += 1; return try self.response(account, root) }))
            XCTAssertEqual(probes, 0)
            XCTAssertTrue(try fixture.runtime.state().agentLaunches.isEmpty)
        }
    }

    // Implements: FR-ORG-1, FR-ORG-3
    func testOwnedSettingsAndLiteralPromptRemainAllowedAndUnboundBehaviorIsPreserved() throws {
        let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        for arguments in [["--settings", fixture.root.appendingPathComponent("settings.json").path],
                          ["--settings=" + fixture.root.appendingPathComponent("trano-settings.json").path],
                          ["--", "--settings", "literal prompt"]] {
            let command = try fixture.runtime.accountCommand(fixture.profile.id, arguments: arguments)
            XCTAssertNoThrow(try fixture.runtime.preflightAccountOrganization(accountID: fixture.profile.id, cwd: "/tmp", command: command, authenticate: response))
        }
        for provider in [AgentKind.claude, .codex] {
            let account = try fixture.runtime.addAccount(provider: provider, label: "Unbound")
            let command = try fixture.runtime.accountCommand(account.id, arguments: ["--settings", "/tmp/unowned-settings.json", "--setting-sources=project"])
            XCTAssertNoThrow(try fixture.runtime.preflightAccountOrganization(accountID: account.id, cwd: "/tmp", command: command,
                authenticate: { _, _ in XCTFail("Unbound organization guard invoked authentication"); throw TerminalError.invalid("Unexpected") }))
        }
    }
}
