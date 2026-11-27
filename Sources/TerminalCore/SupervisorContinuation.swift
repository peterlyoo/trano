import Foundation

public enum SupervisorInputReadinessState: String, Codable {
    case ready, inputInFlight = "input_in_flight", inputReviewRequired = "input_review_required", changed
}

public struct SupervisorInputReadinessSummary: Codable, Equatable {
    public let state: SupervisorInputReadinessState
    public let revision: UInt64?
    public init(state: SupervisorInputReadinessState, revision: UInt64? = nil) { self.state = state; self.revision = revision }
    public init(_ readiness: TerminalInputReadiness) {
        switch readiness {
        case .ready(let lease): state = .ready; revision = lease.revision
        case .inputInFlight: state = .inputInFlight; revision = nil
        case .inputReviewRequired: state = .inputReviewRequired; revision = nil
        case .changed: state = .changed; revision = nil
        }
    }
}

public struct SupervisorContinuationIdentity: Codable, Equatable {
    public let paneID: String
    public let backendPID: Int32
    public let backendIdentity: SupervisorProcessIdentity
    public let generation: String
    public let provider: AgentKind
    public let providerPID: Int32
    public let providerIdentity: SupervisorProcessIdentity
    public let providerExecutable: String?
    public let providerSessionID: String
    public let configurationRoot: String
    public let cwd: String
    public let accountID: String?

    public init(paneID: String, backendPID: Int32, backendIdentity: SupervisorProcessIdentity,
                generation: String, provider: AgentKind, providerPID: Int32, providerIdentity: SupervisorProcessIdentity,
                providerSessionID: String, configurationRoot: String, cwd: String, accountID: String? = nil,
                providerExecutable: String? = nil) {
        self.paneID = paneID; self.backendPID = backendPID; self.backendIdentity = backendIdentity
        self.generation = generation; self.provider = provider; self.providerPID = providerPID
        self.providerIdentity = providerIdentity; self.providerSessionID = providerSessionID
        self.configurationRoot = configurationRoot; self.cwd = cwd; self.accountID = accountID
        self.providerExecutable = providerExecutable
    }
}

public struct SupervisorContinuationAuthority: Codable, Equatable {
    public let binding: SupervisorBinding
    public let launch: SupervisorContinuationIdentity
    public init(binding: SupervisorBinding, launch: SupervisorContinuationIdentity) { self.binding = binding; self.launch = launch }
}

public struct SupervisorContinuationOffer: Codable, Equatable {
    public let target: SupervisorContinuationIdentity
    public let completionID: String
    public let lease: TerminalInputLease
    public init(target: SupervisorContinuationIdentity, completionID: String, lease: TerminalInputLease) {
        self.target = target; self.completionID = completionID; self.lease = lease
    }
}

public struct SupervisorContinuationRequest: Codable, Equatable {
    public let authority: SupervisorContinuationAuthority
    public let offer: SupervisorContinuationOffer
    public let text: String
    public init(authority: SupervisorContinuationAuthority, offer: SupervisorContinuationOffer, text: String) {
        self.authority = authority; self.offer = offer; self.text = text
    }
}

public struct SupervisorContinuationCandidate {
    public let target: SupervisorContinuationIdentity
    public let readiness: TerminalInputReadiness
    public var activity: ActivityState
    public var activitySource: String
    public var alive: Bool
    public var local: Bool
    public var completionID: String?
    public var consumedCompletionID: String?
    public var completedAt: Date?
    public var completionOriginExited: Bool
    public var completionProviderVerified: Bool
    public var pendingDecision: Bool
    public var queuedInput: Bool
    public var quotaHandoff: Bool
    public var quotaLimited: Bool
    public var safeTurnBoundary: Bool

    public init(target: SupervisorContinuationIdentity, readiness: TerminalInputReadiness,
                activity: ActivityState = .unknown, activitySource: String = "unknown", alive: Bool = true, local: Bool = true,
                completionID: String? = nil, consumedCompletionID: String? = nil, completedAt: Date? = nil,
                completionOriginExited: Bool = false, completionProviderVerified: Bool = false,
                pendingDecision: Bool = false, queuedInput: Bool = false, quotaHandoff: Bool = false,
                quotaLimited: Bool = false, safeTurnBoundary: Bool = false) {
        self.target = target; self.readiness = readiness; self.activity = activity; self.activitySource = activitySource
        self.alive = alive; self.local = local; self.completionID = completionID; self.consumedCompletionID = consumedCompletionID
        self.completedAt = completedAt; self.completionOriginExited = completionOriginExited
        self.completionProviderVerified = completionProviderVerified; self.pendingDecision = pendingDecision
        self.queuedInput = queuedInput; self.quotaHandoff = quotaHandoff; self.quotaLimited = quotaLimited
        self.safeTurnBoundary = safeTurnBoundary
    }

