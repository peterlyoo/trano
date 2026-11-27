import Foundation
import Darwin

public struct TwinAPIScope: Equatable {
    public let runID: String
    public init(runID: String) { self.runID = runID }
    public func permits(_ method: String) -> Bool {
        ["twins.hook", "twins.diff", "twins.commit", "twins.report"].contains(method)
    }
    static func hookOutput(_ value: JSONValue, globalSocket: String, scopedSocket: String) -> JSONValue {
        switch value {
        case .string(let text): return .string(text.replacingOccurrences(of: globalSocket, with: scopedSocket))
        case .object(let fields): return .object(fields.mapValues { hookOutput($0, globalSocket: globalSocket, scopedSocket: scopedSocket) })
        case .array(let values): return .array(values.map { hookOutput($0, globalSocket: globalSocket, scopedSocket: scopedSocket) })
        default: return value
        }
    }
}

extension TerminalRuntime {
    func isTwinPeer(_ pid: Int32) throws -> Bool {
        for run in try TwinStore(root: root).load().runs where run.isActive {
            for round in run.rounds where !round.cleaned {
                if let ticket = try? twinLaunchTicket(runID: run.id, round: round.number),
                   let backend = ticket.backendPID, SupervisorProcessIdentity.read(backend) == ticket.backendIdentity,
                   Self.worktreeProcess(pid, descendsFrom: backend) { return true }
            }
        }
        return false
    }

