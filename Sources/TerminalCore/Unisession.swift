import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct UnisessionBinding: Codable, Equatable {
    public let paneID: String
    public let backendPID: Int32
    public let processIdentity: SupervisorProcessIdentity
    public init(paneID: String, backendPID: Int32, processIdentity: SupervisorProcessIdentity) {
        self.paneID = paneID; self.backendPID = backendPID; self.processIdentity = processIdentity
    }
}

public struct UnisessionRecord: Codable, Equatable {
    public var schemaVersion = 1
    public var binding: UnisessionBinding?
    public var pendingPaneID: String?
    public var reservedPaneIDs: Set<String>
    public init(binding: UnisessionBinding? = nil, pendingPaneID: String? = nil, reservedPaneIDs: Set<String> = []) {
        self.binding = binding; self.pendingPaneID = pendingPaneID
        self.reservedPaneIDs = reservedPaneIDs
        if let binding { self.reservedPaneIDs.insert(binding.paneID) }
        if let pendingPaneID { self.reservedPaneIDs.insert(pendingPaneID) }
    }
}

public enum UnisessionNavigationError: Error, LocalizedError, Equatable {
    case requiresOverlay(String)
    case unavailable
    public var errorDescription: String? {
        switch self {
        case .requiresOverlay: return "This terminal belongs to shared Unisession."
        case .unavailable: return "Unisession ownership is unavailable. Existing workspace panes remain accessible."
        }
    }
}

public enum DetachedPaneReservation: Equatable {
    case known(Set<String>), unavailable

    public func permitsDetachedStartupReuse(_ paneID: String) -> Bool {
        guard case .known(let reserved) = self else { return false }
        return !reserved.contains(paneID)
    }
    public func permitsGenericRecovery(_ paneID: String, attachedPaneIDs: Set<String>) -> Bool {
        switch self {
        case .known(let reserved): return !reserved.contains(paneID)
        case .unavailable: return attachedPaneIDs.contains(paneID)
        }
    }
    public func requireOrdinaryPane(_ paneID: String, attachedPaneIDs: Set<String>) throws {
        switch self {
        case .known(let reserved) where reserved.contains(paneID):
            throw UnisessionNavigationError.requiresOverlay(paneID)
        case .unavailable where !attachedPaneIDs.contains(paneID):
            throw UnisessionNavigationError.unavailable
        default: return
        }
    }
}

public struct UnisessionObservation {
    public var sessions: [TerminalSession]
    public var attachedPaneIDs: Set<String>
    public init(sessions: [TerminalSession] = [], attachedPaneIDs: Set<String> = []) {
        self.sessions = sessions; self.attachedPaneIDs = attachedPaneIDs
    }
}

public protocol UnisessionBackend: AnyObject {
    func transaction<T>(_ body: () throws -> T) throws -> T
    func observe() throws -> UnisessionObservation
    func createDetached(paneID: String, cwd: String) throws -> TerminalSession
    func processIdentity(paneID: String, backendPID: Int32) throws -> SupervisorProcessIdentity?
}

public final class UnisessionCoordinator<Backend: UnisessionBackend> {
    public let store: UnisessionStateStore
    private let backend: Backend
    public init(store: UnisessionStateStore, backend: Backend) { self.store = store; self.backend = backend }

    public func binding() throws -> UnisessionBinding? { try store.load()?.binding }

