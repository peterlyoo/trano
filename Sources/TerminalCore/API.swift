import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum JSONValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    public init(from decoder: Decoder) throws {
        let box = try decoder.singleValueContainer()
        if box.decodeNil() { self = .null }
        else if let value = try? box.decode(Bool.self) { self = .bool(value) }
        else if let value = try? box.decode(Double.self) { self = .number(value) }
        else if let value = try? box.decode(String.self) { self = .string(value) }
        else if let value = try? box.decode([String: JSONValue].self) { self = .object(value) }
        else { self = .array(try box.decode([JSONValue].self)) }
    }
    public func encode(to encoder: Encoder) throws {
        var box = encoder.singleValueContainer()
        switch self {
        case .string(let value): try box.encode(value)
        case .number(let value): try box.encode(value)
        case .bool(let value): try box.encode(value)
        case .object(let value): try box.encode(value)
        case .array(let value): try box.encode(value)
        case .null: try box.encodeNil()
        }
    }
    public subscript(_ key: String) -> JSONValue? {
        if case .object(let object) = self { return object[key] }; return nil
    }
    var text: String? { if case .string(let value) = self { return value }; return nil }
    static func encoded<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: JSONEncoder().encode(value))
    }
}

public struct APIRequest: Codable {
    public var apiVersion: Int
    public var method: String
    public var params: [String: JSONValue]
    public init(apiVersion: Int = 1, method: String, params: [String: JSONValue] = [:]) {
        self.apiVersion = apiVersion; self.method = method; self.params = params
    }
}

public struct APIResponse: Codable {
    public let apiVersion: Int
    public let result: JSONValue?
    public let error: String?
    init(result: JSONValue? = nil, error: String? = nil) { apiVersion = 1; self.result = result; self.error = error }
}

public enum UnixSocket {
    public static func make() throws -> Int32 {
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw TerminalError.runtime("Cannot create API socket") }
        configure(fd)
        return fd
    }
    public static func configure(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        #if !os(Linux)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0, gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }
    public static func peerPID(_ fd: Int32) -> Int32? {
        #if canImport(Darwin)
        var pid: pid_t = 0
        var length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0,
              length == MemoryLayout<pid_t>.size, pid > 1 else { return nil }
        return pid
        #else
        return nil
        #endif
    }
    public static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw TerminalError.invalid("API socket path too long") }
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            bytes.withUnsafeBytes { destination.copyMemory(from: $0) }
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { try body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
    public static func sendLine(_ data: Data, fd: Int32) throws {
        guard data.count <= 1_048_576 else { throw TerminalError.invalid("API message exceeds 1 MiB") }
        var line = data
        line.append(10)
        try line.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                #if os(Linux)
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                #else
                let count = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                #endif
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TerminalError.runtime("API write failed") }
                offset += count
            }
        }
    }
    public static func receiveLine(fd: Int32) throws -> Data {
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while result.count <= 1_048_576 {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw TerminalError.runtime("API read timed out or disconnected") }
            result.append(contentsOf: bytes.prefix(count))
            if let newline = result.firstIndex(of: 10) {
                guard newline <= 1_048_576 else { throw TerminalError.invalid("API message exceeds 1 MiB") }
                return Data(result[..<newline])
            }
        }
        throw TerminalError.invalid("API message exceeds 1 MiB")
    }
}

