import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum SupervisorPhase: String, Codable {
    case notStarted = "not_started"
    case starting, running
    case needsAttention = "needs_attention"
    case stopped
}

public struct SupervisorConfiguration: Codable, Equatable {
    public let provider: AgentKind
    public let accountID: String?
    public let cwd: String

    public init(provider: AgentKind, accountID: String? = nil, cwd: String) {
        self.provider = provider
        self.accountID = accountID
        self.cwd = cwd
    }
}

public struct SupervisorBinding: Codable, Equatable {
    public var schemaVersion = 1
    public let paneID: String
    public let backendPID: Int32
    public let configuration: SupervisorConfiguration
    public let createdAt: Date
    public var stoppedAt: Date?
    public let processIdentity: SupervisorProcessIdentity?

    public init(paneID: String, backendPID: Int32, configuration: SupervisorConfiguration,
                createdAt: Date = Date(), stoppedAt: Date? = nil, processIdentity: SupervisorProcessIdentity? = nil) {
        self.paneID = paneID
        self.backendPID = backendPID
        self.configuration = configuration
        self.createdAt = createdAt
        self.stoppedAt = stoppedAt
        self.processIdentity = processIdentity
    }
}

public struct SupervisorObservation {
    public var layout: WorkspaceLayout
    public var sessions: [TerminalSession]
    public var launches: [AgentLaunch]
    public var accounts: [AccountProfile]
    public var pendingDecisionPaneIDs: Set<String>
    public var limitedAccountIDs: Set<String>
    public var backendIdentities: [String: SupervisorProcessIdentity]
    public var continuationContext: SupervisorContinuationContext?

    public init(layout: WorkspaceLayout = WorkspaceLayout(), sessions: [TerminalSession] = [],
                launches: [AgentLaunch] = [], accounts: [AccountProfile] = [],
                pendingDecisionPaneIDs: Set<String> = [], limitedAccountIDs: Set<String> = [],
                backendIdentities: [String: SupervisorProcessIdentity] = [:],
                continuationContext: SupervisorContinuationContext? = nil) {
        self.layout = layout
        self.sessions = sessions
        self.launches = launches
        self.accounts = accounts
        self.pendingDecisionPaneIDs = pendingDecisionPaneIDs
        self.limitedAccountIDs = limitedAccountIDs
        self.backendIdentities = backendIdentities
        self.continuationContext = continuationContext
    }
}

public enum SupervisorContinuationDisposition: String, Codable {
    case working, ready, decisionRequired = "decision_required", quotaLimited = "quota_limited"
    case inputReviewRequired = "input_review_required"
}

public struct SupervisorTarget: Codable, Equatable {
    public let paneID: String
    public let backendPID: Int32
    public let alive: Bool
    public let title: String
    public let provider: AgentKind
    public let activity: ActivityState
    public let generation: String?
    public let pendingDecision: Bool
    public let quotaLimited: Bool
    public let continuation: SupervisorContinuationDisposition
    public var reference: SupervisorContinuationIdentity? = nil
    public var inputReadiness: SupervisorInputReadinessSummary? = nil
    public var continuationOffer: SupervisorContinuationOffer? = nil
}

public struct SupervisorWatchTarget: Codable, Equatable {
    public let paneID: String
    public let backendPID: Int32
    public let alive: Bool
    public let provider: AgentKind
    public let activity: ActivityState
    public let generation: String?
    public let pendingDecision: Bool
    public let quotaLimited: Bool
    public var inputReadiness: SupervisorInputReadinessSummary? = nil
}

public struct SupervisorWatchCursor: Codable, Equatable {
    public let targets: [SupervisorWatchTarget]
    public init(targets: [SupervisorWatchTarget] = []) { self.targets = targets }
}

public struct SupervisorState: Codable, Equatable {
    public let phase: SupervisorPhase
    public let binding: SupervisorBinding?
    public let targets: [SupervisorTarget]
    public let cursor: SupervisorWatchCursor
    public let message: String?
    public var continuationAuthority: SupervisorContinuationAuthority? = nil
}

public struct SupervisorLaunchPlan: Equatable {
    public let arguments: [String]
    public init(arguments: [String]) { self.arguments = arguments }
}

