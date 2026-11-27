import Foundation
import CryptoKit
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum ServerStatusPhase: String, Codable {
    case starting, running, connectionError, startupError, restarting, stopped
}

public struct ServerStatusSnapshot: Codable, Equatable {
    public var phase: ServerStatusPhase = .starting
    public let pid: Int32
    public let buildID: String
    public var itemRegistered = false
    public var checkedAt: Date?
    public var verifiedAt: Date?
    public var error: String?
    public var title: String {
        switch phase {
        case .starting: return "Trano Server Starting…"
        case .running: return "Trano Server Running"
        case .connectionError: return "Trano Server Connection Error"
        case .startupError: return "Trano Server Error"
        case .restarting: return "Trano Server Restarting…"
        case .stopped: return "Trano Server Stopped"
        }
    }
    public var canRetry: Bool { phase == .connectionError || phase == .startupError }
    public var canRestart: Bool { ![.starting, .restarting, .stopped].contains(phase) }
}

public struct ServerStatusProbeLease: Equatable {
    fileprivate let generation: UInt64
    fileprivate let sequence: UInt64
}

public struct ServerStatusState {
    public private(set) var snapshot: ServerStatusSnapshot
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var pending: ServerStatusProbeLease?
    private var canProbe = true
    public init(pid: Int32, buildID: String) { snapshot = ServerStatusSnapshot(pid: pid, buildID: buildID) }
    public mutating func setItemRegistered(_ registered: Bool) { snapshot.itemRegistered = registered }
    @discardableResult public mutating func beginStart(restarting: Bool) -> UInt64 {
        generation &+= 1
        pending = nil; canProbe = false
        snapshot.phase = restarting ? .restarting : .starting
        snapshot.verifiedAt = nil; snapshot.error = nil
        return generation
    }
    public mutating func finishStart(_ owner: UInt64, error: String?) {
        guard owner == generation, snapshot.phase != .stopped else { return }
        snapshot.error = error
        snapshot.phase = error == nil ? .starting : .startupError
        canProbe = error == nil
    }
    public mutating func beginProbe() -> ServerStatusProbeLease? {
        guard canProbe, pending == nil, snapshot.phase != .stopped else { return nil }
        sequence &+= 1
        let lease = ServerStatusProbeLease(generation: generation, sequence: sequence)
        pending = lease
        return lease
    }
    public mutating func finishProbe(_ lease: ServerStatusProbeLease, result: Result<APIResponse, Error>, now: Date) {
        guard pending == lease, lease.generation == generation else { return }
        pending = nil; snapshot.checkedAt = now
        do {
            try ServerHealthIdentity.validate(result.get(), pid: snapshot.pid, buildID: snapshot.buildID)
            snapshot.phase = .running; snapshot.verifiedAt = now; snapshot.error = nil
        } catch {
            snapshot.phase = .connectionError
            snapshot.error = String(error.localizedDescription.prefix(512))
        }
    }
    public mutating func stop() {
        generation &+= 1; pending = nil; canProbe = false
        snapshot.phase = .stopped; snapshot.verifiedAt = nil
    }
}

public final class ServerStatusCache {
    private let lock = NSLock()
    private var value: ServerStatusSnapshot
    public init(_ value: ServerStatusSnapshot) { self.value = value }
    public func update(_ value: ServerStatusSnapshot) { lock.lock(); defer { lock.unlock() }; self.value = value }
    public func snapshot() -> ServerStatusSnapshot { lock.lock(); defer { lock.unlock() }; return value }
    public func json() -> JSONValue { (try? JSONValue.encoded(snapshot())) ?? .null }
}

public enum ServerHealthIdentity {
    public static func validate(_ response: APIResponse, pid: Int32, buildID: String) throws {
        guard response.apiVersion == 1, response.error == nil,
              response.result?["apiVersion"] == .number(1), response.result?["pid"] == .number(Double(pid)),
              response.result?["buildID"] == .string(buildID), response.result?["serviceKind"] == .string("background") else {
            throw TerminalError.runtime("The background server did not return its expected identity.")
        }
    }
}

