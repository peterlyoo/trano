import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class TerminalRuntime: @unchecked Sendable {
    public let root: URL
    public let executable: String
    public let helperExecutable: String?
    public var socketPath: String { root.appendingPathComponent("mux.sock").path }
    private let mutex = NSRecursiveLock()
    private let lockFD: Int32
    private var lockDepth = 0

    public static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["TRANO_DATA_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/trano")
    }

    public init(root: URL = TerminalRuntime.defaultRoot, helperExecutable: String? = nil) throws {
        self.root = root.standardizedFileURL
        self.helperExecutable = helperExecutable
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/tmux" }
            + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TerminalError.runtime("tmux is required. Install tmux before launching Trano.")
        }
        self.executable = executable
        guard self.root.path.utf8.count < 90 else { throw TerminalError.invalid("Runtime directory is too long for a Unix socket") }
        let marker = self.root.appendingPathComponent(".trano")
        if FileManager.default.fileExists(atPath: self.root.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: self.root.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory,
                  (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                throw TerminalError.invalid("Runtime directory must be an owned directory, not a symlink")
            }
            let entries = try FileManager.default.contentsOfDirectory(atPath: self.root.path)
            if !entries.isEmpty && !FileManager.default.fileExists(atPath: marker.path) {
                throw TerminalError.invalid("Refusing to adopt a nonempty unmanaged runtime directory")
            }
        }
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        if !FileManager.default.fileExists(atPath: marker.path) { try Self.atomicWrite(Data("1\n".utf8), to: marker) }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: self.root.path)
        lockFD = open(self.root.appendingPathComponent("state.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lockFD >= 0 else { throw TerminalError.runtime("Cannot lock runtime directory") }
        let config = self.root.appendingPathComponent("tmux.conf")
        if !FileManager.default.fileExists(atPath: config.path) {
            let text = "set -g status off\nset -g exit-empty on\nset -g history-limit 10000\nset -g default-terminal tmux-256color\nset -g mouse off\nset -g set-clipboard off\nset -g allow-passthrough on\nset -g remain-on-exit on\nset -g escape-time 0\nset -g focus-events on\nset -g prefix None\nunbind-key C-b\n"
            try Self.atomicWrite(Data(text.utf8), to: config)
        }
    }

    deinit { close(lockFD) }

    public func transaction<T>(_ operation: () throws -> T) throws -> T {
        mutex.lock()
        defer { mutex.unlock() }
        if lockDepth == 0 {
            guard flock(lockFD, LOCK_EX) == 0 else { throw TerminalError.runtime("State lock failed") }
        }
        lockDepth += 1
        defer {
            lockDepth -= 1
            if lockDepth == 0 { _ = flock(lockFD, LOCK_UN) }
        }
        return try operation()
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T { try transaction(operation) }

    public func state() throws -> RuntimeState { try locked { try load() } }

    public func update(_ action: (inout RuntimeState) throws -> Void) throws {
        try locked {
            var state = try load()
            try action(&state)
            try save(state)
        }
    }

    private func load() throws -> RuntimeState {
        let url = root.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return RuntimeState() }
        let result = try JSONDecoder().decode(RuntimeState.self, from: Data(contentsOf: url))
        guard result.schemaVersion == 1 else { throw TerminalError.invalid("Unsupported state schema") }
        return result
    }

    private func save(_ state: RuntimeState) throws {
        var state = state
        state.revision += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Self.atomicWrite(encoder.encode(state), to: root.appendingPathComponent("state.json"))
    }

    public static func atomicWrite(_ data: Data, to url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".write-" + UUID().uuidString)
        let fd = open(temporary.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TerminalError.runtime("Cannot create state file") }
        defer { close(fd); try? FileManager.default.removeItem(at: temporary) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TerminalError.runtime("State write failed") }
                offset += count
            }
        }
        guard fsync(fd) == 0, rename(temporary.path, url.path) == 0 else { throw TerminalError.runtime("State replacement failed") }
    }

    @discardableResult private func tmux(_ args: [String], allowFailure: Bool = false, outputLimit: Int = 1_048_576) throws -> String {
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        for key in ["REX_BLOCK", "REX_SESSION", "REX_SERVER", "TRANO_LAUNCH_ID"] { environment.removeValue(forKey: key) }
        environment["TERM"] = "xterm-256color"
        environment["LC_MESSAGES"] = "C"
        let arguments = (["-u", "-S", socketPath, "-f", root.appendingPathComponent("tmux.conf").path] + args)
            .map { $0.hasSuffix(";") ? String($0.dropLast()) + "\\;" : $0 }
        let result = try CommandRunner.run(executable, arguments, environment: environment, limit: outputLimit)
        if result.status != 0 {
            let message = String(decoding: result.stderr.prefix(2048), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let absent = message.contains("no server running") || message.contains("can't find session") ||
                (message.contains("error connecting to") && (message.contains("No such file or directory") || message.contains("Connection refused")))
            if !allowFailure || !absent { throw TerminalError.runtime(message) }
        }
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func validateID(_ id: String) throws {
        guard UUID(uuidString: id) != nil else { throw TerminalError.invalid("Invalid session ID") }
    }

    private func requireSession(_ id: String) throws -> TerminalSession {
        try validateID(id)
        guard let item = try load().sessions.first(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown session") }
        return item
    }

    public func create(title: String, cwd: String, shell: String = "/bin/zsh", arguments: [String] = ["-l"], restoringID: String? = nil) throws -> TerminalSession {
        try locked {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue,
                  FileManager.default.isExecutableFile(atPath: shell), title.count <= 200 else {
                throw TerminalError.invalid("Invalid working directory, shell or title")
            }
            let previous = try restoringID.map { try requireSession($0) }
            let id = previous?.id ?? UUID().uuidString.lowercased()
            let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
            var options = ["new-session", "-d", "-P", "-F", "#{pane_pid}", "-s", id, "-x", "100", "-y", "30", "-c", path,
                           "-e", "TRANO_SESSION=" + id, "-e", "TRANO_LAUNCH_ID=", "-e", "TRANO_DATA_DIR=" + root.path, "-e", "COLORTERM=truecolor"]
            if let helperExecutable { options += ["-e", "TRANO_CLI_PATH=" + helperExecutable] }
            if shell == "/bin/zsh", arguments == ["-l"], helperExecutable != nil { options += try shellEnvironment().flatMap { ["-e", $0] } }
            var command = [shell] + arguments
            if previous?.remote == nil, previous != nil, helperExecutable != nil, try load().settings.persistScrollback {
                command = ["/bin/sh", "-c", "\"$TRANO_CLI_PATH\" scrollback replay \"$TRANO_SESSION\"; exec \"$@\"", "trano-restore", shell] + arguments
            }
            let pidText = try tmux(options + ["--"] + command)
            guard let pid = Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                _ = try? tmux(["kill-session", "-t", "=" + id])
                throw TerminalError.runtime("tmux did not return a child PID")
            }
            var state = try load()
            var item = previous ?? TerminalSession(id: id, title: title.isEmpty ? "Terminal" : title, cwd: path, pid: pid)
            item.pid = pid; item.alive = true; item.cwd = path
            if let index = state.sessions.firstIndex(where: { $0.id == id }) { state.sessions[index] = item }
            else { state.sessions.append(item) }
            do {
                try save(state)
                if let helperExecutable {
                    let command = "exec /usr/bin/env " + ShellQuote.quote("TRANO_DATA_DIR=" + root.path) + " " + ShellQuote.quote(helperExecutable) + " monitor " + ShellQuote.quote(id)
                    try tmux(["pipe-pane", "-O", "-t", id + ":0.0", command])
                }
            } catch {
                _ = try? tmux(["kill-session", "-t", "=" + id])
                state.sessions.removeAll { $0.id == id }
                if let previous { state.sessions.append(previous) }
                try? save(state)
                throw error
            }
            return item
        }
    }

    public func restoreLocalShell(_ id: String, cwd: String) throws {
        try transaction {
            let pane = try requireSession(id)
            guard pane.remote == nil else { throw TerminalError.invalid("Use remote reconnect for this pane") }
            if try list().first(where: { $0.id == id })?.alive == true { return }
            _ = try tmux(["kill-session", "-t", "=" + id], allowFailure: true)
            _ = try create(title: pane.title, cwd: cwd, restoringID: id)
        }
    }

    public func restoreRemoteBridge(_ id: String) throws {
        let (original, host): (TerminalSession, RemoteHost) = try transaction {
            let pane = try requireSession(id)
            guard let remote = pane.remote else { throw TerminalError.invalid("Not a remote pane") }
            return (pane, try remoteHost(remote.hostID))
        }
        if try list().first(where: { $0.id == id })?.alive == true { return }
        guard let remote = original.remote else { throw TerminalError.invalid("Not a remote pane") }
        if try !remoteSessions(hostID: host.id).contains(where: { $0.id == remote.sessionID && $0.alive }) {
            let results = try RemoteClient(host: host).recover(sessionID: remote.sessionID)
            guard try remoteSessions(hostID: host.id).contains(where: { $0.id == remote.sessionID && $0.alive }) else {
                throw TerminalError.runtime(results.first?.message ?? "Remote session recovery failed")
            }
        }
        try transaction {
            let pane = try requireSession(id)
            guard pane.remote == original.remote, try remoteHost(host.id) == host else { throw TerminalError.invalid("Remote connection changed while reconnecting") }
            if try list().first(where: { $0.id == id })?.alive == true { return }
            _ = try tmux(["kill-session", "-t", "=" + id], allowFailure: true)
            _ = try create(title: pane.title, cwd: FileManager.default.homeDirectoryForCurrentUser.path, shell: "/usr/bin/ssh", arguments: RemoteClient(host: host).attachArguments(sessionID: remote.sessionID), restoringID: id)
            try update { state in if let index = state.sessions.firstIndex(where: { $0.id == id }) { state.sessions[index].cwd = pane.cwd } }
        }
    }

    public func list() throws -> [TerminalSession] {
        try locked {
            var sessions = try load().sessions
            let rows = try tmux(["list-panes", "-a", "-F", "#{session_name}|#{pane_pid}|#{pane_dead}"], allowFailure: true)
            let live = Dictionary(rows.split(separator: "\n").compactMap { row -> (String, (Int32, Bool))? in
                let fields = row.split(separator: "|", omittingEmptySubsequences: false)
                guard fields.count == 3, UUID(uuidString: String(fields[0])) != nil, let pid = Int32(fields[1]) else { return nil }
                return (String(fields[0]), (pid, fields[2] == "0"))
            }, uniquingKeysWith: { left, _ in left })
            for i in sessions.indices {
                sessions[i].alive = live[sessions[i].id]?.1 == true
                if let pid = live[sessions[i].id]?.0 { sessions[i].pid = pid }
            }
            return sessions
        }
    }

    public func send(_ id: String, text: String, enter: Bool = false) throws {
        try locked {
            _ = try requireSession(id)
            guard text.utf8.count <= 65536, !text.contains("\0") else { throw TerminalError.invalid("Input exceeds 64 KiB or contains NUL") }
            _ = try tmux(["send-keys", "-t", id + ":0.0", "-l", "--", text])
            if enter { _ = try tmux(["send-keys", "-t", id + ":0.0", "Enter"]) }
        }
    }

    public func capture(_ id: String, lines: Int = 100) throws -> String {
        try locked {
            _ = try requireSession(id)
            guard (1...10_000).contains(lines) else { throw TerminalError.invalid("Capture line limit is 1...10000") }
            return try tmux(["capture-pane", "-p", "-t", id + ":0.0", "-S", "-\(lines)"], outputLimit: 4 * 1_048_576)
        }
    }

    public func workingDirectory(_ id: String) throws -> String {
        if let reference = try state().sessions.first(where: { $0.id == id })?.remote {
            guard let remote = try remoteSessions(hostID: reference.hostID).first(where: { $0.id == reference.sessionID }) else { throw TerminalError.invalid("Remote session no longer exists") }
            return remote.cwd
        }
        return try locked {
            _ = try requireSession(id)
            let value = try tmux(["display-message", "-p", "-t", id + ":0.0", "#{pane_current_path}"])
            return value.hasSuffix("\n") ? String(value.dropLast()) : value
        }
    }

    public func report(_ id: String, state: ActivityState, reason: String = "", agent: AgentKind = .shell, source: String = "explicit", clearsActive: Bool = false) throws {
        try locked {
            var store = try load()
            try validateID(id)
            guard let index = store.sessions.firstIndex(where: { $0.id == id }), reason.count <= 1000, ["explicit", "osc7501", "process", "shell", "hook", "remote"].contains(source) else { throw TerminalError.invalid("Unknown session, source or oversized reason") }
            let previous = store.sessions[index]
            if clearsActive && ![.running, .blocked].contains(previous.activity.state) { return }
            if previous.activity.state == state && previous.activity.reason == reason && previous.agent == agent && previous.activity.source == source { return }
            store.sessions[index].activity.state = state
            store.sessions[index].activity.reason = reason
            store.sessions[index].activity.source = source
            store.sessions[index].activity.updatedAt = Date()
            store.sessions[index].agent = agent
            store.events.append(ActivityEvent(revision: store.revision + 1, sessionID: id, title: previous.title, activity: store.sessions[index].activity, agent: agent))
            if store.events.count > 256 {
                store.eventsDiscardedThrough = store.events[store.events.count - 257].revision
                store.events.removeFirst(store.events.count - 256)
            }
            try save(store)
        }
    }

    public func events(since revision: Int) throws -> EventBatch {
        guard revision >= 0 else { throw TerminalError.invalid("Event cursor must be nonnegative") }
        return try locked {
            let store = try load()
            return EventBatch(revision: store.revision, resetRequired: revision < store.eventsDiscardedThrough || revision > store.revision,
                              events: store.events.filter { $0.revision > revision })
        }
    }

    public func terminate(_ id: String) throws {
        if let reference = try state().sessions.first(where: { $0.id == id })?.remote {
            _ = try RemoteClient(host: remoteHost(reference.hostID)).call(APIRequest(method: "sessions.terminate", params: ["id": .string(reference.sessionID)]))
        }
        try disconnectLocalSession(id)
    }

    public func disconnectRemoteSession(_ id: String) throws {
        guard try state().sessions.contains(where: { $0.id == id && $0.remote != nil }) else { throw TerminalError.invalid("Unknown remote connection") }
        try disconnectLocalSession(id)
    }

    private func disconnectLocalSession(_ id: String) throws {
        try locked {
            _ = try requireSession(id)
            _ = try tmux(["kill-session", "-t", "=" + id], allowFailure: true)
            let remaining = try tmux(["list-sessions", "-F", "#{session_name}"], allowFailure: true)
            guard !remaining.split(separator: "\n").contains(Substring(id)) else { throw TerminalError.runtime("Session did not terminate") }
            var store = try load()
            store.sessions.removeAll { $0.id == id }
            store.agentLaunches.removeAll { $0.paneID == id }
            store.recoveryResults.removeAll { $0.paneID == id }
            let generations = Set(store.agentLaunches.map(\.id))
            store.supervision.removeAll { !generations.contains($0.generation) }
            try ScrollbackStore(runtimeRoot: root).remove(paneID: id)
            store.layout.forget(id)
            store.settings.paneAppearanceProfiles.removeValue(forKey: id)
            try save(store)
        }
    }

    public func reconnectRemoteSession(_ id: String) throws {
        guard let reference = try state().sessions.first(where: { $0.id == id })?.remote else { throw TerminalError.invalid("Unknown remote connection") }
        let arguments = try RemoteClient(host: remoteHost(reference.hostID)).attachArguments(sessionID: reference.sessionID)
        try locked {
            _ = try requireSession(id)
            try tmux(["respawn-pane", "-k", "-t", id + ":0.0", "--", "/usr/bin/ssh"] + arguments)
            if let helperExecutable {
                let command = "exec /usr/bin/env " + ShellQuote.quote("TRANO_DATA_DIR=" + root.path) + " " + ShellQuote.quote(helperExecutable) + " monitor " + ShellQuote.quote(id)
                try tmux(["pipe-pane", "-O", "-t", id + ":0.0", command])
            }
        }
    }

    public func attachArguments(_ id: String) throws -> [String] {
        try validateID(id)
        return ["-u", "-S", socketPath, "attach-session", "-t", "=" + id]
    }
}
