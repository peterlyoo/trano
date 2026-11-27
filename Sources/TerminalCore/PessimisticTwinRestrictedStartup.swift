import Foundation
import Darwin

struct TwinRestrictedStartupTarget: Equatable {
    var runID: String
    var round: Int
    var paneID: String
    var generation: String
    var backendPID: Int32
    var backendIdentity: SupervisorProcessIdentity
    var configurationRoot: String
    var cwd: String
    var executable: String
    var accountID: String?
}
struct TwinRestrictedStartupObservation: Equatable {
    var target: TwinRestrictedStartupTarget
    var wrapperPID: Int32
    var wrapperIdentity: SupervisorProcessIdentity
    var providerPID: Int32
    var providerIdentity: SupervisorProcessIdentity
    var conversationID: String?
    var fingerprint: String
    var acknowledged: Bool
    var hasSubmittedInput: Bool
    var binding: TerminalInputBinding {
        TerminalInputBinding(paneID: target.paneID, backendPID: target.backendPID, generation: target.generation, providerPID: providerPID)
    }
    func sameAdmission(as other: Self) -> Bool {
        var lhs = self, rhs = other
        lhs.acknowledged = false; rhs.acknowledged = false
        return lhs == rhs
    }
}
struct TwinRestrictedStartupActions {
    let target: TwinRestrictedStartupTarget
    let expectedFingerprint: String
    let active: () -> Bool
    let observe: () throws -> TwinRestrictedStartupObservation?
    let capture: (String) throws -> String
    let reserve: () throws -> Void
    let loadLedger: () throws -> TerminalInputLedger
    let saveLedger: (TerminalInputLedger) throws -> Void
    let sendEnter: (String) throws -> Void
}
enum TwinRestrictedStartup {
    static let marker = "restrictedStartupAcknowledged"
    static func matches(_ screen: String) -> Bool {
        guard screen.utf8.count <= 131_072,
              !screen.unicodeScalars.contains(where: { $0.value < 32 && ![9, 10, 13].contains($0.value) || $0.value == 127 }) else { return false }
        let lines = screen.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard let heading = lines.lastIndex(of: "Folder access") else { return false }
        let text = lines[heading...].joined(separator: " ").replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        let body = "Config, hooks, and exec policies from untrusted folders stay disabled. Trusted project folders can still contribute settings. Skills still load, and tools follow your permission settings. Opening will not change saved trust."
        guard let bodyRange = text.range(of: body), text.components(separatedBy: body).count == 2 else { return false }
        let lower = text.lowercased()
        let forbidden = ["trust and continue", "open existing task", "trust this folder", "your trust decision will be saved", "permission request", "allow once", "always allow", "approve", "merge", "production", "danger-full-access", "bypass", "escalation"]
        guard !forbidden.contains(where: lower.contains) else { return false }
        let suffix = String(text[bodyRange.upperBound...]).trimmingCharacters(in: .whitespaces)
        let pattern = #"^[^\p{L}]*Open restricted\s+[^\p{L}]*(?:Quit|Back to Agent Command Center|Keep current directory)\s+.{1,16} continue · .{1,16} (?:quit|back|cancel)$"#
        return suffix.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static func acknowledge(_ actions: TwinRestrictedStartupActions) throws -> Bool {
        guard actions.active(), let first = try actions.observe(), eligible(first, actions: actions),
              matches(try actions.capture(first.target.paneID)), actions.active(),
              let current = try actions.observe(), first == current else { return false }
        try actions.reserve()
        guard actions.active(), let reserved = try actions.observe(), reserved.acknowledged,
              reserved.sameAdmission(as: first) else { return false }
        var ledger = try actions.loadLedger()
        guard try ledger.ownedInvocationFingerprint(paneID: first.target.paneID) == actions.expectedFingerprint else { return false }
        let receipt = try ledger.beginProtocolWrite(binding: first.binding)
        try actions.saveLedger(ledger)
        var pending = first
        pending.acknowledged = true
        pending.fingerprint = try ledger.ownedInvocationFingerprint(paneID: first.target.paneID)
        let final = actions.active() ? (try actions.observe()) : nil
        if final != pending {
            guard ledger.finishWrite(receipt, succeeded: true) else { throw TerminalError.invalid("Restricted startup cancellation lost its protocol receipt") }
            try actions.saveLedger(ledger)
            return false
        }
        do {
            try actions.sendEnter(first.target.paneID)
            guard ledger.finishWrite(receipt, succeeded: true),
                  try ledger.ownedInvocationFingerprint(paneID: first.target.paneID) == actions.expectedFingerprint else {
                throw TerminalError.invalid("Restricted startup input changed during acknowledgement")
            }
            try actions.saveLedger(ledger)
            return true
        } catch {
            _ = ledger.finishWrite(receipt, succeeded: false)
            try? actions.saveLedger(ledger)
            throw error
        }
    }
    private static func eligible(_ observation: TwinRestrictedStartupObservation, actions: TwinRestrictedStartupActions) -> Bool {
        observation.target == actions.target && observation.conversationID == nil && !observation.hasSubmittedInput && !observation.acknowledged
            && actions.expectedFingerprint.count == 64 && observation.fingerprint == actions.expectedFingerprint
            && observation.wrapperPID > 1 && observation.providerPID > 1
            && observation.wrapperPID != observation.providerPID && observation.wrapperPID != observation.target.backendPID
            && observation.providerPID != observation.target.backendPID
            && observation.wrapperIdentity.pid == observation.wrapperPID && observation.providerIdentity.pid == observation.providerPID
            && observation.wrapperIdentity.ownerUID == getuid() && observation.providerIdentity.ownerUID == getuid()
    }
}

extension TerminalRuntime {
    public func acknowledgeTwinRestrictedStartup(run: TwinRun, round: TwinRound) throws -> Bool {
        try acknowledgeTwinRestrictedStartup(run: run, round: round, active: { true })
    }
    func acknowledgeTwinRestrictedStartup(run: TwinRun, round: TwinRound, active: @escaping () -> Bool) throws -> Bool {
        guard active(), run.source.provider == .codex, run.phase == .reviewing, run.operation == nil, run.exitReason == nil,
              run.latestRound == round, round.report == nil, !round.cleaned,
              let pane = round.pane, let snapshot = round.snapshot else { return false }
        return try transaction {
            let ticket = try twinLaunchTicket(runID: run.id, round: round.number)
            guard ticket.source == run.source, let fingerprint = ticket.lastInputFingerprint,
                  !ticket.mutationStages.contains(TwinRestrictedStartup.marker),
                  ticket.paneID == pane.paneID, ticket.generation == pane.generation,
                  ticket.backendPID == pane.backendPID, ticket.backendIdentity == pane.backendIdentity,
                  pane.paneID != run.source.paneID, pane.conversationID == nil,
                  ticket.configurationRoot == root.appendingPathComponent("twins/\(run.id)/round-\(round.number)/profile").path else { return false }
            let target = TwinRestrictedStartupTarget(runID: run.id, round: round.number, paneID: pane.paneID, generation: pane.generation,
                backendPID: pane.backendPID, backendIdentity: pane.backendIdentity, configurationRoot: ticket.configurationRoot,
                cwd: snapshot.worktreePath, executable: ticket.providerExecutable, accountID: run.source.accountID)
            let store = TerminalInputLedgerStore(root: root)
            func observe() throws -> TwinRestrictedStartupObservation? {
                guard active(), try self.requireTwin(run.id) == run else { return nil }
                let current = try self.twinLaunchTicket(runID: run.id, round: round.number)
                let state = try self.state()
                guard current.hasSameLaunch(as: ticket), current.lastInputFingerprint == fingerprint,
                      current.paneID == target.paneID, current.backendPID == target.backendPID, current.backendIdentity == target.backendIdentity,
                      current.providerExitCode == nil, current.reportedEnvelope == nil, current.lastCompletion == nil,
                      let session = state.sessions.first(where: { $0.id == target.paneID && $0.pid == target.backendPID && $0.alive && $0.remote == nil }),
                      session.cwd == target.cwd, SupervisorProcessIdentity.read(session.pid) == target.backendIdentity,
                      let launch = state.agentLaunches.first(where: { $0.id == target.generation && $0.paneID == session.id && $0.lifecycle == .active }),
                      launch.provider == .codex, launch.providerSessionID == nil, launch.cwd == target.cwd,
                      launch.configurationRoot == target.configurationRoot, launch.accountID == target.accountID,
                      let wrapper = launch.processID, let provider = launch.providerPID,
                      let wrapperBirth = SupervisorProcessIdentity.read(wrapper), let providerBirth = SupervisorProcessIdentity.read(provider),
                      Self.worktreeProcess(wrapper, descendsFrom: session.pid), Self.worktreeProcess(provider, descendsFrom: wrapper),
                      Self.restrictedStartupExecutable(provider, identity: providerBirth) == target.executable,
                      try self.twinSourceBinding(paneID: run.source.paneID) == run.source else { return nil }
                let submitted = state.followUpTurns.contains { $0.paneID == target.paneID && $0.generation == target.generation && ($0.promptID != nil || $0.armed) }
                return TwinRestrictedStartupObservation(target: target, wrapperPID: wrapper, wrapperIdentity: wrapperBirth,
                    providerPID: provider, providerIdentity: providerBirth, conversationID: launch.providerSessionID,
                    fingerprint: try store.load().ownedInvocationFingerprint(paneID: target.paneID),
                    acknowledged: current.mutationStages.contains(TwinRestrictedStartup.marker), hasSubmittedInput: submitted)
            }
            return try TwinRestrictedStartup.acknowledge(TwinRestrictedStartupActions(target: target, expectedFingerprint: fingerprint,
                active: active, observe: observe, capture: { try self.capture($0, lines: 100) }, reserve: {
                    _ = try self.updateTwinLaunchTicket(runID: run.id, round: round.number) { value in
                        guard value.hasSameLaunch(as: ticket), value.lastInputFingerprint == fingerprint,
                              !value.mutationStages.contains(TwinRestrictedStartup.marker), value.mutationStages.count < 128 else {
                            throw TerminalError.invalid("Restricted startup acknowledgement lost its one-time reservation")
                        }
                        value.mutationStages.append(TwinRestrictedStartup.marker)
                    }
                }, loadLedger: { try store.load() }, saveLedger: { try store.save($0) }, sendEnter: {
                    try self.host.write($0, Data([13]))
                }))
        }
    }
    private static func restrictedStartupExecutable(_ pid: Int32, identity: SupervisorProcessIdentity) -> String? {
        var bytes = [CChar](repeating: 0, count: 4096)
        let count = proc_pidpath(pid, &bytes, UInt32(bytes.count))
        guard count > 0, count < bytes.count, let path = String(validatingCString: bytes),
              SupervisorProcessIdentity.read(pid) == identity else { return nil }
        return path
    }
}
