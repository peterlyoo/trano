import Foundation
import Darwin

struct TwinPaneObservation: Equatable {
    let binding: TwinPaneBinding
    let completion: TwinCompletion?
    let inputClear: Bool
    let hasBlockers: Bool
}

extension TerminalRuntime {
    func twinReservedPaneIDs() throws -> Set<String> {
        let twins = try TwinStore(root: root).load()
        var ids = Set(twins.runs.flatMap { $0.rounds.compactMap { $0.pane?.paneID } })
        for run in twins.runs {
            for round in run.rounds where round.pane == nil {
                if let ticket = try? twinLaunchTicket(runID: run.id, round: round.number), let paneID = ticket.paneID { ids.insert(paneID) }
            }
        }
        return ids
    }

    public func twinSocketPath(runID: String) throws -> String {
        guard UUID(uuidString: runID) != nil else { throw TerminalError.invalid("Invalid twin socket identity") }
        let path = root.appendingPathComponent("twin-" + runID.lowercased() + ".sock").path
        guard path.utf8.count < 104 else { throw TerminalError.invalid("The runtime path is too long for a scoped twin socket") }
        return path
    }

    func launchTwinPane(run: TwinRun, round: TwinRound, active: @escaping () -> Bool) throws -> TwinPaneBinding {
        guard let snapshot = round.snapshot else { throw TerminalError.invalid("Twin snapshot is unavailable") }
        return try transaction {
            let current = try requireTwin(run.id)
            guard active(), current == run, current.phase == .launching,
                  try twinSourceContext(run: run).source == run.source,
                  let workspaceID = try state().layout.tabs.first(where: { $0.panes.contains(run.source.paneID) })?.workspaceID,
                  let helperExecutable else { throw TerminalError.invalid("The original workspace or twin launch changed") }
            var ticket = try twinLaunchTicket(runID: run.id, round: round.number)
            guard ticket.paneID == nil else { throw TerminalError.invalid("A twin launch already owns a pane; inspect its receipt") }
            let paneID = UUID().uuidString.lowercased()
            ticket = try updateTwinLaunchTicket(runID: run.id, round: round.number) { $0.paneID = paneID }
            let owned = OwnedTerminalLaunch(title: "Twin · " + run.mode.rawValue, workspaceID: workspaceID, paneID: paneID, command: { pane in
                guard let birth = SupervisorProcessIdentity.read(pane.pid) else { throw TerminalError.runtime("Cannot verify the twin terminal process") }
                _ = try self.updateTwinLaunchTicket(runID: run.id, round: round.number) {
                    $0.backendPID = pane.pid; $0.backendIdentity = birth
                }
                return [helperExecutable, "twin", "run", run.id, "--round", String(round.number)]
            }, beforeWrite: { pane in
                guard active() else { throw TerminalError.invalid("Twin launch stopped before input") }
                let fingerprint = try TerminalInputLedgerStore(root: self.root).load().ownedInvocationFingerprint(paneID: pane.id)
                _ = try self.updateTwinLaunchTicket(runID: run.id, round: round.number) { $0.inputFingerprint = fingerprint }
            })
            let result = try launch(cwd: snapshot.worktreePath, agent: run.source.provider, owned: owned)
            guard let birth = SupervisorProcessIdentity.read(result.pane.pid) else { throw TerminalError.runtime("The twin terminal process changed") }
            return TwinPaneBinding(paneID: result.pane.id, generation: ticket.generation, backendPID: result.pane.pid, backendIdentity: birth)
        }
    }

