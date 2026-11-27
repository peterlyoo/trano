import Foundation
import Darwin

public enum WorktreeGitError: Error, Equatable, LocalizedError {
    case unsafe(String)
    public var errorDescription: String? { switch self { case .unsafe(let reason): return reason } }
}
public enum WorktreeGitFileKind { case directory, regular, symlink, other }
public struct WorktreeGitFileInfo {
    public let identity: WorktreeFileIdentity
    public let ownerUID: UInt32
    public let kind: WorktreeGitFileKind
    public let size: UInt64
    public init(identity: WorktreeFileIdentity, ownerUID: UInt32, kind: WorktreeGitFileKind, size: UInt64 = 0) {
        self.identity = identity; self.ownerUID = ownerUID; self.kind = kind; self.size = size
    }
}
public protocol WorktreeGitFileSystem {
    func canonicalPath(_ path: String) throws -> String
    func info(_ path: String) throws -> WorktreeGitFileInfo?
    func read(_ path: String, limit: Int) throws -> Data
    func children(_ path: String, limit: Int) throws -> [String]
}
public struct WorktreeGitCommandResult {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data
    public init(status: Int32, stdout: Data = Data(), stderr: Data = Data()) {
        self.status = status; self.stdout = stdout; self.stderr = stderr
    }
}
public protocol WorktreeGitCommandRunning {
    func run(arguments: [String], environment: [String: String], timeout: TimeInterval, limit: Int) throws -> WorktreeGitCommandResult
}
public struct WorktreeGitProcessRecord {
    public let pid: Int32
    public let ownerUID: UInt32
    public let cwd: String?
    public init(pid: Int32, ownerUID: UInt32, cwd: String?) { self.pid = pid; self.ownerUID = ownerUID; self.cwd = cwd }
}
public struct WorktreeGitProcessSnapshot {
    public let records: [WorktreeGitProcessRecord]
    public let complete: Bool
    public init(records: [WorktreeGitProcessRecord], complete: Bool) { self.records = records; self.complete = complete }
}
public protocol WorktreeGitProcessProbing { func snapshot(limit: Int) throws -> WorktreeGitProcessSnapshot }
public final class WorktreeGitInspector: WorktreeGitInspecting {
    private let runner: WorktreeGitCommandRunning
    private let fileSystem: WorktreeGitFileSystem
    private let processProbe: WorktreeGitProcessProbing
    private let userID: UInt32
    private let outputLimit = 1_048_576

    public convenience init() {
        self.init(runner: WorktreeNativeGitRunner(), fileSystem: WorktreeNativeGitFileSystem(),
                  processProbe: WorktreeNativeGitProcessProbe(), userID: getuid())
    }

    public init(runner: WorktreeGitCommandRunning, fileSystem: WorktreeGitFileSystem,
                processProbe: WorktreeGitProcessProbing, userID: UInt32) {
        self.runner = runner; self.fileSystem = fileSystem; self.processProbe = processProbe; self.userID = userID
    }

    public func creationInvocation(cwd: String, gitArguments: [String]) throws -> WorktreeCreationInvocation? {
        try WorktreeGitParser.creation(cwd: cwd, arguments: gitArguments, fileSystem: fileSystem)
    }

    public func snapshot(cwd: String, gitArguments: [String]) throws -> WorktreeRepositorySnapshot {
        guard let invocation = try creationInvocation(cwd: cwd, gitArguments: gitArguments),
              let commandIndex = invocation.gitArguments.firstIndex(of: "worktree") else {
            throw WorktreeGitError.unsafe("Unsupported Git creation invocation")
        }
        let globals = Array(invocation.gitArguments[..<commandIndex])
        let commonData = try command(cwd: invocation.cwd, globals: globals,
            arguments: ["rev-parse", "--path-format=absolute", "--git-common-dir"])
        let common = try canonical(WorktreeGitParser.singleLine(commonData), kind: .directory)
        return try repositorySnapshot(cwd: invocation.cwd, globals: globals, common: common)
    }

