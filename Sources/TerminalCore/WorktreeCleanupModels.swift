import Foundation

public struct WorktreeCompletionProof: Codable, Equatable {
    public let owner: WorktreeOwner
    public let completionID: String
    public let turnID: String
    public let completedAt: Date
    public init(owner: WorktreeOwner, completionID: String, turnID: String, completedAt: Date) {
        self.owner = owner; self.completionID = completionID; self.turnID = turnID; self.completedAt = completedAt
    }
}

public struct WorktreeCleanupContext: Equatable {
    public let enabled: Bool
    public let local: Bool
    public let owner: WorktreeOwner?
    public let completionID: String?
    public let turnID: String?
    public let idle: Bool
    public let inputClear: Bool
    public let inputRevision: UInt64?
    public let hasActiveTools: Bool
    public let hasPendingDecisions: Bool
    public let hasQueuedWork: Bool
    public let quotaSwitching: Bool
    public let sessionCWDs: [String]
    public init(enabled: Bool, local: Bool, owner: WorktreeOwner?, completionID: String? = nil, turnID: String? = nil,
                idle: Bool = false, inputClear: Bool = false, inputRevision: UInt64? = nil, hasActiveTools: Bool = false,
                hasPendingDecisions: Bool = false, hasQueuedWork: Bool = false, quotaSwitching: Bool = false,
                sessionCWDs: [String] = []) {
        self.enabled = enabled; self.local = local; self.owner = owner; self.completionID = completionID; self.turnID = turnID
        self.idle = idle; self.inputClear = inputClear; self.inputRevision = inputRevision; self.hasActiveTools = hasActiveTools
        self.hasPendingDecisions = hasPendingDecisions; self.hasQueuedWork = hasQueuedWork
        self.quotaSwitching = quotaSwitching; self.sessionCWDs = sessionCWDs
    }
}

public enum WorktreeCleanupStatus: String, Codable { case tracked, pending, held, removing, removed, needsReview, error }

public struct WorktreeCreationInvocation: Codable, Equatable {
    public let cwd: String
    public let gitArguments: [String]
    public let targetPath: String
    public init(cwd: String, gitArguments: [String], targetPath: String) {
        self.cwd = cwd; self.gitArguments = gitArguments; self.targetPath = targetPath
    }
}

public struct WorktreeCapture: Codable, Equatable {
    public let id: String
    public let nonce: String
    public let owner: WorktreeOwner
    public let startedAt: Date
    public let invocation: WorktreeCreationInvocation
    public var before: WorktreeRepositorySnapshot?
    public var ambiguous: Bool
    public init(id: String, nonce: String, owner: WorktreeOwner, startedAt: Date, invocation: WorktreeCreationInvocation,
                before: WorktreeRepositorySnapshot? = nil, ambiguous: Bool = false) {
        self.id = id; self.nonce = nonce; self.owner = owner; self.startedAt = startedAt; self.invocation = invocation
        self.before = before; self.ambiguous = ambiguous
    }
}

public struct WorktreeCleanupRecord: Codable, Equatable {
    public let id: String
    public let owner: WorktreeOwner
    public let identity: WorktreeIdentity
    public let createdAt: Date
    public var status: WorktreeCleanupStatus
    public var message: String?
    public var completion: WorktreeCompletionProof?
    public var eligibleAt: Date?
    public var updatedAt: Date
    public var path: String { identity.path }
    public init(id: String, owner: WorktreeOwner, identity: WorktreeIdentity, createdAt: Date,
                status: WorktreeCleanupStatus = .tracked, message: String? = nil,
                completion: WorktreeCompletionProof? = nil, eligibleAt: Date? = nil, updatedAt: Date? = nil) {
        self.id = id; self.owner = owner; self.identity = identity; self.createdAt = createdAt
        self.status = status; self.message = message; self.completion = completion
        self.eligibleAt = eligibleAt; self.updatedAt = updatedAt ?? createdAt
    }
}

public protocol WorktreeCleanupBackend: AnyObject {
    var git: WorktreeGitInspecting { get }
    func context(owner: WorktreeOwner) throws -> WorktreeCleanupContext
    func commitRemoval(record: WorktreeCleanupRecord, expectedContext: WorktreeCleanupContext) throws
}
