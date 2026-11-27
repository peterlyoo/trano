import XCTest
@testable import TerminalCore

final class AccountOrganizationRollbackTests: XCTestCase {
    private let organizationID = "12345678-1234-4234-8234-123456789abc"
    private struct Fixture {
        let runtime: TerminalRuntime
        let source: AgentLaunch
        let targetID: String
        let sourceRoot: URL
        let targetRoot: URL
        let destination: URL
        let backup: URL
        let receipt: AccountTransferReceipt
        let incoming: Data
        let previous: Data?
        let sourceCredential: Data
        let targetCredential: Data
    }

    private func fixture(replacing: Bool = true) throws -> Fixture {
        let runtime = try organizationFixtureRuntime(root: URL(fileURLWithPath: "/tmp/trano-or2-" + UUID().uuidString.prefix(8)))
        let source = try runtime.addAccount(provider: .claude, label: "Source")
        let target = try runtime.addAccount(provider: .claude, label: "Organization", organization: ClaudeOrganizationSelection(uuid: organizationID, name: "Team"))
        let sourceRoot = try runtime.accountRoot(source.id), targetRoot = try runtime.accountRoot(target.id)
        let sessionID = UUID().uuidString.lowercased(), paneID = UUID().uuidString.lowercased()
        let relative = "projects/-tmp/" + sessionID + ".jsonl"
        let incoming = Data("{\"sessionId\":\"\(sessionID)\",\"cwd\":\"/tmp\",\"type\":\"user\",\"message\":{\"content\":\"synthetic incoming\"}}\n".utf8)
        let sourceFile = try AccountSessionFiles.path(relative, beneath: sourceRoot, createParents: true)
        try TerminalRuntime.atomicWrite(incoming, to: sourceFile)
        let destination = try AccountSessionFiles.path(relative, beneath: targetRoot, createParents: true)
        let previous = replacing ? Data("previous synthetic target\n".utf8) : nil
        if let previous { try TerminalRuntime.atomicWrite(previous, to: destination) }
        let sourceCredential = Data(#"{"claudeAiOauth":{"accessToken":"synthetic-source"}}"#.utf8), targetCredential = Data(#"{"claudeAiOauth":{"accessToken":"synthetic-target"}}"#.utf8)
        try TerminalRuntime.atomicWrite(sourceCredential, to: sourceRoot.appendingPathComponent(".credentials.json"))
        try TerminalRuntime.atomicWrite(targetCredential, to: targetRoot.appendingPathComponent(".credentials.json"))
        let launch = AgentLaunch(paneID: paneID, provider: .claude, providerSessionID: sessionID, cwd: "/tmp", accountID: source.id,
                                 configurationRoot: sourceRoot.path, bootID: try TerminalRuntime.bootIdentity(), processID: nil, providerPID: nil)
        try runtime.update { $0.sessions.append(TerminalSession(id: paneID, title: "Synthetic", cwd: "/tmp", pid: 0)); $0.agentLaunches.append(launch) }
        let proof = try runtime.preflightAccountOrganization(accountID: target.id, cwd: "/tmp", authenticate: { account, root in
            let payload: [String: Any] = ["loggedIn": true, "authMethod": "claude.ai", "configDirectory": root.path,
                                          "orgId": self.organizationID, "orgName": "Team"]
            return try AccountAuthenticationAdapter.claude(account: account, root: root, exitCode: 0,
                                                            data: JSONSerialization.data(withJSONObject: payload))
        })
        let plan = try runtime.prepareAccountSwitch(paneID: paneID, targetAccountID: target.id, expectedGeneration: launch.id,
            toolsInFlight: false, safeTurnBoundary: true, organizationAuthorization: proof)
        let receipt = try runtime.transferAccountSession(plan)
        XCTAssertEqual(try Data(contentsOf: destination), incoming)
        return Fixture(runtime: runtime, source: launch, targetID: target.id, sourceRoot: sourceRoot, targetRoot: targetRoot,
            destination: destination, backup: runtime.root.appendingPathComponent("account-transfers/" + receipt.id), receipt: receipt,
            incoming: incoming, previous: previous, sourceCredential: sourceCredential, targetCredential: targetCredential)
    }

    private func assertCredentialsUnchanged(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(try Data(contentsOf: fixture.sourceRoot.appendingPathComponent(".credentials.json")), fixture.sourceCredential, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: fixture.targetRoot.appendingPathComponent(".credentials.json")), fixture.targetCredential, file: file, line: line)
    }

