import Foundation
import XCTest
import Darwin
@testable import TerminalCore

final class PessimisticTwinRuntimeGitWorkTests: XCTestCase {
    // Implements: FR-TWIN-5, FR-TWIN-6, FR-TWIN-8.
    func testCompletedReviewReturnsOnlyCanonicalTrustedCleanTip() throws {
        let f = RuntimeGitFixture()
        let result = try f.work.completedReview(run: f.run, round: f.round)
        XCTAssertEqual(result?.pane, f.observation.binding)
        XCTAssertEqual(result?.completion, f.observation.completion)
        XCTAssertEqual(result?.report, f.round.report)
        XCTAssertEqual(result?.tip, f.git.reviewValue.tip)
        XCTAssertEqual(f.git.reviewCalls, 1)
    }

    func testApprovedMergeRunsOnlyInsideFinalRuntimeAdmission() throws {
        let f = RuntimeGitFixture(); f.claimMerge()
        let result = try f.work.merge(run: f.run, round: f.round, context: f.context, active: { true })
        XCTAssertEqual(result, .merged(commit: RuntimeGitFixture.merged))
        XCTAssertEqual(f.git.mergeCalls, 1)
        XCTAssertTrue(f.git.mutatedUnderLock)
        XCTAssertEqual(f.events, ["merge-preflight", "lock", "mutation", "journal:sourceCheckpointWillAdvance", "journal:mergeCompleted", "unlock"])
    }

    func testCleanupRetiresExactPaneBeforeOwnedGitRemoval() throws {
        let f = RuntimeGitFixture(); f.claimCleanup()
        try f.work.cleanup(run: f.run, round: f.round, active: { true })
        XCTAssertEqual(f.retired, [f.round.pane!])
        XCTAssertEqual(f.git.cleanupCalls, 1)
        XCTAssertEqual(f.git.cleanedTip, f.round.tip)
        XCTAssertEqual(f.events.filter { ["retire", "cleanup"].contains($0) }, ["retire", "cleanup"])
    }
    func testPrivateProfileCleanupRunsOnlyAfterRetirementAndBeforeGitDeletion() throws {
        let f = RuntimeGitFixture(); f.claimCleanup(); var work = f.work
        var cleaned = false
        work.cleanupPrivateProfile = { _, _ in
            XCTAssertEqual(f.retired, [f.round.pane!]); XCTAssertEqual(f.git.cleanupCalls, 0); cleaned = true
        }
        try work.cleanup(run: f.run, round: f.round, active: { true })
        XCTAssertTrue(cleaned); XCTAssertEqual(f.git.cleanupCalls, 1)
    }
    func testPendingProviderRetirementLeavesProfileAndGitUntouched() throws {
        let f = RuntimeGitFixture(); f.claimCleanup(); var work = f.work
        f.retireError = TwinCleanupPending(operationID: f.run.operation!.id, message: "waiting")
        var profileCleaned = false
        work.cleanupPrivateProfile = { _, _ in profileCleaned = true }
        XCTAssertThrowsError(try work.cleanup(run: f.run, round: f.round, active: { true })) { error in
            XCTAssertEqual((error as? TwinCleanupPending)?.operationID, f.run.operation?.id)
        }
        XCTAssertFalse(profileCleaned); XCTAssertEqual(f.git.cleanupCalls, 0)
    }
    func testFailedPrivateProfileOwnershipHoldsGitResources() {
        let f = RuntimeGitFixture(); f.claimCleanup(); var work = f.work
        work.cleanupPrivateProfile = { _, _ in throw TwinGitError.unsafe("Private marker changed") }
        XCTAssertThrowsError(try work.cleanup(run: f.run, round: f.round, active: { true }))
        XCTAssertEqual(f.git.cleanupCalls, 0)
    }
    func testMissingSnapshotWithPaneIsAlwaysRetainedAsPartialResource() throws {
        let f = RuntimeGitFixture(); f.claimCleanup(); f.run.rounds[0].snapshot = nil; f.sync()
        XCTAssertThrowsError(try f.work.cleanup(run: f.run, round: f.round, active: { true }))
        XCTAssertTrue(f.retired.isEmpty); XCTAssertFalse(f.events.contains("cleanup-admission"))
    }
    func testReviewRefusesCaseAliasOfOriginalConversationID() throws {
        let f = RuntimeGitFixture(); f.run.rounds[0].pane?.conversationID = nil; f.sync()
        var alias = f.observation.binding; alias.conversationID = f.run.source.conversationID.uppercased()
        f.observation = TwinPaneObservation(binding: alias, completion: f.observation.completion, inputClear: true, hasBlockers: false)
        XCTAssertThrowsError(try f.work.completedReview(run: f.run, round: f.round))
        XCTAssertEqual(f.git.reviewCalls, 0)
    }

