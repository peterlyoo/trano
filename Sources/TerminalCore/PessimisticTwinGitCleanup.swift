import Foundation

struct TwinGitArtifactCleanup {
    let snapshot: TwinGitSnapshot
    let expectedTip: String
    let root: URL
    let files: TwinGitFileSystem
    let inspector: WorktreeGitInspecting
    let command: ([String]) throws -> Data
    let review: () throws -> TwinGitReview
    let revalidate: () throws -> Void
    let deleteBranch: () throws -> Void
    func cleanup(committing: (_ mutation: () throws -> Void) throws -> Void,
                 recordMutation: @escaping (TwinGitMutationStage) throws -> Void) throws {
        let reviewed = try review()
        guard reviewed.clean, reviewed.tip == expectedTip, try inspector.processUse(path: snapshot.worktreePath) == .unused else {
            throw TwinGitError.unsafe("Twin worktree is dirty, active or uncertain; its artifacts were retained")
        }
        let ignored = try command(Self.ignoredArguments)
        let protected = try TwinGitService.parsePaths(command(Self.protectedArguments))
        let quarantine = (files as? TwinArtifactFileSystem).map { TwinArtifactQuarantine(root: root, files: $0) }
        guard ignored.isEmpty || quarantine != nil else { throw TwinGitError.unsafe("Ignored artifacts require safe native quarantine support") }
        let plan = try quarantine?.prepare(snapshot: snapshot, tip: expectedTip, ignored: ignored, protectedPaths: protected)
        let inspection = try inspector.inspect(snapshot.ownership)
        guard inspection.entry.branch == snapshot.twinBranch, !inspection.operationInProgress,
              !inspection.hasIgnored || plan != nil else { throw TwinGitError.unsafe("Ignored artifact inventory or worktree ownership is uncertain") }
        if let plan, let quarantine {
            try committing {
                try revalidate()
                guard try inspector.processUse(path: snapshot.worktreePath) == .unused,
                      try command(Self.ignoredArguments) == ignored,
                      try TwinGitService.parsePaths(command(Self.protectedArguments)) == protected,
                      try WorktreeGitParser.status(command(Self.statusArguments)).clean else {
                    throw TwinGitError.unsafe("Twin artifacts, tracked state or process use changed during cleanup preflight")
                }
                let destination = try quarantine.perform(plan, recordMutation: recordMutation)
                try revalidate()
                guard try command(Self.ignoredArguments).isEmpty,
                      try inspector.processUse(path: snapshot.worktreePath) == .unused,
                      try inspector.processUse(path: destination) == .unused else {
                    throw TwinGitError.unsafe("An artifact writer or new ignored data remains; retained quarantine needs review")
                }
                if let native = inspector as? WorktreeGitInspector {
                    try native.remove(snapshot.ownership, committing: { mutation in
                        try self.revalidate(); try self.finish(mutation, recordMutation: recordMutation)
                    })
                } else { try finish({ try inspector.remove(snapshot.ownership) }, recordMutation: recordMutation) }
            }
        } else if let native = inspector as? WorktreeGitInspector {
            try native.remove(snapshot.ownership, committing: { mutation in
                try withoutActuallyEscaping(mutation) { bounded in
                    try committing { try self.revalidate(); try self.finish(bounded, recordMutation: recordMutation) }
                }
            })
        } else {
            try committing { try revalidate(); try finish({ try inspector.remove(snapshot.ownership) }, recordMutation: recordMutation) }
        }
    }
    private func finish(_ remove: () throws -> Void, recordMutation: (TwinGitMutationStage) throws -> Void) throws {
        try recordMutation(.worktreeWillRemove)
        try remove()
        try recordMutation(.worktreeRemoved)
        try recordMutation(.branchWillDelete)
        try deleteBranch()
        try recordMutation(.branchDeleted)
    }
    private static let ignoredArguments = ["ls-files", "--others", "--ignored", "--exclude-standard", "--directory", "-z", "--"]
    private static let protectedArguments = ["ls-files", "--cached", "--others", "--exclude-standard", "-z", "--"]
    private static let statusArguments = ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"]
}
