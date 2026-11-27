import Foundation
public struct TwinRuntimeContext: Equatable {
 public let source:TwinSourceBinding?
 public let completion:TwinCompletion?
 public let enabled:Bool
 public let inputClear:Bool
 public let hasActiveTools:Bool
 public let hasPendingDecisions:Bool
 public let hasQueuedInput:Bool
 public let quotaSwitching:Bool
 public init(source:TwinSourceBinding?,completion:TwinCompletion?=nil,enabled:Bool=true,inputClear:Bool=false,hasActiveTools:Bool=false,hasPendingDecisions:Bool=false,hasQueuedInput:Bool=false,quotaSwitching:Bool=false){self.source=source;self.completion=completion;self.enabled=enabled;self.inputClear=inputClear;self.hasActiveTools=hasActiveTools;self.hasPendingDecisions=hasPendingDecisions;self.hasQueuedInput=hasQueuedInput;self.quotaSwitching=quotaSwitching}
 public var ready:Bool{enabled && source != nil && completion != nil && inputClear && !hasActiveTools && !hasPendingDecisions && !hasQueuedInput && !quotaSwitching}
}
public struct TwinReviewOutcome: Equatable {
 public let pane:TwinPaneBinding
 public let completion:TwinCompletion
 public let report:TwinReport
 public let tip:String
 public let changedFiles:[String]
 public let clean:Bool
 public init(pane:TwinPaneBinding,completion:TwinCompletion,report:TwinReport,tip:String,changedFiles:[String],clean:Bool){self.pane=pane;self.completion=completion;self.report=report;self.tip=tip;self.changedFiles=changedFiles;self.clean=clean}
}
public enum TwinMergeOutcome:Equatable{case merged(commit:String),conflict(paths:[String],message:String),held(String),needsReview(String)}
public protocol TwinBackend:AnyObject{
 func sourceContext(run:TwinRun)throws->TwinRuntimeContext
 func snapshot(run:TwinRun,round:TwinRound)throws->TwinGitSnapshot
 func launch(run:TwinRun,round:TwinRound)throws->TwinPaneBinding
 func completedReview(run:TwinRun,round:TwinRound)throws->TwinReviewOutcome?
 func publishDecision(run:TwinRun,round:TwinRound,decisionID:String)throws
 func merge(run:TwinRun,round:TwinRound,sourceContext:TwinRuntimeContext)throws->TwinMergeOutcome
 func enqueueFeedback(run:TwinRun,round:TwinRound,idempotencyKey:String)throws->String
 func cleanup(run:TwinRun,round:TwinRound)throws
}
struct TwinCleanupPending: Error {
    let operationID: String
    let message: String
}

public final class TwinCoordinator {
    public let store: TwinStore
    private let backend: TwinBackend
    public init(store: TwinStore, backend: TwinBackend) { self.store = store; self.backend = backend }

    @discardableResult public func enable(source: TwinSourceBinding, mode: TwinReviewMode, roundCap: Int = 3, noopCap: Int = 2,
                                          enabledCompletionID: String? = nil, now: Date = Date()) throws -> TwinRun {
        try TwinStore.validateSource(source)
        guard (1...8).contains(roundCap), (1...8).contains(noopCap) else { throw TerminalError.invalid("Twin round and noop caps must be between 1 and 8") }
        let run = TwinRun(source: source, mode: mode, roundCap: roundCap, noopCap: noopCap,
            rounds: [TwinRound(number: 1, createdAt: now)], createdAt: now, enabledCompletionID: enabledCompletionID)
        let context = try backend.sourceContext(run: run)
        guard context.enabled, context.source == source else { throw TerminalError.invalid("The original managed session is unavailable") }
        return try store.transaction { state in
            if let existing = state.runs.first(where: { $0.isActive && $0.source.paneID == source.paneID }) {
                guard existing.source == source, existing.mode == mode, existing.roundCap == roundCap, existing.noopCap == noopCap else {
                    throw TerminalError.invalid("Stop the existing twin before changing its source or mode")
                }
                return existing
            }
            guard state.runs.filter(\.isActive).count < 4,
                  !state.reservedPaneIDs.contains(source.paneID) else { throw TerminalError.invalid("Twin capacity reached or source is already a twin") }
            Self.prune(&state)
            state.runs.append(run)
            return run
        }
    }

    public func stop(id: String, now: Date = Date()) throws {
        _ = try modify(id, now: now) { run, _ in
            guard run.phase != .finished else { return }
            run.exitReason = .userInterrupt
            run.phase = run.operation == nil ? .cleaning : .needsReview
            run.message = run.operation == nil ? nil : "Stop requested during a workflow operation; inspect the recorded outcome before cleanup"
        }
    }

