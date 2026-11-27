import Foundation
import CryptoKit

public enum TwinReviewMode: String, Codable, CaseIterable { case codeReview = "code_review", securityReview = "security_review", generalReview = "general_review" }
public enum TwinExitReason: String, Codable, CaseIterable {
    case agentAgreement = "agent_agreement", noopCap = "noop_cap", roundCap = "round_cap", userInterrupt = "user_interrupt"
    case agentUnavailable = "agent_unavailable", invalidAgentOutput = "invalid_agent_output"
}
public enum TwinChoice: String, Codable, CaseIterable { case merge, feedbackOnly = "feedback_only", discard }
public enum TwinPhase: String, Codable, CaseIterable {
    case waitingForSource = "waiting_for_source", snapshotting, launching, reviewing, awaitingDecision = "awaiting_decision"
    case waitingForMerge = "waiting_for_merge", merging, forwarding, awaitingSourceResponse = "awaiting_source_response", cleaning, finished
    case needsReview = "needs_review", conflict
}
public enum TwinOperationKind: String, Codable { case snapshot, launch, publishDecision = "publish_decision", merge, forward, cleanup }

public struct TwinSourceBinding: Codable, Equatable {
    public let paneID: String
    public let generation: String
    public let conversationID: String
    public let cwd: String
    public let configurationRoot: String
    public let provider: AgentKind
    public let accountID: String?
    public let backendPID: Int32
    public let providerPID: Int32
    public let backendIdentity: SupervisorProcessIdentity
    public let providerIdentity: SupervisorProcessIdentity
    public init(paneID: String, generation: String, conversationID: String, cwd: String, configurationRoot: String, provider: AgentKind, accountID: String? = nil, backendPID: Int32, providerPID: Int32, backendIdentity: SupervisorProcessIdentity, providerIdentity: SupervisorProcessIdentity) {
        self.paneID = paneID; self.generation = generation; self.conversationID = conversationID; self.cwd = cwd; self.configurationRoot = configurationRoot
        self.provider = provider; self.accountID = accountID; self.backendPID = backendPID; self.providerPID = providerPID; self.backendIdentity = backendIdentity; self.providerIdentity = providerIdentity
    }
}

public struct TwinCompletion: Codable, Equatable {
    public let id: String
    public let turnID: String
    public let completedAt: Date
    public let inputRevision: UInt64
    public init(id: String, turnID: String, completedAt: Date, inputRevision: UInt64) { self.id = id; self.turnID = turnID; self.completedAt = completedAt; self.inputRevision = inputRevision }
}

public struct TwinGitSnapshot: Codable, Equatable {
    public let runID: String
    public let round: Int
    public let repositoryRoot: String
    public let sourceCWD: String
    public let sourceGitDirectory: String
    public let commonDirectory: String
    public let sourceBranch: String
    public let sourceHEAD: String
    public let sourceIndexSHA256: String
    public let sourceTree: String
    public let snapshotCommit: String
    public let twinBranch: String
    public let worktreePath: String
    public let ownership: WorktreeIdentity
    public init(runID: String, round: Int, repositoryRoot: String, sourceCWD: String, sourceGitDirectory: String, commonDirectory: String, sourceBranch: String, sourceHEAD: String, sourceIndexSHA256: String, sourceTree: String, snapshotCommit: String, twinBranch: String, worktreePath: String, ownership: WorktreeIdentity) {
        self.runID = runID; self.round = round; self.repositoryRoot = repositoryRoot; self.sourceCWD = sourceCWD; self.sourceGitDirectory = sourceGitDirectory; self.commonDirectory = commonDirectory
        self.sourceBranch = sourceBranch; self.sourceHEAD = sourceHEAD; self.sourceIndexSHA256 = sourceIndexSHA256; self.sourceTree = sourceTree; self.snapshotCommit = snapshotCommit
        self.twinBranch = twinBranch; self.worktreePath = worktreePath; self.ownership = ownership
    }
}

public struct TwinPaneBinding: Codable, Equatable {
    public let paneID: String
    public let generation: String
    public let backendPID: Int32
    public let backendIdentity: SupervisorProcessIdentity
    public var conversationID: String?
    public init(paneID: String, generation: String, backendPID: Int32, backendIdentity: SupervisorProcessIdentity, conversationID: String? = nil) {
        self.paneID = paneID; self.generation = generation; self.backendPID = backendPID; self.backendIdentity = backendIdentity; self.conversationID = conversationID
    }
    public func matchesProcess(_ other: TwinPaneBinding) -> Bool {
        paneID == other.paneID && generation == other.generation && backendPID == other.backendPID && backendIdentity == other.backendIdentity
    }
}

