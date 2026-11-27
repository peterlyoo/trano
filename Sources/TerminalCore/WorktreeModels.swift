import Foundation

public struct WorktreeOwner: Codable, Equatable {
    public let paneID: String
    public let generation: String
    public let backendPID: Int32
    public let processIdentity: SupervisorProcessIdentity
    public init(paneID: String, generation: String, backendPID: Int32, processIdentity: SupervisorProcessIdentity) {
        self.paneID = paneID; self.generation = generation; self.backendPID = backendPID; self.processIdentity = processIdentity
    }
}

public struct WorktreeFileIdentity: Codable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public init(device: UInt64, inode: UInt64) { self.device = device; self.inode = inode }
}

public struct WorktreeIdentity: Codable, Equatable {
    public let path: String
    public let commonDirectory: String
    public let adminDirectory: String
    public let pathIdentity: WorktreeFileIdentity
    public let gitFileIdentity: WorktreeFileIdentity
    public let adminIdentity: WorktreeFileIdentity
    public let commonIdentity: WorktreeFileIdentity
    public init(path: String, commonDirectory: String, adminDirectory: String, pathIdentity: WorktreeFileIdentity,
                gitFileIdentity: WorktreeFileIdentity, adminIdentity: WorktreeFileIdentity, commonIdentity: WorktreeFileIdentity) {
        self.path = path; self.commonDirectory = commonDirectory; self.adminDirectory = adminDirectory
        self.pathIdentity = pathIdentity; self.gitFileIdentity = gitFileIdentity
        self.adminIdentity = adminIdentity; self.commonIdentity = commonIdentity
    }
}

public struct WorktreeSnapshotEntry: Codable, Equatable {
    public let path: String
    public let head: String?
    public let branch: String?
    public let isMain: Bool
    public let isBare: Bool
    public let locked: Bool
    public let prunable: Bool
    public let identity: WorktreeIdentity?
    public init(path: String, head: String? = nil, branch: String? = nil, isMain: Bool = false, isBare: Bool = false,
                locked: Bool = false, prunable: Bool = false, identity: WorktreeIdentity? = nil) {
        self.path = path; self.head = head; self.branch = branch; self.isMain = isMain; self.isBare = isBare
        self.locked = locked; self.prunable = prunable; self.identity = identity
    }
}

public struct WorktreeRepositorySnapshot: Codable, Equatable {
    public let commonDirectory: String
    public let commonIdentity: WorktreeFileIdentity
    public let worktrees: [WorktreeSnapshotEntry]
    public init(commonDirectory: String, commonIdentity: WorktreeFileIdentity, worktrees: [WorktreeSnapshotEntry]) {
        self.commonDirectory = commonDirectory; self.commonIdentity = commonIdentity; self.worktrees = worktrees
    }
}

public struct WorktreeInspection: Equatable {
    public let entry: WorktreeSnapshotEntry
    public let clean: Bool
    public let hasIgnored: Bool
    public let operationInProgress: Bool
    public let retainedHEAD: Bool
    public init(entry: WorktreeSnapshotEntry, clean: Bool, hasIgnored: Bool, operationInProgress: Bool, retainedHEAD: Bool) {
        self.entry = entry; self.clean = clean; self.hasIgnored = hasIgnored
        self.operationInProgress = operationInProgress; self.retainedHEAD = retainedHEAD
    }
}

public enum WorktreeProcessUse: Equatable { case unused, inUse, uncertain }

public protocol WorktreeGitInspecting: AnyObject {
    func creationInvocation(cwd: String, gitArguments: [String]) throws -> WorktreeCreationInvocation?
    func snapshot(cwd: String, gitArguments: [String]) throws -> WorktreeRepositorySnapshot
    func inspect(_ identity: WorktreeIdentity) throws -> WorktreeInspection
    func remove(_ identity: WorktreeIdentity) throws
    func processUse(path: String) throws -> WorktreeProcessUse
}