    func testReviewWaitsForTrustedDoneEmptyInputAndNoTools() throws {
        for reason in ["no-done", "input", "tools"] {
            let f = RuntimeGitFixture(), before = f.observation
            f.observation = TwinPaneObservation(binding: before.binding, completion: reason == "no-done" ? nil : before.completion,
                inputClear: reason != "input", hasBlockers: reason == "tools")
            XCTAssertNil(try f.work.completedReview(run: f.run, round: f.round))
            XCTAssertEqual(f.git.reviewCalls, 0); XCTAssertTrue(f.rejected.isEmpty)
        }
    }
    func testReviewRejectsMissingFinalEnvelopeAfterTrustedDone() throws {
        let f = RuntimeGitFixture(); f.run.rounds[0].report = nil; f.sync()
        XCTAssertNil(try f.work.completedReview(run: f.run, round: f.round))
        XCTAssertEqual(f.rejected.count, 1); XCTAssertEqual(f.git.reviewCalls, 0)
    }
    func testReviewWaitsForCompletionAfterAuthenticatedReportReceipt() throws {
        let f = RuntimeGitFixture(); f.run.rounds[0].reportedAt = Date(timeIntervalSince1970: 301); f.sync()
        XCTAssertNil(try f.work.completedReview(run: f.run, round: f.round))
        XCTAssertTrue(f.rejected.isEmpty); XCTAssertEqual(f.git.reviewCalls, 0)
    }
    func testReviewRejectsReportBoundToDifferentCompletedTurn() throws {
        let f = RuntimeGitFixture(); f.run.rounds[0].reportedTurnID = "other-turn"; f.sync()
        XCTAssertNil(try f.work.completedReview(run: f.run, round: f.round))
        XCTAssertEqual(f.rejected.count, 1); XCTAssertEqual(f.git.reviewCalls, 0)
    }
    func testReviewRejectsMalformedOrUncommittedOrMismatchedChangedFiles() throws {
        for reason in ["invalid", "dirty", "paths", "duplicate", "oid"] {
            let f = RuntimeGitFixture()
            if reason == "invalid" { f.run.rounds[0].report = TwinReport(status: "approved", rationale: "bad", changedFiles: []); f.sync() }
            if reason == "dirty" { f.git.reviewValue = .init(tip: RuntimeGitFixture.tip, changedFiles: ["a.swift"], clean: false) }
            if reason == "paths" { f.git.reviewValue = .init(tip: RuntimeGitFixture.tip, changedFiles: ["other.swift"], clean: true) }
            if reason == "duplicate" { f.git.reviewValue = .init(tip: RuntimeGitFixture.tip, changedFiles: ["a.swift", "a.swift"], clean: true) }
            if reason == "oid" { f.git.reviewValue = .init(tip: "bad", changedFiles: ["a.swift"], clean: true) }
            XCTAssertNil(try f.work.completedReview(run: f.run, round: f.round))
            XCTAssertEqual(f.rejected.count, 1, reason)
        }
    }
    func testReviewDoesNotRejectNewerCanonicalReportOrInputAfterGitScan() throws {
        for reason in ["canonical", "input", "completion"] {
            let f = RuntimeGitFixture()
            f.git.beforeReviewReturn = {
                if reason == "canonical" { f.state.runs[0].rounds[0].message = "changed" }
                else {
                    let old = f.observation
                    f.observation = TwinPaneObservation(binding: old.binding,
                        completion: reason == "completion" ? TwinCompletion(id: "new", turnID: "new-turn", completedAt: Date(timeIntervalSince1970: 320), inputRevision: 10) : old.completion,
                        inputClear: reason != "input", hasBlockers: false)
                }
            }
            XCTAssertNil(try f.work.completedReview(run: f.run, round: f.round))
            XCTAssertTrue(f.rejected.isEmpty, reason)
        }
    }
    func testReviewRefusesReplacementPaneOrSourceConversation() throws {
        for reason in ["birth", "source-conversation"] {
            let f = RuntimeGitFixture(), old = f.observation.binding
            let pane = TwinPaneBinding(paneID: old.paneID, generation: old.generation, backendPID: reason == "birth" ? 202 : old.backendPID,
                backendIdentity: old.backendIdentity, conversationID: reason == "source-conversation" ? f.run.source.conversationID : old.conversationID)
            f.observation = TwinPaneObservation(binding: pane, completion: f.observation.completion, inputClear: true, hasBlockers: false)
            XCTAssertThrowsError(try f.work.completedReview(run: f.run, round: f.round))
            XCTAssertEqual(f.git.reviewCalls, 0); XCTAssertTrue(f.rejected.isEmpty)
        }
    }
    func testReviewRetainsResourcesWhenGitValidationIsUncertain() throws {
        let f = RuntimeGitFixture(); f.git.reviewError = TwinGitError.unsafe("unknown Git operation")
        XCTAssertThrowsError(try f.work.completedReview(run: f.run, round: f.round))
        XCTAssertTrue(f.rejected.isEmpty); XCTAssertEqual(f.git.cleanupCalls, 0)
    }
    func testMergeRequiresProtectedBindingAndNativeMergeChoice() throws {
        for reason in ["binding", "choice", "tip", "operation"] {
            let f = RuntimeGitFixture(); f.claimMerge()
            if reason == "binding" { f.state.decisionBindings = [] }
            if reason == "choice" { let c = f.round.consent!; f.run.rounds[0].consent = TwinConsent(choice: .feedbackOnly, decisionID: c.decisionID, twinTip: c.twinTip, sourceCompletionID: c.sourceCompletionID, chosenAt: c.chosenAt); f.sync() }
            if reason == "tip" { f.run.rounds[0].tip = String(repeating: "d", count: 40); f.sync() }
            if reason == "operation" { f.run.operation = TwinOperationIntent(kind: .cleanup, round: 1); f.sync() }
            guard case .held = try f.work.merge(run: f.run, round: f.round, context: f.context, active: { true }) else { return XCTFail(reason) }
            XCTAssertEqual(f.git.mergeCalls, 0, reason); XCTAssertFalse(f.git.mutatedUnderLock)
        }
    }
    func testMergeRequiresNewCompletedSourceTurnAfterHumanChoice() throws {
        for reason in ["old-id", "old-turn", "old-time", "input", "decision", "tools", "queue", "quota"] {
            let f = RuntimeGitFixture(); f.claimMerge()
            let old = f.context.completion!
            f.context = TwinRuntimeContext(source: f.run.source, completion: TwinCompletion(id: reason == "old-id" ? "source-snapshot" : old.id,
                turnID: reason == "old-turn" ? "source-turn-1" : old.turnID, completedAt: Date(timeIntervalSince1970: reason == "old-time" ? 400 : 500), inputRevision: old.inputRevision), inputClear: reason != "input", hasActiveTools: reason == "tools", hasPendingDecisions: reason == "decision", hasQueuedInput: reason == "queue", quotaSwitching: reason == "quota")
            guard case .held = try f.work.merge(run: f.run, round: f.round, context: f.context, active: { true }) else { return XCTFail(reason) }
            XCTAssertEqual(f.git.mergeCalls, 0, reason)
        }
    }
    func testMergeRechecksInputCompletionCanonicalStateAndCancellationInsideFinalLock() throws {
        for reason in ["context", "canonical", "binding", "cancel"] {
            let f = RuntimeGitFixture(); f.claimMerge(); let claimed = f.run, round = f.round, context = f.context
            var enabled = true
            f.git.beforeMergeCallback = {
                if reason == "context" { f.context = TwinRuntimeContext(source: f.run.source, completion: f.context.completion, inputClear: false) }
                if reason == "canonical" { f.state.runs[0].message = "stopped or changed" }
                if reason == "binding" { f.state.decisionBindings = [] }
                if reason == "cancel" { enabled = false }
            }
            guard case .held = try f.work.merge(run: claimed, round: round, context: context, active: { enabled }) else { return XCTFail(reason) }
            XCTAssertFalse(f.git.mutatedUnderLock, reason); XCTAssertFalse(f.events.contains("mutation"), reason)
        }
    }
    func testMergePreservesConflictAndUncertainOutcomeWithoutCleanup() throws {
        let f = RuntimeGitFixture(); f.claimMerge(); f.git.mergeResult = .conflict(paths: ["a.swift"], message: "resolve manually")
        XCTAssertEqual(try f.work.merge(run: f.run, round: f.round, context: f.context, active: { true }), .conflict(paths: ["a.swift"], message: "resolve manually"))
        f.git.mergeResult = .needsReview("uncertain checkpoint")
        XCTAssertEqual(try f.work.merge(run: f.run, round: f.round, context: f.context, active: { true }), .needsReview("uncertain checkpoint"))
        XCTAssertEqual(f.git.cleanupCalls, 0); XCTAssertTrue(f.retired.isEmpty)
    }
    func testCleanupRetainsSourceConflictDirtyAndChangedTipBeforeRetiringPane() throws {
        for reason in ["source-conflict", "dirty", "tip"] {
            let f = RuntimeGitFixture(); f.claimCleanup()
            f.sourceBlocked = reason == "source-conflict"
            f.git.reviewValue = .init(tip: reason == "tip" ? String(repeating: "d", count: 40) : RuntimeGitFixture.tip, changedFiles: ["a.swift"], clean: reason != "dirty")
            XCTAssertThrowsError(try f.work.cleanup(run: f.run, round: f.round, active: { true }))
            XCTAssertTrue(f.retired.isEmpty, reason); XCTAssertEqual(f.git.cleanupCalls, 0)
        }
    }
    func testCleanupOfEarlierRoundWorksWhenSourceIsUnavailable() throws {
        let f = RuntimeGitFixture(); f.claimCleanup()
        f.run.rounds.append(TwinRound(number: 2)); f.sync()
        f.context = TwinRuntimeContext(source: nil)
        try f.work.cleanup(run: f.run, round: f.round, active: { true })
        XCTAssertEqual(f.git.cleanupCalls, 1); XCTAssertEqual(f.retired, [f.round.pane!])
    }
    func testCleanupRefusesPartialSnapshotResourcesWithoutDeletingPane() throws {
        let f = RuntimeGitFixture(); f.claimCleanup(); f.run.rounds[0].snapshot = nil; f.sync(); f.orphaned = true
        XCTAssertThrowsError(try f.work.cleanup(run: f.run, round: f.round, active: { true }))
        XCTAssertTrue(f.retired.isEmpty); XCTAssertEqual(f.git.cleanupCalls, 0)
    }
    func testCleanupUsesSnapshotTipOnlyWhenNoReviewedTipExists() throws {
        let f = RuntimeGitFixture(); f.claimCleanup(); f.run.rounds[0].tip = nil; f.sync()
        f.git.reviewValue = .init(tip: f.round.snapshot!.snapshotCommit, changedFiles: [], clean: true)
        try f.work.cleanup(run: f.run, round: f.round, active: { true })
        XCTAssertEqual(f.git.cleanedTip, f.round.snapshot!.snapshotCommit)
    }
    func testCleanupFinalAdmissionRetainsArtifactsOnReplacementSessionAndCancellation() throws {
        for reason in ["session", "cancel", "canonical", "source-conflict"] {
            let f = RuntimeGitFixture(); f.claimCleanup(); let claimed = f.run, round = f.round
            var enabled = true
            f.git.beforeCleanupCallback = {
                if reason == "session" { f.cleanupBlocked = true }
                if reason == "cancel" { enabled = false }
                if reason == "canonical" { f.state.runs[0].message = "changed" }
                if reason == "source-conflict" { f.sourceBlocked = true }
            }
            XCTAssertThrowsError(try f.work.cleanup(run: claimed, round: round, active: { enabled }))
            XCTAssertFalse(f.git.cleanupMutated, reason)
        }
    }
    func testCleanupRejectsConflictPhaseOrWrongOperationWithoutAnySideEffects() throws {
        for reason in ["phase", "operation", "cancel"] {
            let f = RuntimeGitFixture(); f.claimCleanup()
            if reason == "phase" { f.run.phase = .conflict; f.sync() }
            if reason == "operation" { f.run.operation = TwinOperationIntent(kind: .merge, round: 1); f.sync() }
            XCTAssertThrowsError(try f.work.cleanup(run: f.run, round: f.round, active: { reason != "cancel" }))
            XCTAssertTrue(f.retired.isEmpty); XCTAssertEqual(f.git.cleanupCalls, 0)
        }
    }

}

