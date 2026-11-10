import Foundation

public struct RemotePathEntry: Codable, Identifiable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let directory: Bool
}
public struct RemotePathListing: Codable {
    public let path: String
    public let parent: String
    public let entries: [RemotePathEntry]
    public let truncated: Bool
}

public struct RemoteReference: Codable, Equatable {
    public let hostID: String
    public let sessionID: String
    public init(hostID: String, sessionID: String) { self.hostID = hostID; self.sessionID = sessionID }
}

public struct RemoteRecoveryResult: Codable, Identifiable, Equatable {
    public var id: String { sessionID }
    public let sessionID: String
    public let status: String
    public let message: String
    public let updatedAt: Date
}

public struct RemoteHost: Codable, Identifiable, Equatable {
    public let id: String
    public var name: String
    public var address: String
    public var sshConfigPath: String?
    public init(name: String, address: String, sshConfigPath: String? = nil) throws {
        guard !name.isEmpty, name.count <= 100,
              address.range(of: "^[A-Za-z0-9][A-Za-z0-9._@-]{0,200}$", options: .regularExpression) != nil else {
            throw TerminalError.invalid("Use an SSH config alias or user@hostname without whitespace or options")
        }
        if let sshConfigPath {
            guard sshConfigPath.hasPrefix("/"), !sshConfigPath.contains("\0"), FileManager.default.isReadableFile(atPath: sshConfigPath) else { throw TerminalError.invalid("SSH configuration must be a readable absolute path") }
        }
        id = UUID().uuidString.lowercased(); self.name = name; self.address = address; self.sshConfigPath = sshConfigPath
    }
    public func validated() throws { _ = try RemoteHost(name: name, address: address, sshConfigPath: sshConfigPath) }
}

public struct RemoteClient {
    public let host: RemoteHost
    public init(host: RemoteHost) { self.host = host }
    private var configuration: [String] { host.sshConfigPath.map { ["-F", $0] } ?? [] }
    public func attachArguments(sessionID: String) throws -> [String] {
        try host.validated()
        guard UUID(uuidString: sessionID) != nil else { throw TerminalError.invalid("Invalid remote session ID") }
        return configuration + ["-tt", "-e", "none", "-o", "ServerAliveInterval=15", "-o", "ServerAliveCountMax=3", "--", host.address,
                "exec \"$HOME/.local/bin/trano-server\" attach " + ShellQuote.quote(sessionID)]
    }
    public func call(_ request: APIRequest) throws -> APIResponse {
        try host.validated()
        let arguments = configuration + ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "--", host.address,
                             "exec \"$HOME/.local/bin/trano-server\" rpc"]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        var line = try JSONEncoder().encode(request); line.append(10)
        guard line.count <= 1_048_576 else { throw TerminalError.invalid("Remote request exceeds 1 MiB") }
        let result = try CommandRunner.run("/usr/bin/ssh", arguments, input: line, environment: environment, timeout: 10)
        guard result.status == 0 else { throw TerminalError.runtime(String(decoding: result.stderr.prefix(2048), as: UTF8.self)) }
        let response = try JSONDecoder().decode(APIResponse.self, from: result.stdout)
        if let error = response.error { throw TerminalError.runtime(error) }
        return response
    }

    public func recover(sessionID: String? = nil) throws -> [RemoteRecoveryResult] {
        if let sessionID, UUID(uuidString: sessionID) == nil { throw TerminalError.invalid("Invalid remote session ID") }
        let response = try call(APIRequest(method: "recovery.run", params: sessionID.map { ["id": .string($0)] } ?? [:]))
        guard let result = response.result else { throw TerminalError.runtime("Missing remote recovery results") }
        return try JSONDecoder().decode([RemoteRecoveryResult].self, from: JSONEncoder().encode(result))
    }

    public func recoveryResults() throws -> [RemoteRecoveryResult] {
        let response = try call(APIRequest(method: "recovery.list"))
        guard let result = response.result else { throw TerminalError.runtime("Missing remote recovery results") }
        return try JSONDecoder().decode([RemoteRecoveryResult].self, from: JSONEncoder().encode(result))
    }

    public func uploadPNG(_ data: Data, sessionID: String) throws -> String {
        try host.validated()
        guard UUID(uuidString: sessionID) != nil, (8...20 * 1024 * 1024).contains(data.count), data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { throw TerminalError.invalid("Invalid PNG or remote session") }
        let arguments = configuration + ["-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "LogLevel=ERROR", "--", host.address,
            "exec \"$HOME/.local/bin/trano-server\" upload " + ShellQuote.quote(sessionID)]
        let result = try CommandRunner.run("/usr/bin/ssh", arguments, input: data, timeout: 60)
        guard result.status == 0 else { throw TerminalError.runtime(String(decoding: result.stderr.prefix(2048), as: UTF8.self)) }
        let response = try JSONDecoder().decode(APIResponse.self, from: result.stdout)
        guard let path = response.result?["path"]?.text, path.hasPrefix("/"), !path.contains("\0"), !path.contains("\n"), !path.contains("\r") else { throw TerminalError.runtime(response.error ?? "Missing remote attachment path") }
        return path
    }
}

