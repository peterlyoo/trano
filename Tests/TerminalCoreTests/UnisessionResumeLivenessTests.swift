import Foundation
import XCTest
@testable import TerminalCore

final class UnisessionResumeLivenessTests: XCTestCase {
    // Implements: FR-UNI-3, FR-UNI-6
    func testDeadBoundPaneResumesConversationInFreshTerminalInsteadOfOpeningSharedBlankShell() throws {
        try checkResume(live: false, lifecycle: .active)
    }

    func testEndedLaunchInLiveSharedShellResumesConversationInFreshTerminal() throws {
        try checkResume(live: true, lifecycle: .exited)
    }

    func testLiveActiveSharedLaunchStillReturnsRetainedOwnerWithoutWrites() throws {
        try checkResume(live: true, lifecycle: .active)
    }

    func testDeadMigratedLegacyBindingDoesNotFallBackToOldSupervisorOwner() throws {
        try checkResume(live: false, lifecycle: .active, migratedLegacy: true)
    }

    func testEndedMigratedLegacyLaunchDoesNotFallBackToOldSupervisorOwner() throws {
        try checkResume(live: true, lifecycle: .exited, migratedLegacy: true)
    }

    private func checkResume(live: Bool, lifecycle: AgentLifecycle, migratedLegacy: Bool = false) throws {
        let paneID = "44444444-4444-4444-8444-444444444444"
        let freshPaneID = "55555555-5555-4555-8555-555555555555"
        let sessionID = "33333333-3333-4333-8333-333333333333"
        let source = ConversationHistorySource(id: "source", provider: .codex, configurationRoot: "/tmp/provider", label: "Account")
        let entry = AgentConversation(source: source, providerSessionID: sessionID, title: "Conversation", cwd: "/tmp/project", updatedAt: Date(), relativePath: "sessions/rollout-" + sessionID + ".jsonl")
        var state = RuntimeState()
        var oldPane = TerminalSession(id: paneID, title: "Unisession", cwd: entry.cwd, pid: 123)
        oldPane.alive = live
        state.sessions = [oldPane]
        state.agentLaunches = [AgentLaunch(paneID: paneID, provider: .codex, providerSessionID: sessionID,
            cwd: entry.cwd, accountID: nil, configurationRoot: source.configurationRoot, bootID: "boot", lifecycle: lifecycle)]
        let context = ConversationResumeContext(state: state, livePaneIDs: live ? [paneID] : [], sources: [source], supervisorPaneID: migratedLegacy ? paneID : nil, unisessionPaneID: paneID)
        var calls: [String] = []
        let operations = ConversationResumeOperations(context: { context }, validate: { $0 }, create: { value in
            calls.append("create")
            return TerminalSession(id: freshPaneID, title: value.title, cwd: value.cwd, pid: 456)
        }, stage: { value, pane, _ in
            calls.append("stage")
            return AgentLaunch(paneID: pane.id, provider: value.source.provider, providerSessionID: value.providerSessionID,
                cwd: value.cwd, accountID: nil, configurationRoot: value.source.configurationRoot, bootID: "boot")
        }, launch: { _, _ in calls.append("launch") }, open: { _ in calls.append("open") }, rollback: { _ in calls.append("rollback") })
        let outcome = try ConversationResumeCoordinator.resume(entry, workspaceID: nil, operations: operations)
        if live && lifecycle == .active {
            XCTAssertTrue(outcome.existing)
            XCTAssertTrue(outcome.unisession)
            XCTAssertEqual(outcome.paneID, paneID)
            XCTAssertTrue(calls.isEmpty)
        } else {
            XCTAssertFalse(outcome.existing)
            XCTAssertFalse(outcome.unisession)
            XCTAssertEqual(outcome.paneID, freshPaneID)
            XCTAssertEqual(calls, ["create", "stage", "launch"])
        }
        XCTAssertFalse(outcome.supervisor)
    }
}