private final class RuntimeGitFixture {
    static let tip = String(repeating: "b", count: 40)
    static let merged = String(repeating: "c", count: 40)
    var run: TwinRun
    var round: TwinRound { run.rounds[0] }
    var state: TwinState
    var observation: TwinPaneObservation
    var context: TwinRuntimeContext
    let git = RuntimeGitFake()
    var events: [String] = []
    var retired: [TwinPaneBinding] = []
    var rejected: [String] = []
    var lockHeld = false
    var onObserve: (() -> Void)?
    var onRead: (() -> Void)?
    var sourceBlocked = false
    var orphaned = false
    var cleanupBlocked = false
    var retireError: Error?

    init() {
        let birth = SupervisorProcessIdentity(pid: 101, ownerUID: 501, startedAtSeconds: 100, startedAtMicroseconds: 1)
        let providerBirth = SupervisorProcessIdentity(pid: 102, ownerUID: 501, startedAtSeconds: 100, startedAtMicroseconds: 2)
        let twinBirth = SupervisorProcessIdentity(pid: 201, ownerUID: 501, startedAtSeconds: 100, startedAtMicroseconds: 3)
        let source = TwinSourceBinding(paneID: "11111111-1111-4111-8111-111111111111", generation: "22222222-2222-4222-8222-222222222222", conversationID: "a3333333-3333-4333-8333-333333333333", cwd: "/source", configurationRoot: "/account", provider: .codex, backendPID: 101, providerPID: 102, backendIdentity: birth, providerIdentity: providerBirth)
        let runID = "44444444-4444-4444-8444-444444444444"
        let identity = WorktreeFileIdentity(device: 1, inode: 1)
        let ownership = WorktreeIdentity(path: "/owned/worktree", commonDirectory: "/source/.git", adminDirectory: "/source/.git/worktrees/twin", pathIdentity: identity, gitFileIdentity: identity, adminIdentity: identity, commonIdentity: identity)
        let snapshot = TwinGitSnapshot(runID: runID, round: 1, repositoryRoot: "/source", sourceCWD: "/source", sourceGitDirectory: "/source/.git", commonDirectory: "/source/.git", sourceBranch: "refs/heads/main", sourceHEAD: String(repeating: "1", count: 40), sourceIndexSHA256: String(repeating: "2", count: 64), sourceTree: String(repeating: "3", count: 40), snapshotCommit: String(repeating: "a", count: 40), twinBranch: "refs/heads/trano/twins/" + runID + "/round-1", worktreePath: "/owned/worktree", ownership: ownership)
        let pane = TwinPaneBinding(paneID: "55555555-5555-4555-8555-555555555555", generation: "66666666-6666-4666-8666-666666666666", backendPID: 201, backendIdentity: twinBirth, conversationID: "77777777-7777-4777-8777-777777777777")
        let completion = TwinCompletion(id: "review-done", turnID: "review-turn", completedAt: Date(timeIntervalSince1970: 300), inputRevision: 9)
        let sourceCompletion = TwinCompletion(id: "source-snapshot", turnID: "source-turn-1", completedAt: Date(timeIntervalSince1970: 120), inputRevision: 1)
        let round = TwinRound(number: 1, snapshot: snapshot, pane: pane, report: TwinReport(status: "working", rationale: "Fixed the missing check", changedFiles: ["a.swift"]), tip: Self.tip, createdAt: Date(timeIntervalSince1970: 100), sourceCompletion: sourceCompletion, reviewCompletion: completion, reportedAt: Date(timeIntervalSince1970: 299), reportedTurnID: completion.turnID)
        run = TwinRun(id: runID, source: source, mode: .codeReview, rounds: [round], phase: .reviewing, createdAt: Date(timeIntervalSince1970: 100))
        state = TwinState(runs: [run])
        observation = TwinPaneObservation(binding: pane, completion: completion, inputClear: true, hasBlockers: false)
        context = TwinRuntimeContext(source: source, completion: TwinCompletion(id: "source-next", turnID: "source-turn-2", completedAt: Date(timeIntervalSince1970: 500), inputRevision: 2), inputClear: true)
        git.fixture = self
    }