extension TerminalRuntime {
    public func recoverRemoteSessions(hostID: String, sessionID: String? = nil) throws -> [RemoteRecoveryResult] {
        try RemoteClient(host: remoteHost(hostID)).recover(sessionID: sessionID)
    }

    public func addRemoteHost(name: String, address: String, sshConfigPath: String? = nil) throws -> RemoteHost {
        let host = try RemoteHost(name: name, address: address, sshConfigPath: sshConfigPath)
        try update { state in
            guard !state.remoteHosts.contains(where: { $0.address == address }) else { throw TerminalError.invalid("This SSH host is already registered") }
            state.remoteHosts.append(host)
        }
        return host
    }

    public func removeRemoteHost(_ id: String) throws {
        try update { state in
            guard !state.sessions.contains(where: { $0.remote?.hostID == id }) else { throw TerminalError.invalid("Disconnect the host's local views before removing it") }
            state.remoteHosts.removeAll { $0.id == id }
        }
    }

    public func remoteHost(_ id: String) throws -> RemoteHost {
        guard let host = try state().remoteHosts.first(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown remote host") }
        try host.validated()
        return host
    }

    public func remoteSessions(hostID: String) throws -> [TerminalSession] {
        let response = try RemoteClient(host: remoteHost(hostID)).call(APIRequest(method: "sessions.list"))
        guard let result = response.result else { throw TerminalError.runtime("Missing remote sessions") }
        return try JSONDecoder().decode([TerminalSession].self, from: JSONEncoder().encode(result))
    }

    public func createRemoteSession(hostID: String, cwd: String = "", attachToLayout: Bool = true) throws -> TerminalSession {
        let response = try RemoteClient(host: remoteHost(hostID)).call(APIRequest(method: "sessions.create", params: ["cwd": .string(cwd), "title": .string("Remote Terminal")]))
        guard let result = response.result else { throw TerminalError.runtime("Missing remote session") }
        let remote = try JSONDecoder().decode(TerminalSession.self, from: JSONEncoder().encode(result))
        do { return try attachRemoteSession(hostID: hostID, remote: remote, attachToLayout: attachToLayout) }
        catch {
            _ = try? RemoteClient(host: remoteHost(hostID)).call(APIRequest(method: "sessions.terminate", params: ["id": .string(remote.id)]))
            throw error
        }
    }

    public func attachRemoteSession(hostID: String, remote: TerminalSession, attachToLayout: Bool = true) throws -> TerminalSession {
        let host = try remoteHost(hostID)
        let arguments = try RemoteClient(host: host).attachArguments(sessionID: remote.id)
        return try transaction {
            let existing = try state().sessions.first { $0.remote == RemoteReference(hostID: hostID, sessionID: remote.id) }
            if let existing, try list().first(where: { $0.id == existing.id })?.alive == false { try reconnectRemoteSession(existing.id) }
            var pane = try existing ?? create(title: remote.title, cwd: FileManager.default.homeDirectoryForCurrentUser.path, shell: "/usr/bin/ssh", arguments: arguments)
            pane.host = host.name
            pane.cwd = remote.cwd
            pane.remote = RemoteReference(hostID: hostID, sessionID: remote.id)
            pane.agent = remote.agent
            pane.activity = remote.activity
            pane.agentTasks = remote.agentTasks.map { Array($0.prefix(64)) }
            try update { state in
                if let index = state.sessions.firstIndex(where: { $0.id == pane.id }) { state.sessions[index] = pane }
                guard attachToLayout else { return }
                if state.layout.tabs.contains(where: { $0.panes.contains(pane.id) }) { try state.layout.focusPane(pane.id) }
                else {
                    let existingWorkspace = state.layout.tabs.first { tab in
                        tab.panes.contains { id in state.sessions.contains { $0.id == id && $0.remote?.hostID == hostID } }
                    }?.workspaceID
                    if let existingWorkspace { try state.layout.selectWorkspace(existingWorkspace) }
                    else { state.layout.addWorkspace(title: host.name) }
                    state.layout.addTab(paneID: pane.id)
                }
                if let workspace = state.layout.selectedWorkspaceID { state.navigationRequest = NavigationRequest(workspaceID: workspace, paneID: pane.id) }
            }
            return pane
        }
    }

    public func remotePaths(hostID: String, path: String) throws -> RemotePathListing {
        let response = try RemoteClient(host: remoteHost(hostID)).call(APIRequest(method: "paths.list", params: ["path": .string(path)]))
        guard let result = response.result else { throw TerminalError.runtime("Missing remote directory") }
        return try JSONDecoder().decode(RemotePathListing.self, from: JSONEncoder().encode(result))
    }

    public func saveAttachment(_ data: Data, paneID: String) throws -> String {
        guard let pane = try state().sessions.first(where: { $0.id == paneID }) else { throw TerminalError.invalid("Unknown pane") }
        if let reference = pane.remote { return try RemoteClient(host: remoteHost(reference.hostID)).uploadPNG(data, sessionID: reference.sessionID) }
        return try AttachmentStore(root: root).savePNG(data).path
    }

    public func syncRemoteHost(_ hostID: String) throws {
        var remote = try remoteSessions(hostID: hostID)
        try importRemoteActivity(hostID: hostID, sessions: remote)
        let snapshot = try state()
        guard snapshot.settings.automaticRestore else { return }
        let attached = snapshot.sessions.filter { $0.remote?.hostID == hostID }
        let client = try RemoteClient(host: remoteHost(hostID))
        var recovered = false
        for local in attached {
            guard let reference = local.remote,
                  remote.contains(where: { $0.id == reference.sessionID && !$0.alive }) else { continue }
            _ = try client.recover(sessionID: reference.sessionID)
            recovered = true
        }
        if recovered {
            remote = try remoteSessions(hostID: hostID)
            try importRemoteActivity(hostID: hostID, sessions: remote)
        }
        let localProcesses = try list()
        for local in attached {
            guard let reference = local.remote,
                  remote.contains(where: { $0.id == reference.sessionID && $0.alive }),
                  localProcesses.first(where: { $0.id == local.id })?.alive == false else { continue }
            try restoreRemoteBridge(local.id)
        }
    }

    public func importRemoteActivity(hostID: String, sessions: [TerminalSession]) throws {
        try transaction {
            for local in try state().sessions where local.remote?.hostID == hostID {
                guard let remote = sessions.first(where: { $0.id == local.remote?.sessionID }) else { continue }
                if local.cwd != remote.cwd {
                    try update { state in if let index = state.sessions.firstIndex(where: { $0.id == local.id }) { state.sessions[index].cwd = remote.cwd } }
                }
                let tasks = remote.agentTasks.map { Array($0.prefix(64)) }
                if local.agentTasks != tasks {
                    try update { state in
                        if let index = state.sessions.firstIndex(where: { $0.id == local.id }) { state.sessions[index].agentTasks = tasks }
                    }
                }
                if local.activity.state != remote.activity.state || local.activity.reason != remote.activity.reason || local.agent != remote.agent {
                    try report(local.id, state: remote.activity.state, reason: remote.activity.reason, agent: remote.agent, source: "remote")
                }
                if local.activity != remote.activity || local.agent != remote.agent {
                    try update { state in
                        if let index = state.sessions.firstIndex(where: { $0.id == local.id }) { state.sessions[index].activity = remote.activity }
                    }
                }
            }
        }
    }
}
