import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private final class TailscaleOutputBuffer {
    private let lock = NSLock()
    private var data = Data()
    private var completed = false
    private var overflow = false
    func finish() { lock.lock(); completed = true; lock.unlock() }
    var isCompleted: Bool { lock.lock(); defer { lock.unlock() }; return completed }
    func append(_ chunk: Data, limit: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard data.count + chunk.count <= limit else { overflow = true; return false }
        data.append(chunk); return true
    }
    var snapshot: (Data, Bool) { lock.lock(); defer { lock.unlock() }; return (data, overflow) }
}

public final class BoundedTailscaleExecutor: TailscaleCommandExecuting {
    private let executable: URL
    private let timeout: TimeInterval
    private let maximumOutputBytes: Int
    private let progress: ((Data) -> Void)?
    private let lock = NSLock()
    private var current: Process?
    public init(executable: URL, timeout: TimeInterval = 30, maximumOutputBytes: Int = 1_048_576, progress: ((Data) -> Void)? = nil) {
        self.executable = executable; self.timeout = timeout; self.maximumOutputBytes = maximumOutputBytes; self.progress = progress
    }
    public static func installedExecutable(path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> URL? {
        let candidates = path.split(separator: ":").map { String($0) + "/tailscale" } + ["/opt/homebrew/bin/tailscale", "/usr/local/bin/tailscale", "/Applications/Tailscale.app/Contents/MacOS/Tailscale"]
        return candidates.first { $0.hasPrefix("/") && FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }

    public func run(arguments: [String]) throws -> TailscaleCommandResult {
        guard timeout.isFinite, timeout > 0, timeout <= 300, maximumOutputBytes > 0, maximumOutputBytes <= 1_048_576,
              FileManager.default.isExecutableFile(atPath: executable.path) else { throw TerminalError.invalid("Tailscale executable or command limits are invalid") }
        let process = Process(), pipe = Pipe(), finished = DispatchSemaphore(value: 0), output = TailscaleOutputBuffer()
        process.executableURL = executable; process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = FileHandle.nullDevice
        process.terminationHandler = { _ in output.finish(); finished.signal() }
        lock.lock()
        guard current == nil else { lock.unlock(); throw TerminalError.invalid("A Tailscale action is already running") }
        current = process; lock.unlock()
        defer { lock.lock(); if current === process { current = nil }; lock.unlock() }
        try process.run()
        let reader = DispatchGroup()
        reader.enter()
        DispatchQueue.global(qos: .utility).async { [maximumOutputBytes, progress] in
            defer { reader.leave() }
            let fd = pipe.fileHandleForReading.fileDescriptor
            var bytes = [UInt8](repeating: 0, count: 8192)
            while true {
                var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
                let ready = poll(&descriptor, 1, 100)
                if ready < 0, errno == EINTR { continue }
                if ready < 0 { return }
                if ready == 0 { if output.isCompleted { return }; continue }
                let count = read(fd, &bytes, bytes.count)
                if count < 0, errno == EINTR || errno == EAGAIN { continue }
                guard count > 0 else { return }
                let chunk = Data(bytes.prefix(count))
                if !output.append(chunk, limit: maximumOutputBytes) {
                    if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
                    return
                }
                progress?(chunk)
            }
        }
        let timedOut = finished.wait(timeout: .now() + timeout) != .success
        if timedOut {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            _ = finished.wait(timeout: .now() + 1)
        }
        output.finish()
        let drained = reader.wait(timeout: .now() + 1) == .success
        let (bytes, exceeded) = output.snapshot
        guard !timedOut else { throw TerminalError.runtime("Tailscale action timed out") }
        guard drained, !exceeded else { throw TerminalError.runtime("Tailscale output exceeded its limit") }
        return TailscaleCommandResult(exitCode: process.terminationStatus, output: bytes)
    }
    public func cancel() {
        lock.lock(); let process = current; lock.unlock()
        guard let process, process.isRunning else { return }
        process.terminate()
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.25) {
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
        }
    }
}

public protocol RemoteHTTPListening: AnyObject {
    var target: String? { get }
    func start(gateway: RemoteHTTPGateway) throws -> String
    func stop()
}

public final class RemoteServingCoordinator {
    public let pairing: RemotePairingStore
    private let listener: RemoteHTTPListening
    private let preferences: () throws -> ServerPreferences
    private let identity: () throws -> TailscaleSnapshot?
    private let route: (APIRequest) -> APIResponse
    private let statusObserver: ((TailscaleSnapshot?, Error?) -> Void)?
    private let lock = NSRecursiveLock()
    private var invalidated = false
    private var ownLogin: String?
    private var identityUpdatedAt: Date?
    private var timer: DispatchSourceTimer?
    public init(root: URL, listener: RemoteHTTPListening, preferences: @escaping () throws -> ServerPreferences, identity: @escaping () throws -> TailscaleSnapshot?, route: @escaping (APIRequest) -> APIResponse, statusObserver: ((TailscaleSnapshot?, Error?) -> Void)? = nil) throws {
        pairing = try RemotePairingStore(root: root); self.listener = listener; self.preferences = preferences; self.identity = identity; self.route = route
        self.statusObserver = statusObserver
    }
    deinit { stop() }
    public var target: String? { lock.lock(); defer { lock.unlock() }; return listener.target }
    public func start() throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard !invalidated else { throw TerminalError.runtime("Server is stopping") }
        if let target = listener.target { return target }
        refreshIdentity()
        let gateway = RemoteHTTPGateway(pairing: pairing, preferences: preferences, ownLogin: { [weak self] in
            guard let self else { return nil }; self.lock.lock(); defer { self.lock.unlock() }
            guard let updatedAt = self.identityUpdatedAt, Date().timeIntervalSince(updatedAt) < 60 else { return nil }
            return self.ownLogin
        }, route: route)
        let target = try listener.start(gateway: gateway)
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "trano.remote.identity", qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(3))
        timer.setEventHandler { [weak self] in self?.refreshIdentity() }
        timer.resume(); self.timer = timer
        return target
    }
    public func restoreIfEnabled() throws { if try preferences().serveOverTailscale { _ = try start() } }
    public func refreshIdentity() {
        let snapshot: TailscaleSnapshot?
        do { snapshot = try identity(); statusObserver?(snapshot, nil) }
        catch { snapshot = nil; statusObserver?(nil, error) }
        lock.lock(); defer { lock.unlock() }
        ownLogin = snapshot?.backendState == "Running" ? snapshot?.loginName : nil
        identityUpdatedAt = Date()
    }
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        invalidated = true
        stop()
    }
    public func stop() {
        lock.lock(); defer { lock.unlock() }
        timer?.cancel(); timer = nil; listener.stop(); ownLogin = nil; identityUpdatedAt = nil
    }
}

