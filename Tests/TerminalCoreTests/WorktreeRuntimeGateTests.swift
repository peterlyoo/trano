import Foundation
import XCTest
@testable import TerminalCore

final class WorktreeRuntimeGateTests: XCTestCase {
    // Implements: FR-WT-2, FR-WT-3
    func testExactRootCompletionAndInputRevisionAreRequired() {
        let fixture = fixture()
        let context = WorktreeRuntimeGate.context(owner: fixture.owner, snapshot: fixture.state, backendBirth: fixture.owner.processIdentity,
            providerIdentity: "provider-birth", readyRevision: 9, hasPendingDecisions: false, receipt: nil, enabled: true)
        XCTAssertEqual(context.owner, fixture.owner)
        XCTAssertTrue(context.idle)
        XCTAssertEqual(context.completionID, "completion")
        XCTAssertEqual(context.turnID, "turn")
        XCTAssertEqual(context.inputRevision, 9)
        XCTAssertTrue(context.inputClear)
        let uncertain = WorktreeRuntimeGate.context(owner: fixture.owner, snapshot: fixture.state, backendBirth: fixture.owner.processIdentity,
            providerIdentity: "different-birth", readyRevision: nil, hasPendingDecisions: false, receipt: nil, enabled: true)
        XCTAssertFalse(uncertain.idle)
        XCTAssertNil(uncertain.completionID)
        XCTAssertFalse(uncertain.inputClear)
    }

    func testSubagentQueueDecisionAndAccountSwitchAreIndependentHolds() {
        var fixture = fixture()
        fixture.state.sessions[0].agentTasks = [AgentTask(id: "child", name: "Still working", agent: .claude, activity: Activity(), generation: fixture.owner.generation)]
        fixture.state.followUpInputs = [FollowUpInput(paneID: fixture.owner.paneID, text: "next", generation: fixture.owner.generation)]
        var monitor = AgentSupervision(generation: fixture.owner.generation); monitor.targetAccountID = "next-account"
        fixture.state.supervision = [monitor]
        let context = WorktreeRuntimeGate.context(owner: fixture.owner, snapshot: fixture.state, backendBirth: fixture.owner.processIdentity,
            providerIdentity: "provider-birth", readyRevision: 1, hasPendingDecisions: true, receipt: nil, enabled: true)
        XCTAssertTrue(context.hasActiveTools)
        XCTAssertTrue(context.hasQueuedWork)
        XCTAssertTrue(context.hasPendingDecisions)
        XCTAssertTrue(context.quotaSwitching)
    }

    func testOwnerReplacementOrNonSuccessfulActivityNeverAuthorizesCleanup() {
        var fixture = fixture()
        fixture.state.sessions[0].activity.state = .blocked
        let blocked = WorktreeRuntimeGate.context(owner: fixture.owner, snapshot: fixture.state, backendBirth: fixture.owner.processIdentity,
            providerIdentity: "provider-birth", readyRevision: 1, hasPendingDecisions: false, receipt: nil, enabled: false)
        XCTAssertFalse(blocked.idle)
        XCTAssertFalse(blocked.enabled)
        let replaced = WorktreeRuntimeGate.context(owner: fixture.owner, snapshot: fixture.state,
            backendBirth: SupervisorProcessIdentity(pid: 42, ownerUID: getuid(), startedAtSeconds: 999, startedAtMicroseconds: 0),
            providerIdentity: "provider-birth", readyRevision: 1, hasPendingDecisions: false, receipt: nil, enabled: true)
        XCTAssertNil(replaced.owner)
    }

    func testSuccessfulExitRequiresPriorStopReceiptAndExactInputRevision() {
        var fixture = fixture()
        fixture.state.agentLaunches[0].lifecycle = .exited
        fixture.state.sessions[0].activity.source = "process"
        fixture.state.followUpTurns = []
        let proof = WorktreeCompletionProof(owner: fixture.owner, completionID: "completion", turnID: "turn", completedAt: Date())
        let receipt = WorktreeExitReceipt(proof: proof, inputRevision: 7)
        func context(_ receipt: WorktreeExitReceipt?, revision: UInt64?) -> WorktreeCleanupContext {
            WorktreeRuntimeGate.context(owner: fixture.owner, snapshot: fixture.state, backendBirth: fixture.owner.processIdentity,
                providerIdentity: nil, readyRevision: revision, hasPendingDecisions: false, receipt: receipt, enabled: true)
        }
        XCTAssertFalse(context(nil, revision: 7).idle)
        XCTAssertFalse(context(receipt, revision: 8).idle)
        XCTAssertFalse(context(receipt, revision: nil).idle)
        XCTAssertTrue(context(receipt, revision: 7).idle)
        var replacement = fixture.state.agentLaunches[0]
        replacement.id = UUID().uuidString; replacement.lifecycle = .active
        fixture.state.agentLaunches.append(replacement)
        XCTAssertFalse(context(receipt, revision: 7).idle)
    }