    public func ensure(cwd: String) throws -> UnisessionBinding {
        try backend.transaction {
            let previous = try store.load()
            var record = previous ?? UnisessionRecord()
            var observation = try backend.observe()
            if let binding = record.binding {
                if let pane = try session(binding.paneID, in: observation) {
                    guard !observation.attachedPaneIDs.contains(pane.id), pane.remote == nil else {
                        throw TerminalError.invalid("Unisession was attached to another workflow. It was not moved or restarted.")
                    }
                    if pane.alive {
                        try requireExact(binding, observation: observation)
                        guard record.pendingPaneID == nil else { throw TerminalError.invalid("Unisession creation needs ownership review.") }
                        return binding
                    }
                }
            } else if previous == nil, let migrated = try migrateLegacy(observation: observation) {
                try store.save(UnisessionRecord(binding: migrated))
                return migrated
            }
            if let pending = record.pendingPaneID, let pane = try session(pending, in: observation) {
                guard !observation.attachedPaneIDs.contains(pending), pane.remote == nil else {
                    throw TerminalError.invalid("The reserved shared terminal belongs to another workflow.")
                }
                if pane.alive { return try publish(pane, record: record) }
                record.pendingPaneID = nil
            }
            guard cwd.hasPrefix("/"), !cwd.contains("\0"), cwd.utf8.count <= 4096 else {
                throw TerminalError.invalid("Choose an existing local directory for Unisession.")
            }
            let paneID = record.pendingPaneID ?? UUID().uuidString.lowercased()
            record.pendingPaneID = paneID
            record.reservedPaneIDs.insert(paneID)
            // Publish ownership before the backend creates a shell; a crash cannot make it an adoptable orphan.
            try store.save(record)
            let pane = try backend.createDetached(paneID: paneID, cwd: cwd)
            guard pane.id == paneID, pane.alive, pane.remote == nil, pane.pid > 1 else {
                throw TerminalError.invalid("The shared terminal backend returned a different identity.")
            }
            observation = try backend.observe()
            guard try session(paneID, in: observation)?.pid == pane.pid,
                  !observation.attachedPaneIDs.contains(paneID) else {
                throw TerminalError.invalid("The new shared terminal changed before publication.")
            }
            return try publish(pane, record: record)
        }
    }

    public func validate(_ binding: UnisessionBinding) throws {
        try backend.transaction {
            guard let record = try store.load(), record.binding == binding, record.pendingPaneID == nil else {
                throw TerminalError.invalid("The shared terminal binding changed.")
            }
            try requireExact(binding, observation: backend.observe())
        }
    }

    private func session(_ id: String, in observation: UnisessionObservation) throws -> TerminalSession? {
        let matches = observation.sessions.filter { $0.id == id }
        guard matches.count <= 1 else { throw TerminalError.invalid("Shared terminal ownership is ambiguous.") }
        return matches.first
    }

    private func requireExact(_ binding: UnisessionBinding, observation: UnisessionObservation) throws {
        guard let pane = try session(binding.paneID, in: observation), pane.alive,
              pane.remote == nil, pane.pid == binding.backendPID,
              !observation.attachedPaneIDs.contains(binding.paneID),
              try backend.processIdentity(paneID: pane.id, backendPID: pane.pid) == binding.processIdentity else {
            throw TerminalError.invalid("The shared terminal process identity changed or exited.")
        }
    }

    private func publish(_ pane: TerminalSession, record: UnisessionRecord) throws -> UnisessionBinding {
        guard let identity = try backend.processIdentity(paneID: pane.id, backendPID: pane.pid),
              identity.pid == pane.pid, identity.ownerUID == getuid(), identity.startedAtSeconds > 0,
              identity.startedAtMicroseconds < 1_000_000 else {
            throw TerminalError.invalid("Cannot establish the shared terminal process birth identity.")
        }
        let binding = UnisessionBinding(paneID: pane.id, backendPID: pane.pid, processIdentity: identity)
        try requireExact(binding, observation: backend.observe())
        var next = record
        next.binding = binding; next.pendingPaneID = nil; next.reservedPaneIDs.insert(pane.id)
        try store.save(next)
        return binding
    }

    private func migrateLegacy(observation: UnisessionObservation) throws -> UnisessionBinding? {
        guard let legacy = try SupervisorStateStore(root: store.root).load(),
              let pane = try session(legacy.paneID, in: observation), pane.alive,
              !observation.attachedPaneIDs.contains(pane.id) else { return nil }
        guard legacy.stoppedAt == nil, pane.remote == nil, pane.pid == legacy.backendPID,
              let expected = legacy.processIdentity,
              try backend.processIdentity(paneID: pane.id, backendPID: pane.pid) == expected else {
            throw TerminalError.invalid("The detached Supervisor changed. It was not replaced or adopted.")
        }
        return UnisessionBinding(paneID: pane.id, backendPID: pane.pid, processIdentity: expected)
    }
}