    public func submitReport(runID: String, round: Int, pane: TwinPaneBinding, report: TwinReport, reportedAt: Date? = nil, reportedTurnID: String? = nil, now: Date = Date()) throws {
        let run = try require(runID)
        guard run.phase == .reviewing, let current = run.latestRound, current.number == round,
              current.pane?.matchesProcess(pane) == true else { throw TerminalError.invalid("Twin report belongs to a stale pane or round") }
        do { try report.validate() }
        catch { try finish(run, reason: .invalidAgentOutput, message: error.localizedDescription, now: now); throw error }
        let receiptTime = reportedAt ?? now
        guard receiptTime.timeIntervalSince1970.isFinite, receiptTime >= current.createdAt, receiptTime <= now,
              reportedTurnID.map({ !$0.isEmpty && $0.utf8.count <= 512 && !$0.utf8.contains(0) }) ?? true else { throw TerminalError.invalid("Invalid authenticated twin report receipt") }
        _ = try modify(runID, expected: run, now: now) { value, _ in
            if let previous = value.rounds[round - 1].report {
                guard previous == report else { throw TerminalError.invalid("Twin final report was already submitted") }
                return
            }
            value.rounds[round - 1].report = report
            value.rounds[round - 1].reportedAt = receiptTime
            value.rounds[round - 1].reportedTurnID = reportedTurnID
            value.rounds[round - 1].updatedAt = now
        }
    }

    public func rejectReport(runID: String, round: Int, pane: TwinPaneBinding, message: String, now: Date = Date()) throws {
        let run = try require(runID)
        guard run.phase == .reviewing, run.currentRound == round, run.latestRound?.pane?.matchesProcess(pane) == true else {
            throw TerminalError.invalid("Malformed output belongs to a stale twin pane or round")
        }
        try finish(run, reason: .invalidAgentOutput, message: message, now: now)
    }

    public func submitSourceResponse(runID: String, round: Int, source: TwinSourceBinding, report: TwinReport, now: Date = Date()) throws {
        let run = try require(runID)
        guard run.phase == .awaitingSourceResponse, run.source == source, run.currentRound == round,
              run.latestRound?.forwardedID != nil else { throw TerminalError.invalid("The original reply belongs to a stale twin round") }
        do { try report.validate() }
        catch { try finish(run, reason: .invalidAgentOutput, message: error.localizedDescription, now: now); throw error }
        _ = try modify(runID, expected: run, now: now) { value, _ in
            if let previous = value.rounds[round - 1].sourceResponse {
                guard previous == report else { throw TerminalError.invalid("The original reply was already submitted") }
                return
            }
            value.rounds[round - 1].sourceResponse = report
            value.rounds[round - 1].sourceResponseAt = now
            value.rounds[round - 1].updatedAt = now
        }
    }

    public func recordNativeConsent(runID: String, round: Int, consent: TwinConsent, now: Date = Date()) throws {
        let run = try require(runID)
        if run.currentRound == round, run.latestRound?.consent == consent { return }
        guard run.phase == .awaitingDecision, run.currentRound == round, let current = run.latestRound,
              current.decisionID == consent.decisionID, current.tip == consent.twinTip,
              consent.chosenAt.timeIntervalSince1970.isFinite, consent.chosenAt >= current.createdAt else {
            throw TerminalError.invalid("The native twin choice no longer matches this reviewed round")
        }
        let context = try backend.sourceContext(run: run)
        guard context.enabled, context.source == run.source, context.completion?.id == consent.sourceCompletionID else {
            throw TerminalError.invalid("The original session changed before the native choice")
        }
        _ = try modify(runID, expected: run, now: now) { value, _ in
            value.rounds[round - 1].consent = consent
            value.rounds[round - 1].updatedAt = now
            switch consent.choice {
            case .merge: value.phase = .waitingForMerge
            case .feedbackOnly: value.phase = .forwarding
            case .discard: value.phase = .cleaning; value.exitReason = .userInterrupt
            }
        }
    }

