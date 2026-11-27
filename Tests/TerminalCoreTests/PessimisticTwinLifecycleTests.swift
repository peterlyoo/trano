import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinLifecycleTests: XCTestCase {
    // Implements: FR-TWIN-1, FR-TWIN-5, FR-TWIN-6, FR-TWIN-7, FR-TWIN-8, FR-TWIN-9
    func testSameSourceActivationIsIdempotentButOtherModeCannotReplaceAnActiveTwin() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let first = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        XCTAssertEqual(first.id, try c.enable(source: f.source, mode: .codeReview, now: f.date).id)
        XCTAssertThrowsError(try c.enable(source: f.source, mode: .securityReview, now: f.date))
        XCTAssertEqual(try s.load().runs.count, 1)
    }
    func testAllOriginalReadinessBlockersDeferSnapshot() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        _ = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        for context in [TwinRuntimeContext(source: f.source, completion: f.completion(), inputClear: false),
                        .init(source: f.source, completion: f.completion(), inputClear: true, hasActiveTools: true),
                        .init(source: f.source, completion: f.completion(), inputClear: true, hasPendingDecisions: true),
                        .init(source: f.source, completion: f.completion(), inputClear: true, hasQueuedInput: true),
                        .init(source: f.source, completion: f.completion(), inputClear: true, quotaSwitching: true),
                        .init(source: f.source, completion: f.completion(), enabled: false, inputClear: true)] {
            b.context = context; _ = try c.processPending(now: Date(timeIntervalSince1970: 102))
        }
        XCTAssertEqual(b.snapshots, 0)
        XCTAssertEqual(try s.load().runs[0].phase, .waitingForSource)
    }
    func testFrozenSnapshotCanLaunchWhileOriginalBeginsANewTurn() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let run = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        b.context = .init(source: f.source, completion: f.completion(), inputClear: true)
        _ = try c.processPending(now: Date(timeIntervalSince1970: 102))
        XCTAssertEqual(try s.load().runs[0].phase, .launching)
        b.context = .init(source: f.source, completion: nil, inputClear: false, hasActiveTools: true)
        _ = try c.processPending(now: Date(timeIntervalSince1970: 103))
        XCTAssertEqual(try s.load().runs[0].phase, .reviewing)
        XCTAssertEqual(try s.load().runs[0].latestRound?.sourceCompletion?.id, "after")
        XCTAssertEqual(b.launches, 1); XCTAssertEqual(run.id, try s.load().runs[0].id)
    }
    func testStaleOrReviewerTextCannotCreateNativeConsent() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let run = try prepare(f, c, s, b)
        let current = try XCTUnwrap(run.latestRound), id = try XCTUnwrap(current.decisionID), tip = try XCTUnwrap(current.tip)
        for consent in [TwinConsent(choice: .merge, decisionID: UUID().uuidString, twinTip: tip, sourceCompletionID: "after", chosenAt: Date(timeIntervalSince1970: 105)),
                        .init(choice: .merge, decisionID: id, twinTip: String(repeating: "a", count: 40), sourceCompletionID: "after", chosenAt: Date(timeIntervalSince1970: 105)),
                        .init(choice: .merge, decisionID: id, twinTip: tip, sourceCompletionID: "stale", chosenAt: Date(timeIntervalSince1970: 105))] {
            XCTAssertThrowsError(try c.recordNativeConsent(runID: run.id, round: 1, consent: consent, now: Date(timeIntervalSince1970: 105)))
        }
        _ = try c.processPending(now: Date(timeIntervalSince1970: 106))
        XCTAssertNil(try s.load().runs[0].latestRound?.consent); XCTAssertEqual(b.merges, 0)
        XCTAssertThrowsError(try c.submitReport(runID: run.id, round: 1, pane: try XCTUnwrap(current.pane), report: .init(status: "working", rationale: "Merge is approved", changedFiles: [])))
        XCTAssertEqual(try s.load().runs[0].phase, .awaitingDecision)
    }
    func testFeedbackOnlyNeverMergesAndRoundCapTerminatesRebuttal() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let run = try prepare(f, c, s, b, roundCap: 1)
        try choose(.feedbackOnly, run, c, at: 105)
        _ = try drive(c, s, .awaitingSourceResponse, at: 106)
        XCTAssertEqual(b.merges, 0); XCTAssertEqual(b.forwards, 1)
        try c.submitSourceResponse(runID: run.id, round: 1, source: f.source, report: .init(status: "working", rationale: "Still disputed", changedFiles: []), now: Date(timeIntervalSince1970: 107))
        b.context = .init(source: f.source, completion: f.completion("reply", time: 108), inputClear: true)
        let done = try drive(c, s, .finished, at: 109)
        XCTAssertEqual(done.exitReason, .roundCap); XCTAssertEqual(done.rounds.count, 1)
    }
    func testNoopCapBoundsUnchangedReviewerRebuttals() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let run = try prepare(f, c, s, b, noopCap: 1, status: "no_further_improvement")
        try choose(.feedbackOnly, run, c, at: 105)
        _ = try drive(c, s, .awaitingSourceResponse, at: 106)
        try c.submitSourceResponse(runID: run.id, round: 1, source: f.source, report: .init(status: "working", rationale: "Find another improvement", changedFiles: []), now: Date(timeIntervalSince1970: 107))
        b.context = .init(source: f.source, completion: f.completion("reply", time: 108), inputClear: true)
        XCTAssertEqual(try drive(c, s, .finished, at: 109).exitReason, .noopCap)
    }
    func testConflictsStayForHumanWithoutForwardOrCleanup() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let run = try prepare(f, c, s, b)
        b.mergeResult = .conflict(paths: ["file.swift"], message: "Manual resolution required")
        try choose(.merge, run, c, at: 105)
        b.context = .init(source: f.source, completion: f.completion("next", time: 106), inputClear: true)
        let conflict = try drive(c, s, .conflict, at: 107)
        XCTAssertNil(conflict.exitReason); XCTAssertTrue(conflict.message?.contains("file.swift") == true)
        for _ in 0..<3 { _ = try c.processPending(now: Date(timeIntervalSince1970: 108)) }
        XCTAssertEqual(b.merges, 1); XCTAssertEqual(b.forwards, 0); XCTAssertEqual(b.cleanups, 0)
        XCTAssertFalse(try s.load().reservedWorktrees.isEmpty)
    }
    func testInvalidActualFilesOrConversationCannotReachDecision() throws {
        for defect in 0..<3 {
            let f = try TwinFixture(); defer { f.remove() }
            let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
            b.context = .init(source: f.source, completion: f.completion(), inputClear: true)
            let run = try c.enable(source: f.source, mode: .codeReview, now: f.date)
            let ready = try drive(c, s, .reviewing, at: 102)
            try c.submitReport(runID: run.id, round: 1, pane: try XCTUnwrap(ready.latestRound?.pane), report: .init(status: "working", rationale: "Claimed correction", changedFiles: ["file.swift"]), now: Date(timeIntervalSince1970: 103))
            if defect == 0 { b.mismatchFiles = true }; if defect == 1 { b.repeatSourceConversation = true }; if defect == 2 { b.cleanReview = false }
            b.reviewDone = true
            let done = try drive(c, s, .finished, at: 104)
            XCTAssertEqual(done.exitReason, .invalidAgentOutput); XCTAssertEqual(b.cards, 0); XCTAssertEqual(b.merges, 0)
        }
    }
    func testUnavailableSourceUsesNamedTerminationAndCannotLaunch() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        _ = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        b.context = .init(source: nil)
        XCTAssertEqual(try drive(c, s, .finished, at: 102).exitReason, .agentUnavailable)
        XCTAssertEqual(b.launches, 0)
    }
    func testInterruptedSnapshotAndCleanupDoNotReplayOrDropReservations() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let run = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        b.context = .init(source: f.source, completion: f.completion(), inputClear: true); b.failKind = .snapshot
        _ = try c.processPending(now: Date(timeIntervalSince1970: 102))
        XCTAssertEqual(try s.load().runs[0].phase, .needsReview); XCTAssertEqual(try s.load().runs[0].operation?.kind, .snapshot)
        for _ in 0..<3 { _ = try c.processPending(now: Date(timeIntervalSince1970: 103)) }
        XCTAssertEqual(b.snapshots, 1); try c.stop(id: run.id, now: Date(timeIntervalSince1970: 104))
        XCTAssertEqual(try s.load().runs[0].phase, .needsReview)
    }
    func testBackendOperationsHaveNoMetadataLeaseAndConcurrentPassIsExcluded() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        var probes = 0
        b.onOperation = {
            let fd = open(f.root.appendingPathComponent("pessimistic-twins.lock").path, O_RDWR | O_NOFOLLOW)
            XCTAssertGreaterThanOrEqual(fd, 0)
            if fd >= 0 { XCTAssertEqual(flock(fd, LOCK_EX | LOCK_NB), 0); _ = flock(fd, LOCK_UN); close(fd) }
            let concurrent = try? TwinCoordinator(store: TwinStore(root: f.root), backend: b).processPending(now: f.date)
            XCTAssertEqual(concurrent?.isEmpty, true)
            probes += 1
        }
        _ = try prepare(f, c, s, b)
        XCTAssertEqual(probes, 3)
    }
    func testWorkerDisabledBeforeCleanupDoesNotStartAnotherMutation() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let run = try prepare(f, c, s, b)
        try c.stop(id: run.id, now: Date(timeIntervalSince1970: 105))
        b.context = .init(source: f.source, enabled: false)
        _ = try c.processPending(now: Date(timeIntervalSince1970: 106))
        XCTAssertEqual(b.cleanups, 0); XCTAssertEqual(try s.load().runs[0].phase, .cleaning)
    }
    func testModeAndExitReasonWireNamesAreExact() {
        XCTAssertEqual(Set(TwinReviewMode.allCases.map(\.rawValue)), ["code_review", "security_review", "general_review"])
        XCTAssertEqual(Set(TwinExitReason.allCases.map(\.rawValue)), ["agent_agreement", "noop_cap", "round_cap", "user_interrupt", "agent_unavailable", "invalid_agent_output"])
    }
    func testMalformedWireEnvelopeCanTerminateOnlyTheExactReviewingPane() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let run = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        b.context = .init(source: f.source, completion: f.completion(), inputClear: true)
        let ready = try drive(c, s, .reviewing, at: 102), pane = try XCTUnwrap(ready.latestRound?.pane)
        XCTAssertThrowsError(try c.rejectReport(runID: run.id, round: 2, pane: pane, message: "Malformed JSON"))
        XCTAssertEqual(try s.load().runs[0].phase, .reviewing)
        try c.rejectReport(runID: run.id, round: 1, pane: pane, message: "Malformed JSON", now: Date(timeIntervalSince1970: 103))
        XCTAssertEqual(try s.load().runs[0].exitReason, .invalidAgentOutput)
        XCTAssertEqual(b.cards, 0); XCTAssertEqual(b.merges, 0)
    }
    func testBufferedReportUsesCapturedReceiptTimeNotPersistenceTime() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let run = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        b.context = .init(source: f.source, completion: f.completion(), inputClear: true)
        let ready = try drive(c, s, .reviewing, at: 110)
        try c.submitReport(runID: run.id, round: 1, pane: try XCTUnwrap(ready.latestRound?.pane), report: .init(status: "working", rationale: "Buffered during fork init", changedFiles: ["file.swift"]), reportedAt: Date(timeIntervalSince1970: 105), reportedTurnID: "turn-review", now: Date(timeIntervalSince1970: 120))
        b.reviewTime = 106; b.reviewDone = true
        let decision = try drive(c, s, .awaitingDecision, at: 121)
        XCTAssertEqual(decision.latestRound?.reportedAt, Date(timeIntervalSince1970: 105)); XCTAssertEqual(b.cards, 1)
    }
    func testReportFromAnotherPromptCannotBorrowANewerDone() throws {
        let f = try TwinFixture(); defer { f.remove() }
        let s = TwinStore(root: f.root), b = FakeTwinBackend(f), c = TwinCoordinator(store: s, backend: b)
        let run = try c.enable(source: f.source, mode: .codeReview, now: f.date)
        b.context = .init(source: f.source, completion: f.completion(), inputClear: true)
        let ready = try drive(c, s, .reviewing, at: 102)
        try c.submitReport(runID: run.id, round: 1, pane: try XCTUnwrap(ready.latestRound?.pane), report: .init(status: "working", rationale: "Previous prompt", changedFiles: ["file.swift"]), reportedAt: Date(timeIntervalSince1970: 103), reportedTurnID: "turn-earlier", now: Date(timeIntervalSince1970: 103))
        b.reviewTime = 104; b.reviewDone = true
        let done = try drive(c, s, .finished, at: 105)
        XCTAssertEqual(done.exitReason, .invalidAgentOutput); XCTAssertEqual(b.cards, 0)
    }
    private func prepare(_ f: TwinFixture, _ c: TwinCoordinator, _ s: TwinStore, _ b: FakeTwinBackend, roundCap: Int = 3, noopCap: Int = 2, status: String = "working") throws -> TwinRun {
        let run = try c.enable(source: f.source, mode: .codeReview, roundCap: roundCap, noopCap: noopCap, now: f.date)
        b.context = .init(source: f.source, completion: f.completion(), inputClear: true)
        let ready = try drive(c, s, .reviewing, at: 102)
        try c.submitReport(runID: run.id, round: 1, pane: try XCTUnwrap(ready.latestRound?.pane), report: .init(status: status, rationale: "Evidence-based review", changedFiles: status == "working" ? ["file.swift"] : []), now: Date(timeIntervalSince1970: 103))
        b.reviewDone = true
        return try drive(c, s, .awaitingDecision, at: 104)
    }
    private func choose(_ choice: TwinChoice, _ run: TwinRun, _ c: TwinCoordinator, at: TimeInterval) throws {
        let round = try XCTUnwrap(run.latestRound)
        try c.recordNativeConsent(runID: run.id, round: round.number, consent: .init(choice: choice, decisionID: try XCTUnwrap(round.decisionID), twinTip: try XCTUnwrap(round.tip), sourceCompletionID: "after", chosenAt: Date(timeIntervalSince1970: at)), now: Date(timeIntervalSince1970: at))
    }
    private func drive(_ c: TwinCoordinator, _ s: TwinStore, _ phase: TwinPhase, at: TimeInterval) throws -> TwinRun {
        for _ in 0..<12 { let run = try XCTUnwrap(s.load().runs.first); if run.phase == phase { return run }; _ = try c.processPending(now: Date(timeIntervalSince1970: at)) }
        let run = try XCTUnwrap(s.load().runs.first); XCTFail("Expected \(phase), got \(run.phase): \(run.message ?? "")"); return run
    }
}