public final class PrivateUnixRemoteHTTPListener: RemoteHTTPListening {
    private let root: URL
    private var path: String { root.appendingPathComponent("r.sock").path }
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "trano.remote.unix")
    private let clients = DispatchSemaphore(value: 8)
    private var source: DispatchSourceRead?
    private var stopped: DispatchSemaphore?
    public init(root: URL) { self.root = root }
    public var target: String? { lock.lock(); defer { lock.unlock() }; return source == nil ? nil : "unix:" + path }

    public func start(gateway: RemoteHTTPGateway) throws -> String {
        lock.lock(); defer { lock.unlock() }
        if source != nil { return "unix:" + path }
        _ = try SecureSettingsSidecar<ServerPreferences>(root: root, filename: "server-settings.json")
        let lease = open(root.appendingPathComponent("r.sock.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lease >= 0 else { throw TerminalError.runtime("Cannot open the private remote socket lease") }
        var leaseInfo = stat()
        guard fstat(lease, &leaseInfo) == 0, leaseInfo.st_uid == getuid(), leaseInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), leaseInfo.st_mode & 0o077 == 0,
              flock(lease, LOCK_EX | LOCK_NB) == 0 else { close(lease); throw TerminalError.runtime("Remote socket is already running or its lease is unmanaged") }
        var fd: Int32 = -1
        do {
            var previous = stat()
            if lstat(path, &previous) == 0 {
                guard previous.st_uid == getuid(), previous.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK), previous.st_mode & 0o077 == 0 else { throw TerminalError.invalid("Refusing to replace an unmanaged remote socket") }
                guard unlink(path) == 0 else { throw TerminalError.runtime("Cannot remove a stale private remote socket") }
            } else if errno != ENOENT { throw TerminalError.runtime("Cannot inspect the private remote socket") }
            fd = try UnixSocket.make()
            guard try UnixSocket.address(path, { bind(fd, $0, $1) }) == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else { throw TerminalError.runtime("Cannot bind the private remote socket") }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var identity = stat()
            guard lstat(path, &identity) == 0 else { throw TerminalError.runtime("Cannot identify the private remote socket") }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            let ownedFD = fd, socketPath = path, inode = identity.st_ino, device = identity.st_dev
            source.setEventHandler { [weak self] in
                guard let self else { return }
                while true {
                    let client = accept(ownedFD, nil, nil)
                    if client < 0 { break }
                    UnixSocket.configure(client)
                    guard let proof = TailscaleProxyPeerPolicy.inspect(socket: client), self.clients.wait(timeout: .now()) == .success else { close(client); continue }
                    DispatchQueue.global(qos: .userInitiated).async { [self] in
                        defer { close(client); self.clients.signal() }
                        do { try self.serve(client, proof: proof, gateway: gateway) } catch {}
                    }
                }
            }
            let stopped = DispatchSemaphore(value: 0)
            source.setCancelHandler {
                close(ownedFD)
                var current = stat()
                if lstat(socketPath, &current) == 0, current.st_ino == inode, current.st_dev == device { unlink(socketPath) }
                close(lease); stopped.signal()
            }
            self.stopped = stopped; self.source = source; source.resume()
            return "unix:" + path
        } catch { if fd >= 0 { close(fd) }; close(lease); throw error }
    }
    public func stop() {
        lock.lock(); let source = self.source, stopped = self.stopped; self.source = nil; self.stopped = nil; lock.unlock()
        source?.cancel(); if source != nil { _ = stopped?.wait(timeout: .now() + 1) }
    }
    deinit { stop() }
    private func serve(_ fd: Int32, proof: TrustedTailscaleProxy, gateway: RemoteHTTPGateway) throws {
        let deadline = Date().addingTimeInterval(10)
        var frame = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while Date() < deadline {
            let count = read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { return }
            frame.append(contentsOf: bytes.prefix(count))
            if let request = try RemoteHTTPRequest.parse(frame) {
                let response = gateway.respond(request, proxy: proof)
                guard response.body.count <= 1_048_576 else { throw TerminalError.invalid("Remote response exceeds 1 MiB") }
                let reasons = [200: "OK", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 415: "Unsupported Media Type", 503: "Service Unavailable"]
                var header = "HTTP/1.1 \(response.status) \(reasons[response.status] ?? "Error")\r\nConnection: close\r\nContent-Length: \(response.body.count)\r\n"
                for (key, value) in response.headers.sorted(by: { $0.key < $1.key }) { header += key + ": " + value + "\r\n" }
                var output = Data((header + "\r\n").utf8); output.append(response.body)
                try output.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let count = write(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                        if count < 0, errno == EINTR { continue }
                        guard count > 0 else { throw TerminalError.runtime("Remote client disconnected") }
                        offset += count
                    }
                }
                return
            }
        }
    }
}

