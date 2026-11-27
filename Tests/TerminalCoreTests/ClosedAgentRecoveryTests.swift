import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class ClosedAgentRecoveryTests: XCTestCase {
    // Implements: FR-CLOSE-4
    func testRecoveryCommandPreservesExactProviderConversationAndConfiguration() throws {
        let fixture = try Fixture()
        for provider in [AgentKind.claude, .codex] {
            let launch = fixture.launch(provider: provider)
            let command = try fixture.runtime.recoveryCommand(launch)
            XCTAssertEqual(command.arguments, provider == .claude
                ? ["claude", "--resume", launch.providerSessionID!]
                : ["codex", "resume", launch.providerSessionID!])
            XCTAssertEqual(command.environment[provider == .claude ? "CLAUDE_CONFIG_DIR" : "CODEX_HOME"], fixture.root.path)
            XCTAssertFalse(command.arguments.contains("--last"))
        }
    }

    // Implements: FR-CLOSE-4
    func testRecoveryCommandRejectsAChangedAccountProvider() throws {
        let fixture = try Fixture()
        let account = try fixture.runtime.addAccount(provider: .codex, label: "Synthetic")
        let launch = fixture.launch(provider: .claude, accountID: account.id,
                                    configurationRoot: try fixture.runtime.accountRoot(account.id).path)
        XCTAssertThrowsError(try fixture.runtime.recoveryCommand(launch))
    }

    // Implements: FR-CLOSE-4
    func testRecoveryCommandRejectsAChangedManagedConfigurationRoot() throws {
        let fixture = try Fixture()
        let account = try fixture.runtime.addAccount(provider: .codex, label: "Synthetic")
        let launch = fixture.launch(provider: .codex, accountID: account.id, configurationRoot: fixture.root.path)
        XCTAssertThrowsError(try fixture.runtime.recoveryCommand(launch))
    }

    // Implements: FR-CLOSE-4
    func testRecoveryCommandRejectsAChangedOrganizationBinding() throws {
        let fixture = try Fixture()
        let selection = try ClaudeOrganizationSelection(uuid: UUID().uuidString, name: "Synthetic")
        let account = try fixture.runtime.addAccount(provider: .claude, label: "Synthetic", organization: selection)
        var launch = fixture.launch(provider: .claude, accountID: account.id,
                                    configurationRoot: try fixture.runtime.accountRoot(account.id).path)
        launch.organizationBindingID = UUID().uuidString.lowercased()
        XCTAssertNotEqual(launch.organizationBindingID, account.organizationUsageBindingID)
        XCTAssertThrowsError(try fixture.runtime.recoveryCommand(launch))
    }

    // Implements: FR-CLOSE-4
    func testRecoveryCommandRejectsAddingOrganizationBindingAfterCapture() throws {
        let fixture = try Fixture()
        let selection = try ClaudeOrganizationSelection(uuid: UUID().uuidString, name: "Synthetic")
        let account = try fixture.runtime.addAccount(provider: .claude, label: "Synthetic", organization: selection)
        let launch = fixture.launch(provider: .claude, accountID: account.id,
                                    configurationRoot: try fixture.runtime.accountRoot(account.id).path)
        XCTAssertNil(launch.organizationBindingID)
        XCTAssertNotNil(account.organizationUsageBindingID)
        XCTAssertThrowsError(try fixture.runtime.recoveryCommand(launch))
    }

    // Implements: FR-CLOSE-4, FR-CLOSE-7
    func testResumeRejectsSameGenerationWhoseConversationChanged() throws {
        let fixture = try Fixture()
        let captured = fixture.launch()
        var replacement = captured
        replacement.providerSessionID = UUID().uuidString.lowercased()
        try fixture.stage(replacement)
        XCTAssertThrowsError(try fixture.runtime.beginAgentLaunch(paneID: fixture.paneID, provider: captured.provider,
            cwd: captured.cwd, configurationRoot: captured.configurationRoot, resume: captured))
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.id, captured.id)
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.providerSessionID, replacement.providerSessionID)
    }

    // Implements: FR-CLOSE-4, FR-CLOSE-7
    func testResumeRejectsSameGenerationWhoseDirectoryChanged() throws {
        let fixture = try Fixture()
        let captured = fixture.launch()
        var replacement = captured
        replacement.cwd = fixture.other.path
        try fixture.stage(replacement)
        XCTAssertThrowsError(try fixture.runtime.beginAgentLaunch(paneID: fixture.paneID, provider: captured.provider,
            cwd: captured.cwd, configurationRoot: captured.configurationRoot, resume: captured))
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.id, captured.id)
    }

    // Implements: FR-CLOSE-4, FR-CLOSE-7
    func testResumeRejectsAProviderDifferentFromTheCapturedSeed() throws {
        let fixture = try Fixture()
        let captured = fixture.launch(provider: .claude)
        try fixture.stage(captured)
        XCTAssertThrowsError(try fixture.runtime.beginAgentLaunch(paneID: fixture.paneID, provider: .codex,
            cwd: captured.cwd, configurationRoot: captured.configurationRoot, resume: captured))
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.id, captured.id)
    }

    // Implements: FR-CLOSE-4, FR-CLOSE-7
    func testResumeRejectsConfigurationDifferentFromTheCapturedSeed() throws {
        let fixture = try Fixture()
        let captured = fixture.launch()
        try fixture.stage(captured)
        XCTAssertThrowsError(try fixture.runtime.beginAgentLaunch(paneID: fixture.paneID, provider: captured.provider,
            cwd: captured.cwd, configurationRoot: fixture.other.path, resume: captured))
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.id, captured.id)
    }

    // Implements: FR-CLOSE-4, FR-CLOSE-7
    func testResumeRejectsDirectoryDifferentFromTheCapturedSeed() throws {
        let fixture = try Fixture()
        let captured = fixture.launch()
        try fixture.stage(captured)
        XCTAssertThrowsError(try fixture.runtime.beginAgentLaunch(paneID: fixture.paneID, provider: captured.provider,
            cwd: fixture.other.path, configurationRoot: captured.configurationRoot, resume: captured))
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.id, captured.id)
    }

    // Implements: FR-CLOSE-4, FR-CLOSE-7
    func testResumeRejectsAnAccountDifferentFromTheCapturedSeed() throws {
        let fixture = try Fixture()
        let captured = fixture.launch(provider: .codex)
        let account = try fixture.runtime.addAccount(provider: .codex, label: "Synthetic")
        try fixture.stage(captured)
        XCTAssertThrowsError(try fixture.runtime.beginAgentLaunch(paneID: fixture.paneID, provider: captured.provider,
            cwd: captured.cwd, accountID: account.id, configurationRoot: captured.configurationRoot, resume: captured))
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.id, captured.id)
    }

    // Implements: FR-CLOSE-4, FR-CLOSE-7
    func testResumeAcceptsDirectoryAliasAndPreservesCapturedDirectory() throws {
        let fixture = try Fixture()
        let captured = fixture.launch()
        try fixture.stage(captured)
        let alias = fixture.other.appendingPathComponent("project")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.root)
        let resumed = try fixture.runtime.beginAgentLaunch(paneID: fixture.paneID, provider: captured.provider,
            cwd: alias.path, configurationRoot: captured.configurationRoot, resume: captured)
        XCTAssertEqual(resumed.cwd, captured.cwd)
        XCTAssertEqual(resumed.providerSessionID, captured.providerSessionID)
        XCTAssertNotEqual(resumed.id, captured.id)
    }

    // Implements: FR-CLOSE-4, FR-CLOSE-7
    func testClosedResumeSeedPreservesFrozenIdentityWithFreshGeneration() throws {
        let fixture = try Fixture()
        var captured = fixture.launch(provider: .codex)
        captured.organizationBindingID = UUID().uuidString.lowercased()
        captured.processID = 101
        captured.providerPID = 102
        var exited = captured
        exited.lifecycle = .exited
        exited.processID = nil
        let seed = try XCTUnwrap(ClosedAgentRecovery.seed(source: captured, launches: [exited], bootID: "new-boot"))
        XCTAssertNotEqual(seed.id, captured.id)
        XCTAssertEqual(seed.provider, captured.provider)
        XCTAssertEqual(seed.providerSessionID, captured.providerSessionID)
        XCTAssertEqual(seed.cwd, captured.cwd)
        XCTAssertEqual(seed.accountID, captured.accountID)
        XCTAssertEqual(seed.configurationRoot, captured.configurationRoot)
        XCTAssertEqual(seed.organizationBindingID, captured.organizationBindingID)
        XCTAssertEqual(seed.bootID, "new-boot")
        XCTAssertEqual(seed.lifecycle, .active)
        XCTAssertNil(seed.processID)
        XCTAssertNil(seed.providerPID)
    }

    // Implements: FR-CLOSE-7
    func testClosedResumeDoesNotDispatchAnExistingNewGenerationTwice() throws {
        let fixture = try Fixture()
        let captured = fixture.launch()
        var dispatched = try XCTUnwrap(ClosedAgentRecovery.seed(source: captured, launches: [], bootID: "boot"))
        XCTAssertNil(try ClosedAgentRecovery.seed(source: captured, launches: [dispatched], bootID: "boot"))
        dispatched.lifecycle = .exited
        XCTAssertNil(try ClosedAgentRecovery.seed(source: captured, launches: [dispatched], bootID: "boot"))
    }

    // Implements: FR-CLOSE-7
    func testClosedResumeRejectsChangedConversationAndAnotherPaneBinding() throws {
        let fixture = try Fixture()
        let captured = fixture.launch()
        var changed = captured
        changed.providerSessionID = UUID().uuidString.lowercased()
        XCTAssertThrowsError(try ClosedAgentRecovery.seed(source: captured, launches: [changed], bootID: "boot"))
        let sibling = AgentLaunch(paneID: UUID().uuidString.lowercased(), provider: captured.provider,
            providerSessionID: captured.providerSessionID, cwd: captured.cwd, accountID: nil,
            configurationRoot: captured.configurationRoot, bootID: "boot")
        XCTAssertThrowsError(try ClosedAgentRecovery.seed(source: captured, launches: [sibling], bootID: "boot"))
    }

    // Implements: FR-CLOSE-4
    func testClosedResumeRejectsMissingVerifiedConversation() throws {
        let fixture = try Fixture()
        var captured = fixture.launch()
        captured.providerSessionID = nil
        XCTAssertThrowsError(try ClosedAgentRecovery.seed(source: captured, launches: [], bootID: "boot"))
    }

    // Implements: FR-CLOSE-7
    func testOldExitCannotChangeFreshClosedResumeSeed() throws {
        let fixture = try Fixture()
        let captured = fixture.launch()
        let seed = try XCTUnwrap(ClosedAgentRecovery.seed(source: captured, launches: [], bootID: "boot"))
        try fixture.stage(seed)
        try fixture.runtime.endAgentLaunch(paneID: fixture.paneID, generation: captured.id, normalExit: true)
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.id, seed.id)
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.lifecycle, .active)
    }

    // Implements: FR-CLOSE-2, FR-CLOSE-7
    func testProcessExitProbeRequiresExactBirthAndNeverSignalsTheProcess() throws {
        let current = try XCTUnwrap(SupervisorProcessIdentity.read(getpid()))
        XCTAssertFalse(ClosedAgentRecovery.processHasExited(current))
        let replaced = SupervisorProcessIdentity(pid: current.pid, ownerUID: current.ownerUID,
            startedAtSeconds: current.startedAtSeconds + 1, startedAtMicroseconds: current.startedAtMicroseconds)
        XCTAssertTrue(ClosedAgentRecovery.processHasExited(replaced))
        let invalid = SupervisorProcessIdentity(pid: 0, ownerUID: current.ownerUID,
            startedAtSeconds: current.startedAtSeconds, startedAtMicroseconds: current.startedAtMicroseconds)
        XCTAssertFalse(ClosedAgentRecovery.processHasExited(invalid))
        XCTAssertEqual(SupervisorProcessIdentity.read(getpid()), current)
    }

    // Implements: FR-CLOSE-4, FR-CLOSE-7
    func testScheduleStagesExactConversationWithFreshSeedAndSendsOnce() throws {
        let fixture = try Fixture()
        let snapshot = try fixture.closedSnapshot()
        try fixture.runtime.scheduleClosedAgentResume(snapshot)
        let seed = try XCTUnwrap(fixture.runtime.state().agentLaunches.first)
        XCTAssertNotEqual(seed.id, snapshot.launch?.id)
        XCTAssertEqual(seed.providerSessionID, snapshot.launch?.providerSessionID)
        XCTAssertEqual(seed.configurationRoot, snapshot.launch?.configurationRoot)
        XCTAssertEqual(try fixture.runtime.state().recoveryResults.first?.status, .restoring)
        XCTAssertEqual(try fixture.sentCommands().count, 2)
        try fixture.runtime.scheduleClosedAgentResume(snapshot)
        XCTAssertEqual(try fixture.sentCommands().count, 2)
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.id, seed.id)
    }

    // Implements: FR-CLOSE-7
    func testScheduleRetainsSeedAfterUnknownSendFailureWithoutRedispatch() throws {
        let fixture = try Fixture()
        let snapshot = try fixture.closedSnapshot()
        let failure = fixture.root.appendingPathComponent("fail-send")
        try Data().write(to: failure)
        XCTAssertThrowsError(try fixture.runtime.scheduleClosedAgentResume(snapshot))
        let seed = try XCTUnwrap(fixture.runtime.state().agentLaunches.first)
        XCTAssertNotEqual(seed.id, snapshot.launch?.id)
        XCTAssertEqual(try fixture.runtime.state().recoveryResults.first?.status, .failed)
        XCTAssertEqual(try fixture.sentCommands().count, 1)
        try FileManager.default.removeItem(at: failure)
        try fixture.runtime.scheduleClosedAgentResume(snapshot)
        XCTAssertEqual(try fixture.sentCommands().count, 1)
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.id, seed.id)
        XCTAssertEqual(try fixture.runtime.closedTerminalPaneSnapshot(fixture.paneID)?.archiveID, snapshot.archiveID)
    }

    // Implements: FR-CLOSE-2, FR-CLOSE-7
    func testScheduleRejectsUnreopenedSnapshotAndLivingOriginalProcess() throws {
        let fixture = try Fixture()
        var snapshot = try fixture.closedSnapshot(phase: .closed)
        XCTAssertThrowsError(try fixture.runtime.scheduleClosedAgentResume(snapshot))
        snapshot.phase = .reopened
        snapshot.processWitnesses = [try XCTUnwrap(SupervisorProcessIdentity.read(getpid()))]
        var ledger = try fixture.runtime.closedTerminalStore.ledger()
        ledger.panes[fixture.paneID] = snapshot
        try fixture.runtime.closedTerminalStore.save(ledger)
        XCTAssertThrowsError(try fixture.runtime.scheduleClosedAgentResume(snapshot))
        XCTAssertTrue(try fixture.sentCommands().isEmpty)
        XCTAssertEqual(try fixture.runtime.state().agentLaunches.first?.id, snapshot.launch?.id)
    }

    // Implements: FR-CLOSE-2
    func testAutomaticRecoverySkipsIntentionallyClosedDeadPane() throws {
        let fixture = try Fixture()
        _ = try fixture.closedSnapshot(phase: .closed)
        try Data().write(to: fixture.root.appendingPathComponent("mux-rows"))
        XCTAssertTrue(try fixture.runtime.recoverSessions(automatic: true).isEmpty)
        XCTAssertTrue(try fixture.runtime.state().recoveryResults.isEmpty)
        XCTAssertTrue(try fixture.sentCommands().isEmpty)
    }

    // Implements: FR-CLOSE-2
    func testStartupIgnoresClosedPaneStillPresentInPrimaryLayout() throws {
        let fixture = try Fixture()
        let snapshot = try fixture.closedSnapshot(phase: .closed)
        let other = TerminalSession(id: UUID().uuidString.lowercased(), title: "Open", cwd: fixture.root.path, pid: 900002)
        try fixture.runtime.update {
            $0.sessions.append(other)
            $0.layout.addTab(paneID: other.id)
            try $0.layout.selectTab(snapshot.tab.id)
        }
        XCTAssertEqual(try fixture.runtime.ensureInitialWorkspace(), other.id)
        XCTAssertEqual(try fixture.runtime.state().layout.focusedPaneID, other.id)
        XCTAssertTrue(try fixture.sentCommands().isEmpty)
    }

    private final class Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-close-agent-" + UUID().uuidString.prefix(8))
        let paneID = UUID().uuidString.lowercased()
        let other: URL
        let runtime: TerminalRuntime
        let backend = FakePaneBackend()

        init() throws {
            other = URL(fileURLWithPath: root.path + "-cwd")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            runtime = try TerminalRuntime(root: root, helperExecutable: "/usr/bin/true")
            let root = self.root
            backend.listOverride = {
                let rows = root.appendingPathComponent("mux-rows")
                guard FileManager.default.fileExists(atPath: rows.path) else { throw TerminalError.runtime("Fake pane rows are missing") }
                return try String(contentsOf: rows, encoding: .utf8).split(separator: "\n").compactMap { row in
                    let fields = row.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                    guard fields.count >= 3, let pid = Int32(fields[1]) else { return nil }
                    return FakePaneBackend.pane(id: fields[0], pid: pid, alive: fields[2] == "0",
                                                title: fields.count > 3 && !fields[3].isEmpty ? fields[3] : nil)
                }
            }
            backend.writeHook = { id, data in
                let sent = root.appendingPathComponent("mux-sent")
                let line = Data((id + " " + data.base64EncodedString() + "\n").utf8)
                if let handle = FileHandle(forWritingAtPath: sent.path) {
                    try handle.seekToEnd(); try handle.write(contentsOf: line); try handle.close()
                } else {
                    try line.write(to: sent)
                }
                if FileManager.default.fileExists(atPath: root.appendingPathComponent("fail-send").path) {
                    throw TerminalError.runtime("synthetic send failure")
                }
            }
            runtime.host = backend
        }

        func launch(provider: AgentKind = .claude, accountID: String? = nil,
                    configurationRoot: String? = nil) -> AgentLaunch {
            AgentLaunch(paneID: paneID, provider: provider, providerSessionID: UUID().uuidString.lowercased(),
                cwd: root.path, accountID: accountID, configurationRoot: configurationRoot ?? root.path,
                bootID: "closed-fixture", processID: nil)
        }

        func stage(_ launch: AgentLaunch) throws {
            try runtime.update {
                $0.sessions = [TerminalSession(id: paneID, title: "Synthetic", cwd: root.path, pid: 0)]
                $0.agentLaunches = [launch]
            }
        }

        func closedSnapshot(phase: ClosedPanePhase = .reopened) throws -> ClosedPaneSnapshot {
            let source = launch()
            var layout = WorkspaceLayout()
            layout.addWorkspace(title: "Synthetic")
            layout.addTab(paneID: paneID)
            let pane = TerminalSession(id: paneID, title: "Synthetic", cwd: root.path, pid: 900001)
            let snapshot = ClosedPaneSnapshot(pane: pane, shell: TerminalStartupCommand(executable: "/bin/zsh", arguments: ["-l"]),
                launch: source, processWitnesses: [], archiveID: UUID().uuidString.lowercased(),
                operationID: UUID().uuidString.lowercased(), phase: phase, tab: layout.tabs[0],
                workspace: layout.workspaces[0], closedAt: Date(), remoteSnapshot: nil)
            try runtime.update { $0.sessions = [pane]; $0.agentLaunches = [source]; $0.layout = layout }
            var ledger = try runtime.closedTerminalStore.ledger()
            ledger.panes[paneID] = snapshot
            try runtime.closedTerminalStore.save(ledger)
            try Data("\(paneID)|900001|0|\n".utf8).write(to: root.appendingPathComponent("mux-rows"))
            return snapshot
        }

        func sentCommands() throws -> [String] {
            let path = root.appendingPathComponent("mux-sent")
            guard FileManager.default.fileExists(atPath: path.path) else { return [] }
            return try String(contentsOf: path, encoding: .utf8).split(separator: "\n").map(String.init)
        }

        deinit {
            XCTAssertFalse(backend.calls.contains { $0.hasPrefix("create") || $0.hasPrefix("respawn") })
            for directory in [root, other] { try? FileManager.default.removeItem(at: directory) }
        }
    }
}