    func twinAPI(_ request: APIRequest, originPID: Int32?, scope: TwinAPIScope?) throws -> JSONValue? {
        if let scope {
            guard scope.permits(request.method), request.params["runID"]?.text == scope.runID else { throw TerminalError.invalid("This API is restricted to the bound twin") }
        }
        guard request.method.hasPrefix("twins.") else { return nil }
        func required(_ key: String) throws -> String {
            guard let value = request.params[key]?.text else { throw TerminalError.invalid("Missing twin parameter: " + key) }; return value
        }
        if request.method == "twins.status" {
            return .object(["runs": try .encoded(pessimisticTwins(paneID: request.params["paneID"]?.text))])
        }
        guard let originPID, originPID > 1 else { throw TerminalError.invalid("Twin controls require the local Unix API") }
        if request.method == "twins.enable" {
            guard scope == nil, let mode = TwinReviewMode(rawValue: try required("mode")) else { throw TerminalError.invalid("Choose code_review, security_review or general_review") }
            func cap(_ key: String, default fallback: Int) throws -> Int {
                guard let raw = request.params[key] else { return fallback }
                guard case .number(let value) = raw, value.rounded() == value, (1...8).contains(value) else { throw TerminalError.invalid("Twin caps must be integers between 1 and 8") }
                return Int(value)
            }
            return try .encoded(enablePessimisticTwin(paneID: required("paneID"), mode: mode,
                roundCap: cap("roundCap", default: 3), noopCap: cap("noopCap", default: 2)))
        }
        if request.method == "twins.stop" {
            guard scope == nil else { throw TerminalError.invalid("The reviewer cannot stop its workflow") }
            try stopPessimisticTwin(id: required("runID")); return .object(["ok": .bool(true)])
        }
        guard ["twins.hook", "twins.diff", "twins.commit", "twins.report", "twins.respond"].contains(request.method) else { throw TerminalError.invalid("Unknown twin API method") }
        let runID = try required("runID")
        guard case .number(let rawRound)? = request.params["round"], rawRound.rounded() == rawRound, (1...8).contains(rawRound) else { throw TerminalError.invalid("An exact twin round is required") }
        let number = Int(rawRound)
        let run = try requireTwin(runID)
        guard run.isActive, run.currentRound == number, let round = run.latestRound else { throw TerminalError.invalid("Stale twin round") }
        if request.method == "twins.respond" {
            guard scope == nil else { throw TerminalError.invalid("Only the original conversation can respond") }
            return try transaction {
                try requireTwinSourcePeer(run: run, originPID: originPID)
                guard let forwardedID = round.forwardedID,
                      try !state().followUpInputs.contains(where: { $0.id == forwardedID }) else { throw TerminalError.invalid("The result has not been delivered to the original conversation") }
                let report = try TwinReport.decode(JSONEncoder().encode(request.params["envelope"] ?? .null))
                try twinCoordinator().submitSourceResponse(runID: run.id, round: number, source: run.source, report: report)
                return .object(["ok": .bool(true)])
            }
        }
        guard scope != nil else { throw TerminalError.invalid("Reviewer commands require their dedicated twin socket") }
        let (pane, launch) = try twinPeer(run: run, round: round, originPID: originPID)
        if request.method == "twins.hook" {
            return try transaction {
                guard let providerPID = launch.providerPID, ProcessIdentity.isRootHook(originPID: originPID, providerPID: providerPID, provider: launch.provider),
                      let helperExecutable else { throw TerminalError.invalid("The owned twin hook helper is unavailable") }
                try TwinHookAdmission.validate(originPID: originPID, providerPID: providerPID, provider: launch.provider,
                    helperExecutable: helperExecutable, protectedPath: root.appendingPathComponent("twins/\(runID)/round-\(number)/launch-ticket.json").path)
                guard let payload = request.params["payload"], let worktree = round.snapshot?.worktreePath,
                      TwinHookContext.matches(payload, sourceConversationID: run.source.conversationID, worktree: worktree) else {
                    _ = kill(-providerPID, SIGTERM)
                    throw TerminalError.invalid("Stopped the owned twin because its hook escaped the exact fork or worktree")
                }
                let data = try JSONEncoder().encode(payload)
                try recordAgentHook(paneID: pane.paneID, generation: pane.generation, provider: launch.provider, data: data, originPID: originPID)
                let observation = try twinPaneObservationFromCurrentHook(run: run, round: round)
                let ledger = try TerminalInputLedgerStore(root: root).load()
                let binding = TerminalInputBinding(paneID: pane.paneID, backendPID: pane.backendPID, generation: pane.generation, providerPID: providerPID)
                let fingerprint = ledger.readiness(binding: binding).lease == nil ? nil : try ledger.ownedInvocationFingerprint(paneID: pane.paneID)
                _ = try updateTwinLaunchTicket(runID: runID, round: number) {
                    if let observation { $0.lastCompletion = observation.0 }
                    else if payload["hook_event_name"]?.text != "SessionEnd" { $0.lastCompletion = nil }
                    if let fingerprint { $0.lastInputFingerprint = fingerprint }
                }
                guard let output = try decisionHookOutput(paneID: pane.paneID, generation: pane.generation, provider: launch.provider, data: data, originPID: originPID) else { return .null }
                return TwinAPIScope.hookOutput(output, globalSocket: root.appendingPathComponent("api.sock").path,
                    scopedSocket: try twinSocketPath(runID: runID))
            }
        }
        if request.method == "twins.diff" {
            guard let snapshot = round.snapshot else { throw TerminalError.invalid("Twin snapshot is unavailable") }
            return .object(["diff": .string(try TwinGitService(root: root).snapshotDiff(snapshot: snapshot))])
        }
        if request.method == "twins.report" {
            return try transaction {
                let report: TwinReport
                do { report = try TwinReport.decode(JSONEncoder().encode(request.params["envelope"] ?? .null)) }
                catch {
                    if run.phase == .reviewing { try twinCoordinator().rejectReport(runID: runID, round: number, pane: pane, message: error.localizedDescription) }
                    throw error
                }
                let state = try state()
                guard [.launching, .reviewing].contains(run.phase),
                      let turnID = state.followUpTurns.first(where: { $0.paneID == pane.paneID && $0.generation == pane.generation })?.promptID else {
                    throw TerminalError.invalid("Submit the report in the active trusted twin turn")
                }
                _ = try updateTwinLaunchTicket(runID: runID, round: number) { ticket in
                    guard ticket.reportedEnvelope == nil || ticket.reportedEnvelope == report else { throw TerminalError.invalid("A different final report already exists") }
                    if ticket.reportedEnvelope == nil { ticket.reportedEnvelope = report; ticket.reportedAt = Date(); ticket.reportedTurnID = turnID }
                }
                return .object(["ok": .bool(true)])
            }
        }
        let result = try TwinStore(root: root).withOperationLease { () throws -> JSONValue in
            let ticket = try self.twinLaunchTicket(runID: runID, round: number)
            guard let worktree = round.snapshot?.worktreePath else { throw TerminalError.invalid("Twin commit lacks its exact worktree") }
            try TwinFileAliasAdmission.validate(worktree: worktree, temporaryDirectory: ticket.configurationRoot + "/tmp")
            return try self.transaction {
                let current = try self.requireTwin(runID)
                guard current.phase == .reviewing, current.currentRound == number,
                      current.latestRound?.pane?.matchesProcess(pane) == true, current.latestRound?.report == nil,
                      let snapshot = current.latestRound?.snapshot else { throw TerminalError.invalid("This twin can no longer commit changes") }
                _ = try self.twinPeer(run: current, round: current.latestRound!, originPID: originPID)
                let review = try TwinGitService(root: self.root).commit(snapshot: snapshot, message: required("message"), recordMutation: {
                    try self.twinMutationJournal(runID: runID, round: number, stage: $0)
                })
                return .object(["tip": .string(review.tip), "changed_files": .array(review.changedFiles.map(JSONValue.string))])
            }
        }
        return result ?? .object(["status": .string("busy"), "retryAfterMs": .number(250)])
    }

