import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

private enum SupervisorSocketIO {
    static func wait(_ descriptor: Int32, event: Int16, deadline: TimeInterval) throws {
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { throw TerminalError.runtime("Supervisor bootstrap timed out") }
            var entry = pollfd(fd: descriptor, events: event, revents: 0)
            let count = poll(&entry, 1, Int32(min(5000, ceil(remaining * 1000))))
            if count < 0, errno == EINTR { continue }
            guard count > 0, entry.revents & event != 0 else {
                throw TerminalError.runtime("Supervisor bootstrap disconnected or timed out")
            }
            return
        }
    }

    static func validateRoot(_ root: URL) throws {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TerminalError.invalid("Supervisor bootstrap requires a private runtime") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Supervisor bootstrap requires a private owned runtime")
        }
    }

    static func validatePeer(_ descriptor: Int32) throws {
        #if canImport(Darwin)
        var user: uid_t = 0, group: gid_t = 0
        guard getpeereid(descriptor, &user, &group) == 0, user == getuid() else {
            throw TerminalError.invalid("Supervisor bootstrap peer is not the current user")
        }
        #else
        throw TerminalError.invalid("Supervisor bootstrap peer identity is unavailable on this host")
        #endif
    }
}

private final class SupervisorSocketTransport: SupervisorBootstrapTransport {
    private let descriptor: Int32

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        UnixSocket.configure(descriptor)
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TerminalError.runtime("Cannot configure Supervisor bootstrap transport")
        }
    }

    func send(_ data: Data) throws {
        guard data.count <= 65_536, !data.contains(10) else { throw TerminalError.invalid("Invalid Supervisor bootstrap frame") }
        var frame = data
        frame.append(10)
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                try SupervisorSocketIO.wait(descriptor, event: Int16(POLLOUT), deadline: deadline)
                #if canImport(Darwin)
                let count = Darwin.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                #else
                let count = Glibc.send(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset, Int32(MSG_NOSIGNAL))
                #endif
                if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
                guard count > 0 else { throw TerminalError.runtime("Cannot send Supervisor bootstrap frame") }
                offset += count
            }
        }
    }

    func receive() throws -> Data {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var result = Data()
        var bytes = [UInt8](repeating: 0, count: 8192)
        while result.count <= 65_536 {
            try SupervisorSocketIO.wait(descriptor, event: Int16(POLLIN), deadline: deadline)
            let count = recv(descriptor, &bytes, bytes.count, 0)
            if count < 0, [EINTR, EAGAIN, EWOULDBLOCK].contains(errno) { continue }
            guard count > 0 else { throw TerminalError.runtime("Supervisor bootstrap disconnected") }
            result.append(contentsOf: bytes.prefix(count))
            if let newline = result.firstIndex(of: 10) {
                guard newline <= 65_536 else { throw TerminalError.invalid("Supervisor bootstrap frame exceeds 64 KiB") }
                return Data(result[..<newline])
            }
        }
        throw TerminalError.invalid("Supervisor bootstrap frame exceeds 64 KiB")
    }
}

final class SupervisorBootstrapGate {
    let name = "sg-" + UUID().uuidString.lowercased().prefix(8)
    let nonce = UUID().uuidString.lowercased()
    private let root: URL
    private let descriptor: Int32
    private var inode: ino_t = 0
    private var device: dev_t = 0
    private var path: String { root.appendingPathComponent(name).path }

    init(root: URL) throws {
        self.root = root
        try SupervisorSocketIO.validateRoot(root)
        descriptor = try UnixSocket.make()
        var ready = false
        defer { if !ready { close(descriptor); removeOwnedSocket() } }
        guard try UnixSocket.address(path, { bind(descriptor, $0, $1) }) == 0 else {
            throw TerminalError.runtime("Cannot create private Supervisor bootstrap gate")
        }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() else {
            throw TerminalError.invalid("Supervisor bootstrap gate identity changed")
        }
        inode = info.st_ino
        device = info.st_dev
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              chmod(path, 0o600) == 0, listen(descriptor, 1) == 0 else {
            throw TerminalError.runtime("Cannot prepare private Supervisor bootstrap gate")
        }
        ready = true
    }

