import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class TerminalRuntime: @unchecked Sendable {
    public let root: URL
    public let legacyTmuxExecutable: String?
    public let helperExecutable: String?
    public var legacySocketPath: String { root.appendingPathComponent("mux.sock").path }
    public internal(set) var host: any PaneBackend
    /// Extra environment for new panes, after the host base environment. Isolated fixtures set HOME/ZDOTDIR here.
    var paneEnvironmentOverlay: [String] = []
    var closedRemoteTransport: any ClosedRemoteTerminalTransport = NativeClosedRemoteTerminalTransport()
    var terminalHistoryRemoteCoordinator = RemoteTerminalHistoryCoordinator()
    private let mutex = NSRecursiveLock()
    private let lockFD: Int32
    private var lockDepth = 0
    private let foregroundProgramProbe = ForegroundProgramProbe()
    var accountAuthenticationIdentityReader = ClaudeAuthenticationIdentityReader()

    public static var defaultRoot: URL {
        if let path = ProcessInfo.processInfo.environment["TRANO_DATA_DIR"] { return URL(fileURLWithPath: path) }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/share/trano")
    }

    public init(root: URL = TerminalRuntime.defaultRoot, helperExecutable: String? = nil) throws {
        self.root = root.standardizedFileURL
        self.helperExecutable = helperExecutable
        let candidates = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/tmux" }
            + ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"]
        legacyTmuxExecutable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        host = PaneHostClient(root: self.root, executable: helperExecutable)
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

    func assertOutsideSharedTransaction() throws {
        mutex.lock()
        defer { mutex.unlock() }
        guard lockDepth == 0 else { throw TerminalError.invalid("External work must run outside the shared runtime transaction") }
    }

    private func locked<T>(_ operation: () throws -> T) throws -> T { try transaction(operation) }

    public func state() throws -> RuntimeState { try state(beforeDecode: {}) }

    func state(beforeDecode: () throws -> Void) throws -> RuntimeState {
        let snapshot = try locked { try readStateData() }
        return try decodeState(snapshot, beforeDecode: beforeDecode)
    }

    public func update(_ action: (inout RuntimeState) throws -> Void) throws {
        try locked {
            var state = try load()
            let previousLayout = state.layout
            try action(&state)
            try validateClosedTerminalLayoutMutation(from: previousLayout, to: state.layout)
            try applyInterfaceTopology(from: previousLayout, to: &state.layout)
            try save(state)
        }
    }

    private func load() throws -> RuntimeState { try decodeState(readStateData()) }

    private func readStateData() throws -> (primary: Data, continuity: Data?, organizations: Data?, masterView: Data?)? {
        let url = root.appendingPathComponent("state.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let primary = try Data(contentsOf: url)
        let continuity = try continuityData()
        let organizations = try organizationSidecarData()
        let masterView = try? masterViewData()
        return (primary, continuity, organizations, masterView ?? nil)
    }

    private func decodeState(_ snapshot: (primary: Data, continuity: Data?, organizations: Data?, masterView: Data?)?,
                             beforeDecode: () throws -> Void = {}) throws -> RuntimeState {
        guard let snapshot else { return RuntimeState() }
        try beforeDecode()
        var result = try JSONDecoder().decode(RuntimeState.self, from: snapshot.primary)
        guard result.schemaVersion == 1 else { throw TerminalError.invalid("Unsupported state schema") }
        try restoreContinuity(to: &result, data: snapshot.continuity)
        try restoreAccountOrganizations(to: &result, data: snapshot.organizations)
        applyMasterView(to: &result, data: snapshot.masterView)
        return result
    }

    private func save(_ state: RuntimeState) throws {
        var state = state
        state.revision += 1
        try persistAccountOrganizations(from: &state)
        try persistContinuity(from: &state)
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

    /// Talks to a tmux server left by a release that hosted panes in tmux. Used only by legacy migration.
    @discardableResult func legacyTmux(_ args: [String], allowFailure: Bool = false, outputLimit: Int = 1_048_576) throws -> String {
        guard let executable = legacyTmuxExecutable else {
            if allowFailure { return "" }
            throw TerminalError.runtime("tmux is unavailable")
        }
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "TMUX")
        for key in ["REX_BLOCK", "REX_SESSION", "REX_SERVER", "TRANO_LAUNCH_ID"] { environment.removeValue(forKey: key) }
        environment["TERM"] = "xterm-256color"
        environment["LC_MESSAGES"] = "C"
        let arguments = (["-u", "-S", legacySocketPath] + args)
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

    public func create(title: String, cwd: String, shell: String? = nil, arguments: [String]? = nil, restoringID: String? = nil, reservedID: String? = nil, closedArchiveID: String? = nil) throws -> TerminalSession {
        try locked {
            if let restoringID, try isTerminalIntentionallyClosed(restoringID) {
                guard let closedArchiveID, try closedTerminalPaneSnapshot(restoringID)?.archiveID == closedArchiveID else {
                    throw TerminalError.invalid("Use Reopen Closed Terminal to restore an intentionally closed terminal")
                }
            }
            let preferences = shell == nil && arguments == nil && restoringID == nil
                ? try terminalPreferences() : TerminalPreferences()
            let selected = try TerminalLaunchSelection.resolve(preferences: preferences, shell: shell,
                                                               arguments: arguments, restoringID: restoringID)
            let resolvedShell = selected.executable
            let resolvedArguments = selected.arguments
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: cwd, isDirectory: &directory), directory.boolValue,
                  FileManager.default.isExecutableFile(atPath: resolvedShell), title.count <= 200 else {
                throw TerminalError.invalid("Invalid working directory, shell or title")
            }
            let previous = try restoringID.map { try requireSession($0) }
            let id = try TerminalCreationIdentity.resolve(restoringID: previous?.id, reservedID: reservedID,
                existingPaneIDs: Set(try load().sessions.map(\.id)))
            let path = URL(fileURLWithPath: cwd).standardizedFileURL.path
            var environment = ["TRANO_SESSION=" + id, "TRANO_REOPEN_ARCHIVE=" + (closedArchiveID ?? ""), "TRANO_LAUNCH_ID=", "TRANO_DATA_DIR=" + root.path, "COLORTERM=truecolor"]
            if let helperExecutable { environment.append("TRANO_CLI_PATH=" + helperExecutable) }
            let prepared = try prepareTerminalShell(selected, paneID: id, restoring: previous != nil)
            environment += paneEnvironmentOverlay + prepared.environment
            try rememberTerminalShell(selected, paneID: id)
            let replayScrollback: Bool
            if previous?.remote == nil, previous != nil, helperExecutable != nil {
                replayScrollback = try load().settings.persistScrollback
            } else {
                replayScrollback = false
            }
            var command = TerminalLaunchSelection.argv(prepared.command, replayScrollback: replayScrollback && closedArchiveID == nil)
            if let closedArchiveID, previous?.remote == nil {
                let screen = try closedTerminalStore.screenFile(id: closedArchiveID)
                command = ["/bin/sh", "-c", "/bin/cat \"$1\"; shift; exec \"$@\"", "trano-reopen", screen.path] + [prepared.command.executable] + prepared.command.arguments
            }
            if let existing = try host.pane(id) {
                guard !existing.alive else { throw TerminalError.invalid("Terminal is already running") }
                try host.kill(id)
            }
            let pid = try host.create(id: id, argv: command, environment: environment, cwd: path)
            var state = try load()
            var item = previous ?? TerminalSession(id: id, title: title.isEmpty ? "Terminal" : title, cwd: path, pid: pid)
            item.pid = pid; item.alive = true; item.cwd = path
            if let index = state.sessions.firstIndex(where: { $0.id == id }) { state.sessions[index] = item }
            else { state.sessions.append(item) }
            do {
                if let closedArchiveID {
                    var ledger = try closedTerminalStore.ledger()
                    guard ledger.panes[id]?.archiveID == closedArchiveID else { throw TerminalError.invalid("Reopen archive changed") }
                    ledger.panes[id]?.restoredPID = pid
                    ledger.panes[id]?.restoredProcess = SupervisorProcessIdentity.read(pid)
                    try closedTerminalStore.save(ledger)
                }
                try save(state)
                if let helperExecutable {
                    let command = "exec /usr/bin/env " + ShellQuote.quote("TRANO_DATA_DIR=" + root.path) + " " + ShellQuote.quote(helperExecutable) + " monitor " + ShellQuote.quote(id) + " " + String(pid)
                    try host.pipe(id, command: command)
                }
            } catch {
                try? host.kill(id)
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
            try host.kill(id)
            _ = try create(title: pane.title, cwd: cwd, restoringID: id)
        }
    }

    public func restoreRemoteBridge(_ id: String) throws {
        let (original, host): (TerminalSession, RemoteHost) = try transaction {
            guard try !isTerminalIntentionallyClosed(id) else { throw TerminalError.invalid("Use Reopen Closed Terminal for this remote terminal") }
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
            try self.host.kill(id)
            _ = try create(title: pane.title, cwd: FileManager.default.homeDirectoryForCurrentUser.path, shell: "/usr/bin/ssh", arguments: RemoteClient(host: host).attachArguments(sessionID: remote.sessionID), restoringID: id)
            try update { state in if let index = state.sessions.firstIndex(where: { $0.id == id }) { state.sessions[index].cwd = pane.cwd } }
        }
    }

    public func list() throws -> [TerminalSession] {
        var sessions = try state().sessions
        let live = Dictionary(try host.list().compactMap { pane -> (String, (Int32, Bool, String?))? in
            guard UUID(uuidString: pane.id) != nil else { return nil }
            return (pane.id, (pane.pid, pane.alive, TerminalTitleMetadata.normalize(pane.title)))
        }, uniquingKeysWith: { left, _ in left })
        for i in sessions.indices {
            sessions[i].alive = live[sessions[i].id]?.1 == true
            if let pid = live[sessions[i].id]?.0 { sessions[i].pid = pid }
            sessions[i].terminalTitle = live[sessions[i].id]?.2
        }
        let programs = foregroundProgramProbe.programs(for: sessions, refreshIdentity: true)
        for i in sessions.indices where sessions[i].remote == nil {
            sessions[i].foregroundProgram = programs[sessions[i].id]
        }
        return sessions
    }

    public func foregroundPrograms(for sessions: [TerminalSession]) -> [String: TerminalProgram] {
        foregroundProgramProbe.programs(for: sessions)
    }

    public func sessionLoadTargets() throws -> [SessionLoadTarget] {
        let snapshot = try state()
        return SessionLoadTargetResolver.resolve(sessions: snapshot.sessions, launches: snapshot.agentLaunches, panes: try host.list())
    }

    public func send(_ id: String, text: String, enter: Bool = false) throws {
        try send(id, text: text, enter: enter, beforeWrite: nil)
    }

    func send(_ id: String, text: String, enter: Bool, beforeWrite: (() throws -> Void)?) throws {
        try locked {
            _ = try requireSession(id)
            guard text.utf8.count <= 65536, !text.contains("\0") else { throw TerminalError.invalid("Input exceeds 64 KiB or contains NUL") }
            if !text.isEmpty || enter { try markTerminalInputUncertain(paneID: id) }
            try beforeWrite?()
            if !text.isEmpty { try host.write(id, Data(text.utf8)) }
            if enter { try host.write(id, Data([13])) }
        }
    }

    public func capture(_ id: String, lines: Int = 100) throws -> String {
        try locked {
            _ = try requireSession(id)
            guard (1...10_000).contains(lines) else { throw TerminalError.invalid("Capture line limit is 1...10000") }
            return try host.capture(id, lines: lines)
        }
    }

    public func workingDirectory(_ id: String) throws -> String {
        if let reference = try state().sessions.first(where: { $0.id == id })?.remote {
            guard let remote = try remoteSessions(hostID: reference.hostID).first(where: { $0.id == reference.sessionID }) else { throw TerminalError.invalid("Remote session no longer exists") }
            return remote.cwd
        }
        return try locked {
            _ = try requireSession(id)
            return try host.workingDirectory(id)
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
            if source != "hook" || state != .done {
                for turnIndex in store.followUpTurns.indices where store.followUpTurns[turnIndex].paneID == id {
                    store.followUpTurns[turnIndex].completionID = nil
                    if source != "hook" { store.followUpTurns[turnIndex].armed = false }
                }
            }
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
            try host.kill(id)
            guard try host.pane(id) == nil else { throw TerminalError.runtime("Session did not terminate") }
            var store = try load()
            store.sessions.removeAll { $0.id == id }
            store.agentLaunches.removeAll { $0.paneID == id }
            store.recoveryResults.removeAll { $0.paneID == id }
            store.followUpInputs.removeAll { $0.paneID == id }
            store.followUpTurns.removeAll { $0.paneID == id }
            store.followUpPasteStates.removeAll { $0.paneID == id }
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
            guard try !isTerminalIntentionallyClosed(id) else { throw TerminalError.invalid("Use Reopen Closed Terminal for this remote terminal") }
            let pid = try host.respawn(id: id, argv: ["/usr/bin/ssh"] + arguments, environment: nil, cwd: nil)
            try update { state in
                if let index = state.sessions.firstIndex(where: { $0.id == id }) { state.sessions[index].pid = pid; state.sessions[index].alive = true }
            }
            if let helperExecutable {
                let command = "exec /usr/bin/env " + ShellQuote.quote("TRANO_DATA_DIR=" + root.path) + " " + ShellQuote.quote(helperExecutable) + " monitor " + ShellQuote.quote(id) + " " + String(pid)
                try host.pipe(id, command: command)
            }
        }
    }

    public func attachCommand(_ id: String) throws -> (executable: String, arguments: [String]) {
        try validateID(id)
        guard let executable = PaneHostClient.resolveExecutable(helperExecutable) else {
            throw TerminalError.runtime("The trano helper is required to attach to a terminal")
        }
        return (executable, host.attachArguments(id))
    }
}