    func scopedTwinDecision(_ request: JSONValue, scope: TwinAPIScope, originPID: Int32?) throws -> JSONValue {
        guard let originPID else { throw TerminalError.invalid("Cannot authenticate twin decision peer") }
        let run = try requireTwin(scope.runID)
        guard run.isActive, let round = run.latestRound else { throw TerminalError.invalid("Twin decision is no longer active") }
        let (pane, launch) = try twinPeer(run: run, round: round, originPID: originPID)
        guard let type = request["type"]?.text, ["submit", "poll", "gate"].contains(type) else { throw TerminalError.invalid("Twin decisions allow only asking and reading their own explicit human choice") }
        if type == "submit" {
            guard request["question"]?["source"]?["session_id"]?.text == launch.providerSessionID,
                  request["question"]?["source"]?["workspace"]?.text == launch.cwd else { throw TerminalError.invalid("Decision source differs from the bound twin") }
        } else if type == "poll" {
            guard let id = request["request_id"]?.text, !TwinDecisionID.isReserved(id),
                  let entry = try decisionInbox(paneID: pane.paneID).first(where: { $0.id == id && $0.generation == pane.generation }) else { throw TerminalError.invalid("This is not the twin's operational question") }
            _ = entry
        } else {
            guard request["session_id"]?.text == launch.providerSessionID, request["agent"]?.text == launch.provider.rawValue else { throw TerminalError.invalid("Decision gate differs from the twin conversation") }
        }
        return try decisionAdapter(request, originPID: originPID)
    }

    private func twinPaneObservationFromCurrentHook(run: TwinRun, round: TwinRound) throws -> (TwinCompletion, String)? {
        let ticket = try twinLaunchTicket(runID: run.id, round: round.number)
        guard let paneID = ticket.paneID, let backend = ticket.backendPID else { return nil }
        let state = try state()
        guard let launch = state.agentLaunches.first(where: { $0.id == ticket.generation && $0.paneID == paneID }),
              let providerPID = launch.providerPID, let conversation = launch.providerSessionID,
              conversation.lowercased() != run.source.conversationID.lowercased(),
              let birth = SupervisorProcessIdentity.read(backend), let providerBirth = SupervisorProcessIdentity.read(providerPID) else { return nil }
        let source = TwinSourceBinding(paneID: paneID, generation: launch.id, conversationID: conversation, cwd: launch.cwd,
            configurationRoot: launch.configurationRoot, provider: launch.provider, accountID: launch.accountID,
            backendPID: backend, providerPID: providerPID, backendIdentity: birth, providerIdentity: providerBirth)
        let ledger = try TerminalInputLedgerStore(root: root).load()
        let revision = ledger.readiness(binding: TerminalInputBinding(paneID: paneID, backendPID: backend, generation: launch.id, providerPID: providerPID)).lease?.revision
        let context = TwinRuntimeGate.context(source: source, snapshot: state, backendBirth: birth, providerBirth: providerBirth,
            providerWitness: Self.twinProviderWitness(providerPID), inputRevision: revision, pendingDecisions: try decisionGateReason(paneID: paneID, generation: launch.id) != nil, enabled: true)
        guard context.ready, let completion = context.completion else { return nil }
        return (completion, try ledger.ownedInvocationFingerprint(paneID: paneID))
    }
}


enum TwinHookContext {
    static func matches(_ payload: JSONValue, sourceConversationID: String, worktree: String) -> Bool {
        guard let text = payload["session_id"]?.text, let conversation = UUID(uuidString: text),
              conversation != UUID(uuidString: sourceConversationID), let cwd = payload["cwd"]?.text,
              !cwd.utf8.contains(0), !cwd.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }),
              cwd == worktree || cwd.hasPrefix(worktree + "/") else { return false }
        return payload["hook_event_name"]?.text != "SessionStart" || cwd == worktree
    }
}
