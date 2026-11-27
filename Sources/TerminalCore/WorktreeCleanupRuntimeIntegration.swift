import Foundation
import Darwin

struct WorktreeExitReceipt: Codable, Equatable {
    let proof: WorktreeCompletionProof
    let inputRevision: UInt64
}

private struct WorktreeExitReceipts: SettingsPreferences {
    var entries: [WorktreeExitReceipt] = []
    init() {}
    func validate() throws {
        guard entries.count <= 256, entries.allSatisfy({ !$0.proof.completionID.isEmpty && !$0.proof.turnID.isEmpty && $0.proof.owner.backendPID > 1 }) else {
            throw TerminalError.invalid("Invalid completed worktree task receipts")
        }
    }
}

enum WorktreeRuntimeGate {
    static func inputBinding(owner: WorktreeOwner, snapshot: RuntimeState) -> TerminalInputBinding? {
        guard snapshot.sessions.contains(where: { $0.id == owner.paneID && $0.pid == owner.backendPID && $0.alive && $0.remote == nil }) else { return nil }
        let launches = snapshot.agentLaunches.filter { $0.paneID == owner.paneID }
        if owner.generation == "terminal:\(owner.backendPID)" {
            guard !launches.contains(where: { $0.lifecycle == .active }) else { return nil }
            return TerminalInputBinding(paneID: owner.paneID, backendPID: owner.backendPID, generation: owner.generation)
        }
        guard let launch = launches.first(where: { $0.id == owner.generation }),
              [.active, .exited].contains(launch.lifecycle),
              !launches.contains(where: { $0.lifecycle == .active && $0.id != owner.generation }) else { return nil }
        return TerminalInputBinding(paneID: owner.paneID, backendPID: owner.backendPID, generation: launch.id, providerPID: launch.providerPID)
    }

    static func context(owner: WorktreeOwner, snapshot: RuntimeState, backendBirth: SupervisorProcessIdentity?,
                        providerIdentity: String?, readyRevision: UInt64?, hasPendingDecisions: Bool,
                        receipt: WorktreeExitReceipt?, enabled: Bool) -> WorktreeCleanupContext {
        let pane = snapshot.sessions.first { $0.id == owner.paneID && $0.pid == owner.backendPID && $0.alive }
        let local = pane != nil && pane?.remote == nil
        let launches = snapshot.agentLaunches.filter { $0.paneID == owner.paneID }
        let launch = launches.first { $0.id == owner.generation }
        let terminal = owner.generation == "terminal:\(owner.backendPID)"
        let generationMatches = terminal ? !launches.contains { $0.lifecycle == .active }
            : launch != nil && !launches.contains { $0.lifecycle == .active && $0.id != owner.generation }
        let current = local && backendBirth == owner.processIdentity && generationMatches ? owner : nil
        let turn = snapshot.followUpTurns.first { $0.paneID == owner.paneID && $0.generation == owner.generation }
        let activeProof = launch?.lifecycle == .active && turn?.providerPID == launch?.providerPID
            && turn?.providerIdentity != nil && turn?.providerIdentity == providerIdentity
            && turn?.completedAt != nil && turn?.armed == false && turn?.blocked == false
        let exitedProof = launch?.lifecycle == .exited && receipt?.proof.owner == owner && receipt?.inputRevision == readyRevision
        let completion = activeProof ? turn?.completionID : exitedProof ? receipt?.proof.completionID : nil
        let turnID = activeProof ? turn?.promptID : exitedProof ? receipt?.proof.turnID : nil
        let monitor = snapshot.supervision.first { $0.generation == owner.generation }
        let childActive = pane?.agentTasks?.contains { ($0.generation == nil || $0.generation == owner.generation) && $0.activity.state != .done } ?? false
        let idle = current != nil && completion != nil && turnID != nil && pane?.activity.state == .done
            && (activeProof && pane?.activity.source == "hook" || exitedProof && pane?.activity.source == "process")
        return WorktreeCleanupContext(enabled: enabled, local: local, owner: current,
            completionID: completion, turnID: turnID, idle: idle, inputClear: readyRevision != nil, inputRevision: readyRevision,
            hasActiveTools: childActive || monitor?.activeTools.isEmpty == false || (monitor?.unknownToolCount ?? 0) > 0,
            hasPendingDecisions: hasPendingDecisions, hasQueuedWork: snapshot.followUpInputs.contains { $0.paneID == owner.paneID },
            quotaSwitching: monitor?.targetAccountID != nil,
            sessionCWDs: snapshot.sessions.filter { $0.alive && $0.remote == nil }.map(\.cwd)
                + snapshot.agentLaunches.filter { $0.lifecycle == .active }.map(\.cwd))
    }
}