    public func offer(now: Date) -> SupervisorContinuationOffer? {
        guard target.isValid, alive, local, activity == .done, activitySource == "hook", safeTurnBoundary,
              !pendingDecision, !queuedInput, !quotaHandoff, !quotaLimited,
              let completionID, UUID(uuidString: completionID) != nil, completionID != consumedCompletionID,
              let completedAt, now.timeIntervalSince(completedAt).isFinite, now.timeIntervalSince(completedAt) >= 0.25,
              completionOriginExited, completionProviderVerified, let lease = readiness.lease,
              lease.binding == TerminalInputBinding(paneID: target.paneID, backendPID: target.backendPID,
                  generation: target.generation, providerPID: target.providerPID) else { return nil }
        return SupervisorContinuationOffer(target: target, completionID: completionID, lease: lease)
    }
}

public struct SupervisorContinuationContext {
    public let authority: SupervisorContinuationAuthority?
    public let candidates: [SupervisorContinuationCandidate]
    public init(authority: SupervisorContinuationAuthority?, candidates: [SupervisorContinuationCandidate]) {
        self.authority = authority; self.candidates = candidates
    }
}

public struct SupervisorContinuationResult: Codable, Equatable {
    public let paneID: String
    public let generation: String
    public let completionID: String
    public init(paneID: String, generation: String, completionID: String) {
        self.paneID = paneID; self.generation = generation; self.completionID = completionID
    }
}

public protocol SupervisorContinuationBackend: AnyObject {
    func transaction<T>(_ body: () throws -> T) throws -> T
    func continuationContext() throws -> SupervisorContinuationContext
    func reserveAndCommit(_ request: SupervisorContinuationRequest) throws
    func reviewInput(authority: SupervisorContinuationAuthority, target: SupervisorContinuationIdentity) throws
}

public final class SupervisorContinuationCoordinator<Backend: SupervisorContinuationBackend> {
    private let backend: Backend
    private let now: () -> Date
    public init(backend: Backend, now: @escaping () -> Date = Date.init) { self.backend = backend; self.now = now }

    public func continueWork(_ request: SupervisorContinuationRequest) throws -> SupervisorContinuationResult {
        guard !request.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, request.text.utf8.count <= 65_536,
              !request.text.unicodeScalars.contains(where: { ($0.value < 32 && $0 != "\n" && $0 != "\t") || (127...159).contains($0.value) }) else {
            throw TerminalError.invalid("Enter nonblank continuation text of at most 64 KiB without terminal controls")
        }
        return try backend.transaction {
            let context = try backend.continuationContext()
            let candidate = try requireTarget(context: context, authority: request.authority, target: request.offer.target)
            guard candidate.offer(now: now()) == request.offer else {
                throw TerminalError.invalid("The completed turn or terminal input changed; review the session before continuing")
            }
            try backend.reserveAndCommit(request)
            return SupervisorContinuationResult(paneID: request.offer.target.paneID,
                generation: request.offer.target.generation, completionID: request.offer.completionID)
        }
    }

    public func review(authority: SupervisorContinuationAuthority, target: SupervisorContinuationIdentity) throws {
        try backend.transaction {
            _ = try requireTarget(context: backend.continuationContext(), authority: authority, target: target)
            try backend.reviewInput(authority: authority, target: target)
        }
    }

    public func validateTarget(authority: SupervisorContinuationAuthority, target: SupervisorContinuationIdentity) throws {
        try backend.transaction {
            _ = try requireTarget(context: backend.continuationContext(), authority: authority, target: target)
        }
    }

    private func requireTarget(context: SupervisorContinuationContext, authority: SupervisorContinuationAuthority,
                               target: SupervisorContinuationIdentity) throws -> SupervisorContinuationCandidate {
        guard authority.isValid, context.authority == authority, target.isValid,
              target.paneID != authority.launch.paneID, context.candidates.count <= 4096 else {
            throw TerminalError.invalid("The Supervisor or target process changed; refresh before continuing")
        }
        let matching = context.candidates.filter { $0.target.paneID == target.paneID }
        guard matching.count == 1, let candidate = matching.first, candidate.target == target, candidate.local, candidate.alive else {
            throw TerminalError.invalid("The target session changed; it was not adopted or modified")
        }
        return candidate
    }
}

extension SupervisorContinuationIdentity {
    var isValid: Bool {
        UUID(uuidString: paneID) != nil && UUID(uuidString: generation) != nil && UUID(uuidString: providerSessionID) != nil &&
            provider != .shell && backendPID > 1 && providerPID > 1 && backendIdentity.pid == backendPID &&
            providerIdentity.pid == providerPID && backendIdentity.ownerUID == providerIdentity.ownerUID &&
            backendIdentity.startedAtSeconds > 0 && providerIdentity.startedAtSeconds > 0 &&
            backendIdentity.startedAtMicroseconds < 1_000_000 && providerIdentity.startedAtMicroseconds < 1_000_000 &&
            (providerExecutable.map { $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") } ?? false) &&
            [configurationRoot, cwd].allSatisfy { $0.hasPrefix("/") && $0.utf8.count <= 4096 && !$0.contains("\0") } &&
            (accountID.map { UUID(uuidString: $0) != nil } ?? true)
    }
}

extension SupervisorContinuationAuthority {
    var isValid: Bool {
        binding.stoppedAt == nil && launch.isValid && binding.paneID == launch.paneID &&
            binding.backendPID == launch.backendPID && binding.processIdentity == launch.backendIdentity &&
            binding.configuration.provider == launch.provider
    }
}