public struct APIClient {
    public let path: String
    public init(path: String) { self.path = path }
    public func call(_ request: APIRequest) throws -> APIResponse {
        let fd = try UnixSocket.make()
        defer { close(fd) }
        guard try UnixSocket.address(path, { connect(fd, $0, $1) }) == 0 else { throw TerminalError.runtime("API server is not available") }
        if request.method.hasPrefix("remote.") || request.method == "accounts.usage.refresh" || request.method.hasPrefix("recovery.") || request.method == "actions.perform" {
            var timeout = timeval(tv_sec: 90, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        }
        try UnixSocket.sendLine(JSONEncoder().encode(request), fd: fd)
        return try JSONDecoder().decode(APIResponse.self, from: UnixSocket.receiveLine(fd: fd))
    }
}

public final class APIService {
    public var path: String { twinScope.flatMap { try? runtime.twinSocketPath(runID: $0.runID) } ?? runtime.root.appendingPathComponent("api.sock").path }
    private let twinScope: TwinAPIScope?
    private var twinWorker: PessimisticTwinWorker?
    private let runtime: TerminalRuntime
    private var source: DispatchSourceRead?
    private var stopped: DispatchSemaphore?
    private var followUpTimer: DispatchSourceTimer?
    private var worktreeCleanupWorker: WorktreeCleanupWorker?
    private let followUpQueue = DispatchQueue(label: "trano.followups", qos: .utility)
    private let lifecycle = NSLock()
    private let acceptQueue = DispatchQueue(label: "trano.api.accept")
    private let acceptQueueKey = DispatchSpecificKey<Bool>()
    private let clients = DispatchSemaphore(value: 16)
    private let identity = BuildIdentity.process
    private let startedAt = ProcessInfo.processInfo.systemUptime
    private var remoteCoordinator: RemoteServingCoordinator?
    private let remoteLock = NSLock()
    private var remoteServiceStopped = false
    private var remoteGeneration: UInt64 = 0
    private let tailscaleEvents = TailscaleStatusEvents()
    private let responseDidSend: ((APIRequest, APIResponse) -> Void)?
    private let customHandler: ((APIRequest) throws -> JSONValue?)?
    private let serverStatus: (() -> JSONValue)?
    private var sessionLoadSampler: SessionLoadSampler
    private var sessionLoadTimer: DispatchSourceTimer?
    private let sessionLoadQueue = DispatchQueue(label: "trano.session-load.targets", qos: .utility)
    private var sessionLoadStopped = false
    public init(runtime: TerminalRuntime, customHandler: ((APIRequest) throws -> JSONValue?)? = nil, responseDidSend: ((APIRequest, APIResponse) -> Void)? = nil,
                sessionLoadSampler: SessionLoadSampler? = nil, serverStatus: (() -> JSONValue)? = nil, twinScope: TwinAPIScope? = nil) {
        self.runtime = runtime
        self.twinScope = twinScope
        self.serverStatus = serverStatus
        self.customHandler = customHandler
        self.responseDidSend = responseDidSend
        self.sessionLoadSampler = sessionLoadSampler ?? SessionLoadSampler(source: SessionLoadNativeSource(bindings: { (try? runtime.sessionLoadHookBindings()) ?? [] }))
        acceptQueue.setSpecific(key: acceptQueueKey, value: true)
    }