    var work: TwinRuntimeGitWork {
        TwinRuntimeGitWork(git: git, read: { self.onRead?(); return self.state }, observe: { _, _ in self.onObserve?(); return self.observation }, sourceContext: { _, _ in self.context }, journal: { _, _, stage in self.events.append("journal:" + stage.rawValue) }, reject: { _, _, _, reason in self.rejected.append(reason) }, retire: { _, round in self.events.append("retire"); if let error = self.retireError { throw error }; if let pane = round.pane { self.retired.append(pane) } }, ensureNoOrphans: { _, _ in if self.orphaned { throw TwinGitError.unsafe("partial resources") } }, ensureSourceIdle: { _ in if self.sourceBlocked { throw TwinGitError.unsafe("source conflict") } }, ensureCleanupAdmission: { _, _ in if self.cleanupBlocked { throw TwinGitError.unsafe("replacement session") }; self.events.append("cleanup-admission") }, transaction: { operation in self.events.append("lock"); self.lockHeld = true; defer { self.lockHeld = false; self.events.append("unlock") }; try operation() }, mergeTransaction: { operation in self.events.append("lock"); self.lockHeld = true; defer { self.lockHeld = false; self.events.append("unlock") }; return try operation() })
    }
    func sync() { state.runs = [run] }
    func claimMerge() {
        let id = TwinDecisionID.make(runID: run.id, round: 1)
        run.phase = .merging
        run.operation = TwinOperationIntent(kind: .merge, round: 1)
        run.rounds[0].decisionID = id
        run.rounds[0].consent = TwinConsent(choice: .merge, decisionID: id, twinTip: Self.tip, sourceCompletionID: "source-snapshot", chosenAt: Date(timeIntervalSince1970: 400))
        sync()
        state.decisionBindings = [TwinDecisionBinding(decisionID: id, runID: run.id, round: 1, sourceGeneration: run.source.generation, snapshotOID: round.snapshot!.snapshotCommit, twinTipOID: Self.tip)]
    }
    func claimCleanup() {
        run.phase = .cleaning; run.exitReason = .userInterrupt
        run.operation = TwinOperationIntent(kind: .cleanup, round: 1)
        sync()
    }
}

