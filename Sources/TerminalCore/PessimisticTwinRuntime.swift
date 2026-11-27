import Foundation
import Darwin

public enum TwinRuntimeGate {
    public static func context(source: TwinSourceBinding, snapshot: RuntimeState, backendBirth: SupervisorProcessIdentity?,
                               providerBirth: SupervisorProcessIdentity?, providerWitness: String?, inputRevision: UInt64?,
                               pendingDecisions: Bool, enabled: Bool) -> TwinRuntimeContext {
        let pane = snapshot.sessions.first { $0.id == source.paneID && $0.pid == source.backendPID && $0.alive && $0.remote == nil }
        let launch = snapshot.agentLaunches.first { $0.id == source.generation && $0.paneID == source.paneID && $0.lifecycle == .active }
        let same = pane != nil && launch?.provider == source.provider && launch?.providerSessionID == source.conversationID
            && launch?.providerPID == source.providerPID && launch?.accountID == source.accountID
            && launch?.configurationRoot == source.configurationRoot && launch?.cwd == source.cwd
            && backendBirth == source.backendIdentity && providerBirth == source.providerIdentity
        let turn = snapshot.followUpTurns.first { $0.paneID == source.paneID && $0.generation == source.generation }
        let monitor = snapshot.supervision.first { $0.generation == source.generation }
        let completion: TwinCompletion?
        if same, pane?.activity.state == .done, pane?.activity.source == "hook", turn?.providerPID == source.providerPID,
           turn?.providerIdentity == providerWitness, providerWitness != nil, turn?.armed == false, turn?.blocked == false,
           let id = turn?.completionID, let prompt = turn?.promptID, let date = turn?.completedAt {
            completion = TwinCompletion(id: id, turnID: prompt, completedAt: date, inputRevision: inputRevision ?? 0)
        } else { completion = nil }
        let childActive = pane?.agentTasks?.contains { ($0.generation == nil || $0.generation == source.generation) && $0.activity.state != .done } ?? false
        return TwinRuntimeContext(source: same ? source : nil, completion: completion, enabled: enabled, inputClear: inputRevision != nil,
            hasActiveTools: childActive || monitor?.activeTools.isEmpty == false || (monitor?.unknownToolCount ?? 0) > 0,
            hasPendingDecisions: pendingDecisions, hasQueuedInput: snapshot.followUpInputs.contains { $0.paneID == source.paneID },
            quotaSwitching: monitor?.targetAccountID != nil)
    }
}

extension TerminalRuntime {
    public func pessimisticTwins(paneID: String? = nil) throws -> [TwinRun] {
        try TwinStore(root: root).load().runs.filter { paneID == nil || $0.source.paneID == paneID || $0.rounds.contains { $0.pane?.paneID == paneID } }
    }

    func requireTwin(_ id: String) throws -> TwinRun {
        guard UUID(uuidString: id) != nil, let value = try TwinStore(root: root).load().runs.first(where: { $0.id == id }) else {
            throw TerminalError.invalid("This pessimistic twin is no longer available")
        }
        return value
    }

    public func twinSourceBinding(paneID: String) throws -> TwinSourceBinding {
        let snapshot = try state()
        let reserved = try twinReservedPaneIDs()
        guard !reserved.contains(paneID),
              let pane = snapshot.sessions.first(where: { $0.id == paneID && $0.alive && $0.remote == nil }),
              let launch = snapshot.agentLaunches.first(where: { $0.paneID == paneID && $0.lifecycle == .active && $0.provider != .shell }),
              let conversation = launch.providerSessionID, UUID(uuidString: conversation) != nil,
              let providerPID = launch.providerPID, Self.worktreeProcess(providerPID, descendsFrom: pane.pid),
              let backend = SupervisorProcessIdentity.read(pane.pid), let provider = SupervisorProcessIdentity.read(providerPID) else {
            throw TerminalError.invalid("Open a live managed Claude or Codex conversation before creating its twin")
        }
        if let accountID = launch.accountID {
            guard let account = snapshot.accounts.first(where: { $0.id == accountID && $0.enabled && $0.provider == launch.provider }),
                  account.organizationUsageBindingID == launch.organizationBindingID else { throw TerminalError.invalid("The original account or organization changed") }
        }
        return TwinSourceBinding(paneID: paneID, generation: launch.id, conversationID: conversation, cwd: launch.cwd,
            configurationRoot: launch.configurationRoot, provider: launch.provider, accountID: launch.accountID,
            backendPID: pane.pid, providerPID: providerPID, backendIdentity: backend, providerIdentity: provider)
    }

    func twinSourceContext(run: TwinRun, active: Bool = true) throws -> TwinRuntimeContext {
        let snapshot = try state()
        let exact = (try? twinSourceBinding(paneID: run.source.paneID)) == run.source
        if !exact { return TwinRuntimeContext(source: nil, enabled: active) }
        let binding = try? terminalInputBinding(paneID: run.source.paneID, expectedPID: run.source.backendPID,
            generation: run.source.generation, snapshot: snapshot)
        let revision = try binding.flatMap { try TerminalInputLedgerStore(root: root).load().readiness(binding: $0).lease?.revision }
        let pending = try decisionInbox(paneID: run.source.paneID).contains {
            $0.generation == run.source.generation && !TwinDecisionID.isReserved($0.id)
                && ($0.status == "pending" || $0.status == "resolved" && !$0.delivered)
        }
        return TwinRuntimeGate.context(source: run.source, snapshot: snapshot,
            backendBirth: SupervisorProcessIdentity.read(run.source.backendPID), providerBirth: SupervisorProcessIdentity.read(run.source.providerPID),
            providerWitness: Self.twinProviderWitness(run.source.providerPID), inputRevision: revision,
            pendingDecisions: pending, enabled: active)
    }

