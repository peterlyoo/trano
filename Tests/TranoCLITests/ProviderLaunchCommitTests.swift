import Foundation
import XCTest
@testable import TerminalCore
@testable import TranoCLI

final class ProviderLaunchCommitTests: XCTestCase {
    private enum Failure: Error, Equatable { case organizationChanged, spawnRejected }

    // Implements: FR-ORG-3, FR-ORG-4
    func testLateOrganizationGuardFailureEndsExactLaunchAndReportsFailureWithoutSpawning() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        var spawned = false
        XCTAssertThrowsError(try ProviderLaunchCommit.perform(runtime: fixture.runtime, sessionID: fixture.launch.paneID,
            launch: fixture.launch, agent: .claude) {
                try rejectOrganization()
                spawned = true
            }) { XCTAssertEqual($0 as? Failure, .organizationChanged) }
        XCTAssertFalse(spawned)
        try assertFailed(fixture)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testNonzeroSyntheticSpawnFailureUsesSameLaunchCleanupAndPreservesOriginalError() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        XCTAssertThrowsError(try ProviderLaunchCommit.perform(runtime: fixture.runtime, sessionID: fixture.launch.paneID,
            launch: fixture.launch, agent: .claude) {
                let spawnResult = Int32(2)
                guard spawnResult == 0 else { throw Failure.spawnRejected }
            }) { XCTAssertEqual($0 as? Failure, .spawnRejected) }
        try assertFailed(fixture)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testCleanupDoesNotChangeNewerGenerationOrItsRunningActivity() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        var replacement = fixture.launch
        replacement.id = UUID().uuidString.lowercased()
        replacement.processID = 434343
        var revisionAfterReplacement = -1
        XCTAssertThrowsError(try ProviderLaunchCommit.perform(runtime: fixture.runtime, sessionID: fixture.launch.paneID,
            launch: fixture.launch, agent: .claude) {
                try fixture.runtime.update { $0.agentLaunches = [replacement] }
                try fixture.runtime.report(replacement.paneID, state: .running, reason: "New generation", agent: .claude, source: "process")
                revisionAfterReplacement = try fixture.runtime.state().revision
                throw Failure.organizationChanged
            }) { XCTAssertEqual($0 as? Failure, .organizationChanged) }
        let after = try fixture.runtime.state()
        let launch = try XCTUnwrap(after.agentLaunches.first)
        XCTAssertEqual(launch.id, replacement.id)
        XCTAssertEqual(launch.lifecycle, .active)
        XCTAssertEqual(launch.processID, replacement.processID)
        XCTAssertEqual(after.sessions.first?.activity.state, .running)
        XCTAssertEqual(after.sessions.first?.activity.reason, "New generation")
        XCTAssertEqual(after.revision, revisionAfterReplacement)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testCleanupRejectsWrongPaneWrongProviderAndMissingLaunchWithoutMutatingState() throws {
        for mismatch in ["pane", "provider", "launch", "session"] {
            let fixture = try fixture()
            defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
            let before = try fixture.runtime.state()
            let session = mismatch == "session" ? nil : mismatch == "pane" ? UUID().uuidString.lowercased() : fixture.launch.paneID
            let launch = mismatch == "launch" ? nil : fixture.launch
            XCTAssertThrowsError(try ProviderLaunchCommit.perform(runtime: fixture.runtime, sessionID: session, launch: launch,
                agent: mismatch == "provider" ? .codex : .claude) { throw Failure.spawnRejected })
            let after = try fixture.runtime.state()
            XCTAssertEqual(after.revision, before.revision, mismatch)
            XCTAssertEqual(after.sessions, before.sessions, mismatch)
            XCTAssertEqual(after.agentLaunches.first?.lifecycle, .active, mismatch)
        }
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testSuccessfulCommitReturnsValueAndLeavesLaunchStateUnchanged() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        let before = try fixture.runtime.state()
        let result = try ProviderLaunchCommit.perform(runtime: fixture.runtime, sessionID: fixture.launch.paneID,
            launch: fixture.launch, agent: .claude) { 42 }
        let after = try fixture.runtime.state()
        XCTAssertEqual(result, 42)
        XCTAssertEqual(after.revision, before.revision)
        XCTAssertEqual(after.sessions, before.sessions)
        XCTAssertEqual(after.agentLaunches.first?.lifecycle, .active)
        XCTAssertEqual(after.agentLaunches.first?.processID, fixture.launch.processID)
    }

    // Implements: FR-ORG-3, FR-ORG-4
    func testCommitRunsOutsideRuntimeTransaction() throws {
        let fixture = try fixture()
        defer { try? FileManager.default.removeItem(at: fixture.runtime.root) }
        try ProviderLaunchCommit.perform(runtime: fixture.runtime, sessionID: fixture.launch.paneID,
            launch: fixture.launch, agent: .claude) { try fixture.runtime.assertOutsideSharedTransaction() }
    }

    private struct Fixture {
        let runtime: TerminalRuntime
        let launch: AgentLaunch
        let unrelatedPaneID: String
    }

    private func fixture() throws -> Fixture {
        let root = URL(fileURLWithPath: "/tmp/trano-spawn-" + UUID().uuidString.prefix(12))
        let runtime = try TerminalRuntime(root: root)
        let pane = UUID().uuidString.lowercased(), unrelated = UUID().uuidString.lowercased()
        let launch = AgentLaunch(paneID: pane, provider: .claude, providerSessionID: nil, cwd: "/tmp", accountID: nil,
                                 configurationRoot: root.appendingPathComponent("synthetic-config").path,
                                 bootID: "synthetic-boot", processID: 424242, providerPID: nil)
        try runtime.update {
            $0.sessions = [TerminalSession(id: pane, title: "Synthetic launch", cwd: "/tmp", pid: 0),
                           TerminalSession(id: unrelated, title: "Unrelated", cwd: "/tmp", pid: 0)]
            $0.agentLaunches = [launch]
        }
        try runtime.report(pane, state: .running, agent: .claude, source: "process")
        try runtime.report(unrelated, state: .running, reason: "Unrelated", agent: .codex, source: "process")
        return Fixture(runtime: runtime, launch: launch, unrelatedPaneID: unrelated)
    }

    private func assertFailed(_ fixture: Fixture, file: StaticString = #filePath, line: UInt = #line) throws {
        let after = try fixture.runtime.state()
        let launch = try XCTUnwrap(after.agentLaunches.first { $0.id == fixture.launch.id })
        XCTAssertEqual(launch.lifecycle, .exited, file: file, line: line)
        XCTAssertNil(launch.processID, file: file, line: line)
        let pane = try XCTUnwrap(after.sessions.first { $0.id == fixture.launch.paneID })
        XCTAssertEqual(pane.activity.state, .error, file: file, line: line)
        XCTAssertEqual(pane.activity.reason, "Launch failed", file: file, line: line)
        XCTAssertEqual(pane.activity.source, "process", file: file, line: line)
        let unrelated = try XCTUnwrap(after.sessions.first { $0.id == fixture.unrelatedPaneID })
        XCTAssertEqual(unrelated.activity.state, .running, file: file, line: line)
        XCTAssertEqual(unrelated.activity.reason, "Unrelated", file: file, line: line)
    }

    private func rejectOrganization() throws { throw Failure.organizationChanged }
}