    public func validateTwinBootstrap(ticket: TwinLaunchTicket, paneID: String, provider: AgentKind, cwd: String) throws {
        try validateTwinFrozenAuthentication(ticket: ticket)
        let saved = try twinLaunchTicket(runID: ticket.runID, round: ticket.round)
        let run = try requireTwin(ticket.runID)
        guard saved == ticket, ticket.paneID == paneID, ticket.source == run.source, run.currentRound == ticket.round,
              [.launching, .reviewing].contains(run.phase), run.latestRound?.snapshot?.worktreePath == cwd,
              provider == run.source.provider, let backend = ticket.backendPID, let birth = ticket.backendIdentity,
              SupervisorProcessIdentity.read(backend) == birth, Self.worktreeProcess(getpid(), descendsFrom: backend),
              try twinSourceContext(run: run).source == run.source,
              try TerminalInputLedgerStore(root: root).load().ownedInvocationFingerprint(paneID: paneID) == ticket.inputFingerprint else {
            throw TerminalError.invalid("The owned twin bootstrap, source, or input changed")
        }
    }

    public func registerTwinInvocation(ticket: TwinLaunchTicket, providerPID: Int32) throws {
        try validateTwinFrozenAuthentication(ticket: ticket)
        try transaction {
            let saved = try twinLaunchTicket(runID: ticket.runID, round: ticket.round)
            let run = try requireTwin(ticket.runID)
            guard saved.hasSameLaunch(as: ticket), saved.authenticationSeedProof == ticket.authenticationSeedProof,
                  run.source == ticket.source, run.currentRound == ticket.round, [.launching, .reviewing].contains(run.phase) else {
                throw TerminalError.invalid("The frozen twin authentication or source binding changed before continuation")
            }
            guard let paneID = ticket.paneID, let backend = ticket.backendPID, let fingerprint = ticket.inputFingerprint,
                  let launch = try state().agentLaunches.first(where: { $0.paneID == paneID && $0.id == ticket.generation && $0.providerPID == providerPID }),
                  launch.configurationRoot == ticket.configurationRoot, launch.providerSessionID == nil,
                  SupervisorProcessIdentity.read(backend) == ticket.backendIdentity else { throw TerminalError.invalid("Twin invocation identity changed") }
            let binding = TerminalInputBinding(paneID: paneID, backendPID: backend, generation: ticket.generation, providerPID: providerPID)
            var ledger = try TerminalInputLedgerStore(root: root).load()
            try ledger.registerOwnedInvocationPrompt(binding: binding, expectedPriorFingerprint: fingerprint)
            try TerminalInputLedgerStore(root: root).save(ledger)
            let registered = try ledger.ownedInvocationFingerprint(paneID: paneID)
            _ = try updateTwinLaunchTicket(runID: ticket.runID, round: ticket.round) { $0.lastInputFingerprint = registered }
        }
    }

    public func recordTwinExit(ticket: TwinLaunchTicket, code: Int32) throws {
        try transaction {
            guard let launch = try state().agentLaunches.first(where: { $0.id == ticket.generation && $0.paneID == ticket.paneID }),
                  launch.processID == getpid(), launch.lifecycle == .active,
                  ticket.backendPID.map({ Self.worktreeProcess(getpid(), descendsFrom: $0) }) == true else { throw TerminalError.invalid("Untrusted twin exit receipt") }
            _ = try updateTwinLaunchTicket(runID: ticket.runID, round: ticket.round) { $0.providerExitCode = code }
        }
    }

