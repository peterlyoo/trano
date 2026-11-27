import Foundation
import XCTest
@testable import TerminalCore

final class PessimisticTwinWorkerIsolationTests: XCTestCase {
    // Implements: FR-TWIN-5, FR-TWIN-6, FR-TWIN-8, FR-TWIN-9.
    func testBadFirstSocketHoldsOnlyItsRunAndHealthyRunsReachAdvancement() throws {
        let f = WorkerFixture(); f.badSockets = [f.bad.id]
        try f.iteration.run()
        XCTAssertEqual(f.runs[0].phase, .needsReview)
        XCTAssertEqual(f.startCalls, [f.bad.id, f.merge.id])
        XCTAssertTrue(f.inspectCalls.isEmpty)
        XCTAssertEqual(f.advanceCalls, 1)
        XCTAssertEqual(f.advancementRuns, [f.merge.id, f.cleanup.id])
        XCTAssertEqual(f.diagnostics.count, 1)
    }
    func testBadFirstTicketDoesNotFreezeHealthyMergeOrCleanup() throws {
        let f = WorkerFixture(); f.badTickets = [f.bad.id]
        try f.iteration.run()
        XCTAssertEqual(f.runs[0].phase, .needsReview)
        XCTAssertEqual(f.inspectCalls, [f.bad.id])
        XCTAssertEqual(f.advancementRuns, [f.merge.id, f.cleanup.id])
        XCTAssertEqual(f.advanceCalls, 1)
    }
    func testHeldRunDoesNotRetrySocketOrRewriteStatusEveryTick() throws {
        let f = WorkerFixture(); f.badSockets = [f.bad.id]
        try f.iteration.run(); let once = f.runs[0]
        try f.iteration.run()
        XCTAssertEqual(f.runs[0], once)
        XCTAssertEqual(f.startCalls.filter { $0 == f.bad.id }.count, 1)
        XCTAssertEqual(f.diagnostics.count, 1)
        XCTAssertEqual(f.advanceCalls, 2)
    }
    func testHeldConflictAndCleaningRunsDoNotStartAbsentListeners() throws {
        let f = WorkerFixture()
        f.runs[0].phase = .needsReview; f.runs[1].phase = .conflict
        try f.iteration.run()
        XCTAssertTrue(f.startCalls.isEmpty); XCTAssertTrue(f.inspectCalls.isEmpty)
        XCTAssertEqual(f.advanceCalls, 1)
    }
    func testExistingHeldListenerSurvivesAndInactiveListenerStops() throws {
        let f = WorkerFixture(); f.runs[0].phase = .needsReview
        f.liveScopes = [f.bad.id, "removed-run"]
        try f.iteration.run()
        XCTAssertTrue(f.liveScopes.contains(f.bad.id))
        XCTAssertEqual(f.stopCalls, ["removed-run"])
        XCTAssertFalse(f.startCalls.contains(f.bad.id))
    }
    func testShutdownDuringSocketStartStopsJustCreatedListenerAndDoesNotAdvance() throws {
        let f = WorkerFixture(); f.onStart = { _ in f.enabled = false }
        try f.iteration.run()
        XCTAssertEqual(f.startCalls, [f.bad.id]); XCTAssertEqual(f.stopCalls, [f.bad.id])
        XCTAssertTrue(f.liveScopes.isEmpty); XCTAssertEqual(f.advanceCalls, 0)
        XCTAssertTrue(f.diagnostics.isEmpty); XCTAssertEqual(f.runs[0].phase, .reviewing)
    }
    func testShutdownDuringTicketFailureDoesNotRewriteRunOrAdvance() throws {
        let f = WorkerFixture(); f.onInspect = { _ in f.enabled = false }; f.badTickets = [f.bad.id]
        try f.iteration.run()
        XCTAssertEqual(f.runs[0].phase, .reviewing)
        XCTAssertTrue(f.diagnostics.isEmpty); XCTAssertEqual(f.advanceCalls, 0)
    }
    func testShutdownBeforeTickHasNoSideEffects() throws {
        let f = WorkerFixture(); f.enabled = false
        try f.iteration.run()
        XCTAssertTrue(f.startCalls.isEmpty); XCTAssertTrue(f.stopCalls.isEmpty)
        XCTAssertEqual(f.advanceCalls, 0); XCTAssertEqual(f.loads, 0)
    }
    func testGlobalCanonicalLoadFailureRemainsGlobal() throws {
        let f = WorkerFixture(); f.loadFailure = true
        XCTAssertThrowsError(try f.iteration.run())
        XCTAssertTrue(f.startCalls.isEmpty); XCTAssertEqual(f.advanceCalls, 0)
    }
    func testFailureDiagnosticIsBoundedAndKeepsOneCanonicalLastMessage() throws {
        let f = WorkerFixture(); f.badTickets = [f.bad.id]
        f.errorMessage = String(repeating: "검증\0", count: 5000)
        try f.iteration.run()
        XCTAssertEqual(f.diagnostics.count, 1)
        XCTAssertLessThanOrEqual(f.diagnostics.first?.unicodeScalars.count ?? Int.max, 900)
        XCTAssertFalse(f.diagnostics.first?.contains("\0") ?? true)
        XCTAssertEqual(f.runs[0].message, f.diagnostics.first)
    }
    func testStaleFailureCannotOverrideNativeStopOrNewRoundOperation() throws {
        let f = WorkerFixture(); let expected = f.bad
        var stopped = expected; stopped.phase = .cleaning; stopped.exitReason = .userInterrupt
        XCTAssertNil(TwinWorkerIteration.heldRun(current: stopped, expected: expected, message: "stale", now: Date()))
        var claimed = expected; claimed.operation = TwinOperationIntent(kind: .publishDecision, round: 1)
        XCTAssertNil(TwinWorkerIteration.heldRun(current: claimed, expected: expected, message: "stale", now: Date()))
        var advanced = expected; advanced.rounds.append(TwinRound(number: 2))
        XCTAssertNil(TwinWorkerIteration.heldRun(current: advanced, expected: expected, message: "stale", now: Date()))
    }
    func testFailureDuringDurableOperationPreservesItsIntentForInspection() throws {
        let f = WorkerFixture(); var expected = f.bad
        expected.phase = .snapshotting; expected.operation = TwinOperationIntent(kind: .snapshot, round: 1)
        let held = TwinWorkerIteration.heldRun(current: expected, expected: expected, message: "socket unavailable", now: Date())
        XCTAssertEqual(held?.phase, .needsReview)
        XCTAssertEqual(held?.operation, expected.operation)
    }
    func testRunChangingToNativeStopDuringBadTicketStillAllowsHealthyAdvancement() throws {
        let f = WorkerFixture(); f.badTickets = [f.bad.id]
        f.onInspect = { _ in f.runs[0].phase = .cleaning; f.runs[0].exitReason = .userInterrupt }
        try f.iteration.run()
        XCTAssertEqual(f.runs[0].phase, .cleaning); XCTAssertEqual(f.runs[0].exitReason, .userInterrupt)
        XCTAssertTrue(f.diagnostics.isEmpty); XCTAssertEqual(f.advanceCalls, 1)
        XCTAssertTrue(f.advancementRuns.contains(f.merge.id)); XCTAssertTrue(f.advancementRuns.contains(f.cleanup.id))
    }

