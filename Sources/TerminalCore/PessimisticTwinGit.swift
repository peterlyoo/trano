import Foundation
import CryptoKit
import Darwin

public enum TwinGitError: Error, LocalizedError {
    case unsafe(String)
    public var errorDescription: String? { switch self { case .unsafe(let reason): return reason } }
}
public struct TwinGitReview: Equatable {
    public let tip: String
    public let changedFiles: [String]
    public let clean: Bool
    public init(tip: String, changedFiles: [String], clean: Bool) { self.tip = tip; self.changedFiles = changedFiles; self.clean = clean }
}
public enum TwinGitMergeResult: Equatable {
    case merged(commit: String), conflict(paths: [String], message: String), held(String), needsReview(String)
}
public enum TwinGitMutationStage: String, Codable {
    case sourceCheckpointWillAdvance, sourceCheckpointAdvanced, sourceIndexWritten, mergeWillStart, mergeCompleted
    case artifactsQuarantineWillStart, artifactsQuarantined
    case twinCommitWillAdvance, twinCommitAdvanced, twinIndexWritten, worktreeWillRemove, worktreeRemoved, branchWillDelete, branchDeleted
}

public final class TwinGitService {
    private let root: URL
    private let runner: TwinGitCommandRunning
    private let fileSystem: TwinGitFileSystem
    private let inspector: WorktreeGitInspecting
    private let userID: UInt32
    private let maximumOutput = 8_388_608
    private let maximumFiles = 10_000
    private let maximumSnapshotBytes = 134_217_728
    public convenience init(root: URL) {
        self.init(root: root, runner: TwinNativeGitRunner(), fileSystem: TwinNativeGitFileSystem(), inspector: WorktreeGitInspector())
    }
    public init(root: URL, runner: TwinGitCommandRunning, fileSystem: TwinGitFileSystem, inspector: WorktreeGitInspecting, userID: UInt32 = getuid()) {
        self.root = root; self.runner = runner; self.fileSystem = fileSystem; self.inspector = inspector; self.userID = userID
    }

    public func snapshot(source: TwinSourceBinding, runID: String, round: Int) throws -> TwinGitSnapshot {
        let branch = try Self.checkedBranch(runID: runID, round: round)
        let before = try descriptor(source.cwd)
        guard root.path != before.root, !root.path.hasPrefix(before.root + "/") else { throw TwinGitError.unsafe("Twin runtime data cannot be inside the source worktree") }
        let location = try makeLocation(runID: runID, round: round)
        guard try fileSystem.info(location + "/worktree") == nil else { throw TwinGitError.unsafe("Twin worktree path already exists; review the interrupted operation") }
        guard before.branch != branch, !before.branch.hasPrefix("refs/heads/trano/twins/") else { throw TwinGitError.unsafe("A twin cannot be created from another twin branch") }
        try requireMissingRef(branch, cwd: before.root, gitDirectory: before.common)
        let tree = try workingTree(cwd: before.root, gitDirectory: before.gitDirectory, location: location)
        try unchanged(before, cwd: source.cwd, tree: tree, location: location)
        let snapshot = try oid(command(cwd: before.root, gitDirectory: before.gitDirectory,
            arguments: ["commit-tree", tree, "-p", before.head], input: Data("Trano pessimistic twin snapshot\n".utf8)))
        let plan: [String: String] = ["runID": runID, "round": String(round), "sourceHEAD": before.head, "sourceIndexSHA256": before.indexDigest,
            "sourceTree": tree, "snapshotCommit": snapshot, "twinBranch": branch, "worktreePath": location + "/worktree"]
        let indexBackup = try fileSystem.read(before.gitDirectory + "/index", limit: maximumOutput)
        guard Self.digest(indexBackup) == before.indexDigest else { throw TwinGitError.unsafe("Source index changed before its recovery receipt") }
        try fileSystem.writePrivate(indexBackup, path: location + "/source-index.backup")
        var encoded = try JSONEncoder().encode(plan); encoded.append(10)
        try fileSystem.writePrivate(encoded, path: location + "/snapshot-plan.json")
        try unchanged(before, cwd: source.cwd, tree: tree, location: location)
        _ = try mutationPaths(cwd: before.root, gitDirectory: before.gitDirectory, common: before.common)
        _ = try command(cwd: before.root, gitDirectory: before.gitDirectory,
            arguments: ["worktree", "add", "--no-guess-remote", "-b", String(branch.dropFirst("refs/heads/".count)), "--", location + "/worktree", snapshot])
        let repository = try inspector.snapshot(cwd: before.root, gitArguments: ["worktree", "add", "--", location + "/worktree"])
        guard let entry = repository.worktrees.first(where: { $0.path == location + "/worktree" }),
              entry.branch == branch, entry.head == snapshot, !entry.locked, !entry.prunable,
              let identity = entry.identity, identity.commonDirectory == before.common, identity.commonIdentity == before.commonIdentity else {
            throw TwinGitError.unsafe("Created worktree ownership could not be verified; retain it for review")
        }
        try unchanged(before, cwd: source.cwd, tree: tree, location: location)
        guard try workingTree(cwd: identity.path, gitDirectory: identity.adminDirectory, location: location) == tree else {
            throw TwinGitError.unsafe("Checkout changed snapshot bytes; retain the twin worktree for review")
        }
        let receipt = TwinGitSnapshot(runID: runID, round: round, repositoryRoot: before.root, sourceCWD: before.cwd,
            sourceGitDirectory: before.gitDirectory, commonDirectory: before.common, sourceBranch: before.branch,
            sourceHEAD: before.head, sourceIndexSHA256: before.indexDigest, sourceTree: tree, snapshotCommit: snapshot,
            twinBranch: branch, worktreePath: identity.path, ownership: identity)
        var receiptData = try JSONEncoder().encode(receipt); receiptData.append(10)
        try fileSystem.writePrivate(receiptData, path: location + "/snapshot-receipt.json")
        return receipt
    }