    func twinCoordinator(active: @escaping () -> Bool = { true }) -> TwinCoordinator {
        TwinCoordinator(store: TwinStore(root: root), backend: RuntimeTwinBackend(runtime: self, active: active))
    }

    @discardableResult public func enablePessimisticTwin(paneID: String, mode: TwinReviewMode, roundCap: Int = 3, noopCap: Int = 2, expectedSource: TwinSourceExpectation? = nil) throws -> TwinRun {
        try transaction {
            let source = try twinSourceBinding(paneID: paneID)
            if let expectedSource, !expectedSource.matches(source) {
                throw TerminalError.invalid("The source conversation changed before Twin activation. Open the Twin menu again.")
            }
            let provisional = TwinRun(source: source, mode: mode)
            let context = try twinSourceContext(run: provisional)
            return try twinCoordinator().enable(source: source, mode: mode, roundCap: roundCap, noopCap: noopCap,
                enabledCompletionID: context.completion?.id)
        }
    }

    public func stopPessimisticTwin(id: String) throws {
        try transaction {
            let run = try requireTwin(id)
            try twinCoordinator().stop(id: id)
            guard let round = run.latestRound, let ticket = try? twinLaunchTicket(runID: id, round: round.number),
                  let backend = ticket.backendPID, SupervisorProcessIdentity.read(backend) == ticket.backendIdentity,
                  let launch = try state().agentLaunches.first(where: { $0.id == ticket.generation && $0.paneID == ticket.paneID && $0.lifecycle == .active }),
                  let wrapper = launch.processID, let pid = launch.providerPID,
                  Self.worktreeProcess(wrapper, descendsFrom: backend), Self.worktreeProcess(pid, descendsFrom: wrapper) else { return }
            _ = kill(-pid, SIGINT)
        }
    }

    static func twinProviderWitness(_ pid: Int32) -> String? {
        guard let birth = SupervisorProcessIdentity.read(pid) else { return nil }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
        return "\(birth.startedAtSeconds).\(birth.startedAtMicroseconds):" + String(cString: path)
    }

    func twinPeer(run: TwinRun, round: TwinRound, originPID: Int32) throws -> (TwinPaneBinding, AgentLaunch) {
        let ticket = try twinLaunchTicket(runID: run.id, round: round.number)
        guard let paneID = ticket.paneID, let pid = ticket.backendPID, let birth = ticket.backendIdentity,
              SupervisorProcessIdentity.read(pid) == birth, Self.worktreeProcess(originPID, descendsFrom: pid),
              let launch = try state().agentLaunches.first(where: { $0.id == ticket.generation && $0.paneID == paneID && $0.lifecycle == .active }),
              launch.provider == run.source.provider, launch.configurationRoot == ticket.configurationRoot,
              let providerPID = launch.providerPID, Self.worktreeProcess(originPID, descendsFrom: providerPID),
              SupervisorProcessIdentity.read(providerPID) != nil else { throw TerminalError.invalid("The twin request is not from its exact active provider") }
        return (TwinPaneBinding(paneID: paneID, generation: launch.id, backendPID: pid, backendIdentity: birth,
            conversationID: launch.providerSessionID), launch)
    }

    func requireTwinSourcePeer(run: TwinRun, originPID: Int32) throws {
        guard try twinSourceBinding(paneID: run.source.paneID) == run.source,
              Self.worktreeProcess(originPID, descendsFrom: run.source.providerPID) else {
            throw TerminalError.invalid("The original response is not from the bound source conversation")
        }
    }
}

private final class RuntimeTwinBackend: TwinBackend {
    let runtime: TerminalRuntime
    let active: () -> Bool
    init(runtime: TerminalRuntime, active: @escaping () -> Bool) { self.runtime = runtime; self.active = active }
    func sourceContext(run: TwinRun) throws -> TwinRuntimeContext { try runtime.twinSourceContext(run: run, active: active()) }
    func snapshot(run: TwinRun, round: TwinRound) throws -> TwinGitSnapshot { try runtime.prepareTwinSnapshot(run: run, round: round, active: active) }
    func launch(run: TwinRun, round: TwinRound) throws -> TwinPaneBinding { try runtime.launchTwinPane(run: run, round: round, active: active) }
    func completedReview(run: TwinRun, round: TwinRound) throws -> TwinReviewOutcome? { try runtime.completedTwinReview(run: run, round: round) }
    func publishDecision(run: TwinRun, round: TwinRound, decisionID: String) throws { try runtime.publishTwinDecision(run: run, round: round, decisionID: decisionID) }
    func merge(run: TwinRun, round: TwinRound, sourceContext: TwinRuntimeContext) throws -> TwinMergeOutcome { try runtime.mergeTwinReview(run: run, round: round, context: sourceContext, active: active) }
    func enqueueFeedback(run: TwinRun, round: TwinRound, idempotencyKey: String) throws -> String { try runtime.forwardTwinResult(run: run, round: round, key: idempotencyKey) }
    func cleanup(run: TwinRun, round: TwinRound) throws { try runtime.cleanupTwinRound(run: run, round: round, active: active) }
}
