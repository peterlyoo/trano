import XCTest
@testable import TerminalCore

final class AccountOrganizationContextTests: XCTestCase {
    private let org = "12345678-1234-4234-8234-123456789abc"
    private struct Fixture {
        let runtime: TerminalRuntime
        let account: AccountProfile
        let project: URL
        let authFile: URL
    }
    private func fixture() throws -> Fixture {
        let runtime = try TerminalRuntime(root: URL(fileURLWithPath: "/tmp/trano-auth-context-" + UUID().uuidString.prefix(8)))
        let project = runtime.root.appendingPathComponent("synthetic-project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let authFile = project.appendingPathComponent("auth-projection-fixture")
        try Data("source-a".utf8).write(to: authFile)
        runtime.accountAuthenticationIdentityReader = ClaudeAuthenticationIdentityReader(environment: { ["USER": "fixture", "PATH": "/fixture/bin"] },
            keychain: { _,_ in ClaudeKeychainMetadata(exists: true, digest: AccountSessionFiles.digest(Data("metadata".utf8))) },
            executable: { _,_ in AccountSessionFiles.digest(Data("executable".utf8)) },
            contextReader: { context,_ in
                guard context.cwd == project.path else { return AccountSessionFiles.digest(Data(context.cwd.utf8)) }
                return AccountSessionFiles.digest(try Data(contentsOf: authFile))
            })
        let account = try runtime.addAccount(provider: .claude, label: "Work", organization: ClaudeOrganizationSelection(uuid: org, name: nil))
        return Fixture(runtime: runtime, account: account, project: project, authFile: authFile)
    }
    private func response(_ account: AccountProfile, _ root: URL) throws -> AccountAuthenticationSnapshot {
        try AccountAuthenticationAdapter.claude(account: account, root: root, exitCode: 0,
            data: JSONSerialization.data(withJSONObject: ["loggedIn": true, "authMethod": "claude.ai", "configDirectory": root.path, "orgId": org]))
    }
    private func proof(_ f: Fixture) throws -> AccountOrganizationAuthorization {
        try f.runtime.preflightAccountOrganization(accountID: f.account.id, cwd: f.project.path, authenticate: response)
    }
    // Implements: FR-ORG-3, FR-ORG-4
    func testProofCapturesImmutableActualLaunchWorkingDirectory() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.runtime.root) }
        let proof = try proof(f)
        let raw = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(proof)) as? [String: Any])
        XCTAssertEqual((raw["authenticationContext"] as? [String: Any])?["cwd"] as? String, f.project.path)
        let pane = UUID().uuidString.lowercased()
        try f.runtime.update { $0.sessions.append(TerminalSession(id: pane, title: "Synthetic", cwd: f.project.path, pid: 0)) }
        XCTAssertThrowsError(try f.runtime.beginAgentLaunch(paneID: pane, provider: .claude, cwd: "/tmp", accountID: f.account.id, organizationAuthorization: proof))
        XCTAssertTrue(try f.runtime.state().agentLaunches.isEmpty)
    }
    // Implements: FR-ORG-3, FR-ORG-4
    func testProjectAuthenticationMutationDuringProbeCannotBecomeVerified() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.runtime.root) }
        XCTAssertThrowsError(try f.runtime.preflightAccountOrganization(accountID: f.account.id, cwd: f.project.path, authenticate: { account, root in
            try Data("source-b".utf8).write(to: f.authFile)
            return try self.response(account,root)
        }))
        XCTAssertNotEqual(try f.runtime.state().accounts.first?.organization?.verification, .verified)
    }
    // Implements: FR-ORG-3, FR-ORG-4
    func testProjectAuthenticationMutationBeforeGenerationAndPureCommitIsRefused() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.runtime.root) }
        let proof = try proof(f)
        try Data("source-b".utf8).write(to: f.authFile)
        try f.runtime.transaction { XCTAssertThrowsError(try f.runtime.validateAccountOrganizationAuthorization(proof)) }
        let pane = UUID().uuidString.lowercased()
        try f.runtime.update { $0.sessions.append(TerminalSession(id: pane, title: "Synthetic", cwd: f.project.path, pid: 0)) }
        XCTAssertThrowsError(try f.runtime.beginAgentLaunch(paneID: pane, provider: .claude, cwd: f.project.path, accountID: f.account.id, organizationAuthorization: proof))
        XCTAssertTrue(try f.runtime.state().agentLaunches.isEmpty)
    }
    // Implements: FR-ORG-3, FR-ORG-4
    func testProjectProofsDoNotOverwriteAnotherProjectsIdentityOrInvalidateItOnLocalChange() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.runtime.root) }
        let first = try proof(f)
        let secondProject = f.runtime.root.appendingPathComponent("second-project")
        try FileManager.default.createDirectory(at: secondProject, withIntermediateDirectories: true)
        let second = try f.runtime.preflightAccountOrganization(accountID: f.account.id, cwd: secondProject.path, authenticate: response)
        XCTAssertNil(try f.runtime.state().accounts.first?.organization?.authenticationFingerprint?.contextDigest)
        XCTAssertNoThrow(try f.runtime.validateAccountOrganizationAuthorization(first))
        XCTAssertNoThrow(try f.runtime.validateAccountOrganizationAuthorization(second))
        let persisted = try String(contentsOf: f.runtime.root.appendingPathComponent("account-organizations-v1.json"), encoding: .utf8)
        XCTAssertFalse(persisted.contains(f.project.path))
        try Data("source-b".utf8).write(to: f.authFile)
        XCTAssertThrowsError(try f.runtime.revalidateAccountOrganizationAuthorization(first))
        XCTAssertNoThrow(try f.runtime.validateAccountOrganizationAuthorization(second))
        XCTAssertEqual(try f.runtime.state().accounts.first?.organization?.verification, .verified)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testUnmodeledProjectOrManagedSelectorsRefuseBeforeAuthentication() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.runtime.root) }
        var probes = 0
        for name in ["--project-config-root", "--managed-settings", "--cwd"] {
            for args in [[name, f.project.path], [name + "=" + f.project.path]] {
                let command = AccountCommand(arguments: ["claude"] + args,
                    environment: ["CLAUDE_CONFIG_DIR": try f.runtime.accountRoot(f.account.id).path], removeEnvironment: [])
                XCTAssertThrowsError(try f.runtime.preflightAccountOrganization(accountID: f.account.id, cwd: f.project.path, command: command,
                    authenticate: { account,root in probes += 1; return try self.response(account,root) }))
            }
        }
        XCTAssertEqual(probes, 0)
        XCTAssertTrue(try f.runtime.state().agentLaunches.isEmpty)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testOldProofFailureCannotInvalidateANewerVerifiedRootIdentity() throws {
        let f = try fixture(); defer { try? FileManager.default.removeItem(at: f.runtime.root) }
        let old = try proof(f)
        let root = try f.runtime.accountRoot(f.account.id)
        try TerminalRuntime.atomicWrite(Data("{\"claudeAiOauth\":{\"accessToken\":\"synthetic-replacement\"}}".utf8), to: root.appendingPathComponent(".credentials.json"))
        let fresh = try proof(f)
        XCTAssertThrowsError(try f.runtime.revalidateAccountOrganizationAuthorization(old))
        XCTAssertEqual(try f.runtime.state().accounts.first?.organization?.verification, .verified)
        XCTAssertNoThrow(try f.runtime.validateAccountOrganizationAuthorization(fresh))
    }

}