    func twinPaneObservation(run: TwinRun, round: TwinRound) throws -> TwinPaneObservation? {
        let ticket = try twinLaunchTicket(runID: run.id, round: round.number)
        guard let paneID = ticket.paneID, let backend = ticket.backendPID, let birth = ticket.backendIdentity else { return nil }
        let state = try state()
        guard state.sessions.contains(where: { $0.id == paneID && $0.pid == backend && $0.alive && $0.remote == nil }),
              SupervisorProcessIdentity.read(backend) == birth,
              let launch = state.agentLaunches.first(where: { $0.id == ticket.generation && $0.paneID == paneID }),
              let conversation = launch.providerSessionID, conversation.lowercased() != run.source.conversationID.lowercased(),
              let providerPID = launch.providerPID else { return nil }
        let binding = TwinPaneBinding(paneID: paneID, generation: ticket.generation, backendPID: backend, backendIdentity: birth, conversationID: conversation)
        let input = try TerminalInputLedgerStore(root: root).load()
        let fingerprint = try input.ownedInvocationFingerprint(paneID: paneID)
        let ledgerBinding = TerminalInputBinding(paneID: paneID, backendPID: backend, generation: ticket.generation, providerPID: providerPID)
        let revision = input.readiness(binding: ledgerBinding).lease?.revision
        let pending = try decisionInbox(paneID: paneID).contains { !TwinDecisionID.isReserved($0.id) && ($0.status == "pending" || $0.status == "resolved" && !$0.delivered) }
        let monitor = state.supervision.first { $0.generation == launch.id }
        let children = state.sessions.first { $0.id == paneID }?.agentTasks?.contains { $0.activity.state != .done } ?? false
        let blocked = pending || children || monitor?.activeTools.isEmpty == false || (monitor?.unknownToolCount ?? 0) > 0 || state.followUpInputs.contains { $0.paneID == paneID }
        let completion = ticket.lastInputFingerprint == fingerprint && revision == ticket.lastCompletion?.inputRevision ? ticket.lastCompletion : nil
        let usable = launch.lifecycle == .active && SupervisorProcessIdentity.read(providerPID) != nil || launch.lifecycle == .exited && ticket.providerExitCode == 0
        return TwinPaneObservation(binding: binding, completion: usable ? completion : nil, inputClear: revision != nil, hasBlockers: blocked || !usable)
    }

    func twinMutationJournal(runID: String, round: Int, stage: TwinGitMutationStage) throws {
        _ = try updateTwinLaunchTicket(runID: runID, round: round) { ticket in
            ticket.mutationStages.append(stage.rawValue)
            guard ticket.mutationStages.count <= 128 else { throw TerminalError.invalid("Twin mutation journal is full") }
        }
    }

