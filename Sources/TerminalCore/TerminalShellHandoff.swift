import Foundation
import Darwin

public struct TerminalShellHandoffRequest: @unchecked Sendable {
    public let paneID: String
    public let backendPID: Int32
    public let remote: RemoteReference?
    public let backend: SupervisorProcessIdentity?
    public let launchIDs: Set<String>
    public let activeLaunchID: String?
    public let processes: [SupervisorProcessIdentity]
    public var remoteBackendIdentity: String?
    public var providerPID: Int32?
    public var supervisorPID: Int32?
    public init(paneID: String, backendPID: Int32, remote: RemoteReference?, backend: SupervisorProcessIdentity?,
                launchIDs: Set<String>, activeLaunchID: String?, processes: [SupervisorProcessIdentity]) {
        self.paneID = paneID; self.backendPID = backendPID; self.remote = remote; self.backend = backend
        self.launchIDs = launchIDs; self.activeLaunchID = activeLaunchID; self.processes = processes
    }
}

public struct TerminalShellHandoffSnapshot: @unchecked Sendable {
    public let identity: String
    public let binding: TerminalInputBinding
    public let launches: [AgentLaunch]
    public init(identity: String, binding: TerminalInputBinding, launches: [AgentLaunch]) {
        self.identity = identity; self.binding = binding; self.launches = launches
    }
}

public enum TerminalShellHandoffStatus: @unchecked Sendable {
    case waiting, ready(TerminalShellHandoffSnapshot), changed, unavailable(String)
}

extension TerminalRuntime {
    public func terminalShellHandoff(_ request: TerminalShellHandoffRequest) throws -> TerminalShellHandoffStatus {
        guard let backend = request.backend, SupervisorProcessIdentity.read(request.backendPID) == backend else { return .changed }
        if request.remote != nil, request.remoteBackendIdentity == nil {
            return .unavailable("Update the remote Trano helper, then refresh Remote Hosts to preserve typing during agent exit.")
        }
        do { return try terminalShellHandoff(request, readShell: { pane in
            if let remote = pane.remote {
                let host = try self.remoteHost(remote.hostID)
                guard let value = try RemoteClient(host: host).call(APIRequest(method: "sessions.list")).result else { return nil }
                let sessions = try JSONDecoder().decode([RemoteShellInputSession].self, from: JSONEncoder().encode(value))
                guard let session = sessions.first(where: { $0.id == remote.sessionID }), session.alive else { return nil }
                guard let backendIdentity = session.inputBackendIdentity else { throw ShellHandoffProbeError.unsupported }
                guard !backendIdentity.isEmpty else { return nil }
                guard backendIdentity == request.remoteBackendIdentity else { throw ShellHandoffProbeError.changed }
                guard let identity = session.shellInputIdentity, !identity.isEmpty else { return nil }
                guard identity == backendIdentity else { return nil }
                return "remote:" + remote.hostID + ":" + remote.sessionID + ":" + identity
            }
            guard let expected = request.backend else { return nil }
            return ForegroundProgramProbe.shellInputIdentity(pid: pane.pid, expected: expected)
        }, hasExited: Self.handoffProcessExited) }
        catch ShellHandoffProbeError.changed { return .changed }
        catch ShellHandoffProbeError.unsupported { return .unavailable("Update the remote Trano helper to preserve typing during agent exit.") }
    }

    func terminalShellHandoff(_ request: TerminalShellHandoffRequest, readShell: (TerminalSession) throws -> String?,
                              hasExited: (SupervisorProcessIdentity) -> Bool) throws -> TerminalShellHandoffStatus {
        func matches(_ state: RuntimeState) -> Bool {
            guard let pane = state.sessions.first(where: { $0.id == request.paneID }), pane.alive,
                  pane.pid == request.backendPID, pane.remote == request.remote,
                  pane.remote == nil || pane.inputBackendIdentity == request.remoteBackendIdentity else { return false }
            return state.agentLaunches.filter { $0.paneID == request.paneID }.allSatisfy { request.launchIDs.contains($0.id) }
        }
        let before = try transaction { try state() }
        guard matches(before), let pane = before.sessions.first(where: { $0.id == request.paneID }) else { return .changed }
        guard let identity = try readShell(pane) else { return .waiting }
        return try transaction {
            let current = try state()
            guard matches(current) else { return .changed }
            if let remote = request.remote,
               current.remoteHosts.first(where: { $0.id == remote.hostID }) != before.remoteHosts.first(where: { $0.id == remote.hostID }) { return .changed }
            let launches = current.agentLaunches.filter { $0.paneID == request.paneID }
            let active = launches.filter { $0.lifecycle == .active }
            if !active.isEmpty {
                guard active.count == 1, active.first?.id == request.activeLaunchID,
                      active.first?.providerPID == request.providerPID,
                      active.first?.processID == nil || active.first?.processID == request.supervisorPID,
                      Set(request.processes.map(\.pid)).count >= 2, request.processes.allSatisfy(hasExited) else { return .waiting }
            }
            let binding = try terminalInputBinding(paneID: request.paneID, expectedPID: request.backendPID, snapshot: current)
            return .ready(TerminalShellHandoffSnapshot(identity: identity, binding: binding, launches: launches))
        }
    }

    private static func handoffProcessExited(_ expected: SupervisorProcessIdentity) -> Bool {
        var info = proc_bsdinfo(); errno = 0
        let count = proc_pidinfo(expected.pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
        if count <= 0 { return errno == ESRCH }
        guard count == MemoryLayout<proc_bsdinfo>.size else { return false }
        if info.pbi_pid != UInt32(expected.pid) { return false }
        if info.pbi_start_tvsec != expected.startedAtSeconds || info.pbi_start_tvusec != expected.startedAtMicroseconds { return true }
        return info.pbi_uid == expected.ownerUID && info.pbi_status == 5
    }
}

private struct RemoteShellInputSession: Decodable {
    let id: String
    let alive: Bool
    let shellInputIdentity: String?
    let inputBackendIdentity: String?
}

private enum ShellHandoffProbeError: Error { case changed, unsupported }
