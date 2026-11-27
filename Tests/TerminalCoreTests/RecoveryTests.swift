import XCTest
@testable import TerminalCore

final class RecoveryTests: XCTestCase {
    // Implements: FR-RECOVERY-1, FR-RECOVERY-3
    func testMissingConversationKeepsLayoutAndOpensShellWithDiagnostic() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-recover-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root) }
        let pane = try runtime.create(title: "Unbound agent", cwd: root.path)
        defer { try? runtime.terminate(pane.id) }
        try runtime.update { $0.layout.addTab(paneID: pane.id) }
        _ = try runtime.beginAgentLaunch(paneID: pane.id, provider: .claude, cwd: root.path)
        let layout = try runtime.state().layout
        try runtime.crashTestHost()
        let result = try runtime.recoverSessions(automatic: true)
        XCTAssertEqual(result.first?.status, .needsAttention)
        XCTAssertTrue(result.first?.message.contains("No verified conversation ID") == true)
        XCTAssertNil(try runtime.state().agentLaunches.first?.providerSessionID)
        XCTAssertEqual(try runtime.state().layout, layout)
        let shell = try XCTUnwrap(runtime.list().first)
        XCTAssertTrue(shell.alive)
        XCTAssertNotEqual(shell.pid, pane.pid)
        _ = try runtime.recoverSessions()
        XCTAssertEqual(try runtime.list().first?.pid, shell.pid)
        XCTAssertEqual(try runtime.state().recoveryResults.first?.status, .needsAttention)
    }

    // Implements: FR-RECOVERY-1
    func testBindingRejectsInheritedStaleAndChildIdentityAndStopIsNotExit() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-recover-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root) }
        let pane = try runtime.create(title: "Recovery", cwd: root.path)
        defer { try? runtime.terminate(pane.id) }
        let launch = try runtime.beginAgentLaunch(paneID: pane.id, provider: .claude, cwd: root.path)
        let sessionID = UUID().uuidString.lowercased()
        func event(_ id: String, kind: String = "SessionStart", child: Bool = false) throws -> Data {
            var value = ["session_id": id, "cwd": root.path, "hook_event_name": kind, "source": "startup"]
            if child { value["agent_id"] = "child" }
            return try JSONEncoder().encode(value)
        }
        try runtime.recordAgentHook(paneID: pane.id, generation: launch.id, provider: .claude, data: event(UUID().uuidString, child: true))
        XCTAssertNil(try runtime.state().agentLaunches.first?.providerSessionID)
        try runtime.recordAgentHook(paneID: pane.id, generation: UUID().uuidString, provider: .claude, data: event(UUID().uuidString))
        XCTAssertNil(try runtime.state().agentLaunches.first?.providerSessionID)
        try runtime.recordAgentHook(paneID: pane.id, generation: launch.id, provider: .claude, data: event(sessionID))
        try runtime.recordAgentHook(paneID: pane.id, generation: launch.id, provider: .claude, data: event(UUID().uuidString))
        XCTAssertEqual(try runtime.state().agentLaunches.first?.providerSessionID, sessionID)
        try runtime.recordAgentHook(paneID: pane.id, generation: launch.id, provider: .claude, data: event(sessionID, kind: "Stop"))
        XCTAssertEqual(try runtime.state().agentLaunches.first?.lifecycle, .active)
        XCTAssertEqual(try runtime.state().sessions.first?.activity.state, .done)
        try runtime.endAgentLaunch(paneID: pane.id, generation: launch.id, normalExit: true)
        XCTAssertEqual(try runtime.state().agentLaunches.first?.lifecycle, .exited)
        let next = try runtime.beginAgentLaunch(paneID: pane.id, provider: .codex, cwd: root.path)
        try runtime.endAgentLaunch(paneID: pane.id, generation: launch.id, normalExit: true)
        XCTAssertEqual(try runtime.state().agentLaunches.first?.id, next.id)
        XCTAssertEqual(try runtime.state().agentLaunches.first?.lifecycle, .active)
    }

    // Implements: FR-RECOVERY-2, FR-RECOVERY-3
    func testRebuildsSamePaneLayoutAndNeverRerunsExitedAgent() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-recover-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root)
        defer { runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root) }
        let pane = try runtime.create(title: "Recovery", cwd: root.path)
        defer { try? runtime.terminate(pane.id) }
        try runtime.update { $0.layout.addTab(paneID: pane.id) }
        let launch = try runtime.beginAgentLaunch(paneID: pane.id, provider: .codex, cwd: root.path)
        try runtime.endAgentLaunch(paneID: pane.id, generation: launch.id, normalExit: true)
        let layout = try runtime.state().layout
        try runtime.crashTestHost()
        try runtime.update { $0.settings.automaticRestore = false }
        XCTAssertTrue(try runtime.recoverSessions(automatic: true).isEmpty)
        XCTAssertFalse(try runtime.list().first!.alive)
        let result = try runtime.recoverSessions()
        XCTAssertEqual(result.first?.status, .restored)
        XCTAssertEqual(try runtime.state().layout, layout)
        let restored = try runtime.list().first!
        XCTAssertTrue(restored.alive)
        XCTAssertEqual(restored.id, pane.id)
        XCTAssertNotEqual(restored.pid, pane.pid)
        _ = try runtime.recoverSessions()
        XCTAssertEqual(try runtime.list().first?.pid, restored.pid)
        XCTAssertEqual(try runtime.state().agentLaunches.first?.lifecycle, .exited)
        XCTAssertThrowsError(try runtime.recoverSessions(paneID: UUID().uuidString))
    }

    // Implements: FR-RECOVERY-1
    func testResumeBackoffMatchesClaudeCodeRetryTiming() {
        XCTAssertEqual(RecoveryResumeBackoff.maximumRetries, 10)
        let floor = (1...10).map { RecoveryResumeBackoff.delay(attempt: $0, random: { 0 }) }
        XCTAssertEqual(floor, [0.5, 1, 2, 4, 8, 16, 32, 32, 32, 32])
        XCTAssertEqual(RecoveryResumeBackoff.delay(attempt: 3, random: { 0.999 }), 2.5, accuracy: 0.001)
        XCTAssertEqual(RecoveryResumeBackoff.delay(attempt: 12, random: { 0.5 }), 36)
        XCTAssertEqual(RecoveryResumeBackoff.delay(attempt: 0, random: { 0 }), 0.5)
    }

    // Implements: FR-RECOVERY-1, FR-RECOVERY-3
    func testFailedResumeInLiveShellCanBeRetriedAndRetryTargetsOnlyFailedResume() throws {
        let root = URL(fileURLWithPath: "/tmp/trano-recover-" + UUID().uuidString.prefix(6))
        let runtime = try TerminalRuntime(root: root, helperExecutable: "/usr/bin/true")
        runtime.host = PaneHostClient(root: runtime.root, executable: nil)
        defer { runtime.shutdownTestHost(); try? FileManager.default.removeItem(at: root) }
        let pane = try runtime.create(title: "Resume retry", cwd: root.path)
        defer { try? runtime.terminate(pane.id) }
        try runtime.update { $0.layout.addTab(paneID: pane.id) }
        let launch = try runtime.beginAgentLaunch(paneID: pane.id, provider: .claude, cwd: root.path, configurationRoot: root.path)
        let sessionID = UUID().uuidString.lowercased()
        let hook = try JSONEncoder().encode(["session_id": sessionID, "cwd": root.path, "hook_event_name": "SessionStart", "source": "startup"])
        try runtime.recordAgentHook(paneID: pane.id, generation: launch.id, provider: .claude, data: hook)
        try runtime.endAgentLaunch(paneID: pane.id, generation: launch.id, normalExit: false)

        XCTAssertNil(try runtime.pendingResumeRetry(paneID: pane.id, providerSessionID: sessionID))
        XCTAssertThrowsError(try runtime.retryRecovery(paneID: pane.id))

        try runtime.setRecovery(pane.id, status: .failed, message: RecoveryResumeBackoff.failurePrefix + " (exit 1)")
        XCTAssertEqual(try runtime.pendingResumeRetry(paneID: pane.id, providerSessionID: sessionID)?.id, launch.id)
        XCTAssertNil(try runtime.pendingResumeRetry(paneID: pane.id, providerSessionID: UUID().uuidString.lowercased()))

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, (try? runtime.retryRecovery(paneID: pane.id)) == nil { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertTrue(try runtime.list().first(where: { $0.id == pane.id })?.alive == true)
        XCTAssertEqual(try runtime.list().first(where: { $0.id == pane.id })?.pid, pane.pid)
        let result = try XCTUnwrap(runtime.state().recoveryResults.first(where: { $0.paneID == pane.id }))
        XCTAssertEqual(result.status, .restoring)
        XCTAssertThrowsError(try runtime.retryRecovery(paneID: pane.id))

        try runtime.setRecovery(pane.id, status: .failed, message: "Some other failure")
        XCTAssertNil(try runtime.pendingResumeRetry(paneID: pane.id, providerSessionID: sessionID))
    }
}