public struct TwinReport: Codable, Equatable {
    public let status: String
    public let rationale: String
    public let changedFiles: [String]
    public let additionalFields: [String: JSONValue]
    public init(status: String, rationale: String, changedFiles: [String], additionalFields: [String: JSONValue] = [:]) {
        self.status = status; self.rationale = rationale; self.changedFiles = changedFiles; self.additionalFields = additionalFields
    }
    public init(from decoder: Decoder) throws {
        let object = try decoder.singleValueContainer().decode([String: JSONValue].self)
        guard case .string(let status)? = object["status"], case .string(let rationale)? = object["rationale"], case .array(let paths)? = object["changed_files"] else {
            throw TerminalError.invalid("Twin output requires status, rationale and changed_files")
        }
        var names: [String] = []
        for value in paths { guard case .string(let text) = value else { throw TerminalError.invalid("Twin changed_files must be strings") }; names.append(text) }
        self.init(status: status, rationale: rationale, changedFiles: names, additionalFields: object.filter { !["status", "rationale", "changed_files"].contains($0.key) })
        try validate()
    }
    public func encode(to encoder: Encoder) throws {
        var object = additionalFields
        object["status"] = .string(status); object["rationale"] = .string(rationale); object["changed_files"] = .array(changedFiles.map(JSONValue.string))
        var box = encoder.singleValueContainer(); try box.encode(object)
    }
    public func validate() throws {
        guard ["working", "no_further_improvement"].contains(status),
              status != "no_further_improvement" || changedFiles.isEmpty,
              !rationale.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, rationale.utf8.count <= 8192,
              !rationale.utf8.contains(0), changedFiles.count <= 256,
              Set(changedFiles).count == changedFiles.count,
              changedFiles.allSatisfy(Self.validRelativePath),
              !additionalFields.keys.contains(where: { ["status", "rationale", "changed_files"].contains($0) }),
              try JSONEncoder().encode(self).count <= 16_384 else {
            throw TerminalError.invalid("Twin output has an unsupported status, rationale, path or size")
        }
    }
    public static func validRelativePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.utf8.contains(0) && path.utf8.count <= 1024
            && !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }
    public static func decode(_ data: Data) throws -> TwinReport {
        guard data.count <= 16_384 else { throw TerminalError.invalid("Twin report exceeds 16 KiB") }
        return try JSONDecoder().decode(TwinReport.self, from: data)
    }
}

public struct TwinConsent: Codable, Equatable {
    public let choice: TwinChoice
    public let decisionID: String
    public let twinTip: String
    public let sourceCompletionID: String?
    public let chosenAt: Date
    public init(choice: TwinChoice, decisionID: String, twinTip: String, sourceCompletionID: String?, chosenAt: Date = Date()) {
        self.choice = choice; self.decisionID = decisionID; self.twinTip = twinTip; self.sourceCompletionID = sourceCompletionID; self.chosenAt = chosenAt
    }
}

public struct TwinDecisionBinding: Codable, Equatable {
    public let decisionID: String
    public let runID: String
    public let round: Int
    public let sourceGeneration: String
    public let snapshotOID: String
    public let twinTipOID: String
    public init(decisionID: String, runID: String, round: Int, sourceGeneration: String, snapshotOID: String, twinTipOID: String) {
        self.decisionID = decisionID; self.runID = runID; self.round = round; self.sourceGeneration = sourceGeneration; self.snapshotOID = snapshotOID; self.twinTipOID = twinTipOID
    }
}

public enum TwinDecisionID {
    public static func isReserved(_ id: String) -> Bool { UUID(uuidString: id) != nil && id.lowercased().hasPrefix("7477696e-") }
    public static func make(runID: String, round: Int) -> String {
        let digest = Array(SHA256.hash(data: Data("trano-twin:\(runID):\(round)".utf8)))
        var bytes = Array([UInt8](arrayLiteral: 0x74, 0x77, 0x69, 0x6e) + digest.prefix(12))
        bytes[6] = (bytes[6] & 0x0f) | 0x50; bytes[8] = (bytes[8] & 0x3f) | 0x80
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let cuts = [8, 12, 16, 20, 32]; var start = hex.startIndex; var parts: [String] = []
        for cut in cuts { let end = hex.index(hex.startIndex, offsetBy: cut); parts.append(String(hex[start..<end])); start = end }
        return parts.joined(separator: "-")
    }
}

public struct TwinOperationIntent: Codable, Equatable {
    public let id: String
    public let kind: TwinOperationKind
    public let round: Int
    public let startedAt: Date
    public init(id: String = UUID().uuidString.lowercased(), kind: TwinOperationKind, round: Int, startedAt: Date = Date()) {
        self.id = id; self.kind = kind; self.round = round; self.startedAt = startedAt
    }
}

