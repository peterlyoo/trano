import Foundation
import Darwin

struct SupervisorContinuationProcess {
    let identity: SupervisorProcessIdentity
    let parentPID: Int32
    let executable: String
    var hookIdentity: String { "\(identity.startedAtSeconds).\(identity.startedAtMicroseconds):" + executable }

    static func read(_ pid: Int32) -> SupervisorContinuationProcess? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != 5 else { return nil }
        let identity = SupervisorProcessIdentity(pid: pid, ownerUID: info.pbi_uid,
            startedAtSeconds: info.pbi_start_tvsec, startedAtMicroseconds: info.pbi_start_tvusec)
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0, let end = bytes.firstIndex(of: 0),
              SupervisorProcessIdentity.read(pid) == identity else { return nil }
        let path = String(decoding: bytes.prefix(end).map { UInt8(bitPattern: $0) }, as: UTF8.self)
        guard path.hasPrefix("/") else { return nil }
        return SupervisorContinuationProcess(identity: identity, parentPID: Int32(bitPattern: info.pbi_ppid), executable: path)
    }
}

enum SupervisorContinuationRuntimeProjection {
    static func make(snapshot: RuntimeState, sessions: [TerminalSession], binding: SupervisorBinding?,
                     ledger: TerminalInputLedger, pendingDecisionPaneIDs: Set<String>, limitedAccountIDs: Set<String>,
                     bootID: String, now: Date, process: (Int32) -> SupervisorContinuationProcess?,
                     originExited: (Int32) -> Bool) -> SupervisorContinuationContext {
        guard sessions.count <= 4096, snapshot.agentLaunches.count <= 8192 else {
            return SupervisorContinuationContext(authority: nil, candidates: [])
        }
        let panes = Dictionary(grouping: sessions, by: \.id).compactMapValues { $0.count == 1 ? $0.first : nil }
        let launches = Dictionary(grouping: snapshot.agentLaunches.filter { $0.lifecycle == .active }, by: \.paneID)
            .compactMapValues { $0.count == 1 ? $0.first : nil }
        let turns = Dictionary(grouping: snapshot.followUpTurns, by: { $0.paneID + ":" + $0.generation })
        let monitors = Dictionary(grouping: snapshot.supervision, by: \.generation)
        let queued = Set(snapshot.followUpInputs.map(\.paneID))
        var records: [Int32: SupervisorContinuationProcess] = [:]
        var missing: Set<Int32> = []
        var reads = 0
        func read(_ pid: Int32) -> SupervisorContinuationProcess? {
            if let cached = records[pid] { return cached }
            guard !missing.contains(pid), reads < 16_384 else { return nil }
            reads += 1
            guard let record = process(pid), record.identity.pid == pid,
                  record.identity.ownerUID == getuid(), record.identity.startedAtSeconds > 0,
                  record.identity.startedAtMicroseconds < 1_000_000,
                  record.executable.hasPrefix("/"), record.executable.utf8.count <= 4096,
                  !record.executable.contains("\0") else { missing.insert(pid); return nil }
            records[pid] = record
            return record
        }
        func descends(_ pid: Int32, from ancestor: Int32) -> Bool {
            var current = pid
            var seen: Set<Int32> = []
            for _ in 0..<32 {
                if current == ancestor { return true }
                guard seen.insert(current).inserted, let child = read(current), let parent = read(child.parentPID),
                      (parent.identity.startedAtSeconds, parent.identity.startedAtMicroseconds) <=
                        (child.identity.startedAtSeconds, child.identity.startedAtMicroseconds) else { return false }
                current = child.parentPID
            }
            return false
        }
        func identity(_ paneID: String) -> SupervisorContinuationIdentity? {
            guard let pane = panes[paneID], pane.alive, pane.remote == nil, let launch = launches[paneID],
                  launch.bootID == bootID, let supervisorPID = launch.processID, supervisorPID > 1,
                  let providerPID = launch.providerPID, providerPID != pane.pid,
                  let providerSessionID = launch.providerSessionID,
                  let backend = read(pane.pid), let provider = read(providerPID), read(supervisorPID) != nil,
                  descends(providerPID, from: pane.pid), descends(providerPID, from: supervisorPID) else { return nil }
            let value = SupervisorContinuationIdentity(paneID: paneID, backendPID: pane.pid, backendIdentity: backend.identity,
                generation: launch.id, provider: launch.provider, providerPID: providerPID, providerIdentity: provider.identity,
                providerSessionID: providerSessionID, configurationRoot: launch.configurationRoot, cwd: launch.cwd,
                accountID: launch.accountID, providerExecutable: provider.executable)
            return value.isValid ? value : nil
        }
        let authority: SupervisorContinuationAuthority?
        if let binding, let ownPane = panes[binding.paneID],
           !pendingDecisionPaneIDs.contains(binding.paneID),
           ![ActivityState.blocked, .error].contains(ownPane.activity.state), let own = identity(binding.paneID) {
            let value = SupervisorContinuationAuthority(binding: binding, launch: own)
            authority = value.isValid ? value : nil
        } else { authority = nil }
        let candidates = sessions.compactMap { pane -> SupervisorContinuationCandidate? in
            guard pane.id != binding?.paneID, let target = identity(pane.id), let launch = launches[pane.id] else { return nil }
            let turnRows = turns[pane.id + ":" + launch.id] ?? []
            let turn = turnRows.count == 1 ? turnRows.first : nil
            let monitorRows = monitors[launch.id] ?? []
            let monitor = monitorRows.count == 1 ? monitorRows.first : nil
            let input = TerminalInputBinding(paneID: pane.id, backendPID: pane.pid, generation: launch.id, providerPID: target.providerPID)
            return SupervisorContinuationCandidate(target: target, readiness: ledger.readiness(binding: input),
                activity: pane.activity.state, activitySource: pane.activity.source, alive: pane.alive, local: pane.remote == nil,
                completionID: turn?.completionID, consumedCompletionID: turn?.consumedCompletionID, completedAt: turn?.completedAt,
                completionOriginExited: turn?.completionOriginPID.map { $0 > 1 && originExited($0) } ?? false,
                completionProviderVerified: turn?.providerPID == target.providerPID && turn?.providerIdentity == read(target.providerPID)?.hookIdentity,
                pendingDecision: pendingDecisionPaneIDs.contains(pane.id), queuedInput: queued.contains(pane.id),
                quotaHandoff: monitor?.targetAccountID != nil, quotaLimited: launch.accountID.map(limitedAccountIDs.contains) ?? false,
                safeTurnBoundary: monitor?.safeToSwitch == true)
        }
        return SupervisorContinuationContext(authority: authority, candidates: candidates)
    }
}

