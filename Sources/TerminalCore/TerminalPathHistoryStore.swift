import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct TerminalPathHistoryStore {
    public let root: URL
    public var url: URL { root.appendingPathComponent("terminal-path-history.json") }
    public init(root: URL) { self.root = root }
    private static let maximumBytes = 1_048_576
    private struct Envelope: Codable {
        let schemaVersion: Int
        let history: TerminalPathHistory
    }

    public func load() throws -> TerminalPathHistory {
        try validateRoot()
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return TerminalPathHistory() }
            throw TerminalError.invalid("Cannot read terminal path history safely")
        }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == getuid(), metadata.st_nlink == 1,
              metadata.st_mode & 0o777 == 0o600,
              metadata.st_size >= 0, metadata.st_size <= Self.maximumBytes else {
            throw TerminalError.invalid("Terminal path history must be a private owned regular file up to 1 MiB")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw TerminalError.invalid("Terminal path history exceeds 1 MiB") }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.schemaVersion == 1 else { throw TerminalError.invalid("Unsupported terminal path history schema") }
        try validate(envelope.history)
        return envelope.history
    }

    public func save(_ history: TerminalPathHistory) throws {
        try validate(history)
        _ = try load()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(Envelope(schemaVersion: 1, history: history))
        guard data.count <= Self.maximumBytes else { throw TerminalError.invalid("Terminal path history exceeds 1 MiB") }
        try TerminalRuntime.atomicWrite(data, to: url)
    }

    private func validate(_ history: TerminalPathHistory) throws {
        guard history.entries.count <= 1280 else { throw TerminalError.invalid("Too many terminal recent paths") }
        var validated = TerminalPathHistory()
        for entry in history.entries {
            let count = validated.entries.count
            try validated.record(entry.path, hostID: entry.hostID, at: entry.usedAt)
            guard validated.entries.count == count + 1 else {
                throw TerminalError.invalid("Terminal recent paths must be unique and bounded to twenty per host")
            }
        }
    }

    private func validateRoot() throws {
        var metadata = stat()
        guard lstat(root.path, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
              metadata.st_uid == getuid(), metadata.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Terminal path history directory must be private and owned")
        }
    }
}
