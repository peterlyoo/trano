import Foundation
#if canImport(Darwin)
import Darwin
#endif

public struct PaneHostPane: Codable, Equatable {
    public var id: String
    public var pid: Int32
    public var alive: Bool
    public var exitStatus: Int32?
    public var title: String?
    public var created: Double
    public var tty: String
    public var pipe: Bool
    public var options: [String: String]
    public var argv: [String]
    public var generation: String?
}

public enum PaneHostFrame {
    public static let input: UInt8 = 0
    public static let resize: UInt8 = 1

    public static func encode(_ type: UInt8, _ payload: [UInt8]) -> [UInt8] {
        let count = UInt32(payload.count)
        return [type, UInt8(count >> 24), UInt8(count >> 16 & 0xff), UInt8(count >> 8 & 0xff), UInt8(count & 0xff)] + payload
    }

    public static func resizePayload(cols: Int, rows: Int) -> [UInt8] {
        let c = UInt16(clamping: cols), r = UInt16(clamping: rows)
        return [UInt8(c >> 8), UInt8(c & 0xff), UInt8(r >> 8), UInt8(r & 0xff)]
    }
}

/// Owns pane PTYs outside the UI process. `PaneHostClient` is the production implementation; tests inject fakes.
public protocol PaneBackend: Sendable {
    var socketPath: String { get }
    func isRunning() -> Bool
    func create(id: String, argv: [String], environment: [String], cwd: String, cols: Int, rows: Int) throws -> Int32
    func respawn(id: String, argv: [String], environment: [String]?, cwd: String?) throws -> Int32
    func list() throws -> [PaneHostPane]
    func write(_ id: String, _ data: Data) throws
    func capture(_ id: String, lines: Int, escapes: Bool) throws -> String
    func workingDirectory(_ id: String) throws -> String
    func kill(_ id: String) throws
    func pipe(_ id: String, command: String) throws
    func setOption(_ id: String, key: String, value: String) throws
    func environment(_ id: String, key: String) throws -> String?
    func attachArguments(_ id: String) -> [String]
}

extension PaneBackend {
    public func pane(_ id: String) throws -> PaneHostPane? { try list().first { $0.id == id } }
    public func capture(_ id: String, lines: Int) throws -> String { try capture(id, lines: lines, escapes: false) }
    public func create(id: String, argv: [String], environment: [String], cwd: String) throws -> Int32 {
        try create(id: id, argv: argv, environment: environment, cwd: cwd, cols: 100, rows: 30)
    }
}

public struct PaneHostClient: PaneBackend {
    public static let protocolVersion = 1
    public let root: URL
    public let executable: String?

    public init(root: URL, executable: String?) { self.root = root; self.executable = executable }

    public var socketPath: String { root.appendingPathComponent("pty.sock").path }

    public static func resolveExecutable(_ helper: String?) -> String? {
        if let helper, FileManager.default.isExecutableFile(atPath: helper) { return helper }
        if let path = ProcessInfo.processInfo.environment["TRANO_PTY_HOST_EXECUTABLE"], FileManager.default.isExecutableFile(atPath: path) { return path }
        if let main = Bundle.main.executableURL {
            for candidate in [main.deletingLastPathComponent().appendingPathComponent("trano"),
                              main.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("trano")]
            where FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        for bundle in Bundle.allBundles where bundle.bundleURL.pathExtension == "xctest" {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("trano")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate.path }
        }
        return nil
    }

    func connect() throws -> Int32 {
        let fd = try UnixSocket.make()
        guard try UnixSocket.address(socketPath, { Darwin.connect(fd, $0, $1) }) == 0 else {
            close(fd); throw TerminalError.runtime("Terminal host is not running")
        }
        return fd
    }

    @discardableResult public func request(_ body: [String: Any], start: Bool = true) throws -> [String: Any] {
        var fd: Int32
        do { fd = try connect() }
        catch {
            guard start else { throw error }
            try ensureRunning()
            fd = try connect()
        }
        defer { close(fd) }
        var message = body
        message["version"] = Self.protocolVersion
        try UnixSocket.sendLine(JSONSerialization.data(withJSONObject: message), fd: fd)
        let line = try Self.receive(fd: fd)
        guard let reply = try JSONSerialization.jsonObject(with: line) as? [String: Any] else { throw TerminalError.runtime("Terminal host sent an invalid reply") }
        if let error = reply["error"] as? String { throw TerminalError.runtime(error) }
        return reply
    }

    static func receive(fd: Int32, limit: Int = 16 << 20) throws -> Data {
        var timeout = timeval(tv_sec: 30, tv_usec: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while result.count <= limit {
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw TerminalError.runtime("Terminal host disconnected") }
            result.append(contentsOf: bytes.prefix(count))
            if let newline = result.firstIndex(of: 10) { return Data(result[..<newline]) }
        }
        throw TerminalError.invalid("Terminal host reply is too large")
    }

