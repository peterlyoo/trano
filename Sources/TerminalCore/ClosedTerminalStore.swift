import Foundation
import Darwin

public enum ClosedPanePhase: String, Codable { case closing, closed, restoring, reopened }

public struct ClosedPaneSnapshot: Codable, Equatable {
    public var pane: TerminalSession
    public var shell: TerminalStartupCommand
    public var launch: AgentLaunch?
    public var processWitnesses: [SupervisorProcessIdentity]
    public var archiveID: String
    public var operationID: String
    public var phase: ClosedPanePhase
    public var tab: TerminalTab
    public var workspace: WorkspaceRecord?
    public var closedAt: Date
    public var remoteSnapshot: RemoteClosedTerminal?
    public var restoredPID: Int32? = nil
    public var restoredProcess: SupervisorProcessIdentity? = nil
}

struct ClosedPaneContents: Codable {
    var screen: String
    var history: ShellHistoryArchive
}

struct ClosedTerminalLedger: Codable {
    var version = 1
    var shells: [String: TerminalStartupCommand] = [:]
    var panes: [String: ClosedPaneSnapshot] = [:]
    var retired: Set<String> = []
}

struct ClosedTerminalStore {
    let runtimeRoot: URL
    private var directory: URL { runtimeRoot.appendingPathComponent("closed-terminals") }
    static let maximumFileBytes = 16 * 1_048_576

    private func validatedDirectory(create: Bool) throws -> URL? {
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            if errno == ENOENT, !create { return nil }
            guard errno == ENOENT else { throw TerminalError.runtime("Cannot read closed terminal directory") }
            return try ManagedDirectory.ensure(runtimeRoot, component: "closed-terminals")
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Closed terminal state must be a private owned directory")
        }
        return directory
    }

    private func name(_ id: String, suffix: String) throws -> String {
        guard UUID(uuidString: id) != nil else { throw TerminalError.invalid("Invalid closed terminal archive ID") }
        return id.lowercased() + suffix
    }

    func read(_ name: String) throws -> Data? {
        guard let directory = try validatedDirectory(create: false) else { return nil }
        let fd = open(directory.appendingPathComponent(name).path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw TerminalError.invalid("Cannot read closed terminal archive") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= Self.maximumFileBytes else {
            throw TerminalError.invalid("Invalid closed terminal archive ownership or size")
        }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.runtime("Cannot read closed terminal archive") }
            if count == 0 { return data }
            guard data.count + count <= Self.maximumFileBytes else { throw TerminalError.invalid("Closed terminal archive exceeds its limit") }
            data.append(contentsOf: bytes.prefix(count))
        }
    }

    private func write(_ data: Data, name: String) throws {
        guard data.count <= Self.maximumFileBytes, let directory = try validatedDirectory(create: true) else {
            throw TerminalError.invalid("Closed terminal archive exceeds its limit")
        }
        // Validate existing targets before replacement as well as before reads.
        _ = try read(name)
        try TerminalRuntime.atomicWrite(data, to: directory.appendingPathComponent(name))
    }

    func operation<T>(_ body: () throws -> T) throws -> T {
        guard let directory = try validatedDirectory(create: true) else { throw TerminalError.runtime("Cannot lock terminal close state") }
        let fd = open(directory.appendingPathComponent("operation.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
        guard fd >= 0 else { throw TerminalError.invalid("Cannot lock terminal close state") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else { throw TerminalError.invalid("Invalid terminal close lock") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw TerminalError.invalid("A terminal close or reopen is still in progress. Retry shortly.") }
        defer { _ = flock(fd, LOCK_UN) }
        return try body()
    }

    func ledger() throws -> ClosedTerminalLedger {
        guard let data = try read("index.json") else { return ClosedTerminalLedger() }
        let value = try JSONDecoder().decode(ClosedTerminalLedger.self, from: data)
        guard value.version == 1 else { throw TerminalError.invalid("Unsupported closed terminal state") }
        return value
    }
    func save(_ ledger: ClosedTerminalLedger) throws { try write(JSONEncoder().encode(ledger), name: "index.json") }
    func save(_ contents: ClosedPaneContents, id: String) throws {
        try write(JSONEncoder().encode(contents), name: name(id, suffix: ".json"))
    }
    func contents(id: String) throws -> ClosedPaneContents {
        guard let data = try read(name(id, suffix: ".json")) else { throw TerminalError.invalid("Saved terminal state is missing") }
        return try JSONDecoder().decode(ClosedPaneContents.self, from: data)
    }
    func screenFile(id: String) throws -> URL {
        let contents = try contents(id: id)
        let filename = try name(id, suffix: ".screen")
        try write(Data(ClosedTerminalScreen.sanitized(contents.screen).utf8), name: filename)
        return directory.appendingPathComponent(filename)
    }
    func prune(retaining archives: Set<String>) throws {
        guard let directory = try validatedDirectory(create: false) else { return }
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            let id = String(file.split(separator: ".").first ?? "")
            guard UUID(uuidString: id) != nil, !archives.contains(id), file.hasSuffix(".json") || file.hasSuffix(".screen") else { continue }
            _ = try read(file)
            if unlink(directory.appendingPathComponent(file).path) != 0, errno != ENOENT {
                throw TerminalError.runtime("Cannot prune closed terminal archive")
            }
        }
    }
}

public enum ClosedTerminalScreen {
    public static func sanitized(_ text: String) -> String {
        let bytes = Array(text.utf8)
        var result: [UInt8] = [], index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 27 {
                index += 1
                guard index < bytes.count else { break }
                if bytes[index] == 91 {
                    let start = index - 1
                    index += 1
                    while index < bytes.count && !(64...126).contains(bytes[index]) { index += 1 }
                    if index < bytes.count, bytes[index] == 109, index - start < 128,
                       bytes[(start + 2)..<index].allSatisfy({ (48...57).contains($0) || $0 == 59 || $0 == 58 }) {
                        result.append(contentsOf: bytes[start...index])
                    }
                    index += 1
                } else if [93, 80, 88, 94, 95].contains(bytes[index]) {
                    index += 1
                    while index < bytes.count {
                        if bytes[index] == 7 { index += 1; break }
                        if bytes[index] == 27, index + 1 < bytes.count, bytes[index + 1] == 92 { index += 2; break }
                        index += 1
                    }
                } else { index += 1 }
                continue
            }
            if byte == 10 || byte == 9 || byte >= 32 && byte != 127 { result.append(byte) }
            index += 1
        }
        var bounded = Data(result.suffix(ScrollbackStore.maximumBytes - 4))
        while let first = bounded.first, first & 0xC0 == 0x80 { bounded.removeFirst() }
        let lines = String(decoding: bounded, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false)
        return lines.suffix(ScrollbackStore.maximumLines - 1).joined(separator: "\n") + "\u{1b}[0m"
    }
}