    // Implements: FR-ORG-3, FR-ORG-4, FR-ACCOUNT-2
    func testFailedOrUnconfirmedOrgResumeRestoresSourceMappingAndPriorTargetFile() throws {
        for failure in ["resume rejected", "confirmation timed out"] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            let target = AgentLaunch(paneID: fixture.source.paneID, provider: .claude, providerSessionID: fixture.source.providerSessionID,
                cwd: fixture.source.cwd, accountID: fixture.targetID, configurationRoot: fixture.targetRoot.path,
                bootID: try TerminalRuntime.bootIdentity(), processID: nil, providerPID: nil)
            try fixture.runtime.update { $0.agentLaunches.removeAll { $0.paneID == target.paneID }; $0.agentLaunches.append(target) }
            try fixture.runtime.restoreSwitchSource(fixture.source)
            try fixture.runtime.rollbackAccountTransfer(fixture.receipt)
            let restored = try XCTUnwrap(fixture.runtime.state().agentLaunches.first { $0.paneID == fixture.source.paneID })
            XCTAssertEqual(restored.id, fixture.source.id, failure)
            XCTAssertEqual(restored.accountID, fixture.source.accountID, failure)
            XCTAssertEqual(restored.providerSessionID, fixture.source.providerSessionID, failure)
            XCTAssertEqual(try fixture.runtime.state().recoveryResults.first?.status, .needsAttention, failure)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.previous, failure)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path), failure)
            try assertCredentialsUnchanged(fixture)
        }
    }

    // Implements: FR-ORG-3, FR-ACCOUNT-2
    func testFirstCopyRollbackWorksForDisabledPinnedOrgTargetWithoutAuthentication() throws {
        let fixture = try fixture(replacing: false); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        try fixture.runtime.updateAccount(fixture.targetID, enabled: false, pinned: true)
        try fixture.runtime.rollbackAccountTransfer(fixture.receipt)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.destination.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.backup.path))
        let target = try XCTUnwrap(fixture.runtime.state().accounts.first { $0.id == fixture.targetID })
        XCTAssertFalse(target.enabled); XCTAssertTrue(target.pinned)
        XCTAssertEqual(target.organization?.selection?.uuid, organizationID)
        try assertCredentialsUnchanged(fixture)
    }

    // Implements: FR-ORG-3, FR-ACCOUNT-2
    func testNewerTargetWorkAndChangedBackupRemainProtectedForOrgTarget() throws {
        for mutateBackup in [false, true] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            let mutation = Data("newer synthetic work\n".utf8)
            if mutateBackup {
                try TerminalRuntime.atomicWrite(mutation, to: fixture.backup.appendingPathComponent("backup/projects/-tmp/" + fixture.source.providerSessionID! + ".jsonl"))
            } else { try TerminalRuntime.atomicWrite(mutation, to: fixture.destination) }
            let before = try Data(contentsOf: fixture.destination)
            XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt))
            XCTAssertEqual(try Data(contentsOf: fixture.destination), before)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
            try assertCredentialsUnchanged(fixture)
        }
    }

    // Implements: FR-ORG-3, FR-ACCOUNT-2
    func testOrganizationMarkerRequiresValidSidecarAndCannotBeDowngradedForRollback() throws {
        for state in ["missing metadata", "corrupt metadata", "legacy downgrade", "unknown marker"] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            let metadata = fixture.runtime.root.appendingPathComponent("account-organizations-v1.json")
            switch state {
            case "missing metadata": try FileManager.default.removeItem(at: metadata)
            case "corrupt metadata": try TerminalRuntime.atomicWrite(Data(#"{"schemaVersion":99,"profiles":{}}"#.utf8), to: metadata)
            case "legacy downgrade": try TerminalRuntime.atomicWrite(Data("trano-account-v1\n".utf8), to: fixture.targetRoot.appendingPathComponent(".trano-account"))
            default: try TerminalRuntime.atomicWrite(Data("unowned\n".utf8), to: fixture.targetRoot.appendingPathComponent(".trano-account"))
            }
            XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt), state)
            XCTAssertEqual(try Data(contentsOf: fixture.destination), fixture.incoming, state)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path), state)
            try assertCredentialsUnchanged(fixture)
        }
    }

    // Implements: FR-ORG-3, FR-ACCOUNT-2
    func testMissingOrSymlinkedAccountRootIsNotCreatedOrTraversedDuringRollback() throws {
        for symlink in [false, true] {
            let fixture = try fixture(); defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            let retained = fixture.targetRoot.deletingLastPathComponent().appendingPathComponent(fixture.targetID + "-retained")
            try FileManager.default.moveItem(at: fixture.targetRoot, to: retained)
            if symlink { try FileManager.default.createSymbolicLink(at: fixture.targetRoot, withDestinationURL: retained) }
            XCTAssertThrowsError(try fixture.runtime.rollbackAccountTransfer(fixture.receipt))
            if !symlink { XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.targetRoot.path)) }
            XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent("projects/-tmp/" + fixture.source.providerSessionID! + ".jsonl")), fixture.incoming)
            XCTAssertEqual(try Data(contentsOf: retained.appendingPathComponent(".credentials.json")), fixture.targetCredential)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.backup.path))
        }
    }
}