    public func start() throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard source == nil else { throw TerminalError.invalid("API server already started") }
        if let twinScope { _ = try runtime.twinSocketPath(runID: twinScope.runID) }
        let lease = open(runtime.root.appendingPathComponent(twinScope.map { "twin-" + $0.runID + ".lock" } ?? "api.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0 else { throw TerminalError.runtime("Cannot open API lease") }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else { close(lease); throw TerminalError.runtime("API server is already running") }
        var fd: Int32 = -1
        do {
            fd = try UnixSocket.make()
            if FileManager.default.fileExists(atPath: path) {
                let probe = try UnixSocket.make()
                let result = try UnixSocket.address(path) { connect(probe, $0, $1) }
                let failure = errno
                close(probe)
                if result == 0 { throw TerminalError.invalid("API server is already running") }
                let attributes = try FileManager.default.attributesOfItem(atPath: path)
                guard failure == ECONNREFUSED, attributes[.type] as? FileAttributeType == .typeSocket,
                      (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid() else {
                    throw TerminalError.invalid("Refusing to replace unmanaged API socket")
                }
                try FileManager.default.removeItem(atPath: path)
            }
            guard try UnixSocket.address(path, { bind(fd, $0, $1) }) == 0 else { throw TerminalError.runtime("Cannot bind API socket") }
            guard chmod(path, 0o600) == 0, listen(fd, 16) == 0 else { throw TerminalError.runtime("Cannot listen on API socket") }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            let path = self.path
            var identity = stat()
            guard lstat(path, &identity) == 0 else { throw TerminalError.runtime("Cannot identify API socket") }
            let inode = identity.st_ino, device = identity.st_dev
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
            source.setEventHandler { [weak self] in
                guard let self else { return }
                while true {
                    let client = accept(fd, nil, nil)
                    if client < 0 { break }
                    UnixSocket.configure(client)
                    guard self.clients.wait(timeout: .now()) == .success else { close(client); continue }
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        defer { close(client); self.clients.signal() }
                        do {
                            let data = try UnixSocket.receiveLine(fd: client)
                            let raw = try JSONDecoder().decode(JSONValue.self, from: data)
                            if raw["type"] != nil {
                                let response: JSONValue
                                do {
                                    guard data.count <= 512 * 1024 else { throw TerminalError.invalid("Decision frame exceeds 512 KiB") }
                                    let peerPID = UnixSocket.peerPID(client)
                                    if raw["type"] == .string("submit"), peerPID == nil { throw TerminalError.invalid("Cannot verify decision socket peer") }
                                    if let scope = self.twinScope { response = try self.runtime.scopedTwinDecision(raw, scope: scope, originPID: peerPID) }
                                    else {
                                        if let peerPID, try self.runtime.isTwinPeer(peerPID) { throw TerminalError.invalid("Use the twin scoped decision socket") }
                                        response = try self.runtime.decisionAdapter(raw, originPID: peerPID)
                                    }
                                }
                                catch { response = .object(["ok": .bool(false), "error": .string("INBOX_UNAVAILABLE"), "detail": .string(error.localizedDescription)]) }
                                try UnixSocket.sendLine(JSONEncoder().encode(response), fd: client)
                            } else {
                                let request = try JSONDecoder().decode(APIRequest.self, from: data)
                                let response = self.route(request, originPID: UnixSocket.peerPID(client))
                                try UnixSocket.sendLine(JSONEncoder().encode(response), fd: client)
                                self.responseDidSend?(request, response)
                            }
                        } catch {
                            if let response = try? JSONEncoder().encode(APIResponse(error: error.localizedDescription)) {
                                try? UnixSocket.sendLine(response, fd: client)
                            }
                        }
                    }
                }
            }
            let done = DispatchSemaphore(value: 0)
            let ownedFD = fd
            source.setCancelHandler {
                close(ownedFD)
                var current = stat()
                if lstat(path, &current) == 0 && current.st_ino == inode && current.st_dev == device { unlink(path) }
                close(lease)
                done.signal()
            }
            stopped = done
            self.source = source
            source.resume()
            if twinScope != nil { return }
            let worker = PessimisticTwinWorker(runtime: runtime)
            twinWorker = worker
            worker.start()
            let timer = DispatchSource.makeTimerSource(queue: followUpQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(500), leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in try? self?.runtime.processPendingFollowUps() }
            followUpTimer = timer
            timer.resume()
            let worktreeWorker = WorktreeCleanupWorker(runtime: runtime)
            worktreeCleanupWorker = worktreeWorker
            worktreeWorker.start()
            if sessionLoadStopped {
                sessionLoadSampler = SessionLoadSampler(source: SessionLoadNativeSource(bindings: { [runtime] in (try? runtime.sessionLoadHookBindings()) ?? [] }))
                sessionLoadStopped = false
            }
            let loadTimer = DispatchSource.makeTimerSource(queue: sessionLoadQueue)
            let sampler = sessionLoadSampler
            loadTimer.schedule(deadline: .now(), repeating: .seconds(2), leeway: .milliseconds(250))
            loadTimer.setEventHandler { [weak self] in
                guard let self, let targets = try? self.runtime.sessionLoadTargets() else { return }
                sampler.requestRefresh(targets: targets)
            }
            sessionLoadTimer = loadTimer
            loadTimer.resume()
            remoteLock.lock()
            remoteServiceStopped = false; remoteGeneration &+= 1
            let generation = remoteGeneration
            remoteLock.unlock()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                guard let self, self.remoteActivationIsCurrent(generation),
                      (try? self.runtime.serverPreferences().serveOverTailscale) == true else { return }
                do { try self.remoteServing(generation: generation).restoreIfEnabled() }
                catch {
                    guard self.remoteActivationIsCurrent(generation) else { return }
                    try? TerminalRuntime.atomicWrite(Data((error.localizedDescription + "\n").utf8), to: self.runtime.root.appendingPathComponent("remote-service-diagnostic"))
                }
            }
        } catch { if fd >= 0 { close(fd) }; close(lease); throw error }
    }

    public func stop() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        twinWorker?.stop(); twinWorker = nil
        worktreeCleanupWorker?.stop(); worktreeCleanupWorker = nil
        followUpTimer?.cancel()
        followUpTimer = nil
        sessionLoadTimer?.cancel()
        sessionLoadTimer = nil
        sessionLoadSampler.stop()
        sessionLoadStopped = true
        remoteLock.lock()
        remoteServiceStopped = true; remoteGeneration &+= 1
        let remote = remoteCoordinator; remoteCoordinator = nil
        remoteLock.unlock()
        remote?.invalidate()
        source?.cancel()
        if DispatchQueue.getSpecific(key: acceptQueueKey) == nil { stopped?.wait() }
        source = nil; stopped = nil
    }
    deinit { stop() }