public enum SupervisorPaneReservation: Equatable {
    case absent
    case bound(String)
    case unavailable

    public func permitsDetachedStartupReuse(_ paneID: String) -> Bool {
        switch self {
        case .absent: return true
        case .bound(let reserved): return paneID != reserved
        case .unavailable: return false
        }
    }

    public func permitsGenericRecovery(_ paneID: String, attachedPaneIDs: Set<String>) -> Bool {
        switch self {
        case .absent: return true
        case .bound(let reserved): return paneID != reserved
        case .unavailable: return attachedPaneIDs.contains(paneID)
        }
    }
}

public protocol SupervisorBackend: AnyObject {
    func transaction<T>(_ body: () throws -> T) throws -> T
    func observe() throws -> SupervisorObservation
    func createDetached(cwd: String) throws -> TerminalSession
    func launch(paneID: String, plan: SupervisorLaunchPlan) throws
    func terminate(paneID: String) throws
    func processIdentity(paneID: String, backendPID: Int32) throws -> SupervisorProcessIdentity?
}

extension SupervisorBackend {
    public func processIdentity(paneID: String, backendPID: Int32) throws -> SupervisorProcessIdentity? { nil }
}

public final class SupervisorStateStore {
    public let root: URL
    public var url: URL { root.appendingPathComponent("supervisor.json") }
    private let lock = NSRecursiveLock()
    private let maximumBytes = 65_536
    public init(root: URL) { self.root = root }

    public func load() throws -> SupervisorBinding? {
        lock.lock(); defer { lock.unlock() }
        return try readPublishedBinding()
    }

    public func readPublishedBinding() throws -> SupervisorBinding? {
        let directory = try openRoot()
        defer { close(directory) }
        guard let data = try readData(in: directory) else { return nil }
        let binding: SupervisorBinding?
        do { binding = try JSONDecoder().decode(SupervisorBinding?.self, from: data) }
        catch { throw TerminalError.invalid("Supervisor state is not valid JSON") }
        if let binding { try validate(binding) }
        return binding
    }

    public func reservation() -> SupervisorPaneReservation {
        do { return try load().map { .bound($0.paneID) } ?? .absent }
        catch { return .unavailable }
    }

    public func save(_ binding: SupervisorBinding?) throws {
        lock.lock(); defer { lock.unlock() }
        if let binding { try validate(binding) }
        let directory = try openRoot()
        defer { close(directory) }
        _ = try readData(in: directory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(binding)
        data.append(10)
        guard data.count <= maximumBytes else { throw TerminalError.invalid("Supervisor state exceeds 64 KiB") }
        let temporary = ".supervisor-write-" + UUID().uuidString.lowercased()
        let descriptor = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TerminalError.runtime("Cannot create private Supervisor state") }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TerminalError.runtime("Cannot write Supervisor state") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, renameat(directory, temporary, directory, "supervisor.json") == 0 else {
            throw TerminalError.runtime("Cannot replace Supervisor state")
        }
    }

    private func openRoot() throws -> Int32 {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TerminalError.invalid("Supervisor runtime must be a private owned directory") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor)
            throw TerminalError.invalid("Supervisor runtime must be a private owned directory")
        }
        return descriptor
    }

    private func readData(in directory: Int32) throws -> Data? {
        let descriptor = openat(directory, "supervisor.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw TerminalError.invalid("Cannot open private Supervisor state") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw TerminalError.invalid("Supervisor state must be a private owned regular file of at most 64 KiB")
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.runtime("Cannot read Supervisor state") }
            if count == 0 { return data }
            guard data.count + count <= maximumBytes else { throw TerminalError.invalid("Supervisor state exceeds 64 KiB") }
            data.append(contentsOf: bytes.prefix(count))
        }
    }

    private func validate(_ binding: SupervisorBinding) throws {
        guard binding.schemaVersion == 1, UUID(uuidString: binding.paneID) != nil, binding.backendPID > 1,
              binding.configuration.provider != .shell,
              binding.configuration.cwd.hasPrefix("/"), !binding.configuration.cwd.contains("\0"),
              binding.configuration.cwd.utf8.count <= 4096,
              binding.configuration.accountID.map({ UUID(uuidString: $0) != nil }) ?? true else {
            throw TerminalError.invalid("Supervisor binding is invalid or uses an unsupported schema")
        }
        if let identity = binding.processIdentity {
            guard identity.pid == binding.backendPID, identity.ownerUID == getuid(),
                  identity.startedAtSeconds > 0, identity.startedAtMicroseconds < 1_000_000 else {
                throw TerminalError.invalid("Supervisor process birth identity is invalid")
            }
        }
    }
}

