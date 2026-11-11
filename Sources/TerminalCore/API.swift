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

private enum UnixSocket {
    static func make() throws -> Int32 {
        #if os(Linux)
        let fd = socket(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0)
        #else
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        #endif
        guard fd >= 0 else { throw TerminalError.runtime("Cannot create API socket") }
        configure(fd)
        return fd
    }
    static func configure(_ fd: Int32) {
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
    static func address<T>(_ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
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
    static func sendLine(_ data: Data, fd: Int32) throws {
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
    static func receiveLine(fd: Int32) throws -> Data {
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
        if request.method.hasPrefix("remote.") || request.method == "accounts.usage.refresh" || request.method.hasPrefix("recovery.") {
            var timeout = timeval(tv_sec: 90, tv_usec: 0)
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        }
        try UnixSocket.sendLine(JSONEncoder().encode(request), fd: fd)
        return try JSONDecoder().decode(APIResponse.self, from: UnixSocket.receiveLine(fd: fd))
    }
}

public final class APIService {
    public var path: String { runtime.root.appendingPathComponent("api.sock").path }
    private let runtime: TerminalRuntime
    private var source: DispatchSourceRead?
    private var stopped: DispatchSemaphore?
    private let lifecycle = NSLock()
    private let acceptQueue = DispatchQueue(label: "trano.api.accept")
    private let acceptQueueKey = DispatchSpecificKey<Bool>()
    private let clients = DispatchSemaphore(value: 16)
    private let identity = BuildIdentity.process
    private let responseDidSend: ((APIRequest, APIResponse) -> Void)?
    private let customHandler: ((APIRequest) throws -> JSONValue?)?
    public init(runtime: TerminalRuntime, customHandler: ((APIRequest) throws -> JSONValue?)? = nil, responseDidSend: ((APIRequest, APIResponse) -> Void)? = nil) {
        self.runtime = runtime
        self.customHandler = customHandler
        self.responseDidSend = responseDidSend
        acceptQueue.setSpecific(key: acceptQueueKey, value: true)
    }

    public func start() throws {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        guard source == nil else { throw TerminalError.invalid("API server already started") }
        let lease = open(runtime.root.appendingPathComponent("api.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
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
                            let request = try JSONDecoder().decode(APIRequest.self, from: UnixSocket.receiveLine(fd: client))
                            let response = self.route(request)
                            try UnixSocket.sendLine(JSONEncoder().encode(response), fd: client)
                            self.responseDidSend?(request, response)
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
        } catch { if fd >= 0 { close(fd) }; close(lease); throw error }
    }

    public func stop() {
        lifecycle.lock()
        defer { lifecycle.unlock() }
        source?.cancel()
        if DispatchQueue.getSpecific(key: acceptQueueKey) == nil { stopped?.wait() }
        source = nil; stopped = nil
    }
    deinit { stop() }

    public func route(_ request: APIRequest) -> APIResponse {
        do {
            guard request.apiVersion == 1 else { throw TerminalError.invalid("Unsupported API version") }
            func required(_ key: String) throws -> String {
                guard let value = request.params[key]?.text else { throw TerminalError.invalid("Missing string parameter: \(key)") }
                return value
            }
            var result: JSONValue = .object(["ok": .bool(true)])
            switch request.method {
            case "server.info": result = .object(["apiVersion": .number(1), "version": .string(identity.version), "buildNumber": .string(identity.buildNumber), "buildID": .string(identity.buildID), "pid": .number(Double(getpid())), "serviceKind": .string(CommandLine.arguments.contains("--service") ? "background" : "cli")])
            case "sessions.list":
                let query = request.params["query"]?.text ?? ""
                result = try .encoded(runtime.list().filter { query.isEmpty || ($0.title + " " + $0.cwd).localizedCaseInsensitiveContains(query) })
            case "sessions.create": result = try .encoded(runtime.create(title: request.params["title"]?.text ?? "Terminal", cwd: required("cwd")))
            case "sessions.terminate": try runtime.terminate(required("id"))
            case "sessions.attach":
                let id = try required("id")
                try runtime.update { state in
                    guard state.sessions.contains(where: { $0.id == id }) else { throw TerminalError.invalid("Unknown session") }
                    if state.layout.tabs.contains(where: { $0.panes.contains(id) }) { try state.layout.focusPane(id) }
                    else { state.layout.addTab(paneID: id) }
                    if let workspaceID = state.layout.selectedWorkspaceID { state.navigationRequest = NavigationRequest(workspaceID: workspaceID, paneID: id) }
                }
            case "panes.capture": result = try .object(["text": .string(runtime.capture(required("id")))])
            case "panes.send": try runtime.send(required("id"), text: required("text"), enter: request.params["enter"] == .bool(true))
            case "activity.report":
                guard let state = ActivityState(rawValue: try required("state")), let agent = AgentKind(rawValue: request.params["agent"]?.text ?? "shell") else { throw TerminalError.invalid("Invalid state or agent") }
                try runtime.report(required("id"), state: state, reason: request.params["reason"]?.text ?? "", agent: agent)
            case "state.get": result = try .encoded(runtime.state())
            case "scrollback.list": result = try .encoded(runtime.scrollbackMetadata())
            case "scrollback.settings":
                guard case .bool(let enabled)? = request.params["enabled"] else { throw TerminalError.invalid("enabled must be a boolean") }
                try runtime.setScrollbackPersistence(enabled)
            case "recovery.list": result = try .encoded(runtime.state().recoveryResults)
            case "recovery.run", "recovery.retry": result = try .encoded(runtime.recoverSessions(paneID: request.params["id"]?.text))
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
                result = try .encoded(runtime.addAccount(provider: provider, label: required("label")))
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
}