    @discardableResult public func processPending(now: Date = Date()) throws -> [TwinRun] {
        try store.withOperationLease {
            let initial = try self.store.load().runs.filter(\.isActive)
            var changed: [TwinRun] = []
            for old in initial {
                guard let run = try self.store.load().runs.first(where: { $0.id == old.id }), run.isActive else { continue }
                do { try self.advance(run, now: now) }
                catch let pending as TwinCleanupPending {
                    _ = try self.modify(run.id, now: now) { value, _ in
                        guard value.phase == .cleaning, value.operation?.kind == .cleanup, value.operation?.id == pending.operationID else {
                            value.phase = .needsReview; value.message = "Twin cleanup lost its pending operation identity"; return
                        }
                        value.operation = nil
                        value.message = Self.message(pending.message)
                    }
                }
                catch {
                    _ = try self.modify(run.id, now: now) { value, _ in
                        guard value.phase != .finished else { return }
                        value.phase = .needsReview; value.message = Self.message(error.localizedDescription)
                    }
                }
                if let latest = try self.store.load().runs.first(where: { $0.id == old.id }), latest != old { changed.append(latest) }
            }
            return changed
        } ?? []
    }

    private func advance(_ run: TwinRun, now: Date) throws {
        guard ![.needsReview, .conflict, .finished].contains(run.phase) else { return }
        guard run.operation == nil else {
            _ = try modify(run.id, expected: run, now: now) { value, _ in
                value.phase = .needsReview; value.message = "A workflow operation was interrupted; verify its outcome before continuing"
            }
            return
        }
        let context = try backend.sourceContext(run: run)
        guard context.enabled else { return }
        if run.phase == .cleaning { try clean(run, now: now); return }
        guard context.source == run.source else { try finish(run, reason: .agentUnavailable, message: "The original managed session is no longer available", now: now); return }
        switch run.phase {
        case .waitingForSource:
            let inputWait = "Waiting for terminal input verification; the review has not started."
            let message = context.completion != nil && !context.inputClear ? inputWait : nil
            let current: TwinRun
            if (run.message == nil || run.message == inputWait), run.message != message {
                current = try modify(run.id, expected: run, now: now) { value, _ in value.message = message }
            } else { current = run }
            try snapshot(current, context: context, now: now)
        case .launching: try launch(run, now: now)
        case .reviewing: try review(run, now: now)
        case .awaitingDecision: break
        case .waitingForMerge: try merge(run, context: context, now: now)
        case .forwarding: try forward(run, context: context, now: now)
        case .awaitingSourceResponse: try respond(run, context: context, now: now)
        case .snapshotting, .merging:
            _ = try modify(run.id, expected: run, now: now) { value, _ in value.phase = .needsReview; value.message = "The workflow lost an operation result; review the owned artifacts" }
        case .cleaning, .finished, .needsReview, .conflict: break
        }
    }

    private func snapshot(_ run: TwinRun, context: TwinRuntimeContext, now: Date) throws {
        guard context.ready, let completion = context.completion, let round = run.latestRound else { return }
        if round.number == 1 {
            guard completion.id != run.enabledCompletionID, completion.completedAt >= run.createdAt else { return }
        } else {
            guard let response = run.rounds.dropLast().last?.responseCompletion,
                  completion.id == response.id || completion.completedAt > response.completedAt else { return }
        }
        let claimed = try claim(run, kind: .snapshot, phase: .snapshotting, now: now) { value, _ in
            value.rounds[value.rounds.count - 1].sourceCompletion = completion
            value.rounds[value.rounds.count - 1].lastSourceCompletionID = completion.id
        }
        let receipt = try backend.snapshot(run: claimed, round: claimed.latestRound!)
        guard receipt.runID == run.id, receipt.round == round.number, receipt.sourceCWD == run.source.cwd else {
            throw TerminalError.invalid("Snapshot receipt does not match the original session")
        }
        try complete(claimed, next: .launching, now: now) { value, _ in value.rounds[value.rounds.count - 1].snapshot = receipt }
    }

    private func launch(_ run: TwinRun, now: Date) throws {
        guard run.latestRound?.snapshot != nil, run.latestRound?.sourceCompletion != nil else { throw TerminalError.invalid("Twin launch lacks a frozen source snapshot") }
        let claimed = try claim(run, kind: .launch, phase: .launching, now: now)
        let pane = try backend.launch(run: claimed, round: claimed.latestRound!)
        guard pane.paneID != run.source.paneID, pane.conversationID == nil || pane.conversationID != run.source.conversationID else {
            throw TerminalError.invalid("Fork launch returned the original conversation or pane")
        }
        try complete(claimed, next: .reviewing, now: now) { value, _ in value.rounds[value.rounds.count - 1].pane = pane }
    }