    public func inspect(_ identity: WorktreeIdentity) throws -> WorktreeInspection {
        guard try linkedIdentity(path: identity.path, common: identity.commonDirectory) == identity else {
            throw WorktreeGitError.unsafe("Worktree identity changed")
        }
        let globals = ["--git-dir=" + identity.adminDirectory, "--work-tree=" + identity.path]
        let snapshot = try repositorySnapshot(cwd: identity.path, globals: globals, common: identity.commonDirectory)
        guard let entry = snapshot.worktrees.first(where: { $0.path == identity.path }), entry.identity == identity,
              !entry.isMain, !entry.isBare, !entry.locked, !entry.prunable else {
            throw WorktreeGitError.unsafe("Worktree is no longer an eligible linked worktree")
        }
        let filters = try commandResult(cwd: identity.path, globals: globals,
            arguments: ["config", "--null", "--name-only", "--get-regexp", "^filter\\..*\\.(clean|process)$"])
        guard filters.status == 1, filters.stdout.isEmpty, filters.stderr.isEmpty else {
            throw WorktreeGitError.unsafe("Repository clean or process filters prevent safe inspection")
        }
        let sparse = try commandResult(cwd: identity.path, globals: globals,
            arguments: ["config", "--type=bool", "--get-regexp", "^(core\\.sparsecheckout(cone)?|index\\.sparse)$"])
        try WorktreeGitParser.requireNoSparseConfiguration(sparse)
        try WorktreeGitParser.requireVisibleIndex(command(cwd: identity.path, globals: globals,
            arguments: ["ls-files", "-v", "-z", "--"]))
        let state = try WorktreeGitParser.status(command(cwd: identity.path, globals: globals,
            arguments: ["status", "--porcelain=v1", "-z", "--untracked-files=all", "--ignored=matching", "--ignore-submodules=none"]))
        let operations = try operationInProgress(identity)
        let head = try WorktreeGitParser.singleLine(command(cwd: identity.path, globals: globals,
            arguments: ["rev-parse", "--verify", "HEAD^{commit}"]))
        guard WorktreeGitParser.validOID(head), head == entry.head else {
            throw WorktreeGitError.unsafe("Worktree HEAD changed during inspection")
        }
        let refs = try command(cwd: identity.path, globals: globals,
            arguments: ["for-each-ref", "--contains=" + head, "--format=%(refname)", "refs/heads/", "refs/tags/", "refs/remotes/"])
        let retained = try WorktreeGitParser.retained(refs)
        guard try linkedIdentity(path: identity.path, common: identity.commonDirectory) == identity else {
            throw WorktreeGitError.unsafe("Worktree identity changed during inspection")
        }
        return WorktreeInspection(entry: entry, clean: state.clean, hasIgnored: state.ignored,
            operationInProgress: operations, retainedHEAD: retained)
    }

    public func remove(_ identity: WorktreeIdentity) throws {
        try remove(identity, beforeRemoval: {})
    }

    public func remove(_ identity: WorktreeIdentity, beforeRemoval: () throws -> Void) throws {
        try remove(identity, committing: { mutation in try beforeRemoval(); try mutation() })
    }

    public func remove(_ identity: WorktreeIdentity, committing: (_ mutation: () throws -> Void) throws -> Void) throws {
        try requireSafe(inspect(identity))
        guard try processUse(path: identity.path) == .unused else {
            throw WorktreeGitError.unsafe("Worktree process use is active or uncertain")
        }
        try requireSafe(inspect(identity))
        guard try processUse(path: identity.path) == .unused,
              try linkedIdentity(path: identity.path, common: identity.commonDirectory) == identity else {
            throw WorktreeGitError.unsafe("Worktree changed before removal")
        }
        try committing {
            _ = try command(cwd: identity.commonDirectory, globals: ["--git-dir=" + identity.commonDirectory],
                arguments: ["worktree", "remove", "--", identity.path])
        }
    }

    public func processUse(path: String) throws -> WorktreeProcessUse {
        do {
            let target = try canonical(path, kind: .directory)
            let sample = try processProbe.snapshot(limit: 16_384)
            guard sample.complete, sample.records.count <= 16_384 else { return .uncertain }
            var seen = Set<Int32>()
            var uncertain = false
            let deadline = ProcessInfo.processInfo.systemUptime + 2
            for record in sample.records {
                guard ProcessInfo.processInfo.systemUptime < deadline else { return .uncertain }
                guard record.pid > 0, seen.insert(record.pid).inserted,
                      record.ownerUID == userID, let cwd = record.cwd, cwd.hasPrefix("/") else {
                    uncertain = true; continue
                }
                guard let current = try? fileSystem.canonicalPath(cwd), current.hasPrefix("/") else {
                    uncertain = true; continue
                }
                if current == target || current.hasPrefix(target + "/") { return .inUse }
            }
            return uncertain ? .uncertain : .unused
        } catch { return .uncertain }
    }