    public func route(_ request: APIRequest, originPID: Int32? = nil) -> APIResponse {
        do {
            guard request.apiVersion == 1 else { throw TerminalError.invalid("Unsupported API version") }
            if twinScope == nil, let originPID, try runtime.isTwinPeer(originPID) { throw TerminalError.invalid("Twin processes must use their scoped API") }
            if let value = try runtime.twinAPI(request, originPID: originPID, scope: twinScope) { return APIResponse(result: value) }
            if twinScope != nil { throw TerminalError.invalid("Method unavailable on the twin scoped API") }
            if let notifications = try NotificationPreferencesAPI.handle(request, runtime: runtime) { return APIResponse(result: notifications) }
            func required(_ key: String) throws -> String {
                guard let value = request.params[key]?.text else { throw TerminalError.invalid("Missing string parameter: \(key)") }
                return value
            }
            func optionalOrganizationString(_ key: String) throws -> String? {
                guard let value = request.params[key], value != .null else { return nil }
                guard let text = value.text else { throw TerminalError.invalid(key + " must be a string") }
                return text
            }
            func organizationSelection() throws -> ClaudeOrganizationSelection? {
                let uuid = try optionalOrganizationString("organizationUUID")
                let name = try optionalOrganizationString("organizationName")
                guard let uuid else {
                    guard name == nil else { throw TerminalError.invalid("An organization name requires its UUID") }
                    return nil
                }
                return try ClaudeOrganizationSelection(uuid: uuid, name: name)
            }
            var result: JSONValue = .object(["ok": .bool(true)])
            switch request.method {
            case "worktrees.status":
                result = .object(["enabled": .bool(try runtime.integrationsPreferences().automaticallyCleanWorktrees),
                    "trackingAvailable": .bool(GitTrackingShell.isInstalled(root: runtime.root)),
                    "scope": .string("future-local-session-creations"),
                    "graceSeconds": .number(30),
                    "records": try .encoded(WorktreeCleanupStore(root: runtime.root).load().records)])
            case "worktrees.configure":
                guard originPID != nil, case .bool(let enabled)? = request.params["enabled"] else {
                    throw TerminalError.invalid("Worktree configuration requires a boolean and the local Unix API")
                }
                let preferences = try SecureSettingsSidecar<IntegrationsPreferences>(root: runtime.root, filename: "integrations-settings.json").update { $0.automaticallyCleanWorktrees = enabled }
                result = .object(["enabled": .bool(preferences.automaticallyCleanWorktrees)])
            case "worktrees.retry":
                guard originPID != nil else { throw TerminalError.invalid("Worktree cleanup requires the local Unix API") }
                try runtime.worktreeCleanupCoordinator().retry(id: required("id"))
            case "worktrees.keep":
                guard originPID != nil else { throw TerminalError.invalid("Worktree cleanup requires the local Unix API") }
                try runtime.keepWorktree(id: required("id"))
            case "worktrees.diagnostics":
                guard originPID != nil else { throw TerminalError.invalid("Worktree diagnostics require the local Unix API") }
                let census = try WorktreeNativeGitProcessProbe().snapshot(limit: 16_384)
                result = .object(["processCensusComplete": .bool(census.complete), "processCount": .number(Double(census.records.count)),
                    "trackingAvailable": .bool(GitTrackingShell.isInstalled(root: runtime.root))])
            case "supervisor.state", "supervisor.start", "supervisor.stop", "supervisor.continue":
                guard let value = try SupervisorAPI.route(request, operations: runtime.supervisorOperations()) else {
                    throw TerminalError.invalid("Unsupported Supervisor API method")
                }
                result = value
            case "server.info":
                var information: [String: JSONValue] = ["apiVersion": .number(1), "version": .string(identity.version), "buildNumber": .string(identity.buildNumber), "buildID": .string(identity.buildID), "pid": .number(Double(getpid())), "serviceKind": .string(CommandLine.arguments.contains("--service") ? "background" : "cli"), "uptime": .number(max(0, ProcessInfo.processInfo.systemUptime - startedAt))]
                if request.params["healthOnly"] != .bool(true) {
                    information["label"] = .string(try runtime.serverPreferences().clientLabel)
                    information["localAPIURL"] = .string("unix://" + path)
                    information["remoteReady"] = .bool(remoteTarget != nil)
                }
                if let serverStatus { information["serverStatus"] = serverStatus() }
                result = .object(information)
            case "agent.name-session":
                try runtime.nameAgentSession(paneID: required("paneID"), generation: required("generation"), expectedTitle: required("expectedTitle"), title: required("title"), originPID: originPID)
            case "server.preferences.get": result = try .encoded(runtime.serverPreferences())
            case "server.tailscale.observe":
                guard originPID != nil else { throw TerminalError.invalid("Network status reports require the local Unix API") }
                publishTailscale(state: request.params["state"]?.text, failed: request.params["failed"] == .bool(true))
            case "server.remote.status": result = .object(["ready": .bool(remoteTarget != nil), "target": remoteTarget.map { .string($0) } ?? .null])
            case "server.remote.start":
                guard originPID != nil else { throw TerminalError.invalid("Remote serving requires the local Unix API") }
                result = .object(["target": .string(try remoteServing().start()), "ready": .bool(true)])
            case "server.remote.stop":
                guard originPID != nil else { throw TerminalError.invalid("Remote serving requires the local Unix API") }
                remoteLock.lock(); let remote = remoteCoordinator; remoteLock.unlock(); remote?.stop()
            case "server.clients.list": result = try .encoded(RemotePairingStore(root: runtime.root).clients())
            case "server.clients.revoke":
                guard originPID != nil else { throw TerminalError.invalid("Client administration requires the local Unix API") }
                try RemotePairingStore(root: runtime.root).revoke(id: required("id"))
            case "server.clients.remote-control":
                guard originPID != nil, case .bool(let allowed)? = request.params["allowed"] else { throw TerminalError.invalid("Client administration requires a boolean and the local Unix API") }
                try RemotePairingStore(root: runtime.root).setRemoteControl(id: required("id"), allowed: allowed)
            case "server.pairing.invite":
                guard originPID != nil, try runtime.serverPreferences().serveOverTailscale, remoteTarget != nil else { throw TerminalError.invalid("Enable remote serving before pairing a client") }
                let invitation = try remoteServing().pairing.invite()
                result = .object(["code": .string(invitation.code), "expiresAt": .number(invitation.expiresAt.timeIntervalSince1970)])
            case "sessions.list":
                let query = request.params["query"]?.text ?? ""
                result = try .encoded(runtime.list().filter { query.isEmpty || ($0.title + " " + $0.cwd).localizedCaseInsensitiveContains(query) })
            case "sessions.load":
                if let paneID = request.params["paneID"], paneID.text == nil { throw TerminalError.invalid("paneID must be a string") }
                let paneID = request.params["paneID"]?.text
                func pageValue(_ key: String, fallback: Int, range: ClosedRange<Int>) throws -> Int {
                    guard let value = request.params[key] else { return fallback }
                    guard case .number(let number) = value, number.isFinite, number.rounded() == number,
                          number >= Double(range.lowerBound), number <= Double(range.upperBound) else {
                        throw TerminalError.invalid(key + " is outside the supported page range")
                    }
                    return Int(number)
                }
                let offset = try pageValue("offset", fallback: 0, range: 0...4096)
                let limit = try pageValue("limit", fallback: 64, range: 1...64)
                lifecycle.lock()
                let sampler = sessionLoadSampler
                lifecycle.unlock()
                result = try .encoded(Array(sampler.snapshots().filter { paneID == nil || $0.paneID == paneID }.dropFirst(offset).prefix(limit)))
            case "sessions.create": result = try .encoded(runtime.create(title: request.params["title"]?.text ?? "Terminal", cwd: required("cwd")))
            case "sessions.terminate": try runtime.terminate(required("id"))
            case "sessions.attach":
                let id = try required("id")
                try runtime.update { state in
                    try runtime.requireOrdinaryPane(id,
                        attachedPaneIDs: Set((state.layout.tabs + state.layout.closedTabs).flatMap(\.panes)))
                    guard state.sessions.contains(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown session") }
                    if state.layout.tabs.contains(where: { $0.panes.contains(id) }) { try state.layout.focusPane(id) }
                    else { state.layout.addTab(paneID: id) }
                    if let workspaceID = state.layout.selectedWorkspaceID { state.navigationRequest = NavigationRequest(workspaceID: workspaceID, paneID: id) }
                }
            case "panes.capture": result = try .object(["text": .string(runtime.capture(required("id")))])
            case "panes.send": try runtime.send(required("id"), text: required("text"), enter: request.params["enter"] == .bool(true))
            case "followups.list": result = try .encoded(runtime.followUps(paneID: required("paneID")))
            case "followups.add": result = try .encoded(runtime.addFollowUp(paneID: required("paneID"), text: required("text")))
            case "followups.update": result = try .encoded(runtime.updateFollowUp(id: required("id"), text: required("text")))
            case "followups.remove": try runtime.removeFollowUp(id: required("id"))
            case "activity.report":
                guard let state = ActivityState(rawValue: try required("state")), let agent = AgentKind(rawValue: request.params["agent"]?.text ?? "shell") else { throw TerminalError.invalid("Invalid state or agent") }
                try runtime.report(required("id"), state: state, reason: request.params["reason"]?.text ?? "", agent: agent)
            case "state.get": result = try .encoded(runtime.state())
            case "decisions.list": result = try .encoded(runtime.decisionInbox(paneID: request.params["paneID"]?.text))
            case "decisions.resolve":
                result = try .encoded(runtime.resolveDecision(required("id"), generation: required("generation"), action: required("action"), optionID: request.params["optionID"]?.text, instruction: request.params["instruction"]?.text, locale: request.params["locale"]?.text))
            case "decisions.delete": try runtime.deleteDecision(required("id"))
            case "decisions.abandon": result = try runtime.decisionAdapter(.object(["type": .string("abandon"), "request_id": .string(required("id"))]))
            case "scrollback.list": result = try .encoded(runtime.scrollbackMetadata())
            case "scrollback.settings":
                guard case .bool(let enabled)? = request.params["enabled"] else { throw TerminalError.invalid("enabled must be a boolean") }
                try runtime.setScrollbackPersistence(enabled)
            case "recovery.list": result = try .encoded(runtime.state().recoveryResults)
            case "recovery.run": result = try .encoded(runtime.recoverSessions(paneID: request.params["id"]?.text))
            case "recovery.retry":
                guard let id = request.params["id"]?.text else { result = try .encoded(runtime.recoverSessions()); break }
                result = try .encoded(runtime.retryRecovery(paneID: id))
            case "recovery.settings":
                guard case .bool(let enabled)? = request.params["automaticRestore"] else { throw TerminalError.invalid("automaticRestore must be a boolean") }
                try runtime.update { $0.settings.automaticRestore = enabled }
                result = .object(["automaticRestore": .bool(enabled)])
            case "workspaces.list": result = try .encoded(runtime.state().layout.workspaces)
            case "accounts.list": result = try .encoded(runtime.state().accounts)
            case "accounts.usage": result = try .encoded(runtime.accountUsage())
            case "accounts.usage.refresh": result = try .encoded(runtime.refreshAccountUsage(accountID: required("id")))
            case "accounts.update":
                func optionalBool(_ key: String) throws -> Bool? {
                    guard let value = request.params[key] else { return nil }
                    guard case .bool(let flag) = value else { throw TerminalError.invalid(key + " must be a boolean") }
                    return flag
                }
                try runtime.updateAccount(required("id"), label: request.params["label"]?.text, enabled: optionalBool("enabled"), pinned: optionalBool("pinned"))
                result = try .encoded(runtime.state().accounts)
            case "accounts.reorder":
                guard case .array(let ids)? = request.params["ids"], ids.allSatisfy({ $0.text != nil }) else { throw TerminalError.invalid("ids must be an array of strings") }
                try runtime.reorderAccounts(ids.compactMap(\.text))
            case "accounts.switch": result = try .encoded(runtime.requestAccountSwitch(paneID: required("paneID"), targetAccountID: required("accountID")))
            case "accounts.switching":
                guard case .bool(let enabled)? = request.params["enabled"] else { throw TerminalError.invalid("enabled must be a boolean") }
                try runtime.update { $0.settings.automaticAccountSwitching = enabled }
            case "accounts.add":
                guard let provider = AgentKind(rawValue: try required("provider")) else { throw TerminalError.invalid("Unknown provider") }
                result = try .encoded(runtime.addAccount(provider: provider, label: required("label"), organization: organizationSelection()))
            case "accounts.organizations": result = try .encoded(runtime.knownAccountOrganizations())
            case "accounts.organization.set":
                guard request.params["organizationUUID"] != nil else { throw TerminalError.invalid("Provide organizationUUID or null to clear") }
                let id = try required("id")
                try runtime.setAccountOrganization(id, selection: organizationSelection(), expectedBindingID: optionalOrganizationString("expectedBindingID"))
                result = try .encoded(runtime.state().accounts.first { $0.id == id }?.organization)
            case "accounts.organization.refresh":
                result = try .encoded(runtime.refreshAccountOrganization(accountID: required("id"), expectedBindingID: optionalOrganizationString("expectedBindingID")))
            case "accounts.command": result = try .encoded(runtime.accountCommand(required("id"), login: request.params["login"] == .bool(true)))
            case "accounts.launch": result = try .encoded(runtime.launchAccount(required("id"), cwd: required("cwd"), login: request.params["login"] == .bool(true)))
            case "extensions.list": result = try .encoded(runtime.state().extensions)
            case "extensions.import":
                guard let kind = ExtensionKind(rawValue: try required("kind")) else { throw TerminalError.invalid("Unknown extension kind") }
                result = try .encoded(runtime.importExtension(name: required("name"), kind: kind, source: URL(fileURLWithPath: required("path"))))
            case "extensions.enabled": result = try .encoded(runtime.enabledExtensions(accountID: required("accountID")))
            case "extensions.preview":
                guard case .array(let ids)? = request.params["extensionIDs"], ids.allSatisfy({ $0.text != nil }) else { throw TerminalError.invalid("extensionIDs must be an array of strings") }
                result = try .encoded(runtime.extensionPlan(accountID: required("accountID"), extensionIDs: ids.compactMap(\.text)))
            case "extensions.apply":
                guard let plan = request.params["plan"] else { throw TerminalError.invalid("Missing preview plan") }
                try runtime.applyExtensions(JSONDecoder().decode(ExtensionPlan.self, from: JSONEncoder().encode(plan)))
            case "extensions.plugin.command": result = try .encoded(runtime.pluginCommand(accountID: required("accountID"), extensionID: required("extensionID")))
            case "extensions.plugin.install": result = try .encoded(runtime.launchPluginInstall(accountID: required("accountID"), extensionID: required("extensionID"), cwd: required("cwd")))
            case "remote.hosts.list": result = try .encoded(runtime.state().remoteHosts)
            case "remote.hosts.add": result = try .encoded(runtime.addRemoteHost(name: required("name"), address: required("address"), sshConfigPath: request.params["sshConfigPath"]?.text))
            case "remote.hosts.remove": try runtime.removeRemoteHost(required("id"))
            case "remote.installation.check": result = try .encoded(runtime.checkRemoteInstallation(hostID: required("hostID")))
            case "remote.installation.install": result = try .encoded(runtime.installRemoteHelper(hostID: required("hostID"), force: request.params["force"] == .bool(true)))
            case "remote.recovery.run": result = try .encoded(runtime.recoverRemoteSessions(hostID: required("hostID"), sessionID: request.params["id"]?.text))
            case "remote.recovery.list": result = try .encoded(RemoteClient(host: runtime.remoteHost(required("hostID"))).recoveryResults())
            case "remote.sessions.list": result = try .encoded(runtime.remoteSessions(hostID: required("hostID")))
            case "remote.sync": try runtime.syncRemoteHost(required("hostID"))
            case "remote.paths.list": result = try .encoded(runtime.remotePaths(hostID: required("hostID"), path: request.params["path"]?.text ?? ""))
            case "attachments.upload":
                let url = URL(fileURLWithPath: try required("path"))
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                guard attributes[.type] as? FileAttributeType == .typeRegular, (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 20 * 1024 * 1024 else { throw TerminalError.invalid("Select a PNG of at most 20 MiB") }
                result = try .object(["path": .string(runtime.saveAttachment(Data(contentsOf: url), paneID: required("id")))])
            case "remote.sessions.create": result = try .encoded(runtime.createRemoteSession(hostID: required("hostID"), cwd: request.params["cwd"]?.text ?? ""))
            case "remote.sessions.attach":
                let host = try required("hostID"), id = try required("id")
                guard let remote = try runtime.remoteSessions(hostID: host).first(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown remote session") }
                result = try .encoded(runtime.attachRemoteSession(hostID: host, remote: remote))
            case "remote.sessions.reconnect": try runtime.reconnectRemoteSession(required("id"))
            case "remote.sessions.disconnect": try runtime.disconnectRemoteSession(required("id"))
            case "workspaces.launch":
                guard let agent = AgentKind(rawValue: request.params["agent"]?.text ?? "shell") else { throw TerminalError.invalid("Unknown agent") }
                result = try .encoded(runtime.launch(cwd: required("cwd"), agent: agent, prompt: request.params["prompt"]?.text ?? ""))
            case "workspaces.select":
                let id = try required("id")
                try runtime.update { try $0.layout.selectWorkspace(id); $0.navigationRequest = NavigationRequest(workspaceID: id) }
            case "workspaces.master":
                if let value = request.params["id"] {
                    switch value {
                    case .null: try runtime.setMasterWorkspace(nil)
                    case .string(let id): try runtime.setMasterWorkspace(id)
                    default: throw TerminalError.invalid("id must be a workspace ID or null")
                    }
                }
                let master = try runtime.state().layout.masterView
                result = .object(["workspaceID": master.map { .string($0.workspaceID) } ?? .null,
                                  "tabIDs": .array((master?.tabIDs ?? []).map(JSONValue.string))])
            case "actions.list": result = try .encoded(ActionCatalog.resolved(overrides: runtime.state().settings.keyBindings))
            case "actions.perform":
                guard let action = ActionID(rawValue: try required("id")) else { throw TerminalError.invalid("Unknown action") }
                if let title = request.params["title"], title.text == nil { throw TerminalError.invalid("title must be a string") }
                try runtime.performAction(action, cwd: request.params["cwd"]?.text, title: request.params["title"]?.text, workspaceID: request.params["workspaceID"]?.text, tabID: request.params["tabID"]?.text, paneID: request.params["paneID"]?.text, requestNavigation: true)
            case "activity.list": result = try .encoded(runtime.list())
            case "events.list":
                var cursor = 0
                if let value = request.params["since"] {
                    guard case .number(let number) = value, number >= 0, number < Double(Int.max), number.rounded() == number else { throw TerminalError.invalid("Invalid event cursor") }
                    cursor = Int(number)
                }
                result = try .encoded(runtime.events(since: cursor))
            case "panes.detach", "panes.move", "sessions.rename":
                let id = try required("id")
                try runtime.update { store in
                    guard let index = store.sessions.firstIndex(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown session") }
                    if request.method == "panes.detach" { store.layout.detach(id) }
                    else if request.method == "panes.move" { try store.layout.move(paneID: id, to: required("tabID")) }
                    else {
                        let title = try required("title")
                        guard !title.isEmpty, title.count <= 200 else { throw TerminalError.invalid("Title must contain 1...200 characters") }
                        store.sessions[index].title = title
                    }
                }
            default:
                guard let value = try customHandler?(request) else { throw TerminalError.invalid("Unknown API method") }
                result = value
            }
            return APIResponse(result: result)
        } catch { return APIResponse(error: error.localizedDescription) }
    }

    private var remoteTarget: String? {
        remoteLock.lock(); let coordinator = remoteCoordinator; remoteLock.unlock()
        return coordinator?.target
    }

    private func remoteActivationIsCurrent(_ generation: UInt64) -> Bool {
        remoteLock.lock(); defer { remoteLock.unlock() }
        return !remoteServiceStopped && remoteGeneration == generation
    }

    private func remoteServing(generation expected: UInt64? = nil) throws -> RemoteServingCoordinator {
        remoteLock.lock(); defer { remoteLock.unlock() }
        guard !remoteServiceStopped, expected == nil || expected == remoteGeneration else { throw TerminalError.runtime("Server is stopping") }
        let generation = remoteGeneration
        if let remoteCoordinator { return remoteCoordinator }
        let coordinator = try RemoteServingCoordinator(root: runtime.root, listener: PrivateUnixRemoteHTTPListener(root: runtime.root), preferences: { [runtime] in try runtime.serverPreferences() }, identity: { [runtime] in
            guard let executable = BoundedTailscaleExecutor.installedExecutable() else { return nil }
            return try TailscaleAdministration(root: runtime.root, executor: BoundedTailscaleExecutor(executable: executable, timeout: 5)).refresh()
        }, route: { [weak self] request in self?.route(request) ?? APIResponse(error: "Server is stopping") }, statusObserver: { [weak self] snapshot, error in
            guard let self, self.remoteActivationIsCurrent(generation) else { return }
            self.publishTailscale(state: snapshot?.backendState, failed: error != nil)
        })
        remoteCoordinator = coordinator
        return coordinator
    }

    private func publishTailscale(state: String?, failed: Bool) {
        for message in tailscaleEvents.observe(state: state, failed: failed) {
            _ = route(APIRequest(method: "notifications.publish", params: ["kind": .string(message.kind.rawValue), "title": .string(message.title), "body": .string(message.body)]))
        }
    }
}