extension TerminalRuntime {
    func reserveSupervisorContinuation(_ offer: SupervisorContinuationOffer, write: () throws -> Void) throws {
        try transaction {
            try update { state in
                let indices = state.followUpTurns.indices.filter {
                    state.followUpTurns[$0].paneID == offer.target.paneID && state.followUpTurns[$0].generation == offer.target.generation
                }
                guard indices.count == 1, let index = indices.first,
                      state.followUpTurns[index].completionID == offer.completionID,
                      state.followUpTurns[index].consumedCompletionID != offer.completionID else {
                    throw TerminalError.invalid("The completed turn was already used or changed")
                }
                state.followUpTurns[index].consumedCompletionID = offer.completionID
            }
            try write()
        }
    }

    func makeSupervisorContinuationContext(snapshot: RuntimeState, sessions: [TerminalSession], binding: SupervisorBinding?,
                                           pendingDecisionPaneIDs: Set<String>, limitedAccountIDs: Set<String>, now: Date) throws -> SupervisorContinuationContext {
        SupervisorContinuationRuntimeProjection.make(snapshot: snapshot, sessions: sessions, binding: binding,
            ledger: try TerminalInputLedgerStore(root: root).load(), pendingDecisionPaneIDs: pendingDecisionPaneIDs,
            limitedAccountIDs: limitedAccountIDs, bootID: try Self.bootIdentity(), now: now,
            process: SupervisorContinuationProcess.read, originExited: { pid in kill(pid, 0) != 0 && errno == ESRCH })
    }

    public func supervisorContinuationCoordinator() -> SupervisorContinuationCoordinator<SupervisorRuntimeBackend> {
        SupervisorContinuationCoordinator(backend: SupervisorRuntimeBackend(runtime: self))
    }
}
