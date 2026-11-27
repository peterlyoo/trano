import Foundation

public enum WorktreeCleanupCommitError: Error, LocalizedError {
    case changed
    public var errorDescription: String? { "Task or input state changed before cleanup; the worktree was kept" }
}

public enum WorktreeCleanupPolicy {
    public static func validate(record: WorktreeCleanupRecord, context: WorktreeCleanupContext) throws {
        guard context.enabled else { throw TerminalError.invalid("Automatic worktree cleanup is disabled.") }
        guard context.local, context.owner == record.owner else { throw TerminalError.invalid("The original local session identity changed.") }
        guard let proof = record.completion, proof.owner == record.owner,
              context.completionID == proof.completionID, context.turnID == proof.turnID else {
            throw TerminalError.invalid("The completed task changed or has new work.")
        }
        guard context.idle, context.inputClear, context.inputRevision != nil,
              !context.hasActiveTools, !context.hasPendingDecisions, !context.hasQueuedWork, !context.quotaSwitching else {
            throw TerminalError.invalid("The session has activity, input, questions, queued work, or an account switch.")
        }
        let target = URL(fileURLWithPath: record.path).standardizedFileURL.path
        guard target != "/", !context.sessionCWDs.contains(where: { value in
            let path = URL(fileURLWithPath: value).standardizedFileURL.path
            return path == target || path.hasPrefix(target + "/")
        }) else { throw TerminalError.invalid("Another session is using this worktree directory.") }
    }
}

public final class WorktreeCleanupCoordinator {
    private let store: WorktreeCleanupStore
    private let backend: WorktreeCleanupBackend
    public init(store: WorktreeCleanupStore, backend: WorktreeCleanupBackend) { self.store = store; self.backend = backend }

    public func beginCapture(owner: WorktreeOwner, cwd: String, gitArguments: [String], now: Date = Date()) throws -> WorktreeCapture? {
        let context = try backend.context(owner: owner)
        guard context.enabled, context.local, context.owner == owner,
              let invocation = try backend.git.creationInvocation(cwd: cwd, gitArguments: gitArguments) else { return nil }
        let before = try backend.git.snapshot(cwd: invocation.cwd, gitArguments: invocation.gitArguments)
        guard before.worktrees.count <= 512 else { throw TerminalError.invalid("The repository worktree list exceeds its capture bound.") }
        // The shim starts Git only after begin returns; a baseline captured before another finish still fails the exact delta check.
        return try store.transaction { state in
            state.captures.removeAll { now.timeIntervalSince($0.startedAt) > 1800 }
            pruneHistory(&state)
            guard state.captures.count < 32, state.records.filter({ $0.status != .removed }).count < 128,
                  !state.records.contains(where: { $0.status == .removing &&
                      $0.identity.commonDirectory == before.commonDirectory && $0.identity.commonIdentity == before.commonIdentity }) else { return nil }
            let conflicts = state.captures.indices.filter { index in
                guard let other = state.captures[index].before else { return true }
                return other.commonDirectory == before.commonDirectory && other.commonIdentity == before.commonIdentity
            }
            for index in conflicts { state.captures[index].ambiguous = true }
            let value = WorktreeCapture(id: UUID().uuidString.lowercased(), nonce: UUID().uuidString.lowercased(),
                owner: owner, startedAt: now, invocation: invocation, before: before, ambiguous: !conflicts.isEmpty)
            state.captures.append(value)
            return value
        }
    }