public enum SupervisorProjection {
    public static func state(binding: SupervisorBinding?, observation: SupervisorObservation, now: Date = Date()) -> SupervisorState {
        let context = observation.continuationContext
        func matches(_ reference: SupervisorContinuationIdentity, pane: TerminalSession, launch: AgentLaunch?) -> Bool {
            guard let launch else { return false }
            return reference.paneID == pane.id && reference.backendPID == pane.pid && launch.lifecycle == .active &&
                reference.generation == launch.id && reference.provider == launch.provider && reference.providerPID == launch.providerPID &&
                reference.providerSessionID == launch.providerSessionID && reference.configurationRoot == launch.configurationRoot &&
                reference.cwd == launch.cwd && reference.accountID == launch.accountID && pane.remote == nil && pane.alive
        }
        let authority = context?.authority.flatMap { value -> SupervisorContinuationAuthority? in
            let ownPanes = observation.sessions.filter { $0.id == value.launch.paneID }
            let ownLaunches = observation.launches.filter { $0.paneID == value.launch.paneID && $0.lifecycle == .active }
            guard value.binding == binding, value.isValid, ownPanes.count == 1, let pane = ownPanes.first,
                  ownLaunches.count == 1, matches(value.launch, pane: pane, launch: ownLaunches.first),
                  observation.backendIdentities[pane.id] == value.launch.backendIdentity,
                  !observation.pendingDecisionPaneIDs.contains(pane.id), ![ActivityState.blocked, .error].contains(pane.activity.state) else { return nil }
            return value
        }
        let candidates = Dictionary(grouping: context?.candidates ?? [], by: { $0.target.paneID })
        var seen: Set<String> = []
        let targets = observation.sessions.filter { $0.id != binding?.paneID && seen.insert($0.id).inserted }
            .sorted { $0.id < $1.id }.map { pane in
                let launch = observation.launches.filter { $0.paneID == pane.id && $0.lifecycle == .active }
                    .max { $0.updatedAt < $1.updatedAt }
                let pending = observation.pendingDecisionPaneIDs.contains(pane.id)
                let limited = launch?.accountID.map(observation.limitedAccountIDs.contains) ?? false
                let candidateRows = candidates[pane.id] ?? []
                let candidate = candidateRows.count == 1 ? candidateRows.first.flatMap { matches($0.target, pane: pane, launch: launch) ? $0 : nil } : nil
                let offer = authority == nil ? nil : candidate?.offer(now: now)
                let disposition: SupervisorContinuationDisposition
                if !pane.alive { disposition = .inputReviewRequired }
                else if pending { disposition = .decisionRequired }
                else if limited { disposition = .quotaLimited }
                else if pane.activity.state == .running { disposition = .working }
                else if offer != nil { disposition = .ready }
                else { disposition = .inputReviewRequired }
                var row = SupervisorTarget(paneID: pane.id, backendPID: pane.pid, alive: pane.alive,
                                        title: pane.displayTitle, provider: launch?.provider ?? pane.agent,
                                        activity: pane.activity.state, generation: launch?.id,
                                        pendingDecision: pending, quotaLimited: limited, continuation: disposition)
                if candidate?.target.backendPID == pane.pid, candidate?.target.generation == launch?.id {
                    row.reference = candidate?.target
                    row.inputReadiness = candidate.map { SupervisorInputReadinessSummary($0.readiness) }
                    row.continuationOffer = disposition == .ready ? offer : nil
                }
                return row
            }
        let cursor = SupervisorWatchCursor(targets: targets.map {
            SupervisorWatchTarget(paneID: $0.paneID, backendPID: $0.backendPID, alive: $0.alive,
                                  provider: $0.provider, activity: $0.activity, generation: $0.generation,
                                  pendingDecision: $0.pendingDecision, quotaLimited: $0.quotaLimited, inputReadiness: $0.inputReadiness)
        })
        func result(_ phase: SupervisorPhase, _ message: String? = nil) -> SupervisorState {
            var value = SupervisorState(phase: phase, binding: binding, targets: targets, cursor: cursor, message: message)
            value.continuationAuthority = authority
            return value
        }
        guard let binding else { return result(.notStarted) }
        let pane = observation.sessions.first { $0.id == binding.paneID }
        if binding.stoppedAt != nil {
            return pane?.alive == true
                ? result(.needsAttention, "A stopped Supervisor binding still has a running session.")
                : result(.stopped)
        }
        guard let pane else { return result(.needsAttention, "The Supervisor session is no longer available. Review it before starting another.") }
        guard pane.pid == binding.backendPID, pane.remote == nil else {
            return result(.needsAttention, "The Supervisor process identity changed. Review it before resuming.")
        }
        guard let expected = binding.processIdentity, observation.backendIdentities[pane.id] == expected else {
            return result(.needsAttention, "The Supervisor process birth identity is unavailable or changed. Review it before resuming.")
        }
        guard pane.alive else { return result(.needsAttention, "The Supervisor exited. Review its recorded conversation before stopping or restarting it explicitly.") }
        if observation.pendingDecisionPaneIDs.contains(pane.id) || [.blocked, .error].contains(pane.activity.state) {
            return result(.needsAttention)
        }
        let launch = observation.launches.filter { $0.paneID == pane.id && $0.lifecycle == .active }
            .max { $0.updatedAt < $1.updatedAt }
        guard let launch else { return result(.starting) }
        guard launch.provider == binding.configuration.provider else {
            return result(.needsAttention, "A different provider is running in the Supervisor session.")
        }
        return result(launch.providerPID == nil ? .starting : .running)
    }
}