    public func isRunning() -> Bool { processIdentifier() != nil }

    public func processIdentifier() -> Int32? {
        ((try? request(["op": "ping"], start: false))?["pid"] as? NSNumber)?.int32Value
    }

    /// Stops every pane and the host process. Used by isolated test fixtures and explicit shutdown.
    public func shutdown() throws {
        guard isRunning() else { return }
        _ = try? request(["op": "shutdown"], start: false)
        let deadline = Date().addingTimeInterval(5)
        while isRunning(), Date() < deadline { usleep(20_000) }
    }

    public func ensureRunning() throws {
        if isRunning() { return }
        guard let executable = Self.resolveExecutable(executable) else { throw TerminalError.runtime("The trano helper is required to start the terminal host") }
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for target in [Int32(0), 1, 2] { posix_spawn_file_actions_addopen(&actions, target, "/dev/null", target == 0 ? O_RDONLY : O_WRONLY, 0) }
        var environment = ProcessInfo.processInfo.environment
        for key in ["TMUX", "TMUX_PANE", "REX_BLOCK", "REX_SESSION", "REX_SERVER", "TRANO_LAUNCH_ID", "TRANO_SESSION"] { environment.removeValue(forKey: key) }
        environment["TRANO_DATA_DIR"] = root.path
        let argv = [executable, "pty-host"]
        let env = environment.map { $0.key + "=" + $0.value }
        var pid: pid_t = 0
        let status = withCStrings(argv) { cArgs in withCStrings(env) { cEnv in posix_spawn(&pid, executable, &actions, &attributes, cArgs, cEnv) } }
        guard status == 0 else { throw TerminalError.runtime("Cannot start the terminal host (\(status))") }
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if isRunning() { return }
            var exitStatus: Int32 = 0
            if waitpid(pid, &exitStatus, WNOHANG) == pid, isRunning() == false {
                usleep(50_000)
                if isRunning() { return }
            }
            usleep(20_000)
        }
        throw TerminalError.runtime("The terminal host did not start")
    }

    public func create(id: String, argv: [String], environment: [String], cwd: String, cols: Int, rows: Int) throws -> Int32 {
        let reply = try request(["op": "create", "id": id, "argv": argv, "env": environment, "cwd": cwd, "cols": cols, "rows": rows])
        guard let pid = (reply["pid"] as? NSNumber)?.int32Value, pid > 1 else { throw TerminalError.runtime("The terminal host did not return a child PID") }
        return pid
    }

    public func respawn(id: String, argv: [String], environment: [String]?, cwd: String?) throws -> Int32 {
        var body: [String: Any] = ["op": "respawn", "id": id, "argv": argv]
        if let environment { body["env"] = environment }
        if let cwd { body["cwd"] = cwd }
        guard let pid = (try request(body)["pid"] as? NSNumber)?.int32Value, pid > 1 else { throw TerminalError.runtime("The terminal host did not return a child PID") }
        return pid
    }

    public func list() throws -> [PaneHostPane] {
        guard isRunning() else { return [] }
        let reply = try request(["op": "list"], start: false)
        let data = try JSONSerialization.data(withJSONObject: reply["panes"] ?? [])
        return try JSONDecoder().decode([PaneHostPane].self, from: data)
    }


    public func write(_ id: String, _ data: Data) throws {
        try request(["op": "write", "id": id, "data": data.base64EncodedString()], start: false)
    }

    public func capture(_ id: String, lines: Int, escapes: Bool) throws -> String {
        (try request(["op": "capture", "id": id, "lines": lines, "escapes": escapes], start: false)["text"] as? String) ?? ""
    }

    public func workingDirectory(_ id: String) throws -> String {
        guard let path = try request(["op": "cwd", "id": id], start: false)["cwd"] as? String else { throw TerminalError.runtime("Terminal working directory is unavailable") }
        return path
    }

    public func kill(_ id: String) throws {
        guard isRunning() else { return }
        try request(["op": "kill", "id": id], start: false)
    }

    public func pipe(_ id: String, command: String) throws {
        try request(["op": "pipe", "id": id, "command": command], start: false)
    }

    public func setOption(_ id: String, key: String, value: String) throws {
        try request(["op": "option", "id": id, "key": key, "value": value], start: false)
    }

    public func environment(_ id: String, key: String) throws -> String? {
        try request(["op": "env", "id": id, "key": key], start: false)["value"] as? String
    }

    public func attachArguments(_ id: String) -> [String] { ["pty-attach", id, "--root", root.path] }
}

private func withCStrings<T>(_ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> T) -> T {
    var pointers = strings.map { strdup($0) } + [nil]
    defer { for pointer in pointers { free(pointer) } }
    return pointers.withUnsafeMutableBufferPointer { body(UnsafePointer($0.baseAddress!)) }
}