    public func finishCapture(id: String, nonce: String, exitStatus: Int32, now: Date = Date()) throws {
        guard let capture = try store.load().captures.first(where: { $0.id == id && $0.nonce == nonce }) else {
            throw TerminalError.invalid("Worktree creation capture is unavailable or its token changed.")
        }
        guard exitStatus == 0 else {
            try store.transaction { $0.captures.removeAll { $0.id == id && $0.nonce == nonce } }
            return
        }
        let context = try backend.context(owner: capture.owner)
        guard context.enabled, context.local, context.owner == capture.owner, let before = capture.before,
              now.timeIntervalSince(capture.startedAt) >= 0, now.timeIntervalSince(capture.startedAt) <= 1800 else {
            try store.transaction { $0.captures.removeAll { $0.id == id && $0.nonce == nonce } }
            return
        }
        let after = try backend.git.snapshot(cwd: capture.invocation.cwd, gitArguments: capture.invocation.gitArguments)
        try store.transaction { state in
            guard let index = state.captures.firstIndex(where: { $0.id == id && $0.nonce == nonce }) else {
                throw TerminalError.invalid("Worktree creation capture changed.")
            }
            let latest = state.captures.remove(at: index)
            guard after.commonDirectory == before.commonDirectory, after.commonIdentity == before.commonIdentity,
                  after.worktrees.count <= 512,
                  Set(before.worktrees.map(\.path)).count == before.worktrees.count,
                  Set(after.worktrees.map(\.path)).count == after.worktrees.count,
                  !before.worktrees.contains(where: { $0.path == capture.invocation.targetPath }) else { return }
            let created = after.worktrees.filter { entry in !before.worktrees.contains(where: { $0.path == entry.path }) }
            guard created.count == 1, let entry = created.first, entry.path == capture.invocation.targetPath,
                  !entry.isMain, !entry.isBare, !entry.prunable, let identity = entry.identity,
                  identity.path == entry.path, identity.commonDirectory == after.commonDirectory,
                  identity.commonIdentity == after.commonIdentity,
                  !state.records.contains(where: { $0.identity == identity && $0.status != .removed }) else { return }
            let stable = before.worktrees.allSatisfy { old in after.worktrees.first(where: { $0.path == old.path }) == old }
            let ambiguous = latest.ambiguous || !stable
            let record = WorktreeCleanupRecord(id: id, owner: capture.owner, identity: identity, createdAt: now,
                status: ambiguous ? .needsReview : .tracked,
                message: ambiguous ? "Concurrent repository changes prevented creation ownership verification." : nil)
            pruneHistory(&state)
            guard state.records.count < 256 else { return }
            state.records.append(record)
        }
    }

    public func recordCompletion(_ proof: WorktreeCompletionProof) throws {
        let context = try backend.context(owner: proof.owner)
        guard context.enabled, context.local, context.owner == proof.owner,
              context.completionID == proof.completionID, context.turnID == proof.turnID,
              !proof.completionID.isEmpty, !proof.turnID.isEmpty else {
            throw TerminalError.invalid("Worktree cleanup requires the original trusted root completion.")
        }
        try store.transaction { state in
            for index in state.records.indices where state.records[index].owner == proof.owner &&
                [.tracked, .pending, .held].contains(state.records[index].status) && state.records[index].createdAt <= proof.completedAt {
                state.records[index].completion = proof
                state.records[index].eligibleAt = proof.completedAt.addingTimeInterval(30)
                state.records[index].status = .pending; state.records[index].message = nil
                state.records[index].updatedAt = proof.completedAt
            }
        }
    }