    func testCurrentFailurePreservesReportAndOperationWhileHoldingExactRound() throws {
        let f = WorkerFixture(); let expected = f.bad
        var current = expected
        current.rounds[0].report = TwinReport(status: "working", rationale: "Authenticated report arrived", changedFiles: [])
        let held = TwinWorkerIteration.heldRun(current: current, expected: expected, message: "bad ticket", now: Date(timeIntervalSince1970: 500))
        XCTAssertNotNil(held)
        XCTAssertEqual(held?.phase, .needsReview); XCTAssertEqual(held?.latestRound?.report, current.latestRound?.report)
        XCTAssertEqual(held?.source, expected.source); XCTAssertEqual(held?.operation, expected.operation)
        XCTAssertEqual(held?.updatedAt, Date(timeIntervalSince1970: 500))
    }
}

private enum WorkerFailure: LocalizedError {
    case failure(String)
    var errorDescription: String? { switch self { case .failure(let message): return message } }
}
private final class WorkerFixture {
    let bad = makeWorkerRun(.reviewing)
    let merge = makeWorkerRun(.waitingForMerge)
    let cleanup = makeWorkerRun(.cleaning)
    var runs: [TwinRun] = []
    var liveScopes: Set<String> = []
    var badSockets: Set<String> = [], badTickets: Set<String> = []
    var startCalls: [String] = [], stopCalls: [String] = [], inspectCalls: [String] = [], diagnostics: [String] = [], advancementRuns: [String] = []
    var advanceCalls = 0, loads = 0
    var enabled = true, loadFailure = false
    var errorMessage = "corrupt owned ticket"
    var onStart: ((TwinRun) -> Void)?, onInspect: ((TwinRun) -> Void)?
    init() { runs = [bad, merge, cleanup] }
    var iteration: TwinWorkerIteration {
        TwinWorkerIteration(active: { self.enabled }, load: {
            self.loads += 1
            if self.loadFailure { throw WorkerFailure.failure("corrupt canonical store") }
            return self.runs
        }, scopes: { self.liveScopes }, startScope: { run in
            self.startCalls.append(run.id)
            if self.badSockets.contains(run.id) { throw WorkerFailure.failure("scoped socket unavailable") }
            self.liveScopes.insert(run.id); self.onStart?(run)
        }, stopScope: { id in self.stopCalls.append(id); self.liveScopes.remove(id) }, inspectReview: { run in
            self.inspectCalls.append(run.id); self.onInspect?(run)
            if self.badTickets.contains(run.id) { throw WorkerFailure.failure(self.errorMessage) }
        }, hold: { expected, message in
            guard let index = self.runs.firstIndex(where: { $0.id == expected.id }),
                  let held = TwinWorkerIteration.heldRun(current: self.runs[index], expected: expected, message: message, now: Date(timeIntervalSince1970: 500)) else { return false }
            self.runs[index] = held; return true
        }, diagnostic: { self.diagnostics.append($0) }, advance: {
            self.advanceCalls += 1
            self.advancementRuns = self.runs.filter { [.waitingForMerge, .cleaning].contains($0.phase) }.map(\.id)
        })
    }
}
private func makeWorkerRun(_ phase: TwinPhase) -> TwinRun {
    let source = TwinSourceBinding(paneID: UUID().uuidString.lowercased(), generation: UUID().uuidString.lowercased(), conversationID: UUID().uuidString.lowercased(), cwd: "/project", configurationRoot: "/profile", provider: .codex, backendPID: 101, providerPID: 102, backendIdentity: .init(pid: 101, ownerUID: 501, startedAtSeconds: 1, startedAtMicroseconds: 1), providerIdentity: .init(pid: 102, ownerUID: 501, startedAtSeconds: 1, startedAtMicroseconds: 2))
    return TwinRun(source: source, mode: .codeReview, rounds: [TwinRound(number: 1)], phase: phase)
}