    func testExitedRuntimeChecksTheExistingManagedLedgerWithoutRebindingIt() throws {
        let fixture = fixture()
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-wt-exit-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root)
        try runtime.update { $0 = fixture.state }
        let binding = TerminalInputBinding(paneID: fixture.owner.paneID, backendPID: fixture.owner.backendPID,
            generation: fixture.owner.generation, providerPID: 99)
        var ledger = TerminalInputLedger()
        let input = try ledger.beginManualWrite(binding: binding, submissionCandidate: true)
        XCTAssertTrue(ledger.finishWrite(input, succeeded: true))
        XCTAssertTrue(ledger.observeTrustedSubmit(binding: binding))
        let store = TerminalInputLedgerStore(root: root)
        try store.save(ledger)
        XCTAssertTrue(try runtime.worktreeCleanupContext(owner: fixture.owner, active: true).inputClear)
        try runtime.endAgentLaunch(paneID: fixture.owner.paneID, generation: fixture.owner.generation, normalExit: true)
        XCTAssertTrue(try runtime.worktreeCleanupContext(owner: fixture.owner, active: true).inputClear)
        let terminal = TerminalInputBinding(paneID: fixture.owner.paneID, backendPID: fixture.owner.backendPID,
            generation: "terminal:\(fixture.owner.backendPID)")
        let next = try ledger.beginManualWrite(binding: terminal, submissionCandidate: false)
        XCTAssertTrue(ledger.finishWrite(next, succeeded: true))
        try store.save(ledger)
        XCTAssertFalse(try runtime.worktreeCleanupContext(owner: fixture.owner, active: true).inputClear)
    }

    func testFinalMutationSerializesOtherRuntimeAdmissionsAndReleasesAfterFailure() throws {
        let fixture = fixture()
        let root = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano-wt-commit-" + UUID().uuidString.prefix(8))
        defer { try? FileManager.default.removeItem(at: root) }
        let runtime = try TerminalRuntime(root: root), other = try TerminalRuntime(root: root)
        let node = WorktreeFileIdentity(device: 1, inode: 2)
        let identity = WorktreeIdentity(path: "/task", commonDirectory: "/repo/.git", adminDirectory: "/repo/.git/worktrees/task",
            pathIdentity: node, gitFileIdentity: node, adminIdentity: node, commonIdentity: node)
        let record = WorktreeCleanupRecord(id: UUID().uuidString, owner: fixture.owner, identity: identity, createdAt: Date(),
            completion: WorktreeCompletionProof(owner: fixture.owner, completionID: "completion", turnID: "turn", completedAt: Date()))
        let context = WorktreeRuntimeGate.context(owner: fixture.owner, snapshot: fixture.state, backendBirth: fixture.owner.processIdentity,
            providerIdentity: "provider-birth", readyRevision: 9, hasPendingDecisions: false, receipt: nil, enabled: true)
        let started = DispatchSemaphore(value: 0), admitted = DispatchSemaphore(value: 0)
        try runtime.withWorktreeCleanupCommit(record: record, expectedContext: context, refresh: { context }) {
            DispatchQueue.global().async {
                started.signal()
                do { _ = try other.transaction { admitted.signal() } } catch { XCTFail(error.localizedDescription) }
            }
            XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
            XCTAssertEqual(admitted.wait(timeout: .now() + 0.05), .timedOut)
        }
        XCTAssertEqual(admitted.wait(timeout: .now() + 2), .success)
        enum MutationFailure: Error { case stopped }
        XCTAssertThrowsError(try runtime.withWorktreeCleanupCommit(record: record, expectedContext: context, refresh: { context }) { throw MutationFailure.stopped })
        try other.transaction {}
        var mutations = 0
        let changed = WorktreeCleanupContext(enabled: false, local: true, owner: fixture.owner)
        XCTAssertThrowsError(try runtime.withWorktreeCleanupCommit(record: record, expectedContext: context, refresh: { changed }) { mutations += 1 })
        XCTAssertEqual(mutations, 0)
    }

    private func fixture() -> (owner: WorktreeOwner, state: RuntimeState) {
        let paneID = UUID().uuidString.lowercased(), generation = UUID().uuidString.lowercased()
        let owner = WorktreeOwner(paneID: paneID, generation: generation, backendPID: 42,
            processIdentity: SupervisorProcessIdentity(pid: 42, ownerUID: getuid(), startedAtSeconds: 10, startedAtMicroseconds: 0))
        var pane = TerminalSession(id: paneID, title: "Agent", cwd: "/project", pid: 42)
        pane.activity.state = .done; pane.activity.source = "hook"
        var launch = AgentLaunch(paneID: paneID, provider: .claude, cwd: "/project", accountID: nil, configurationRoot: "/profile", bootID: "boot")
        launch.id = generation; launch.providerPID = 99
        var turn = FollowUpTurn(paneID: paneID, generation: generation)
        turn.completionID = "completion"; turn.promptID = "turn"; turn.providerPID = 99; turn.providerIdentity = "provider-birth"; turn.completedAt = Date()
        var state = RuntimeState(); state.sessions = [pane]; state.agentLaunches = [launch]; state.followUpTurns = [turn]
        return (owner, state)
    }
}

final class WorktreeCleanupErrorPresentationTests: XCTestCase {
    // Implements: FR-WT-5
    func testHeldReasonPreservesGitSafetyExplanation() {
        XCTAssertEqual(WorktreeGitError.unsafe("Sparse checkout prevents cleanup").localizedDescription, "Sparse checkout prevents cleanup")
    }
}