    public func processPending(now: Date = Date()) throws -> [WorktreeCleanupRecord] {
        try store.withCleanupLease {
            var changed: [WorktreeCleanupRecord] = []
            let pending = try self.store.transaction { state -> [WorktreeCleanupRecord] in
                for index in state.records.indices where state.records[index].status == .removing {
                    state.records[index].status = .needsReview
                    state.records[index].message = "Cleanup was interrupted. Review the worktree before another attempt."
                    state.records[index].updatedAt = now
                    changed.append(state.records[index])
                }
                return Array(state.records.filter { record in
                    record.status == .pending && record.eligibleAt.map({ $0 <= now }) == true &&
                        !state.captures.contains(where: { self.conflicts($0, with: record.identity) })
                }.prefix(2))
            }
            for record in pending {
                var claimed = false
                do {
                    let context = try self.backend.context(owner: record.owner)
                    try WorktreeCleanupPolicy.validate(record: record, context: context)
                    try self.validateGit(record)
                    let fresh = try self.backend.context(owner: record.owner)
                    guard fresh == context else { throw TerminalError.invalid("Session input or task state changed during inspection.") }
                    try WorktreeCleanupPolicy.validate(record: record, context: fresh)
                    let removing = try self.store.transaction { state -> WorktreeCleanupRecord in
                        guard !state.captures.contains(where: { self.conflicts($0, with: record.identity) }),
                              let index = state.records.firstIndex(where: { $0 == record }) else {
                            throw TerminalError.invalid("Worktree cleanup ownership changed before removal.")
                        }
                        state.records[index].status = .removing; state.records[index].updatedAt = now
                        return state.records[index]
                    }
                    claimed = true
                    try self.backend.commitRemoval(record: removing, expectedContext: fresh)
                    if let value = try self.mark(record.id, expected: .removing, status: .removed,
                        message: "Removed clean session worktree; branch references were preserved.", now: now) { changed.append(value) }
                } catch {
                    let status: WorktreeCleanupStatus = claimed && !(error is WorktreeCleanupCommitError) ? .needsReview : .held
                    let message = claimed && status == .needsReview ? "Removal outcome requires review: " + error.localizedDescription : error.localizedDescription
                    if let value = try self.mark(record.id, expected: claimed ? .removing : .pending,
                        status: status, message: String(message.prefix(512)), now: now) { changed.append(value) }
                }
            }
            return changed
        } ?? []
    }

    public func status() throws -> [WorktreeCleanupRecord] { try store.load().records }

    public func retry(id: String, now: Date = Date()) throws {
        guard let record = try store.load().records.first(where: { $0.id == id }), [.held, .error].contains(record.status),
              record.completion != nil else { throw TerminalError.invalid("This worktree needs ownership review before retrying cleanup.") }
        try WorktreeCleanupPolicy.validate(record: record, context: backend.context(owner: record.owner))
        try store.transaction { state in
            guard let index = state.records.firstIndex(where: { $0 == record }) else { throw TerminalError.invalid("Worktree cleanup selection changed.") }
            state.records[index].status = .pending; state.records[index].message = nil; state.records[index].updatedAt = now
        }
    }

    private func conflicts(_ capture: WorktreeCapture, with identity: WorktreeIdentity) -> Bool {
        guard let before = capture.before else { return true }
        return before.commonDirectory == identity.commonDirectory && before.commonIdentity == identity.commonIdentity
    }

    private func validateGit(_ record: WorktreeCleanupRecord) throws {
        let inspection = try backend.git.inspect(record.identity)
        guard inspection.entry.identity == record.identity, inspection.entry.path == record.path,
              !inspection.entry.isMain, !inspection.entry.isBare, !inspection.entry.locked, !inspection.entry.prunable,
              inspection.clean, !inspection.hasIgnored, !inspection.operationInProgress, inspection.retainedHEAD else {
            throw TerminalError.invalid("Worktree changes, ignored files, locks, repository operations, identity, or commit retention prevent cleanup.")
        }
        guard try backend.git.processUse(path: record.path) == .unused else {
            throw TerminalError.invalid("A local process may still be using this worktree directory.")
        }
    }

    private func mark(_ id: String, expected: WorktreeCleanupStatus, status: WorktreeCleanupStatus,
                      message: String, now: Date) throws -> WorktreeCleanupRecord? {
        try store.transaction { state in
            guard let index = state.records.firstIndex(where: { $0.id == id && $0.status == expected }) else { return nil }
            state.records[index].status = status; state.records[index].message = message; state.records[index].updatedAt = now
            return state.records[index]
        }
    }

    private func pruneHistory(_ state: inout WorktreeCleanupState) {
        let removed = state.records.filter { $0.status == .removed }.sorted { $0.updatedAt > $1.updatedAt }
        let retained = Set(removed.prefix(128).map(\.id))
        state.records.removeAll { $0.status == .removed && !retained.contains($0.id) }
    }
}
