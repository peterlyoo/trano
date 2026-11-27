import XCTest
import TerminalCore
@testable import TranoApp

final class PessimisticTwinPresentationTests: XCTestCase {
    // Implements: FR-TWIN-1, FR-TWIN-6, FR-TWIN-8
    func testBackendAndManagedLauncherHaveDistinctPIDsForAValidSource() {
        XCTAssertTrue(PessimisticTwinMenuTarget.startable(local: true, alive: true, backendPID: 100,
            launcherPID: 150, providerPID: 200, provider: .codex, conversationID: "00000000-0000-0000-0000-000000000001"))
        XCTAssertFalse(PessimisticTwinMenuTarget.startable(local: true, alive: true, backendPID: 100,
            launcherPID: nil, providerPID: 200, provider: .codex, conversationID: "00000000-0000-0000-0000-000000000001"))
        XCTAssertFalse(PessimisticTwinMenuTarget.startable(local: false, alive: true, backendPID: 100,
            launcherPID: 150, providerPID: 200, provider: .codex, conversationID: "00000000-0000-0000-0000-000000000001"))
    }
    func testThreeNamedModesAndEveryLifecycleStageHaveHumanLabels() {
        XCTAssertEqual(TwinReviewMode.allCases.map(PessimisticTwinPresentation.title), ["Code Review", "Security Review", "General Review"])
        XCTAssertEqual(TwinPhase.allCases.map(PessimisticTwinPresentation.title), ["Waiting for Source", "Snapshotting", "Starting Twin", "Reviewing", "Decision Required", "Merge Scheduled", "Merging", "Sending Feedback", "Waiting for Response", "Cleaning Up", "Finished", "Review Needed", "Merge Conflict"])
    }
    func testActiveWaitingReviewAndConflictSummariesIncludeModeAndRound() {
        var run = pessimisticTwinControlRun(phase: .reviewing)
        XCTAssertEqual(PessimisticTwinPresentation.summary(run), "Code Review · Reviewing · Round 1/3")
        XCTAssertFalse(PessimisticTwinPresentation.needsAttention(run))
        for phase in [TwinPhase.needsReview, .conflict, .awaitingDecision] {
            run.phase = phase
            XCTAssertTrue(PessimisticTwinPresentation.needsAttention(run))
        }
        run.phase = .finished; run.exitReason = .roundCap
        XCTAssertEqual(PessimisticTwinPresentation.summary(run), "Code Review · Round Limit Reached · Round 1/3")
    }
    func testActivityKeepsActiveRunsBeforeRecentFinishedRunsAndBoundsHistory() {
        var active = pessimisticTwinControlRun(phase: .waitingForSource); active.updatedAt = Date(timeIntervalSince1970: 1)
        let finished = (0..<25).map { index -> TwinRun in
            var run = pessimisticTwinControlRun(phase: .finished); run.updatedAt = Date(timeIntervalSince1970: Double(index + 2)); return run
        }
        let rows = PessimisticTwinPresentation.visibleRuns(finished + [active])
        XCTAssertEqual(rows.count, 12)
        XCTAssertEqual(rows.first?.id, active.id)
        XCTAssertEqual(rows.dropFirst().map(\.id), Array(finished.reversed().prefix(11)).map(\.id))
    }
}
func pessimisticTwinControlRun(phase: TwinPhase = .waitingForSource) -> TwinRun {
    let identity = SupervisorProcessIdentity(pid: 100, ownerUID: 500, startedAtSeconds: 1, startedAtMicroseconds: 0)
    let source = TwinSourceBinding(paneID: "pane", generation: "generation", conversationID: "conversation", cwd: "/tmp/source", configurationRoot: "/tmp/config", provider: .codex, backendPID: 100, providerPID: 200, backendIdentity: identity, providerIdentity: identity)
    return TwinRun(source: source, mode: .codeReview, phase: phase)
}