    func release(binding: SupervisorBinding, plan: SupervisorLaunchPlan) throws {
        let payload = try SupervisorBootstrap.payload(for: plan, binding: binding, nonce: nonce)
        try SupervisorSocketIO.wait(descriptor, event: Int16(POLLIN), deadline: ProcessInfo.processInfo.systemUptime + 5)
        let client = accept(descriptor, nil, nil)
        guard client >= 0 else { throw TerminalError.runtime("Cannot accept Supervisor bootstrap") }
        defer { close(client) }
        try SupervisorSocketIO.validatePeer(client)
        guard UnixSocket.peerPID(client) == binding.backendPID, let expected = binding.processIdentity,
              SupervisorProcessIdentity.read(binding.backendPID) == expected else {
            throw TerminalError.invalid("Supervisor bootstrap process identity changed")
        }
        let transport = try SupervisorSocketTransport(descriptor: client)
        guard try transport.receive() == SupervisorBootstrap.ready(paneID: binding.paneID, backendPID: binding.backendPID, nonce: nonce) else {
            throw TerminalError.invalid("Supervisor bootstrap ready token changed")
        }
        try transport.send(payload)
        guard try transport.receive() == SupervisorBootstrap.accepted(nonce: nonce) else {
            throw TerminalError.invalid("Supervisor bootstrap acknowledgement changed")
        }
    }

    private func removeOwnedSocket() {
        var info = stat()
        if inode != 0, lstat(path, &info) == 0, info.st_ino == inode, info.st_dev == device,
           info.st_mode & S_IFMT == S_IFSOCK, info.st_uid == getuid() { _ = unlink(path) }
    }

    deinit { close(descriptor); removeOwnedSocket() }
}

public enum SupervisorBootstrapClient {
    public static func receivePlan(root: URL, gateName: String, nonce: String, paneID: String,
                                    backendPID: Int32, helperExecutable: String) throws -> SupervisorLaunchPlan {
        _ = try SupervisorBootstrap.arguments(gateName: gateName, nonce: nonce)
        try SupervisorSocketIO.validateRoot(root)
        let path = root.appendingPathComponent(gateName).path
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Supervisor bootstrap gate is not private")
        }
        let descriptor = try UnixSocket.make()
        defer { close(descriptor) }
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw TerminalError.runtime("Cannot configure Supervisor bootstrap connection")
        }
        if try UnixSocket.address(path, { connect(descriptor, $0, $1) }) != 0 {
            guard errno == EINPROGRESS else { throw TerminalError.runtime("Supervisor bootstrap gate is unavailable") }
            try SupervisorSocketIO.wait(descriptor, event: Int16(POLLOUT), deadline: ProcessInfo.processInfo.systemUptime + 5)
            var failure: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &failure, &length) == 0, failure == 0 else {
                throw TerminalError.runtime("Supervisor bootstrap connection failed")
            }
        }
        try SupervisorSocketIO.validatePeer(descriptor)
        return try SupervisorBootstrap.prepareChild(paneID: paneID, backendPID: backendPID, nonce: nonce,
            helperExecutable: helperExecutable, transport: SupervisorSocketTransport(descriptor: descriptor),
            readPublishedBinding: { try SupervisorStateStore(root: root).readPublishedBinding() },
            readIdentity: SupervisorProcessIdentity.read)
    }

    public static func execute(_ plan: SupervisorLaunchPlan) throws -> Never {
        guard let executable = plan.arguments.first, executable.hasPrefix("/"),
              plan.arguments.allSatisfy({ !$0.contains("\0") }) else { throw TerminalError.invalid("Invalid Supervisor executable arguments") }
        var arguments = plan.arguments.map { strdup($0) } + [nil]
        defer { for pointer in arguments { free(pointer) } }
        guard arguments.dropLast().allSatisfy({ $0 != nil }) else { throw TerminalError.runtime("Cannot allocate Supervisor executable arguments") }
        execv(executable, &arguments)
        throw TerminalError.runtime("Cannot execute Supervisor managed agent: " + String(cString: strerror(errno)))
    }
}