    private func review(_ run: TwinRun, now: Date) throws {
        guard let round = run.latestRound, let outcome = try backend.completedReview(run: run, round: round) else { return }
        do { try outcome.report.validate() }
        catch { try finish(run, reason: .invalidAgentOutput, message: error.localizedDescription, now: now); return }
        guard let pane = round.pane, outcome.pane.matchesProcess(pane),
              let conversation = outcome.pane.conversationID, UUID(uuidString: conversation) != nil, conversation != run.source.conversationID,
              round.report == outcome.report, outcome.clean, TwinStore.oid(outcome.tip),
              Set(outcome.changedFiles).count == outcome.changedFiles.count,
              Set(outcome.changedFiles) == Set(outcome.report.changedFiles),
              let receiptTime = round.reportedAt, outcome.completion.completedAt >= receiptTime,
              round.reportedTurnID.map({ $0 == outcome.completion.turnID }) ?? true else {
            try finish(run, reason: .invalidAgentOutput, message: "The twin report, committed files, fresh conversation or trusted completion could not be verified", now: now)
            return
        }
        let decisionID = TwinDecisionID.make(runID: run.id, round: round.number)
        let claimed = try claim(run, kind: .publishDecision, phase: .reviewing, now: now) { value, state in
            let index = value.rounds.count - 1
            value.rounds[index].pane = outcome.pane; value.rounds[index].report = outcome.report; value.rounds[index].tip = outcome.tip
            value.rounds[index].reviewCompletion = outcome.completion; value.rounds[index].decisionID = decisionID
            state.decisionBindings.removeAll { $0.decisionID == decisionID }
            state.decisionBindings.append(TwinDecisionBinding(decisionID: decisionID, runID: run.id, round: round.number,
                sourceGeneration: run.source.generation, snapshotOID: round.snapshot!.snapshotCommit, twinTipOID: outcome.tip))
        }
        try backend.publishDecision(run: claimed, round: claimed.latestRound!, decisionID: decisionID)
        try complete(claimed, next: .awaitingDecision, now: now)
    }

    private func merge(_ run: TwinRun, context: TwinRuntimeContext, now: Date) throws {
        guard context.ready, let round = run.latestRound, let consent = round.consent, consent.choice == .merge,
              consent.decisionID == round.decisionID, consent.twinTip == round.tip,
              let completion = context.completion, completion.id != consent.sourceCompletionID,
              completion.id != round.sourceCompletion?.id, completion.completedAt > consent.chosenAt else { return }
        let claimed = try claim(run, kind: .merge, phase: .merging, now: now)
        let outcome = try backend.merge(run: claimed, round: claimed.latestRound!, sourceContext: context)
        switch outcome {
        case .merged(let commit):
            guard TwinStore.oid(commit) else { throw TerminalError.invalid("Merge returned an uncertain commit identity") }
            try complete(claimed, next: .forwarding, now: now, evenWhenStopped: true) { value, _ in
                value.rounds[value.rounds.count - 1].mergedCommit = commit
                value.rounds[value.rounds.count - 1].lastSourceCompletionID = completion.id
            }
        case .conflict(let paths, let detail):
            try complete(claimed, next: .conflict, now: now, evenWhenStopped: true) { value, _ in
                value.message = Self.message(detail + (paths.isEmpty ? "" : "\n" + paths.joined(separator: "\n")))
            }
        case .held(let detail):
            try complete(claimed, next: .needsReview, now: now) { value, _ in value.message = Self.message(detail) }
        case .needsReview(let detail):
            _ = try modify(run.id, now: now) { value, _ in
                guard value.operation?.id == claimed.operation?.id else { throw TerminalError.invalid("Twin merge ownership changed") }
                value.phase = .needsReview; value.message = Self.message(detail)
            }
        }
    }

    private func forward(_ run: TwinRun, context: TwinRuntimeContext, now: Date) throws {
        guard let round = run.latestRound, let consent = round.consent,
              consent.choice == .feedbackOnly || consent.choice == .merge && round.mergedCommit != nil else {
            throw TerminalError.invalid("Twin feedback has no human-selected outcome")
        }
        let claimed = try claim(run, kind: .forward, phase: .forwarding, now: now)
        let id = try backend.enqueueFeedback(run: claimed, round: claimed.latestRound!, idempotencyKey: "twin:\(run.id):\(round.number)")
        guard !id.isEmpty, id.utf8.count <= 512, !id.utf8.contains(0) else { throw TerminalError.invalid("Twin feedback returned an invalid queued-input identity") }
        try complete(claimed, next: run.exitReason == nil ? .awaitingSourceResponse : .cleaning, now: now) { value, _ in
            value.rounds[value.rounds.count - 1].forwardedID = id
            value.rounds[value.rounds.count - 1].lastSourceCompletionID = context.completion?.id
        }
    }