public struct TwinRound: Codable, Equatable {
    public let number: Int
    public var snapshot: TwinGitSnapshot?
    public var pane: TwinPaneBinding?
    public var report: TwinReport?
    public var tip: String?
    public var decisionID: String?
    public var consent: TwinConsent?
    public var sourceResponse: TwinReport?
    public var forwardedID: String?
    public var lastSourceCompletionID: String?
    public var message: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var reportedAt: Date?
    public var reportedTurnID: String?
    public var sourceCompletion: TwinCompletion?
    public var reviewCompletion: TwinCompletion?
    public var sourceResponseAt: Date?
    public var responseCompletion: TwinCompletion?
    public var mergedCommit: String?
    public var cleaned: Bool
    public init(number: Int, snapshot: TwinGitSnapshot? = nil, pane: TwinPaneBinding? = nil, report: TwinReport? = nil, tip: String? = nil, decisionID: String? = nil, consent: TwinConsent? = nil, sourceResponse: TwinReport? = nil, forwardedID: String? = nil, lastSourceCompletionID: String? = nil, message: String? = nil, createdAt: Date = Date(), updatedAt: Date? = nil, sourceCompletion: TwinCompletion? = nil, reviewCompletion: TwinCompletion? = nil, sourceResponseAt: Date? = nil, responseCompletion: TwinCompletion? = nil, mergedCommit: String? = nil, cleaned: Bool = false, reportedAt: Date? = nil, reportedTurnID: String? = nil) {
        self.number = number; self.snapshot = snapshot; self.pane = pane; self.report = report; self.tip = tip; self.decisionID = decisionID; self.consent = consent
        self.sourceResponse = sourceResponse; self.forwardedID = forwardedID; self.lastSourceCompletionID = lastSourceCompletionID; self.message = message; self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt
        self.reportedAt = reportedAt; self.reportedTurnID = reportedTurnID
        self.sourceCompletion = sourceCompletion; self.reviewCompletion = reviewCompletion; self.sourceResponseAt = sourceResponseAt; self.responseCompletion = responseCompletion; self.mergedCommit = mergedCommit; self.cleaned = cleaned
    }
}

public struct TwinRun: Codable, Equatable, Identifiable {
    public let id: String
    public let source: TwinSourceBinding
    public let mode: TwinReviewMode
    public let roundCap: Int
    public let noopCap: Int
    public var rounds: [TwinRound]
    public var phase: TwinPhase
    public var exitReason: TwinExitReason?
    public var message: String?
    public var createdAt: Date
    public var updatedAt: Date
    public let enabledCompletionID: String?
    public var operation: TwinOperationIntent?
    public init(id: String = UUID().uuidString.lowercased(), source: TwinSourceBinding, mode: TwinReviewMode, roundCap: Int = 3, noopCap: Int = 2, rounds: [TwinRound] = [], phase: TwinPhase = .waitingForSource, exitReason: TwinExitReason? = nil, message: String? = nil, createdAt: Date = Date(), updatedAt: Date? = nil, enabledCompletionID: String? = nil, operation: TwinOperationIntent? = nil) {
        self.id = id; self.source = source; self.mode = mode; self.roundCap = roundCap; self.noopCap = noopCap; self.rounds = rounds; self.phase = phase; self.exitReason = exitReason; self.message = message
        self.createdAt = createdAt; self.updatedAt = updatedAt ?? createdAt; self.enabledCompletionID = enabledCompletionID; self.operation = operation
    }
    public var currentRound: Int { rounds.last?.number ?? 1 }
    public var latestRound: TwinRound? { rounds.last }
    public var isActive: Bool { phase != .finished }
}

public struct TwinForwardReceipt: Codable, Equatable {
    public let key: String
    public let runID: String
    public let round: Int
    public let paneID: String
    public let generation: String
    public let inputID: String
    public let createdAt: Date
    public init(key: String, runID: String, round: Int, paneID: String, generation: String, inputID: String, createdAt: Date = Date()) {
        self.key = key; self.runID = runID; self.round = round; self.paneID = paneID; self.generation = generation; self.inputID = inputID; self.createdAt = createdAt
    }
}

public struct TwinState: Codable, Equatable {
    public var schemaVersion = 1
    public var runs: [TwinRun]
    public var decisionBindings: [TwinDecisionBinding]
    public var forwardReceipts: [TwinForwardReceipt]
    public init(runs: [TwinRun] = [], decisionBindings: [TwinDecisionBinding] = [], forwardReceipts: [TwinForwardReceipt] = []) {
        self.runs = runs; self.decisionBindings = decisionBindings; self.forwardReceipts = forwardReceipts
    }
    public func decisionBinding(id: String) -> TwinDecisionBinding? { decisionBindings.first { $0.decisionID == id } }
    public func protectsDecision(_ id: String) -> Bool { TwinDecisionID.isReserved(id) || decisionBinding(id: id) != nil }
    public var reservedWorktrees: [String] { runs.filter(\.isActive).flatMap { $0.rounds.compactMap { $0.cleaned ? nil : $0.snapshot?.worktreePath } } }
    public var reservedPaneIDs: Set<String> { Set(runs.filter(\.isActive).flatMap { $0.rounds.compactMap { $0.cleaned ? nil : $0.pane?.paneID } }) }
}
