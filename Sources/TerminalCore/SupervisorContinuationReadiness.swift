import Foundation

public enum SupervisorReadinessProjection {
    public static func revoke(state: SupervisorState) -> SupervisorState {
        let unknown = refresh(state: state, ledger: TerminalInputLedger())
        let targets = unknown.targets.map { target -> SupervisorTarget in
            var row = target
            if row.reference != nil { row.inputReadiness = SupervisorInputReadinessSummary(state: .changed) }
            row.continuationOffer = nil
            return row
        }
        let cursor = SupervisorWatchCursor(targets: targets.map {
            SupervisorWatchTarget(paneID: $0.paneID, backendPID: $0.backendPID, alive: $0.alive, provider: $0.provider,
                activity: $0.activity, generation: $0.generation, pendingDecision: $0.pendingDecision,
                quotaLimited: $0.quotaLimited, inputReadiness: $0.inputReadiness)
        })
        var next = SupervisorState(phase: unknown.phase, binding: unknown.binding, targets: targets, cursor: cursor,
            message: "Terminal input metadata is unavailable. Automatic continuation is paused.")
        next.continuationAuthority = unknown.continuationAuthority
        return next
    }
    public static func refresh(state: SupervisorState, ledger: TerminalInputLedger) -> SupervisorState {
        let targets = state.targets.prefix(4096).map { target -> SupervisorTarget in
            guard let reference = target.reference else { return target }
            let readiness = ledger.readiness(binding: TerminalInputBinding(paneID: reference.paneID,
                backendPID: reference.backendPID, generation: reference.generation, providerPID: reference.providerPID))
            let retained = target.continuationOffer.flatMap { $0.lease == readiness.lease ? $0 : nil }
            let disposition: SupervisorContinuationDisposition = target.continuation == .ready && retained == nil
                ? .inputReviewRequired : target.continuation
            var row = SupervisorTarget(paneID: target.paneID, backendPID: target.backendPID, alive: target.alive,
                title: target.title, provider: target.provider, activity: target.activity, generation: target.generation,
                pendingDecision: target.pendingDecision, quotaLimited: target.quotaLimited, continuation: disposition)
            row.reference = reference
            row.inputReadiness = SupervisorInputReadinessSummary(readiness)
            row.continuationOffer = retained
            return row
        }
        let cursor = SupervisorWatchCursor(targets: targets.map {
            SupervisorWatchTarget(paneID: $0.paneID, backendPID: $0.backendPID, alive: $0.alive, provider: $0.provider,
                activity: $0.activity, generation: $0.generation, pendingDecision: $0.pendingDecision,
                quotaLimited: $0.quotaLimited, inputReadiness: $0.inputReadiness)
        })
        var next = SupervisorState(phase: state.phase, binding: state.binding, targets: targets, cursor: cursor, message: state.message)
        next.continuationAuthority = state.continuationAuthority
        return next
    }
}

extension TerminalRuntime {
    public func refreshSupervisorInputReadiness(state: SupervisorState) throws -> SupervisorState {
        do { return SupervisorReadinessProjection.refresh(state: state, ledger: try TerminalInputLedgerStore(root: root).load()) }
        catch { return SupervisorReadinessProjection.revoke(state: state) }
    }
}