public final class SupervisorCoordinator<Backend: SupervisorBackend> {
    public let store: SupervisorStateStore
    private let backend: Backend
    private let helperExecutable: String

    public init(store: SupervisorStateStore, backend: Backend, helperExecutable: String) {
        self.store = store
        self.backend = backend
        self.helperExecutable = helperExecutable
    }

    public func state() throws -> SupervisorState {
        try backend.transaction {
            SupervisorProjection.state(binding: try store.load(), observation: try backend.observe())
        }
    }

    public func start(configuration: SupervisorConfiguration, instructions: String) throws -> SupervisorState {
        try backend.transaction {
            let observation = try backend.observe()
            let plan = try launchPlan(configuration: configuration, instructions: instructions, observation: observation)
            let previous = try store.load()
            if let previous {
                let pane = observation.sessions.first { $0.id == previous.paneID }
                if previous.stoppedAt == nil {
                    guard let pane, pane.alive, pane.pid == previous.backendPID, pane.remote == nil else {
                        throw TerminalError.invalid("The Supervisor session changed or exited. Review its recovery before starting another.")
                    }
                    guard let expected = previous.processIdentity, observation.backendIdentities[pane.id] == expected else {
                        throw TerminalError.invalid("The Supervisor process birth identity changed. It was not resumed.")
                    }
                    guard equivalent(previous.configuration, configuration) else {
                        throw TerminalError.invalid("Stop the current Supervisor before changing its provider, account or directory.")
                    }
                    return SupervisorProjection.state(binding: previous, observation: observation)
                }
                guard pane?.alive != true else { throw TerminalError.invalid("The stopped Supervisor still has a running session") }
            }
            let pane = try backend.createDetached(cwd: configuration.cwd)
            guard UUID(uuidString: pane.id) != nil, pane.pid > 1, pane.remote == nil,
                  !observation.sessions.contains(where: { $0.id == pane.id }) else {
                throw TerminalError.runtime("The Supervisor backend did not create a fresh local session")
            }
            var saved = false
            do {
                guard let identity = try backend.processIdentity(paneID: pane.id, backendPID: pane.pid),
                      identity.pid == pane.pid, identity.ownerUID == getuid(),
                      identity.startedAtSeconds > 0, identity.startedAtMicroseconds < 1_000_000 else {
                    throw TerminalError.runtime("Cannot establish the new Supervisor process birth identity")
                }
                let binding = SupervisorBinding(paneID: pane.id, backendPID: pane.pid, configuration: configuration, processIdentity: identity)
                try store.save(binding)
                saved = true
                try backend.launch(paneID: pane.id, plan: plan)
                return SupervisorProjection.state(binding: binding, observation: try backend.observe())
            } catch {
                let original = error
                var rollbackFailed = false
                do {
                    if let current = try backend.observe().sessions.first(where: { $0.id == pane.id }) {
                        guard current.pid == pane.pid, current.remote == nil else { throw TerminalError.runtime("New Supervisor process identity changed") }
                        try backend.terminate(paneID: pane.id)
                    }
                } catch { rollbackFailed = true }
                if saved && !rollbackFailed {
                    do { try store.save(previous) } catch { rollbackFailed = true }
                }
                if rollbackFailed {
                    throw TerminalError.runtime("Supervisor launch failed; the new session \(pane.id) requires cleanup review.")
                }
                throw original
            }
        }
    }