private final class RuntimeWorktreeBackend: WorktreeCleanupBackend {
    private let inspector = WorktreeGitInspector()
    var git: WorktreeGitInspecting { inspector }
    private let runtime: TerminalRuntime
    private let active: () -> Bool
    init(runtime: TerminalRuntime, active: @escaping () -> Bool) { self.runtime = runtime; self.active = active }
    func context(owner: WorktreeOwner) throws -> WorktreeCleanupContext { try runtime.worktreeCleanupContext(owner: owner, active: active()) }
    func commitRemoval(record: WorktreeCleanupRecord, expectedContext: WorktreeCleanupContext) throws {
        let current = try context(owner: record.owner)
        guard current == expectedContext else { throw WorktreeCleanupCommitError.changed }
        do { try WorktreeCleanupPolicy.validate(record: record, context: current) }
        catch { throw WorktreeCleanupCommitError.changed }
        try inspector.remove(record.identity, committing: { mutation in
            try self.runtime.withWorktreeCleanupCommit(record: record, expectedContext: expectedContext,
                refresh: { try self.context(owner: record.owner) }, mutation: mutation)
        })
    }
}

extension TerminalRuntime {
    func withWorktreeCleanupCommit(record: WorktreeCleanupRecord, expectedContext: WorktreeCleanupContext,
                                   refresh: () throws -> WorktreeCleanupContext, mutation: () throws -> Void) throws {
        try transaction {
            let final = try refresh()
            guard final == expectedContext else { throw WorktreeCleanupCommitError.changed }
            do { try WorktreeCleanupPolicy.validate(record: record, context: final) }
            catch { throw WorktreeCleanupCommitError.changed }
            let twins = try TwinStore(root: root).load()
            guard !twins.runs.contains(where: { run in
                run.rounds.contains { round in
                    !round.cleaned && (round.snapshot?.worktreePath == record.path || root.appendingPathComponent("twins/\(run.id)/round-\(round.number)/worktree").path == record.path)
                }
            }) else { throw TerminalError.invalid("This worktree belongs to a pessimistic twin workflow") }
            try mutation()
        }
    }

    public func worktreeCleanupCoordinator(active: @escaping () -> Bool = { true }) -> WorktreeCleanupCoordinator {
        WorktreeCleanupCoordinator(store: WorktreeCleanupStore(root: root), backend: RuntimeWorktreeBackend(runtime: self, active: active))
    }

    public func worktreeCaptureOwner(paneID: String, generation: String?, originPID: Int32) throws -> WorktreeOwner? {
        let snapshot = try state()
        guard let pane = snapshot.sessions.first(where: { $0.id == paneID && $0.remote == nil && $0.alive }),
              let birth = SupervisorProcessIdentity.read(pane.pid), Self.worktreeProcess(originPID, descendsFrom: pane.pid) else { return nil }
        let launch = snapshot.agentLaunches.first { $0.paneID == paneID && $0.lifecycle == .active }
        if let launch {
            guard generation == launch.id, let providerPID = launch.providerPID,
                  Self.worktreeProcess(originPID, descendsFrom: providerPID) else { return nil }
        } else if generation?.isEmpty == false { return nil }
        return WorktreeOwner(paneID: paneID, generation: launch?.id ?? "terminal:\(pane.pid)", backendPID: pane.pid, processIdentity: birth)
    }

    func worktreeCleanupContext(owner: WorktreeOwner, active: Bool) throws -> WorktreeCleanupContext {
        let snapshot = try state()
        let launch = snapshot.agentLaunches.first { $0.id == owner.generation && $0.paneID == owner.paneID }
        let binding = WorktreeRuntimeGate.inputBinding(owner: owner, snapshot: snapshot)
        let revision = try binding.flatMap { try TerminalInputLedgerStore(root: root).load().readiness(binding: $0).lease?.revision }
        let receipts = try SecureSettingsSidecar<WorktreeExitReceipts>(root: root, filename: "worktree-task-receipts.json").load()
        let pending = try decisionInbox().contains { $0.paneID == owner.paneID && $0.status == "pending" }
        let enabled = try integrationsPreferences().automaticallyCleanWorktrees
        return WorktreeRuntimeGate.context(owner: owner, snapshot: snapshot, backendBirth: SupervisorProcessIdentity.read(owner.backendPID),
            providerIdentity: launch?.providerPID.flatMap(Self.worktreeProviderIdentity), readyRevision: revision,
            hasPendingDecisions: pending, receipt: receipts.entries.first { $0.proof.owner == owner },
            enabled: active && enabled)
    }

    func observeWorktreeCompletion(paneID: String, generation: String, originPID: Int32) throws {
        let snapshot = try state()
        guard let launch = snapshot.agentLaunches.first(where: { $0.id == generation && $0.paneID == paneID && $0.lifecycle == .active }),
              let providerPID = launch.providerPID, ProcessIdentity.isRootHook(originPID: originPID, providerPID: providerPID, provider: launch.provider),
              let owner = try worktreeCaptureOwner(paneID: paneID, generation: generation, originPID: originPID),
              let turn = snapshot.followUpTurns.first(where: { $0.paneID == paneID && $0.generation == generation }),
              let completion = turn.completionID, let prompt = turn.promptID, let completedAt = turn.completedAt,
              try WorktreeCleanupStore(root: root).load().records.contains(where: { $0.owner == owner && $0.status != .removed }) else { return }
        try worktreeCleanupCoordinator().recordCompletion(WorktreeCompletionProof(owner: owner, completionID: completion, turnID: prompt, completedAt: completedAt))
    }