    public func snapshotDiff(snapshot: TwinGitSnapshot) throws -> String {
        try validateSnapshot(snapshot)
        let output = try command(cwd: snapshot.repositoryRoot, gitDirectory: snapshot.commonDirectory,
            arguments: ["diff", "--no-ext-diff", "--no-textconv", "--binary", "--no-renames", snapshot.sourceHEAD, snapshot.snapshotCommit, "--"], limit: 524_288)
        guard let result = String(data: output, encoding: .utf8) else { throw TwinGitError.unsafe("Snapshot diff is not valid UTF-8") }
        return result
    }

    public func review(snapshot: TwinGitSnapshot) throws -> TwinGitReview {
        try validateSnapshot(snapshot)
        let inspection = try inspector.inspect(snapshot.ownership)
        guard inspection.entry.branch == snapshot.twinBranch, !inspection.operationInProgress else { throw TwinGitError.unsafe("Twin branch or repository operation changed") }
        let tip = try ownTip(snapshot)
        try requireAncestor(snapshot.snapshotCommit, tip, snapshot: snapshot)
        let location = try existingLocation(snapshot)
        let tree = try workingTree(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory, location: location)
        let committed = try oid(command(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory,
            arguments: ["rev-parse", "--verify", tip + "^{tree}"]))
        let files = try Self.parsePaths(command(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory,
            arguments: ["diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--name-only", "-z", snapshot.snapshotCommit, tip, "--"]))
        guard try ownTip(snapshot) == tip else { throw TwinGitError.unsafe("Twin branch changed during report validation") }
        let status = try WorktreeGitParser.status(command(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory,
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignore-submodules=none"], limit: 1_048_576))
        return .init(tip: tip, changedFiles: files, clean: status.clean && tree == committed)
    }

    public func commit(snapshot: TwinGitSnapshot, message: String,
                       recordMutation: @escaping (TwinGitMutationStage) throws -> Void = { _ in }) throws -> TwinGitReview {
        guard !message.isEmpty, message.utf8.count <= 4096, !message.utf8.contains(0) else { throw TwinGitError.unsafe("Invalid twin commit message") }
        try validateSnapshot(snapshot)
        let inspection = try inspector.inspect(snapshot.ownership)
        guard inspection.entry.branch == snapshot.twinBranch, !inspection.operationInProgress else { throw TwinGitError.unsafe("Twin ownership or repository operation changed") }
        let before = try descriptor(snapshot.worktreePath)
        guard before.branch == snapshot.twinBranch, before.gitDirectory == snapshot.ownership.adminDirectory else { throw TwinGitError.unsafe("Twin Git metadata changed") }
        try requireAncestor(snapshot.snapshotCommit, before.head, snapshot: snapshot)
        let location = try existingLocation(snapshot)
        let tree = try workingTree(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory, location: location)
        try unchanged(before, cwd: snapshot.worktreePath, tree: tree, location: location)
        let committedTree = try oid(command(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory,
            arguments: ["rev-parse", "--verify", before.head + "^{tree}"]))
        if tree != committedTree {
            let newCommit = try oid(command(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory,
                arguments: ["commit-tree", tree, "-p", before.head], input: Data((message + "\n").utf8)))
            try unchanged(before, cwd: snapshot.worktreePath, tree: tree, location: location)
            try recordMutation(.twinCommitWillAdvance)
            _ = try mutationPaths(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory, common: snapshot.commonDirectory)
            guard try finalMetadataMatches(before) else { throw TwinGitError.unsafe("Twin HEAD or index changed before its trusted commit") }
            _ = try command(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory,
                arguments: ["update-ref", snapshot.twinBranch, newCommit, before.head])
            try recordMutation(.twinCommitAdvanced)
            _ = try command(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory, arguments: ["read-tree", newCommit])
            try recordMutation(.twinIndexWritten)
        }
        let result = try review(snapshot: snapshot)
        guard result.clean else { throw TwinGitError.unsafe("Twin files changed during commit; review and commit again") }
        return result
    }

    public func merge(snapshot: TwinGitSnapshot, tip: String,
                      committing: (_ mutation: () throws -> TwinGitMergeResult) throws -> TwinGitMergeResult,
                      recordMutation: @escaping (TwinGitMutationStage) throws -> Void = { _ in }) throws -> TwinGitMergeResult {
        var mutationStarted = false
        do {
            try validateSnapshot(snapshot)
            let review = try self.review(snapshot: snapshot)
            guard review.clean, review.tip == tip else { return .held("Twin changes are uncommitted or its reviewed tip changed") }
            let before = try descriptor(snapshot.sourceCWD)
            guard before.root == snapshot.repositoryRoot, before.gitDirectory == snapshot.sourceGitDirectory,
                  before.common == snapshot.commonDirectory, before.commonIdentity == snapshot.ownership.commonIdentity,
                  before.branch == snapshot.sourceBranch, before.head == snapshot.sourceHEAD, before.indexDigest == snapshot.sourceIndexSHA256 else {
                return .held("Original branch, HEAD or index diverged from the approved snapshot")
            }
            let location = try existingLocation(snapshot)
            var inventory: TwinGitMergeInventory?
            guard try workingTree(cwd: before.root, gitDirectory: before.gitDirectory, location: location, capture: { inventory = $0 }) == snapshot.sourceTree,
                  let sourceInventory = inventory else {
                return .held("Original working files changed; review the new source state before merging")
            }
            try unchanged(before, cwd: snapshot.sourceCWD, tree: snapshot.sourceTree, location: location)
            return try committing {
                try recordMutation(.sourceCheckpointWillAdvance)
                let paths = try self.mutationPaths(cwd: before.root, gitDirectory: before.gitDirectory, common: before.common)
                guard try self.finalMetadataMatches(before), try self.ownTip(snapshot) == tip,
                      try sourceInventory.matches(paths: paths, files: self.fileSystem) else {
                    return .held("Original files, paths, parent identity or Git metadata changed before merge")
                }
                mutationStarted = true
                _ = try self.command(cwd: before.root, gitDirectory: before.gitDirectory,
                    arguments: ["update-ref", before.branch, snapshot.snapshotCommit, before.head])
                try recordMutation(.sourceCheckpointAdvanced)
                _ = try self.command(cwd: before.root, gitDirectory: before.gitDirectory, arguments: ["read-tree", snapshot.snapshotCommit])
                try recordMutation(.sourceIndexWritten)
                try recordMutation(.mergeWillStart)
                let result = try self.commandResult(cwd: before.root, gitDirectory: before.gitDirectory,
                    arguments: ["merge", "--no-ff", "--no-edit", tip])
                if result.status == 0 {
                    let merged = try self.oid(self.command(cwd: before.root, gitDirectory: before.gitDirectory, arguments: ["rev-parse", "--verify", "HEAD^{commit}"]))
                    try recordMutation(.mergeCompleted)
                    return .merged(commit: merged)
                }
                let conflicts = try Self.conflictedPaths(self.command(cwd: before.root, gitDirectory: before.gitDirectory, arguments: ["ls-files", "--unmerged", "-z"]))
                if !conflicts.isEmpty { return .conflict(paths: conflicts, message: "Merge conflicts are preserved in the original worktree for human resolution") }
                return .needsReview("Git did not finish the approved merge; inspect the checkpoint and merge state before continuing")
            }
        } catch {
            return mutationStarted ? .needsReview("Approved merge outcome requires review: " + error.localizedDescription) : .held(error.localizedDescription)
        }
    }

    public func cleanup(snapshot: TwinGitSnapshot, expectedTip: String,
                        committing: (_ mutation: () throws -> Void) throws -> Void = { try $0() },
                        recordMutation: @escaping (TwinGitMutationStage) throws -> Void = { _ in }) throws {
        try validateSnapshot(snapshot)
        guard Self.validOID(expectedTip) else { throw TwinGitError.unsafe("Invalid reviewed twin commit") }
        let exists = try fileSystem.info(snapshot.worktreePath) != nil
        let ref = try reference(snapshot.twinBranch, cwd: snapshot.repositoryRoot, gitDirectory: snapshot.commonDirectory)
        if !exists && ref == nil {
            guard try fileSystem.info(snapshot.ownership.adminDirectory) == nil else { throw TwinGitError.unsafe("Twin Git administration remains after an interrupted cleanup") }
            return
        }
        guard exists, ref == expectedTip else { throw TwinGitError.unsafe("Twin worktree or branch changed before cleanup") }
        let source = try descriptor(snapshot.sourceCWD), twin = try descriptor(snapshot.worktreePath)
        guard source.root == snapshot.repositoryRoot, source.gitDirectory == snapshot.sourceGitDirectory,
              source.common == snapshot.commonDirectory, source.commonIdentity == snapshot.ownership.commonIdentity,
              source.branch == snapshot.sourceBranch, twin.branch == snapshot.twinBranch else { throw TwinGitError.unsafe("Original or twin Git ownership changed before cleanup") }
        try TwinGitArtifactCleanup(snapshot: snapshot, expectedTip: expectedTip, root: root, files: fileSystem, inspector: inspector,
            command: { try self.command(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory, arguments: $0) },
            review: { try self.review(snapshot: snapshot) }, revalidate: {
                try self.validateSnapshot(snapshot)
                guard try self.finalMetadataMatches(source), try self.finalMetadataMatches(twin),
                      try self.reference(source.branch, cwd: source.root, gitDirectory: source.gitDirectory) == source.head,
                      try self.ownTip(snapshot) == expectedTip else { throw TwinGitError.unsafe("Git identity, source branch, index or reviewed twin tip changed before cleanup") }
            }, deleteBranch: {
                _ = try self.command(cwd: snapshot.repositoryRoot, gitDirectory: snapshot.commonDirectory,
                    arguments: ["update-ref", "-d", snapshot.twinBranch, expectedTip])
            }).cleanup(committing: committing, recordMutation: recordMutation)
    }

    static func checkedBranch(runID: String, round: Int) throws -> String {
        guard UUID(uuidString: runID)?.uuidString.lowercased() == runID, (1...8).contains(round) else {
            throw TwinGitError.unsafe("Invalid twin ownership identity")
        }
        return "refs/heads/trano/twins/" + runID + "/round-" + String(round)
    }
    static func parsePaths(_ data: Data) throws -> [String] {
        if data.isEmpty { return [] }
        guard data.last == 0 else { throw TwinGitError.unsafe("Truncated Git path list") }
        var values: [String] = []
        for bytes in data.dropLast().split(separator: 0, omittingEmptySubsequences: false) {
            guard let path = String(data: Data(bytes), encoding: .utf8), !path.isEmpty, path.utf8.count <= 16_384,
                  !path.hasPrefix("/"), !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." || $0.isEmpty || $0.caseInsensitiveCompare(".git") == .orderedSame }) else {
                throw TwinGitError.unsafe("Invalid or unsupported Git snapshot path")
            }
            values.append(path)
        }
        guard values.count <= 10_000 else { throw TwinGitError.unsafe("Git snapshot has too many paths") }
        var seen = Set<Data>(), normalized: [String: Data] = [:], result: [String] = []
        for value in values {
            let bytes = Data(value.utf8)
            if let other = normalized[value], other != bytes { throw TwinGitError.unsafe("Canonical-equivalent Git paths are ambiguous") }
            normalized[value] = bytes
            if seen.insert(bytes).inserted { result.append(value) }
        }
        return result.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }

    private struct Descriptor: Equatable {
        let cwd, root, gitDirectory, common, branch, head, indexDigest: String
        let commonIdentity: WorktreeFileIdentity
        let gitIdentity: WorktreeFileIdentity
    }
    private func descriptor(_ cwd: String) throws -> Descriptor {
        let cwd = try fileSystem.canonicalPath(cwd)
        let root = try path(command(cwd: cwd, arguments: ["rev-parse", "--show-toplevel"]))
        guard cwd == root || cwd.hasPrefix(root + "/") else { throw TwinGitError.unsafe("Source cwd is outside its Git worktree") }
        let directory = try path(command(cwd: cwd, arguments: ["rev-parse", "--absolute-git-dir"]))
        let common = try path(command(cwd: cwd, arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"]))
        guard let commonInfo = try fileSystem.info(common), commonInfo.kind == .directory, commonInfo.ownerUID == userID,
              let adminInfo = try fileSystem.info(directory), adminInfo.kind == .directory, adminInfo.ownerUID == userID else {
            throw TwinGitError.unsafe("Git metadata must be owned canonical directories")
        }
        let branch = try line(command(cwd: root, gitDirectory: directory, arguments: ["symbolic-ref", "--quiet", "HEAD"]))
        guard branch.hasPrefix("refs/heads/"), branch.utf8.count <= 1024, !branch.contains("\n") else { throw TwinGitError.unsafe("Source must have a named branch") }
        let head = try oid(command(cwd: root, gitDirectory: directory, arguments: ["rev-parse", "--verify", "HEAD^{commit}"]))
        let worktrees = try WorktreeGitParser.worktrees(command(cwd: root, gitDirectory: directory, arguments: ["worktree", "list", "--porcelain", "-z"]))
        let owners = worktrees.filter { $0.branch == branch }
        guard worktrees.count <= 512, owners.count == 1, owners[0].path == root else { throw TwinGitError.unsafe("The source branch is shared by another worktree or its ownership changed") }
        try safeRepository(cwd: root, gitDirectory: directory, common: common)
        let index = try path(command(cwd: root, gitDirectory: directory, arguments: ["rev-parse", "--path-format=absolute", "--git-path", "index"]))
        guard index == directory + "/index" else { throw TwinGitError.unsafe("Unexpected source Git index path") }
        let digest = Self.digest(try fileSystem.read(index, limit: maximumOutput))
        return .init(cwd: cwd, root: root, gitDirectory: directory, common: common, branch: branch, head: head, indexDigest: digest, commonIdentity: commonInfo.identity, gitIdentity: adminInfo.identity)
    }
    private func safeRepository(cwd: String, gitDirectory: String, common: String) throws {
        for directory in Set([gitDirectory, common]) {
            for name in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "rebase-merge", "rebase-apply", "sequencer", "index.lock", "HEAD.lock", "config.lock", "packed-refs.lock", "shallow"] {
                guard try fileSystem.info(directory + "/" + name) == nil else { throw TwinGitError.unsafe("Repository has an active operation, lock or shallow boundary") }
            }
        }
        let filters = try commandResult(cwd: cwd, gitDirectory: gitDirectory,
            arguments: ["config", "--includes", "--null", "--name-only", "--get-regexp", "^(filter\\..*\\.(clean|smudge|process)|merge\\..*\\.driver)$"])
        guard filters.status == 1, filters.stdout.isEmpty, filters.stderr.isEmpty else { throw TwinGitError.unsafe("Repository filters or custom merge drivers prevent isolated twin operations") }
        let sparse = try commandResult(cwd: cwd, gitDirectory: gitDirectory,
            arguments: ["config", "--includes", "--type=bool", "--get-regexp", "^(core\\.sparsecheckout(cone)?|index\\.sparse|core\\.splitindex)$"])
        if sparse.status != 1 {
            guard sparse.status == 0, let values = String(data: sparse.stdout, encoding: .utf8), !values.isEmpty,
                  values.split(separator: "\n").allSatisfy({ $0.hasSuffix(" false") }) else { throw TwinGitError.unsafe("Sparse or split indexes prevent complete twin snapshots") }
        } else if !sparse.stdout.isEmpty || !sparse.stderr.isEmpty { throw TwinGitError.unsafe("Cannot verify snapshot index configuration") }
        let visible = try command(cwd: cwd, gitDirectory: gitDirectory, arguments: ["ls-files", "-v", "-z", "--"])
        if !visible.isEmpty {
            guard visible.last == 0 else { throw TwinGitError.unsafe("Truncated source index flags") }
            for value in visible.dropLast().split(separator: 0, omittingEmptySubsequences: false) {
                guard value.count > 2, value.first == 72, value.dropFirst().first == 32 else { throw TwinGitError.unsafe("Hidden or skipped source index entries prevent a complete snapshot") }
            }
        }
        let stages = try command(cwd: cwd, gitDirectory: gitDirectory, arguments: ["ls-files", "--stage", "-z"])
        if !stages.isEmpty {
            guard stages.last == 0 else { throw TwinGitError.unsafe("Truncated source index entries") }
            for value in stages.dropLast().split(separator: 0) {
                guard let tab = value.firstIndex(of: 9), let prefix = String(data: Data(value[..<tab]), encoding: .utf8) else { throw TwinGitError.unsafe("Invalid source index metadata") }
                let fields = prefix.split(separator: " ")
                guard fields.count == 3, ["100644", "100755", "120000"].contains(String(fields[0])), Self.validOID(String(fields[1])), fields[2] == "0" else {
                    throw TwinGitError.unsafe("Submodules or unresolved source index entries prevent a complete snapshot")
                }
            }
        }
    }
    private func workingTree(cwd: String, gitDirectory: String, location: String, capture: ((TwinGitMergeInventory) throws -> Void)? = nil) throws -> String {
        let paths = try Self.parsePaths(command(cwd: cwd, gitDirectory: gitDirectory, arguments: ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]))
        guard paths.count <= maximumFiles else { throw TwinGitError.unsafe("Snapshot file count exceeds its bound") }
        try TwinGitMutationPolicy.attributes(paths: paths) { try self.command(cwd: cwd, gitDirectory: gitDirectory, arguments: $0, input: $1) }
        let privateIndex = location + "/index-" + UUID().uuidString.lowercased()
        defer { try? fileSystem.removePrivateFile(privateIndex); try? fileSystem.removePrivateFile(privateIndex + ".lock") }
        _ = try command(cwd: cwd, gitDirectory: gitDirectory, arguments: ["read-tree", "--empty"], index: privateIndex)
        let entries = try paths.map { relative -> (String, TwinGitNode?) in
            let absolute = cwd + "/" + relative
            try safeParents(absolute, root: cwd)
            return (relative, try fileSystem.info(absolute))
        }
        var indexData = Data(), bytes = 0
        for (relative, captured) in entries {
            let absolute = cwd + "/" + relative
            guard try fileSystem.info(absolute) == captured else { throw TwinGitError.unsafe("Snapshot paths changed before reading") }
            guard let node = captured else { continue }
            guard node.ownerUID == userID else { throw TwinGitError.unsafe("Snapshot file is not owned by the current user") }
            let content: Data, mode: String
            switch node.kind {
            case .regular: content = try fileSystem.read(absolute, limit: min(67_108_864, maximumSnapshotBytes - bytes)); mode = node.mode & 0o111 == 0 ? "100644" : "100755"
            case .symlink: content = try fileSystem.readLink(absolute, limit: 16_384); mode = "120000"
            default: throw TwinGitError.unsafe("Nested repositories, directories or special files prevent a complete snapshot")
            }
            bytes += content.count
            guard bytes <= maximumSnapshotBytes, try fileSystem.info(absolute) == node else { throw TwinGitError.unsafe("Snapshot bytes changed or exceed their bound") }
            let object = try oid(command(cwd: cwd, gitDirectory: gitDirectory, arguments: ["hash-object", "-w", "--no-filters", "--stdin"], input: content))
            indexData.append(Data((mode + " " + object + "\t" + relative).utf8)); indexData.append(0)
        }
        _ = try command(cwd: cwd, gitDirectory: gitDirectory, arguments: ["update-index", "-z", "--index-info"], input: indexData, index: privateIndex)
        let tree = try oid(command(cwd: cwd, gitDirectory: gitDirectory, arguments: ["write-tree"], index: privateIndex))
        if let capture { try capture(TwinGitMergeInventory(root: cwd, paths: paths, leaves: entries, files: fileSystem)) }
        return tree
    }
    private func mutationPaths(cwd: String, gitDirectory: String, common: String) throws -> [String] {
        try safeRepository(cwd: cwd, gitDirectory: gitDirectory, common: common)
        let paths = try Self.parsePaths(command(cwd: cwd, gitDirectory: gitDirectory, arguments: ["ls-files", "--cached", "--others", "--exclude-standard", "-z"]))
        try TwinGitMutationPolicy.attributes(paths: paths) { try self.command(cwd: cwd, gitDirectory: gitDirectory, arguments: $0, input: $1) }
        return paths
    }
    private func unchanged(_ before: Descriptor, cwd: String, tree: String, location: String) throws {
        guard try metadataUnchanged(before, cwd: cwd),
              try workingTree(cwd: before.root, gitDirectory: before.gitDirectory, location: location) == tree,
              try metadataUnchanged(before, cwd: cwd) else { throw TwinGitError.unsafe("Source files, HEAD or index changed during the twin operation") }
    }
    private func metadataUnchanged(_ before: Descriptor, cwd: String) throws -> Bool { try descriptor(cwd) == before }
    private func finalMetadataMatches(_ before: Descriptor) throws -> Bool {
        guard try fileSystem.info(before.common)?.identity == before.commonIdentity,
              try fileSystem.info(before.gitDirectory)?.identity == before.gitIdentity,
              try fileSystem.read(before.gitDirectory + "/HEAD", limit: 16_384) == Data(("ref: " + before.branch + "\n").utf8),
              Self.digest(try fileSystem.read(before.gitDirectory + "/index", limit: maximumOutput)) == before.indexDigest else { return false }
        for name in ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "rebase-merge", "rebase-apply", "sequencer", "index.lock", "HEAD.lock"] {
            if try fileSystem.info(before.gitDirectory + "/" + name) != nil { return false }
        }
        return true
    }
    private func makeLocation(runID: String, round: Int) throws -> String {
        _ = try Self.checkedBranch(runID: runID, round: round)
        try fileSystem.ensurePrivateDirectory(root.path)
        let parts = ["twins", runID, "round-" + String(round)]
        var path = root.path
        for part in parts { path += "/" + part; try fileSystem.ensurePrivateDirectory(path) }
        return path
    }
    private func existingLocation(_ snapshot: TwinGitSnapshot) throws -> String {
        let expected = root.appendingPathComponent("twins").appendingPathComponent(snapshot.runID).appendingPathComponent("round-" + String(snapshot.round)).path
        guard snapshot.worktreePath == expected + "/worktree", let directory = try fileSystem.info(expected), directory.kind == .directory,
              directory.ownerUID == userID, directory.mode & 0o077 == 0, try fileSystem.canonicalPath(expected) == expected else { throw TwinGitError.unsafe("Twin resource path changed") }
        return expected
    }
    private func validateSnapshot(_ snapshot: TwinGitSnapshot) throws {
        guard snapshot.twinBranch == (try Self.checkedBranch(runID: snapshot.runID, round: snapshot.round)),
              snapshot.ownership.path == snapshot.worktreePath, snapshot.ownership.commonDirectory == snapshot.commonDirectory,
              snapshot.sourceBranch != snapshot.twinBranch, snapshot.sourceBranch.hasPrefix("refs/heads/"),
              Self.validOID(snapshot.sourceHEAD), Self.validOID(snapshot.sourceTree), Self.validOID(snapshot.snapshotCommit) else {
            throw TwinGitError.unsafe("Twin ownership receipt is invalid")
        }
        _ = try existingLocation(snapshot)
        let location = URL(fileURLWithPath: snapshot.worktreePath).deletingLastPathComponent().path
        let stored = try JSONDecoder().decode(TwinGitSnapshot.self, from: fileSystem.read(location + "/snapshot-receipt.json", limit: 65_536))
        guard Self.digest(try fileSystem.read(location + "/source-index.backup", limit: maximumOutput)) == snapshot.sourceIndexSHA256 else { throw TwinGitError.unsafe("Source index recovery receipt changed") }
        guard stored == snapshot else { throw TwinGitError.unsafe("Twin ownership receipt changed") }
        let planPath = location + "/snapshot-plan.json"
        let plan = try JSONDecoder().decode([String: String].self, from: fileSystem.read(planPath, limit: 16_384))
        guard plan["runID"] == snapshot.runID, plan["round"] == String(snapshot.round), plan["sourceHEAD"] == snapshot.sourceHEAD,
              plan["sourceTree"] == snapshot.sourceTree, plan["snapshotCommit"] == snapshot.snapshotCommit,
              plan["sourceIndexSHA256"] == snapshot.sourceIndexSHA256, plan["twinBranch"] == snapshot.twinBranch, plan["worktreePath"] == snapshot.worktreePath else {
            throw TwinGitError.unsafe("Twin snapshot journal changed")
        }
    }
    private func ownTip(_ snapshot: TwinGitSnapshot) throws -> String {
        let current = try descriptor(snapshot.worktreePath)
        guard current.root == snapshot.worktreePath, current.gitDirectory == snapshot.ownership.adminDirectory,
              current.common == snapshot.commonDirectory, current.commonIdentity == snapshot.ownership.commonIdentity,
              current.branch == snapshot.twinBranch else { throw TwinGitError.unsafe("Twin worktree branch or Git identity changed") }
        return current.head
    }
    private func requireAncestor(_ base: String, _ tip: String, snapshot: TwinGitSnapshot) throws {
        guard Self.validOID(base), Self.validOID(tip) else { throw TwinGitError.unsafe("Invalid twin commit identity") }
        let result = try commandResult(cwd: snapshot.worktreePath, gitDirectory: snapshot.ownership.adminDirectory, arguments: ["merge-base", "--is-ancestor", base, tip])
        guard result.status == 0 else { throw TwinGitError.unsafe("Twin branch no longer descends from its source snapshot") }
    }
    private func reference(_ ref: String, cwd: String, gitDirectory: String) throws -> String? {
        let result = try commandResult(cwd: cwd, gitDirectory: gitDirectory, arguments: ["show-ref", "--verify", "--quiet", ref])
        if result.status == 1, result.stdout.isEmpty, result.stderr.isEmpty { return nil }
        guard result.status == 0, result.stdout.isEmpty, result.stderr.isEmpty else { throw TwinGitError.unsafe("Cannot verify twin branch reference") }
        return try oid(command(cwd: cwd, gitDirectory: gitDirectory, arguments: ["rev-parse", "--verify", ref + "^{commit}"]))
    }
    private func requireMissingRef(_ ref: String, cwd: String, gitDirectory: String) throws {
        guard try reference(ref, cwd: cwd, gitDirectory: gitDirectory) == nil else { throw TwinGitError.unsafe("Twin branch already exists; review ownership before retrying") }
    }
    private func safeParents(_ path: String, root: String) throws {
        var parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        while parent != root {
            guard parent.hasPrefix(root + "/") else { throw TwinGitError.unsafe("Snapshot parent escapes the worktree") }
            if let node = try fileSystem.info(parent) {
                guard node.kind == .directory, try fileSystem.canonicalPath(parent) == parent else { throw TwinGitError.unsafe("Snapshot parent traverses a symbolic link") }
            }
            parent = URL(fileURLWithPath: parent).deletingLastPathComponent().path
        }
    }
    private func command(cwd: String, gitDirectory: String? = nil, arguments: [String], input: Data? = nil, index: String? = nil, limit: Int? = nil) throws -> Data {
        let result = try commandResult(cwd: cwd, gitDirectory: gitDirectory, arguments: arguments, input: input, index: index, limit: limit)
        guard result.status == 0 else { throw TwinGitError.unsafe("Git twin operation failed; its artifacts were retained for review") }
        return result.stdout
    }
    private func commandResult(cwd: String, gitDirectory: String? = nil, arguments: [String], input: Data? = nil, index: String? = nil, limit: Int? = nil) throws -> WorktreeGitCommandResult {
        var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/empty", "XDG_CONFIG_HOME": "/var/empty",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ATTR_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0", "GIT_NO_REPLACE_OBJECTS": "1", "GIT_NO_LAZY_FETCH": "1", "GIT_PROTOCOL_FROM_USER": "0",
            "GIT_PAGER": "cat", "GIT_AUTHOR_NAME": "Trano", "GIT_AUTHOR_EMAIL": "trano@localhost", "GIT_COMMITTER_NAME": "Trano", "GIT_COMMITTER_EMAIL": "trano@localhost"]
        if let index { environment["GIT_INDEX_FILE"] = index }
        let config = ["core.fsmonitor=false", "core.hooksPath=/dev/null", "protocol.allow=never", "core.untrackedCache=false", "core.quotePath=false",
            "core.sshCommand=false", "commit.gpgsign=false", "tag.gpgsign=false", "rerere.enabled=false", "rerere.autoupdate=false", "merge.renormalize=false", "core.autocrlf=false", "core.safecrlf=false"]
        var args = ["-C", cwd, "--no-pager", "--no-replace-objects"]
        if let gitDirectory { args += ["--git-dir=" + gitDirectory, "--work-tree=" + cwd] }
        for item in config { args += ["-c", item] }
        let bound = limit ?? maximumOutput
        let result = try runner.run(arguments: args + arguments, input: input, environment: environment, timeout: 5, limit: bound)
        guard result.stdout.count <= bound, result.stderr.count <= bound - result.stdout.count else { throw TwinGitError.unsafe("Git twin output exceeds its bound") }
        return result
    }
    private func path(_ data: Data) throws -> String {
        let path = try line(data)
        guard path.hasPrefix("/"), try fileSystem.canonicalPath(path) == path else { throw TwinGitError.unsafe("Git returned a noncanonical path") }
        return path
    }
    private func line(_ data: Data) throws -> String {
        guard data.last == 10, data.count <= 16_384, let value = String(data: data.dropLast(), encoding: .utf8), !value.isEmpty, !value.utf8.contains(0) else {
            throw TwinGitError.unsafe("Git returned an invalid identity or path")
        }
        return value
    }
    private func oid(_ data: Data) throws -> String {
        let value = try line(data)
        guard Self.validOID(value) else { throw TwinGitError.unsafe("Git returned an invalid object identity") }
        return value
    }
    static func validOID(_ value: String) -> Bool { (value.utf8.count == 40 || value.utf8.count == 64) && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) } }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func conflictedPaths(_ data: Data) throws -> [String] {
        if data.isEmpty { return [] }
        guard data.last == 0 else { throw TwinGitError.unsafe("Truncated merge-conflict metadata") }
        var paths = Data()
        for record in data.dropLast().split(separator: 0) {
            guard let tab = record.firstIndex(of: 9) else { throw TwinGitError.unsafe("Invalid merge-conflict metadata") }
            paths.append(contentsOf: record[record.index(after: tab)...]); paths.append(0)
        }
        return try parsePaths(paths)
    }
}
