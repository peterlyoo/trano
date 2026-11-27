import Foundation

public struct RuntimeDetachedPaneReservations {
    public let supervisor: SupervisorPaneReservation
    public let unisession: DetachedPaneReservation
    public let twinPaneIDs: Set<String>?
    public init(supervisor: SupervisorPaneReservation, unisession: DetachedPaneReservation, twinPaneIDs: Set<String>? = []) {
        self.supervisor = supervisor; self.unisession = unisession; self.twinPaneIDs = twinPaneIDs
    }
    public func permitsDetachedStartupReuse(_ paneID: String) -> Bool {
        twinPaneIDs.map { !$0.contains(paneID) } == true && supervisor.permitsDetachedStartupReuse(paneID) && unisession.permitsDetachedStartupReuse(paneID)
    }
    public func permitsGenericRecovery(_ paneID: String, attachedPaneIDs: Set<String>) -> Bool {
        twinPaneIDs.map { !$0.contains(paneID) } == true && supervisor.permitsGenericRecovery(paneID, attachedPaneIDs: attachedPaneIDs)
            && unisession.permitsGenericRecovery(paneID, attachedPaneIDs: attachedPaneIDs)
    }
    public func requireOrdinaryPane(_ paneID: String, attachedPaneIDs: Set<String>) throws {
        try unisession.requireOrdinaryPane(paneID, attachedPaneIDs: attachedPaneIDs)
        try SupervisorNavigationGuard.requireOrdinaryPane(paneID, reservation: supervisor, attachedPaneIDs: attachedPaneIDs)
    }
    public func reservedPaneIDs() throws -> Set<String> {
        guard let twins = twinPaneIDs else { throw TerminalError.invalid("Twin workflow ownership is unavailable.") }
        guard case .known(var ids) = unisession else { throw TerminalError.invalid("Unisession ownership is unavailable.") }
        ids.formUnion(twins)
        switch supervisor {
        case .absent: return ids
        case .bound(let id): ids.insert(id); return ids
        case .unavailable: throw TerminalError.invalid("Supervisor ownership is unavailable.")
        }
    }
}

enum TerminalCreationIdentity {
    static func resolve(restoringID: String?, reservedID: String?, existingPaneIDs: Set<String>) throws -> String {
        if let reservedID {
            guard restoringID == nil, UUID(uuidString: reservedID) != nil, !existingPaneIDs.contains(reservedID) else {
                throw TerminalError.invalid("The reserved terminal identity already exists or is invalid.")
            }
            return reservedID
        }
        return restoringID ?? UUID().uuidString.lowercased()
    }
}

private final class UnisessionRuntimeBackend: UnisessionBackend {
    let runtime: TerminalRuntime
    init(runtime: TerminalRuntime) { self.runtime = runtime }
    func transaction<T>(_ body: () throws -> T) throws -> T { try runtime.transaction(body) }
    func observe() throws -> UnisessionObservation {
        let snapshot = try runtime.state()
        return UnisessionObservation(sessions: try runtime.list(),
            attachedPaneIDs: Set((snapshot.layout.tabs + snapshot.layout.closedTabs).flatMap(\.panes)))
    }
    func createDetached(paneID: String, cwd: String) throws -> TerminalSession {
        try runtime.create(title: "Unisession", cwd: cwd, reservedID: paneID)
    }
    func processIdentity(paneID: String, backendPID: Int32) throws -> SupervisorProcessIdentity? {
        guard try runtime.list().contains(where: { $0.id == paneID && $0.pid == backendPID && $0.alive && $0.remote == nil }) else { return nil }
        return SupervisorProcessIdentity.read(backendPID)
    }
}

extension TerminalRuntime {
    private func unisessionCoordinator() -> UnisessionCoordinator<UnisessionRuntimeBackend> {
        UnisessionCoordinator(store: UnisessionStateStore(root: root), backend: UnisessionRuntimeBackend(runtime: self))
    }
    public func ensureUnisession(cwd: String) throws -> UnisessionBinding { try unisessionCoordinator().ensure(cwd: cwd) }
    public func unisessionBinding() throws -> UnisessionBinding? { try UnisessionStateStore(root: root).load()?.binding }
    public func validateUnisession(_ binding: UnisessionBinding) throws { try unisessionCoordinator().validate(binding) }
    public func detachedPaneReservations() -> RuntimeDetachedPaneReservations {
        RuntimeDetachedPaneReservations(supervisor: SupervisorStateStore(root: root).reservation(),
                                        unisession: UnisessionStateStore(root: root).reservation(), twinPaneIDs: try? twinReservedPaneIDs())
    }
    public func requireOrdinaryPane(_ paneID: String, attachedPaneIDs: Set<String>) throws {
        try detachedPaneReservations().requireOrdinaryPane(paneID, attachedPaneIDs: attachedPaneIDs)
    }
}
