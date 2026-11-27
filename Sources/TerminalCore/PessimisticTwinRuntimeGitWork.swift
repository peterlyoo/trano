import Foundation
import Darwin

protocol TwinRuntimeGitServicing {
    func review(snapshot: TwinGitSnapshot) throws -> TwinGitReview
    func merge(snapshot: TwinGitSnapshot, tip: String,
               committing: (_ mutation: () throws -> TwinGitMergeResult) throws -> TwinGitMergeResult,
               recordMutation: @escaping (TwinGitMutationStage) throws -> Void) throws -> TwinGitMergeResult
    func cleanup(snapshot: TwinGitSnapshot, expectedTip: String,
                 committing: (_ mutation: () throws -> Void) throws -> Void,
                 recordMutation: @escaping (TwinGitMutationStage) throws -> Void) throws
}
extension TwinGitService: TwinRuntimeGitServicing {}

struct TwinRuntimeGitWork {
    let git: TwinRuntimeGitServicing
    let read: () throws -> TwinState
    let observe: (TwinRun, TwinRound) throws -> TwinPaneObservation
    let sourceContext: (TwinRun, Bool) throws -> TwinRuntimeContext
    let journal: (String, Int, TwinGitMutationStage) throws -> Void
    let reject: (TwinRun, TwinRound, TwinPaneBinding, String) throws -> Void
    let retire: (TwinRun, TwinRound) throws -> Void
    var cleanupPrivateProfile: (TwinRun, TwinRound) throws -> Void = { _, _ in }
    let ensureNoOrphans: (String, Int) throws -> Void
    let ensureSourceIdle: (TwinGitSnapshot) throws -> Void
    let ensureCleanupAdmission: (TwinRun, TwinRound) throws -> Void
    let transaction: (_ operation: () throws -> Void) throws -> Void
    let mergeTransaction: (_ operation: () throws -> TwinGitMergeResult) throws -> TwinGitMergeResult

    func completedReview(run: TwinRun, round: TwinRound) throws -> TwinReviewOutcome? {
        guard run.phase == .reviewing, run.operation == nil, run.exitReason == nil,
              run.latestRound == round, try canonical(run, round) else { return nil }
        let snapshot = try receipt(run, round)
        let first = try observe(run, round)
        guard let completion = first.completion, first.inputClear, !first.hasBlockers else { return nil }
        try requirePane(first.binding, run: run, round: round)
        guard validCompletion(completion), completion.completedAt >= round.createdAt else {
            throw TwinGitError.unsafe("Twin completion is not a trusted current review boundary")
        }
        guard let report = round.report, let reportedAt = round.reportedAt else {
            try rejectIfCurrent(run, round, first, "The twin finished without its authenticated final report")
            return nil
        }
        guard reportedAt.timeIntervalSince1970.isFinite, reportedAt >= round.createdAt else {
            try rejectIfCurrent(run, round, first, "The twin report receipt is invalid")
            return nil
        }
        guard completion.completedAt >= reportedAt else { return nil }
        do {
            try report.validate()
            guard round.reportedTurnID.map({ $0 == completion.turnID }) ?? true else {
                throw TwinGitError.unsafe("The final report belongs to a different completed twin turn")
            }
        } catch {
            try rejectIfCurrent(run, round, first, error.localizedDescription)
            return nil
        }
        let review = try git.review(snapshot: snapshot)
        var result: TwinReviewOutcome?
        try transaction {
            guard try canonical(run, round), same(first, try observe(run, round)) else { return }
            guard review.clean, TwinStore.oid(review.tip), Set(review.changedFiles).count == review.changedFiles.count,
                  review.changedFiles.allSatisfy(TwinReport.validRelativePath),
                  Set(review.changedFiles) == Set(report.changedFiles) else {
                try reject(run, round, first.binding, "The final report does not match the clean committed twin changes")
                return
            }
            result = TwinReviewOutcome(pane: first.binding, completion: completion, report: report,
                tip: review.tip, changedFiles: review.changedFiles, clean: true)
        }
        return result
    }

    func merge(run: TwinRun, round: TwinRound, context: TwinRuntimeContext, active: () -> Bool) throws -> TwinMergeOutcome {
        do {
            guard active() else { return .held("Twin processing stopped before merge") }
            let snapshot = try mergeReceipt(run, round, context: context)
            let result = try git.merge(snapshot: snapshot, tip: round.tip!, committing: { mutation in
                try mergeTransaction {
                    guard active() else { return .held("Twin processing stopped before the approved merge") }
                    _ = try mergeReceipt(run, round, context: context)
                    let fresh = try sourceContext(run, active())
                    guard fresh == context else { return .held("The original input or completed turn changed during merge preflight") }
                    return try mutation()
                }
            }, recordMutation: { try self.journal(run.id, round.number, $0) })
            switch result {
            case .merged(let commit):
                return TwinStore.oid(commit) ? .merged(commit: commit) : .needsReview("Git returned an uncertain merge commit")
            case .conflict(let paths, let message): return .conflict(paths: paths, message: message)
            case .held(let message): return .held(message)
            case .needsReview(let message): return .needsReview(message)
            }
        } catch { return .held(error.localizedDescription) }
    }