    private func respond(_ run: TwinRun, context: TwinRuntimeContext, now: Date) throws {
        guard context.ready, let round = run.latestRound, let response = round.sourceResponse, let at = round.sourceResponseAt,
              let completion = context.completion, completion.id != round.lastSourceCompletionID, completion.completedAt >= at else { return }
        _ = try modify(run.id, expected: run, now: now) { value, _ in
            value.rounds[value.rounds.count - 1].responseCompletion = completion
            if response.status == "no_further_improvement" { value.exitReason = .agentAgreement }
            else if value.rounds.reversed().prefix(while: { $0.report?.status == "no_further_improvement" }).count >= value.noopCap { value.exitReason = .noopCap }
            else if round.number >= value.roundCap { value.exitReason = .roundCap }
            value.phase = .cleaning
        }
    }

    private func clean(_ run: TwinRun, now: Date) throws {
        if let round = run.rounds.first(where: { !$0.cleaned }) {
            let claimed = try claim(run, kind: .cleanup, phase: .cleaning, round: round.number, now: now)
            try backend.cleanup(run: claimed, round: round)
            try complete(claimed, next: .cleaning, now: now) { value, _ in value.rounds[round.number - 1].cleaned = true }
            return
        }
        _ = try modify(run.id, expected: run, now: now) { value, state in
            if value.exitReason != nil { value.phase = .finished }
            else if let current = value.latestRound, current.sourceResponse != nil, current.responseCompletion != nil, current.number < value.roundCap {
                value.rounds.append(TwinRound(number: current.number + 1, createdAt: now)); value.phase = .waitingForSource
            } else { value.phase = .needsReview; value.message = "Twin cleanup completed without a verified continuation or termination" }
        }
    }

    private func require(_ id: String) throws -> TwinRun {
        guard let value = try store.load().runs.first(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown twin workflow") }
        return value
    }

    private func claim(_ run: TwinRun, kind: TwinOperationKind, phase: TwinPhase, round: Int? = nil, now: Date,
                       setup: (inout TwinRun, inout TwinState) throws -> Void = { _, _ in }) throws -> TwinRun {
        try modify(run.id, expected: run, now: now) { value, state in
            guard value.operation == nil else { throw TerminalError.invalid("Twin operation is already in progress") }
            value.operation = TwinOperationIntent(kind: kind, round: round ?? value.currentRound, startedAt: now)
            value.phase = phase
            try setup(&value, &state)
        }
    }

    private func complete(_ claimed: TwinRun, next: TwinPhase, now: Date, evenWhenStopped: Bool = false,
                          update: (inout TwinRun, inout TwinState) throws -> Void = { _, _ in }) throws {
        _ = try modify(claimed.id, now: now) { value, state in
            guard value.operation?.id == claimed.operation?.id else { throw TerminalError.invalid("Twin operation result no longer owns its reservation") }
            try update(&value, &state)
            value.operation = nil
            value.phase = value.exitReason != nil && !evenWhenStopped ? .cleaning : next
            value.rounds[value.currentRound - 1].updatedAt = now
        }
    }

    private func finish(_ run: TwinRun, reason: TwinExitReason, message: String?, now: Date) throws {
        _ = try modify(run.id, expected: run, now: now) { value, _ in
            value.exitReason = reason; value.phase = .cleaning; value.message = message.map(Self.message)
        }
    }

    private func modify(_ id: String, expected: TwinRun? = nil, now: Date,
                        update: (inout TwinRun, inout TwinState) throws -> Void) throws -> TwinRun {
        try store.transaction { state in
            guard let index = state.runs.firstIndex(where: { $0.id == id }), expected == nil || state.runs[index] == expected else {
                throw TerminalError.invalid("Twin lifecycle changed before this operation")
            }
            var value = state.runs[index]
            try update(&value, &state)
            guard let currentIndex = state.runs.firstIndex(where: { $0.id == id }) else { throw TerminalError.invalid("Twin workflow was removed during its update") }
            value.updatedAt = now; state.runs[currentIndex] = value
            return value
        }
    }

    private static func message(_ value: String) -> String { String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value != 0 }.prefix(900))) }
    private static func prune(_ state: inout TwinState, preserving: String? = nil) {
        let keep = Set(state.runs.filter { !$0.isActive && $0.id != preserving }.sorted { $0.updatedAt > $1.updatedAt }.prefix(16).map(\.id))
        let removed = Set(state.runs.filter { !$0.isActive && $0.id != preserving && !keep.contains($0.id) }.map(\.id))
        state.runs.removeAll { removed.contains($0.id) }; state.decisionBindings.removeAll { removed.contains($0.runID) }; state.forwardReceipts.removeAll { removed.contains($0.runID) }
    }
}
