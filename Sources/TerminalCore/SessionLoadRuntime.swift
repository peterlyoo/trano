import Foundation
import Darwin

enum SessionLoadTargetResolver {
    static func resolve(sessions: [TerminalSession], launches: [AgentLaunch], panes: [PaneHostPane]) -> [SessionLoadTarget] {
        struct Live { let pid: Int32; let alive: Bool; let token: String }
        var live: [String: Live] = [:]
        var duplicated: Set<String> = []
        for pane in panes.prefix(4096) {
            guard UUID(uuidString: pane.id) != nil, pane.pid > 1, let generation = pane.generation, !generation.isEmpty,
                  !generation.contains("|") else { continue }
            if live[pane.id] != nil { duplicated.insert(pane.id); continue }
            live[pane.id] = Live(pid: pane.pid, alive: pane.alive, token: "pty:" + generation + ":" + String(pane.pid))
        }
        let activeGroups = Dictionary(grouping: launches.filter { $0.lifecycle == .active }, by: \.paneID)
        let active = activeGroups.compactMapValues { $0.count == 1 ? $0.first : nil }
        return sessions.prefix(4096).map { session in
            let backend = duplicated.contains(session.id) ? nil : live[session.id]
            let launch = session.remote == nil ? active[session.id] : nil
            let token = (backend?.token ?? "missing:" + session.id) + ":agent:" + (launch?.id ?? "shell")
            return SessionLoadTarget(paneID: session.id, backendPID: backend?.pid ?? session.pid, ownershipToken: token,
                provider: launch?.provider ?? .shell, providerSessionID: launch?.providerSessionID,
                providerPID: launch.map { $0.providerPID ?? 0 }, hookBindingToken: launch?.id,
                alive: backend?.alive == true, local: session.remote == nil)
        }
    }
}

struct SessionHookBindingStore {
    let root: URL
    private struct Envelope: Codable { let schemaVersion: Int; let bindings: [SessionHookFileBinding] }
    private var path: URL { root.appendingPathComponent("session-load-hooks.json") }
    func read() throws -> [SessionHookFileBinding] {
        var attributes = stat()
        if lstat(path.path, &attributes) != 0 {
            guard errno == ENOENT else { throw TerminalError.invalid("Cannot inspect hook telemetry bindings") }
            return []
        }
        guard attributes.st_mode & S_IFMT == S_IFREG, attributes.st_uid == getuid(), attributes.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Hook telemetry bindings must be a private owned regular file")
        }
        let value = try JSONDecoder().decode(Envelope.self, from: AccountFile.read(path, limit: 1_048_576))
        guard value.schemaVersion == 1, value.bindings.count <= 4096 else { throw TerminalError.invalid("Unsupported hook telemetry bindings") }
        return value.bindings
    }
    func record(_ binding: SessionHookFileBinding) throws {
        guard UUID(uuidString: binding.paneID) != nil, UUID(uuidString: binding.ownershipToken) != nil,
              UUID(uuidString: binding.providerSessionID) != nil, binding.configurationRoot.hasPrefix("/"),
              !binding.configurationRoot.contains("\0"), binding.relativePath.utf8.count <= 4096 else {
            throw TerminalError.invalid("Invalid hook telemetry binding")
        }
        var bindings = try read()
        if bindings.first(where: { $0.paneID == binding.paneID }) == binding { return }
        bindings.removeAll { $0.paneID == binding.paneID }
        bindings.append(binding)
        bindings = Array(bindings.suffix(4096))
        let data = try JSONEncoder().encode(Envelope(schemaVersion: 1, bindings: bindings))
        guard data.count <= 1_048_576 else { throw TerminalError.invalid("Hook telemetry binding limit exceeded") }
        try TerminalRuntime.atomicWrite(data, to: path)
    }
}

extension TerminalRuntime {
    public func sessionLoadHookBindings() throws -> [SessionHookFileBinding] {
        try transaction {
            let launches = try state().agentLaunches
            return try SessionHookBindingStore(root: root).read().filter { binding in
                launches.contains { $0.paneID == binding.paneID && $0.id == binding.ownershipToken && $0.provider == .claude &&
                    $0.lifecycle == .active && $0.providerSessionID == binding.providerSessionID &&
                    URL(fileURLWithPath: $0.configurationRoot).standardizedFileURL.path == binding.configurationRoot }
            }
        }
    }
    func recordSessionLoadHookSource(launch: AgentLaunch, providerSessionID: String, transcriptPath: String) throws {
        guard launch.provider == .claude, UUID(uuidString: providerSessionID) != nil,
              transcriptPath.hasPrefix("/"), !transcriptPath.contains("\0"), !transcriptPath.contains("\n") else { return }
        let configuration = URL(fileURLWithPath: launch.configurationRoot).standardizedFileURL.path
        let transcript = URL(fileURLWithPath: transcriptPath).standardizedFileURL
        guard transcript.path == transcriptPath, transcript.path.hasPrefix(configuration + "/"),
              transcript.lastPathComponent == providerSessionID + ".jsonl" else { return }
        let relative = String(transcript.path.dropFirst(configuration.count + 1))
        guard relative.hasPrefix("projects/") else { return }
        try SessionHookBindingStore(root: root).record(SessionHookFileBinding(paneID: launch.paneID, ownershipToken: launch.id,
            providerSessionID: providerSessionID, configurationRoot: configuration, relativePath: relative))
    }
}