public struct ServerHealthResponseBuffer {
    private var data = Data()
    public init() {}
    public mutating func append(_ bytes: Data) throws -> APIResponse? {
        guard data.count + bytes.count <= 16_384 else { throw TerminalError.runtime("Server health response is too large.") }
        data.append(bytes)
        guard let newline = data.firstIndex(of: 10) else { return nil }
        return try JSONDecoder().decode(APIResponse.self, from: data[..<newline])
    }
}

public struct ServerHealthDeadline {
    private let deadline: TimeInterval
    public init(timeout: TimeInterval, now: TimeInterval) {
        deadline = now + max(0.01, min(timeout.isFinite ? timeout : 1, 5))
    }
    public func waitMilliseconds(now: TimeInterval) throws -> Int32 {
        let remaining = deadline - now
        guard remaining > 0 else { throw TerminalError.runtime("Server health check timed out.") }
        return Int32(max(1, min(5000, remaining * 1000)))
    }
}

public enum ServerHealthClient {
    public static func probe(path: String, timeout: TimeInterval = 1) throws -> APIResponse {
        let fd = try UnixSocket.make()
        defer { close(fd) }
        guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else { throw TerminalError.runtime("Cannot configure server health connection.") }
        let deadline = ServerHealthDeadline(timeout: timeout, now: ProcessInfo.processInfo.systemUptime)
        func wait(_ events: Int16) throws {
            while true {
                let milliseconds = try deadline.waitMilliseconds(now: ProcessInfo.processInfo.systemUptime)
                var descriptor = pollfd(fd: fd, events: events, revents: 0)
                let result = poll(&descriptor, 1, milliseconds)
                if result < 0 && errno == EINTR { continue }
                guard result > 0 else { throw TerminalError.runtime("Server health check timed out.") }
                guard descriptor.revents & Int16(POLLNVAL) == 0 else { throw TerminalError.runtime("Server health connection closed.") }
                return
            }
        }
        let connected = try UnixSocket.address(path) { connect(fd, $0, $1) }
        if connected != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { throw TerminalError.runtime("Cannot connect to the Trano server.") }
            try wait(Int16(POLLOUT))
            var failure: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size) == 0, failure == 0 else { throw TerminalError.runtime("Cannot connect to the Trano server.") }
        }
        var request = try JSONEncoder().encode(APIRequest(method: "server.info", params: ["healthOnly": .bool(true)])); request.append(10)
        try request.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try wait(Int16(POLLOUT))
                #if canImport(Darwin)
                let sent = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                #else
                let sent = send(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if sent < 0 && [EINTR, EAGAIN].contains(errno) { continue }
                guard sent > 0 else { throw TerminalError.runtime("Cannot send server health check.") }
                offset += sent
            }
        }
        var buffer = ServerHealthResponseBuffer(), bytes = [UInt8](repeating: 0, count: 4096)
        while true {
            try wait(Int16(POLLIN))
            let count = recv(fd, &bytes, bytes.count, 0)
            if count < 0 && [EINTR, EAGAIN].contains(errno) { continue }
            guard count > 0 else { throw TerminalError.runtime("Server health connection closed.") }
            if let response = try buffer.append(Data(bytes.prefix(count))) { return response }
        }
    }
}

public enum ServerHelperLeaseError: Error { case alreadyRunning }

public final class ServerHelperLease {
    private let fd: Int32
    public init(root: URL) throws {
        let directory = URL(fileURLWithPath: "/tmp").resolvingSymlinksInPath().appendingPathComponent("trano-service-\(getuid())")
        var info = stat()
        if mkdir(directory.path, 0o700) != 0 && errno != EEXIST { throw TerminalError.runtime("Cannot create server status directory.") }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TerminalError.runtime("The server status directory must be private and owned by the current user.")
        }
        let key = SHA256.hash(data: Data(root.standardizedFileURL.resolvingSymlinksInPath().path.utf8)).map { String(format: "%02x", $0) }.joined()
        let descriptor = open(directory.appendingPathComponent(key + ".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TerminalError.runtime("Cannot open server status lease.") }
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(), fchmod(descriptor, 0o600) == 0 else {
            close(descriptor); throw TerminalError.runtime("Invalid server status lease ownership.")
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { close(descriptor); throw ServerHelperLeaseError.alreadyRunning }
        fd = descriptor
    }
    deinit { close(fd) }
}