    func retireTwinPane(run: TwinRun, round: TwinRound) throws {
        guard run.phase == .cleaning, let operation = run.operation, operation.kind == .cleanup, operation.round == round.number else {
            throw TerminalError.invalid("Twin pane retirement lacks an exact cleanup claim")
        }
        try transaction {
            let ticket = try twinLaunchTicket(runID: run.id, round: round.number)
            guard let paneID = ticket.paneID, let backend = ticket.backendPID, let birth = ticket.backendIdentity else { return }
            let state = try state()
            guard let pane = state.sessions.first(where: { $0.id == paneID }) else {
                if SupervisorProcessIdentity.read(backend) == birth {
                    throw TwinCleanupPending(operationID: operation.id, message: "Waiting for the owned twin terminal to exit before deleting its profile")
                }
                return
            }
            guard pane.pid == backend, SupervisorProcessIdentity.read(backend) == birth,
                  !state.agentLaunches.contains(where: { $0.paneID == paneID && $0.id != ticket.generation }) else { throw TerminalError.invalid("Twin terminal ownership changed; kept its worktree") }
            if let launch = state.agentLaunches.first(where: { $0.paneID == paneID }),
               ticket.providerExitCode != nil, launch.providerPID.flatMap(SupervisorProcessIdentity.read) == nil {
                guard try TerminalInputLedgerStore(root: root).load().ownedInvocationFingerprint(paneID: paneID) == ticket.lastInputFingerprint,
                      try decisionGateReason(paneID: paneID, generation: ticket.generation) == nil else { throw TerminalError.invalid("Twin exit input or decisions changed; cleanup is held") }
            } else if state.agentLaunches.contains(where: { $0.paneID == paneID }) {
                let fingerprint = try TerminalInputLedgerStore(root: root).load().ownedInvocationFingerprint(paneID: paneID)
                let interrupt = TwinProviderRetirement.canInterruptReview(reason: run.exitReason, expectedFingerprint: ticket.lastInputFingerprint,
                    fingerprint: fingerprint, pendingDecision: try decisionGateReason(paneID: paneID, generation: ticket.generation) != nil)
                if !interrupt {
                    guard let observation = try twinPaneObservation(run: run, round: round), observation.inputClear, !observation.hasBlockers, observation.completion != nil else {
                        throw TerminalError.invalid("Twin terminal has live work, input, or an unresolved decision; cleanup is held")
                    }
                }
            } else {
                guard try TerminalInputLedgerStore(root: root).load().ownedInvocationFingerprint(paneID: paneID) == ticket.inputFingerprint else {
                    throw TerminalError.invalid("Twin bootstrap input changed; cleanup is held")
                }
            }
            if let launch = state.agentLaunches.first(where: { $0.paneID == paneID && $0.id == ticket.generation }),
               let provider = launch.providerPID, let identity = SupervisorProcessIdentity.read(provider) {
                guard let wrapper = launch.processID, Self.worktreeProcess(wrapper, descendsFrom: backend),
                      Self.worktreeProcess(provider, descendsFrom: wrapper), getpgid(provider) == provider,
                      Self.twinProviderWitness(provider) == "\(identity.startedAtSeconds).\(identity.startedAtMicroseconds):" + ticket.providerExecutable else {
                    throw TerminalError.invalid("Twin provider ownership changed before retirement; resources are retained")
                }
                let request = try TwinProviderRetirement.request(stages: ticket.mutationStages, now: Date())
                if let marker = request.marker {
                    _ = try updateTwinLaunchTicket(runID: run.id, round: round.number) {
                        guard $0.mutationStages == ticket.mutationStages, $0.mutationStages.count < 128 else {
                            throw TerminalError.invalid("Twin retirement journal changed")
                        }
                        $0.mutationStages.append(marker)
                    }
                }
                if let signal = request.signal {
                    guard SupervisorProcessIdentity.read(provider) == identity, getpgid(provider) == provider else {
                        throw TerminalError.invalid("Twin provider changed before its stop signal")
                    }
                    guard kill(-provider, signal) == 0 || errno == ESRCH else { throw TerminalError.invalid("Cannot stop the owned twin provider") }
                }
                throw TwinCleanupPending(operationID: operation.id, message: "Waiting for the owned twin provider and its exit receipt before cleanup")
            }
            try terminate(paneID)
            if SupervisorProcessIdentity.read(backend) == birth {
                throw TwinCleanupPending(operationID: operation.id, message: "Waiting for the owned twin terminal to exit before deleting its profile")
            }
        }
    }

    func ensureNoOrphanedTwinResources(runID: String, round: Int) throws {
        try TwinUnclaimedRoundResources.requireAbsent(path: root.appendingPathComponent("twins/\(runID)/round-\(round)").path)
    }

    func ensureTwinCleanupAdmission(run: TwinRun, round: TwinRound) throws {
        let current = try requireTwin(run.id)
        guard current.phase == .cleaning, current.currentRound == round.number, current.latestRound?.snapshot == round.snapshot,
              current.operation?.kind == .cleanup else { throw TerminalError.invalid("Twin cleanup ownership changed") }
        guard let snapshot = round.snapshot else { return }
        guard !FileManager.default.fileExists(atPath: snapshot.sourceGitDirectory + "/MERGE_HEAD") else { throw TerminalError.invalid("The source merge conflict needs human resolution") }
        let state = try state()
        let inside: (String) -> Bool = { path in path == snapshot.worktreePath || path.hasPrefix(snapshot.worktreePath + "/") }
        guard !state.sessions.contains(where: { $0.alive && $0.remote == nil && inside($0.cwd) }),
              !state.agentLaunches.contains(where: { $0.lifecycle == .active && inside($0.cwd) }) else { throw TerminalError.invalid("Another session is using the twin worktree") }
    }
}