private final class RuntimeGitFake: TwinRuntimeGitServicing {
    weak var fixture: RuntimeGitFixture?
    var reviewValue = TwinGitReview(tip: RuntimeGitFixture.tip, changedFiles: ["a.swift"], clean: true)
    var reviewCalls = 0
    var mergeCalls = 0
    var cleanupCalls = 0
    var cleanedTip: String?
    var cleanupMutated = false
    var reviewError: Error?
    var beforeCleanupCallback: (() -> Void)?
    var mutatedUnderLock = false
    var beforeReviewReturn: (() -> Void)?
    var beforeMergeCallback: (() -> Void)?
    var mergeResult: TwinGitMergeResult = .merged(commit: RuntimeGitFixture.merged)
    func review(snapshot: TwinGitSnapshot) throws -> TwinGitReview {
        reviewCalls += 1; if let error = reviewError { throw error }; beforeReviewReturn?(); return reviewValue
    }
    func merge(snapshot: TwinGitSnapshot, tip: String, committing: (_ mutation: () throws -> TwinGitMergeResult) throws -> TwinGitMergeResult, recordMutation: @escaping (TwinGitMutationStage) throws -> Void) throws -> TwinGitMergeResult {
        mergeCalls += 1; fixture?.events.append("merge-preflight"); beforeMergeCallback?()
        return try committing {
            self.mutatedUnderLock = self.fixture?.lockHeld == true
            self.fixture?.events.append("mutation")
            try recordMutation(.sourceCheckpointWillAdvance)
            try recordMutation(.mergeCompleted)
            return self.mergeResult
        }
    }
    func cleanup(snapshot: TwinGitSnapshot, expectedTip: String, committing: (_ mutation: () throws -> Void) throws -> Void, recordMutation: @escaping (TwinGitMutationStage) throws -> Void) throws {
        cleanupCalls += 1; cleanedTip = expectedTip; beforeCleanupCallback?()
        try committing {
            self.cleanupMutated = true
            self.fixture?.events.append("cleanup")
            try recordMutation(.worktreeWillRemove); try recordMutation(.branchDeleted)
        }
    }
}