    public func stop(expectedPaneID: String, expectedBackendPID: Int32) throws -> SupervisorState {
        try backend.transaction {
            guard var binding = try store.load(), binding.paneID == expectedPaneID,
                  binding.backendPID == expectedBackendPID else { throw TerminalError.invalid("The Supervisor selection changed") }
            let observation = try backend.observe()
            if let pane = observation.sessions.first(where: { $0.id == binding.paneID }) {
                guard pane.pid == binding.backendPID, pane.remote == nil else {
                    throw TerminalError.invalid("The Supervisor process identity changed; it was not stopped")
                }
                if pane.alive {
                    guard let expected = binding.processIdentity, observation.backendIdentities[pane.id] == expected else {
                        throw TerminalError.invalid("The Supervisor process birth identity changed; it was not stopped")
                    }
                }
                if binding.stoppedAt == nil { try backend.terminate(paneID: binding.paneID) }
                else if pane.alive { throw TerminalError.invalid("The stopped Supervisor still has a running session") }
            }
            if binding.stoppedAt == nil {
                binding.stoppedAt = Date()
                try store.save(binding)
            }
            return SupervisorProjection.state(binding: binding, observation: try backend.observe())
        }
    }

    private func launchPlan(configuration: SupervisorConfiguration, instructions: String,
                            observation: SupervisorObservation) throws -> SupervisorLaunchPlan {
        guard configuration.provider != .shell else { throw TerminalError.invalid("Choose Claude or Codex for the Supervisor") }
        guard helperExecutable.hasPrefix("/"), helperExecutable.utf8.count <= 4096,
              !helperExecutable.contains("\0"), !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instructions.utf8.count <= 32_768, !instructions.contains("\0") else {
            throw TerminalError.invalid("Supervisor instructions must be nonempty and fit in 32 KiB")
        }
        var directory: ObjCBool = false
        guard configuration.cwd.hasPrefix("/"), !configuration.cwd.contains("\0"), configuration.cwd.utf8.count <= 4096,
              FileManager.default.fileExists(atPath: configuration.cwd, isDirectory: &directory), directory.boolValue else {
            throw TerminalError.invalid("Choose an existing local directory for the Supervisor")
        }
        let arguments: [String]
        if let id = configuration.accountID {
            guard observation.accounts.contains(where: { $0.id == id && $0.provider == configuration.provider && $0.enabled }) else {
                throw TerminalError.invalid("Choose an enabled account for the selected provider")
            }
            arguments = [helperExecutable, "account", "exec", id, "--", instructions]
        } else {
            arguments = [helperExecutable, "run", "--agent", configuration.provider.rawValue, "--", instructions]
        }
        guard arguments.map(ShellQuote.quote).joined(separator: " ").utf8.count <= 65_536 else {
            throw TerminalError.invalid("Supervisor launch input exceeds 64 KiB")
        }
        return SupervisorLaunchPlan(arguments: arguments)
    }

    private func equivalent(_ first: SupervisorConfiguration, _ second: SupervisorConfiguration) -> Bool {
        first.provider == second.provider && first.accountID == second.accountID &&
            URL(fileURLWithPath: first.cwd).standardizedFileURL == URL(fileURLWithPath: second.cwd).standardizedFileURL
    }
}