    public func worktreeSuccessfulExitCandidate(paneID: String, generation: String, originPID: Int32) throws -> WorktreeCompletionProof? {
        let snapshot = try state()
        guard let launch = snapshot.agentLaunches.first(where: { $0.paneID == paneID && $0.id == generation && $0.lifecycle == .active }),
              launch.processID == originPID, let pane = snapshot.sessions.first(where: { $0.id == paneID && $0.remote == nil }),
              let birth = SupervisorProcessIdentity.read(pane.pid), Self.worktreeProcess(originPID, descendsFrom: pane.pid),
              let proof = try WorktreeCleanupStore(root: root).load().records.filter({ $0.owner.paneID == paneID && $0.owner.generation == generation })
                .compactMap(\.completion).max(by: { $0.completedAt < $1.completedAt }), proof.owner.processIdentity == birth,
              let turn = snapshot.followUpTurns.first(where: { $0.paneID == paneID && $0.generation == generation }),
              turn.completionID == proof.completionID, turn.promptID == proof.turnID else { return nil }
        return proof
    }

    public func confirmWorktreeSuccessfulExit(_ proof: WorktreeCompletionProof, originPID: Int32) throws {
        let snapshot = try state()
        guard let launch = snapshot.agentLaunches.first(where: { $0.id == proof.owner.generation && $0.paneID == proof.owner.paneID && $0.lifecycle == .exited }),
              !snapshot.agentLaunches.contains(where: { $0.paneID == launch.paneID && $0.lifecycle == .active }),
              let pane = snapshot.sessions.first(where: { $0.id == launch.paneID && $0.pid == proof.owner.backendPID && $0.remote == nil }),
              pane.activity.state == .done, pane.activity.source == "process", SupervisorProcessIdentity.read(pane.pid) == proof.owner.processIdentity,
              Self.worktreeProcess(originPID, descendsFrom: pane.pid),
              let binding = WorktreeRuntimeGate.inputBinding(owner: proof.owner, snapshot: snapshot),
              let revision = try TerminalInputLedgerStore(root: root).load().readiness(binding: binding).lease?.revision else { return }
        try SecureSettingsSidecar<WorktreeExitReceipts>(root: root, filename: "worktree-task-receipts.json").update { receipts in
            receipts.entries.removeAll { $0.proof.owner.paneID == pane.id }
            receipts.entries.append(WorktreeExitReceipt(proof: proof, inputRevision: revision))
            receipts.entries.sort { $0.proof.completedAt > $1.proof.completedAt }
            receipts.entries = Array(receipts.entries.prefix(256))
        }
    }

    public func keepWorktree(id: String, expectedUpdatedAt: Date? = nil) throws {
        try WorktreeCleanupStore(root: root).transaction { state in
            guard let record = state.records.first(where: { $0.id == id }), ![.removing, .needsReview].contains(record.status),
                  expectedUpdatedAt == nil || record.updatedAt == expectedUpdatedAt else { throw TerminalError.invalid("Worktree cleanup selection changed") }
            state.records.removeAll { $0.id == id }
        }
    }

    @discardableResult public func prepareWorktreeTracking() -> Bool {
        guard let helperExecutable else { return false }
        return (try? GitTrackingShell.install(root: root, helperExecutable: helperExecutable)) != nil
    }

    static func worktreeProcess(_ pid: Int32, descendsFrom ancestor: Int32) -> Bool {
        var current = pid, seen = Set<Int32>()
        for _ in 0..<64 {
            guard current > 1, seen.insert(current).inserted else { return false }
            var info = proc_bsdinfo()
            guard proc_pidinfo(current, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size)) == MemoryLayout<proc_bsdinfo>.size,
                  info.pbi_uid == getuid() else { return false }
            if current == ancestor { return true }
            current = Int32(info.pbi_ppid)
        }
        return false
    }

    private static func worktreeProviderIdentity(_ pid: Int32) -> String? {
        guard let birth = SupervisorProcessIdentity.read(pid) else { return nil }
        var bytes = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &bytes, UInt32(bytes.count)) > 0 else { return nil }
        return "\(birth.startedAtSeconds).\(birth.startedAtMicroseconds):" + String(cString: bytes)
    }
}

public final class WorktreeCleanupWorker {
    private let runtime: TerminalRuntime
    private let queue = DispatchQueue(label: "trano.worktree-cleanup", qos: .utility)
    private let lock = NSLock()
    private var active = true
    private var timer: DispatchSourceTimer?
    public init(runtime: TerminalRuntime) { self.runtime = runtime }
    public func start() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 2, repeating: .seconds(5), leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.isActive else { return }
            _ = try? self.runtime.worktreeCleanupCoordinator(active: { [weak self] in self?.isActive == true }).processPending()
        }
        self.timer = timer; timer.resume()
    }
    public func stop() { lock.lock(); active = false; lock.unlock(); timer?.cancel(); timer = nil }
    private var isActive: Bool { lock.lock(); defer { lock.unlock() }; return active }
    deinit { stop() }
}