    func cleanup(run: TwinRun, round: TwinRound, active: () -> Bool) throws {
        try requireCleanup(run, round, active: active())
        guard let snapshot = round.snapshot else {
            guard round.pane == nil else { throw TwinGitError.unsafe("A partial twin pane has no verified snapshot receipt; retain it for review") }
            try ensureNoOrphans(run.id, round.number)
            try transaction {
                try requireCleanup(run, round, active: active())
                try ensureNoOrphans(run.id, round.number)
                try ensureCleanupAdmission(run, round)
            }
            return
        }
        _ = try receipt(run, round)
        try ensureSourceIdle(snapshot)
        let tip = round.tip ?? snapshot.snapshotCommit
        guard TwinStore.oid(tip) else { throw TwinGitError.unsafe("Twin cleanup lacks an exact owned tip") }
        let reviewed = try git.review(snapshot: snapshot)
        guard reviewed.clean, reviewed.tip == tip else {
            throw TwinGitError.unsafe("Twin changes are dirty or no longer match the retained cleanup tip")
        }
        try transaction {
            try requireCleanup(run, round, active: active())
            try ensureSourceIdle(snapshot)
            if round.pane != nil { try retire(run, round) }
        }
        try cleanupPrivateProfile(run, round)
        try git.cleanup(snapshot: snapshot, expectedTip: tip, committing: { mutation in
            try transaction {
                try requireCleanup(run, round, active: active())
                try ensureSourceIdle(snapshot)
                try ensureCleanupAdmission(run, round)
                try mutation()
            }
        }, recordMutation: { try self.journal(run.id, round.number, $0) })
    }

    private func canonical(_ run: TwinRun, _ round: TwinRound) throws -> Bool {
        let state = try read()
        return state.runs.filter { $0.id == run.id } == [run]
            && run.rounds.filter { $0.number == round.number } == [round] && !round.cleaned
    }
    private func receipt(_ run: TwinRun, _ round: TwinRound) throws -> TwinGitSnapshot {
        guard let snapshot = round.snapshot, snapshot.runID == run.id, snapshot.round == round.number,
              snapshot.sourceCWD == run.source.cwd, snapshot.worktreePath != run.source.cwd,
              snapshot.ownership.path == snapshot.worktreePath,
              snapshot.ownership.commonDirectory == snapshot.commonDirectory,
              snapshot.twinBranch == "refs/heads/trano/twins/\(run.id)/round-\(round.number)" else {
            throw TwinGitError.unsafe("Twin resources do not match the canonical run and round")
        }
        return snapshot
    }
    private func requirePane(_ pane: TwinPaneBinding, run: TwinRun, round: TwinRound) throws {
        guard let expected = round.pane, pane.matchesProcess(expected), pane.paneID != run.source.paneID,
              let conversation = pane.conversationID, let conversationID = UUID(uuidString: conversation),
              conversationID != UUID(uuidString: run.source.conversationID),
              expected.conversationID.map({ $0 == conversation }) ?? true else {
            throw TwinGitError.unsafe("The twin is no longer the exact separate managed conversation")
        }
    }
    private func mergeReceipt(_ run: TwinRun, _ round: TwinRound, context: TwinRuntimeContext) throws -> TwinGitSnapshot {
        guard try canonical(run, round), run.phase == .merging, run.exitReason == nil,
              run.latestRound == round, run.operation?.kind == .merge, run.operation?.round == round.number,
              context.ready, context.source == run.source, let completion = context.completion, validCompletion(completion),
              let original = round.sourceCompletion, completion.id != original.id, completion.turnID != original.turnID,
              let consent = round.consent, consent.choice == .merge, consent.chosenAt.timeIntervalSince1970.isFinite,
              consent.chosenAt >= round.createdAt, completion.id != consent.sourceCompletionID, completion.completedAt > consent.chosenAt,
              let tip = round.tip, TwinStore.oid(tip), tip == consent.twinTip,
              let decision = round.decisionID, decision == consent.decisionID,
              decision == TwinDecisionID.make(runID: run.id, round: round.number),
              let report = round.report, let at = round.reportedAt, let review = round.reviewCompletion,
              validCompletion(review), review.completedAt >= at, at >= round.createdAt,
              round.reportedTurnID.map({ $0 == review.turnID }) ?? true,
              let pane = round.pane else { throw TwinGitError.unsafe("The merge lacks a current native choice and a later trusted source turn") }
        try report.validate()
        try requirePane(pane, run: run, round: round)
        let snapshot = try receipt(run, round)
        let binding = TwinDecisionBinding(decisionID: decision, runID: run.id, round: round.number,
            sourceGeneration: run.source.generation, snapshotOID: snapshot.snapshotCommit, twinTipOID: tip)
        guard try read().decisionBindings.filter({ $0.decisionID == decision }) == [binding] else {
            throw TwinGitError.unsafe("The approved twin decision lost its protected native binding")
        }
        return snapshot
    }
    private func requireCleanup(_ run: TwinRun, _ round: TwinRound, active: Bool) throws {
        guard active, try canonical(run, round), run.phase == .cleaning,
              run.operation?.kind == .cleanup, run.operation?.round == round.number else {
            throw TwinGitError.unsafe("Twin cleanup no longer owns this exact round operation")
        }
    }
    private func rejectIfCurrent(_ run: TwinRun, _ round: TwinRound, _ observation: TwinPaneObservation, _ reason: String) throws {
        try transaction {
            guard try canonical(run, round), same(observation, try observe(run, round)) else { return }
            try reject(run, round, observation.binding, reason)
        }
    }
    private func same(_ lhs: TwinPaneObservation, _ rhs: TwinPaneObservation) -> Bool {
        lhs.binding == rhs.binding && lhs.completion == rhs.completion && lhs.inputClear == rhs.inputClear && lhs.hasBlockers == rhs.hasBlockers
    }
    private func validCompletion(_ completion: TwinCompletion) -> Bool {
        completion.completedAt.timeIntervalSince1970.isFinite && !completion.id.isEmpty && !completion.turnID.isEmpty
            && completion.id.utf8.count <= 512 && completion.turnID.utf8.count <= 512
            && !completion.id.utf8.contains(0) && !completion.turnID.utf8.contains(0)
    }