    private func requireSafe(_ inspection: WorktreeInspection) throws {
        guard inspection.clean, !inspection.hasIgnored, !inspection.operationInProgress, inspection.retainedHEAD else {
            throw WorktreeGitError.unsafe("Worktree has files, repository operations, or unretained HEAD")
        }
    }

    private func command(cwd: String, globals: [String], arguments: [String]) throws -> Data {
        let result = try commandResult(cwd: cwd, globals: globals, arguments: arguments)
        guard result.status == 0 else { throw WorktreeGitError.unsafe("Git inspection or nonforce removal failed") }
        return result.stdout
    }

    private func commandResult(cwd: String, globals: [String], arguments: [String]) throws -> WorktreeGitCommandResult {
        let fixed = ["--no-pager", "--no-replace-objects", "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null",
                     "-c", "protocol.allow=never", "-c", "core.untrackedCache=false", "-c", "core.quotePath=false", "-c", "core.sshCommand=false"]
        let environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": "/var/empty", "XDG_CONFIG_HOME": "/var/empty",
                           "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_SYSTEM": "/dev/null", "GIT_CONFIG_GLOBAL": "/dev/null",
                           "GIT_ATTR_NOSYSTEM": "1", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
                           "GIT_NO_REPLACE_OBJECTS": "1", "GIT_NO_LAZY_FETCH": "1", "GIT_PAGER": "cat", "GIT_PROTOCOL_FROM_USER": "0"]
        let result = try runner.run(arguments: ["-C", cwd] + globals + fixed + arguments,
                                    environment: environment, timeout: 5, limit: outputLimit)
        guard result.stdout.count <= outputLimit,
              result.stderr.count <= outputLimit - result.stdout.count else {
            throw WorktreeGitError.unsafe("Git inspection or nonforce removal failed")
        }
        return result
    }

    private func repositorySnapshot(cwd: String, globals: [String], common: String) throws -> WorktreeRepositorySnapshot {
        let commonBefore = try owned(common, kind: .directory)
        let parsed = try WorktreeGitParser.worktrees(command(cwd: cwd, globals: globals,
            arguments: ["worktree", "list", "--porcelain", "-z"]))
        var entries: [WorktreeSnapshotEntry] = []
        for (index, value) in parsed.enumerated() {
            let path = try WorktreeGitParser.absolute(value.path)
            let isMain = index == 0
            let identity: WorktreeIdentity?
            if !isMain && !value.bare && !value.locked && !value.prunable {
                identity = try? linkedIdentity(path: path, common: common)
            } else { identity = nil }
            entries.append(.init(path: path, head: value.head, branch: value.branch, isMain: isMain,
                isBare: value.bare, locked: value.locked, prunable: value.prunable, identity: identity))
        }
        guard try owned(common, kind: .directory).identity == commonBefore.identity else {
            throw WorktreeGitError.unsafe("Repository identity changed")
        }
        return WorktreeRepositorySnapshot(commonDirectory: common, commonIdentity: commonBefore.identity, worktrees: entries)
    }

    private func linkedIdentity(path: String, common: String) throws -> WorktreeIdentity {
        guard try canonical(path, kind: .directory) == path,
              try canonical(common, kind: .directory) == common else {
            throw WorktreeGitError.unsafe("Worktree paths must be canonical")
        }
        let pathInfo = try owned(path, kind: .directory)
        let gitFile = path + "/.git"
        let gitInfo = try owned(gitFile, kind: .regular)
        let pointer = try WorktreeGitParser.singleLine(fileSystem.read(gitFile, limit: 16_384))
        guard pointer.hasPrefix("gitdir: ") else { throw WorktreeGitError.unsafe("Invalid linked worktree Git pointer") }
        let admin = try canonical(WorktreeGitParser.resolvedPath(String(pointer.dropFirst(8)), relativeTo: path, fileSystem: fileSystem), kind: .directory)
        let worktrees = common + "/worktrees"
        guard URL(fileURLWithPath: admin).deletingLastPathComponent().path == worktrees,
              try canonical(worktrees, kind: .directory) == worktrees else {
            throw WorktreeGitError.unsafe("Git administrative directory is outside repository worktrees")
        }
        let adminInfo = try owned(admin, kind: .directory)
        let commonInfo = try owned(common, kind: .directory)
        let commonPointerPath = admin + "/commondir", reversePointerPath = admin + "/gitdir"
        _ = try owned(commonPointerPath, kind: .regular); _ = try owned(reversePointerPath, kind: .regular)
        let commonPointer = try WorktreeGitParser.singleLine(fileSystem.read(commonPointerPath, limit: 16_384))
        let reversePointer = try WorktreeGitParser.singleLine(fileSystem.read(reversePointerPath, limit: 16_384))
        guard try canonical(WorktreeGitParser.resolvedPath(commonPointer, relativeTo: admin, fileSystem: fileSystem), kind: .directory) == common,
              try canonical(WorktreeGitParser.resolvedPath(reversePointer, relativeTo: admin, fileSystem: fileSystem), kind: .regular) == gitFile,
              try owned(gitFile, kind: .regular).identity == gitInfo.identity,
              try owned(path, kind: .directory).identity == pathInfo.identity,
              try owned(admin, kind: .directory).identity == adminInfo.identity,
              try owned(common, kind: .directory).identity == commonInfo.identity else {
            throw WorktreeGitError.unsafe("Linked worktree pointer or identity changed")
        }
        return WorktreeIdentity(path: path, commonDirectory: common, adminDirectory: admin,
            pathIdentity: pathInfo.identity, gitFileIdentity: gitInfo.identity,
            adminIdentity: adminInfo.identity, commonIdentity: commonInfo.identity)
    }

    private func canonical(_ path: String, kind: WorktreeGitFileKind) throws -> String {
        let absolute = try WorktreeGitParser.absolute(path)
        var current = ""
        for component in absolute.split(separator: "/") {
            current += "/" + component
            guard let info = try fileSystem.info(current), info.kind != .symlink else {
                throw WorktreeGitError.unsafe("Missing or symbolic-link path component")
            }
        }
        let result = try fileSystem.canonicalPath(absolute)
        guard result == absolute else { throw WorktreeGitError.unsafe("Noncanonical path") }
        _ = try owned(result, kind: kind)
        return result
    }

    private func owned(_ path: String, kind: WorktreeGitFileKind) throws -> WorktreeGitFileInfo {
        guard let info = try fileSystem.info(path), info.kind == kind, info.ownerUID == userID else {
            throw WorktreeGitError.unsafe("Missing, unowned, or wrong-kind worktree metadata")
        }
        return info
    }

    private func operationInProgress(_ identity: WorktreeIdentity) throws -> Bool {
        let sentinels: Set<String> = ["MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "BISECT_LOG", "BISECT_START", "AUTO_MERGE",
                                      "rebase-merge", "rebase-apply", "sequencer"]
        var remaining = 4096
        var found = false
        func visit(_ path: String, recursive: Bool, depth: Int) throws {
            remaining -= 1
            guard remaining >= 0, depth <= 16 else { throw WorktreeGitError.unsafe("Repository metadata scan exceeds bound") }
            _ = try owned(path, kind: .directory)
            let names = try fileSystem.children(path, limit: remaining)
            remaining -= names.count
            guard remaining >= 0 else { throw WorktreeGitError.unsafe("Repository metadata scan exceeds bound") }
            for name in names {
                guard !name.isEmpty, !name.contains("/"), name != ".", name != "..", !name.utf8.contains(0) else {
                    throw WorktreeGitError.unsafe("Invalid repository directory entry")
                }
                if name.hasSuffix(".lock") || sentinels.contains(name) { found = true }
                let child = path + "/" + name
                guard let info = try fileSystem.info(child), info.kind != .symlink, info.ownerUID == userID else {
                    throw WorktreeGitError.unsafe("Uncertain repository metadata")
                }
                let objectMetadata = path == identity.commonDirectory + "/objects" && ["pack", "info"].contains(name)
                if info.kind == .directory && (recursive || name == "refs" || name == "logs" || name == "worktrees" || name == "objects" || objectMetadata) {
                    try visit(child, recursive: name != "objects", depth: depth + 1)
                }
            }
        }
        try visit(identity.commonDirectory, recursive: false, depth: 0)
        return found
    }
}