    static func ensureSourceIdle(_ snapshot: TwinGitSnapshot, fileSystem: TwinGitFileSystem) throws {
        guard let common = try fileSystem.info(snapshot.commonDirectory), common.kind == .directory,
              common.identity == snapshot.ownership.commonIdentity,
              let source = try fileSystem.info(snapshot.sourceGitDirectory), source.kind == .directory,
              source.ownerUID == getuid() else { throw TwinGitError.unsafe("Source Git metadata is unavailable; retain twin artifacts") }
        let markers = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "BISECT_START", "AUTO_MERGE",
            "rebase-merge", "rebase-apply", "sequencer", "index.lock", "HEAD.lock"]
        for directory in Set([snapshot.sourceGitDirectory, snapshot.commonDirectory]) {
            for marker in markers where try fileSystem.info(directory + "/" + marker) != nil {
                throw TwinGitError.unsafe("A source Git operation is active; retain the twin pane, branch and worktree")
            }
        }
    }
}

extension TerminalRuntime {
    func completedTwinReview(run: TwinRun, round: TwinRound) throws -> TwinReviewOutcome? {
        guard try twinPaneObservation(run: run, round: round) != nil else { return nil }
        return try twinGitWork().completedReview(run: run, round: round)
    }
    func mergeTwinReview(run: TwinRun, round: TwinRound, context: TwinRuntimeContext, active: () -> Bool) throws -> TwinMergeOutcome {
        try twinGitWork().merge(run: run, round: round, context: context, active: active)
    }
    func cleanupTwinRound(run: TwinRun, round: TwinRound, active: () -> Bool) throws {
        try twinGitWork().cleanup(run: run, round: round, active: active)
    }
    private func twinGitWork() -> TwinRuntimeGitWork {
        TwinRuntimeGitWork(git: TwinGitService(root: root), read: { try TwinStore(root: self.root).load() },
            observe: {
                guard let observation = try self.twinPaneObservation(run: $0, round: $1) else { throw TwinGitError.unsafe("Twin pane changed during review admission") }
                return observation
            },
            sourceContext: { try self.twinSourceContext(run: $0, active: $1) },
            journal: { try self.twinMutationJournal(runID: $0, round: $1, stage: $2) },
            reject: { try self.twinCoordinator().rejectReport(runID: $0.id, round: $1.number, pane: $2, message: $3) },
            retire: { try self.retireTwinPane(run: $0, round: $1) },
            cleanupPrivateProfile: { try self.cleanupTwinPrivateProfile(run: $0, round: $1) },
            ensureNoOrphans: { try self.ensureNoOrphanedTwinResources(runID: $0, round: $1) },
            ensureSourceIdle: { try TwinRuntimeGitWork.ensureSourceIdle($0, fileSystem: TwinNativeGitFileSystem()) },
            ensureCleanupAdmission: { try self.ensureTwinCleanupAdmission(run: $0, round: $1) },
            transaction: { try self.transaction($0) }, mergeTransaction: { try self.transaction($0) })
    }
}
