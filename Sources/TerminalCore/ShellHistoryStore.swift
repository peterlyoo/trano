import Foundation
import Darwin

public enum ShellHistoryFormat: String, Codable, Sendable { case zsh, bash, fish, none }
public enum ShellHistoryProvenance: String, Codable, Sendable { case journal, persistedFallback, unavailable }

public struct ShellHistoryArchive: Codable, Equatable, Sendable {
    public let format: ShellHistoryFormat
    public let content: Data
    public let provenance: ShellHistoryProvenance
    public let capturesRunningCommand: Bool

    public init(format: ShellHistoryFormat, content: Data, provenance: ShellHistoryProvenance,
                capturesRunningCommand: Bool = false) {
        self.format = format; self.content = content; self.provenance = provenance
        self.capturesRunningCommand = capturesRunningCommand
    }
}

struct ShellHistoryFiles {
    let journal: URL
    let capability: URL
    let restore: URL?
    let token: String
}

public struct ShellHistoryStore {
    public static let maximumBytes = 1024 * 1024
    public static let maximumEntries = 10_000
    private static let marker = Data("trano-shell-history-v1\n".utf8)
    private let runtimeRoot: URL
    private let home: URL
    private let environment: [String: String]

    private struct Journal: Codable {
        let token: String
        let command: TerminalStartupCommand
    }

    public init(runtimeRoot: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.runtimeRoot = runtimeRoot; self.home = home; self.environment = environment
    }

    static func format(for command: TerminalStartupCommand) -> ShellHistoryFormat {
        ShellHistoryFormat(rawValue: URL(fileURLWithPath: command.executable).lastPathComponent) ?? .none
    }

    private func identifier(_ value: String) throws -> String {
        guard UUID(uuidString: value) != nil else { throw TerminalError.invalid("Invalid shell history pane ID") }
        return value.lowercased()
    }

    private func directory(create: Bool) throws -> URL? {
        let path = runtimeRoot.appendingPathComponent("shell-history", isDirectory: true)
        var info = stat()
        if lstat(path.path, &info) != 0 {
            guard errno == ENOENT else { throw TerminalError.invalid("Cannot inspect shell history directory") }
            guard create else { return nil }
            _ = try ManagedDirectory.ensure(runtimeRoot, component: "shell-history")
            guard lstat(path.path, &info) == 0 else { throw TerminalError.invalid("Cannot inspect shell history directory") }
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            throw TerminalError.invalid("Shell history must use a private owned directory")
        }
        let marker = path.appendingPathComponent(".trano-shell-history")
        if try read(marker, limit: Self.marker.count, privateFile: true) == nil {
            guard create, try FileManager.default.contentsOfDirectory(atPath: path.path).isEmpty else {
                throw TerminalError.invalid("Refusing unmanaged shell history directory")
            }
            try TerminalRuntime.atomicWrite(Self.marker, to: marker)
        }
        guard try read(marker, limit: Self.marker.count, privateFile: true)?.data == Self.marker else {
            throw TerminalError.invalid("Invalid shell history ownership marker")
        }
        return path
    }

    private func locked<T>(_ directory: URL, _ body: () throws -> T) throws -> T {
        let fd = open(directory.appendingPathComponent(".lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw TerminalError.runtime("Cannot open shell history lock") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, flock(fd, LOCK_EX) == 0 else {
            throw TerminalError.runtime("Cannot lock private shell history")
        }
        return try body()
    }

    private func read(_ file: URL, limit: Int, tail: Bool = false, privateFile: Bool = false) throws -> (data: Data, clipped: Bool)? {
        let fd = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0, errno == ENOENT { return nil }
        guard fd >= 0 else { throw TerminalError.invalid("Cannot safely read shell history") }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_size >= 0, (!privateFile || info.st_mode & 0o077 == 0),
              tail || info.st_size <= limit else { throw TerminalError.invalid("Invalid shell history file") }
        let offset = tail ? max(0, info.st_size - off_t(limit)) : 0
        if offset > 0 { try handle.seek(toOffset: UInt64(offset)) }
        let data = try handle.read(upToCount: limit) ?? Data()
        return (data, offset > 0)
    }

    private func journal(_ directory: URL, id: String) throws -> Journal? {
        guard let raw = try read(directory.appendingPathComponent(id + ".json"), limit: 2 * 1_048_576, privateFile: true) else { return nil }
        let value = try JSONDecoder().decode(Journal.self, from: raw.data)
        _ = try identifier(value.token)
        return value
    }

    func prepareJournal(paneID: String, command: TerminalStartupCommand, restoring: Bool,
                        seedEmpty: Bool = false) throws -> ShellHistoryFiles {
        let id = try identifier(paneID)
        guard let directory = try directory(create: true) else { throw TerminalError.runtime("Cannot create shell history directory") }
        return try locked(directory) {
            let previous = try journal(directory, id: id)
            let value = Journal(token: UUID().uuidString.lowercased(), command: command)
            let base = directory.appendingPathComponent(id + "." + value.token)
            let journalURL = base.appendingPathExtension("history")
            if seedEmpty { try TerminalRuntime.atomicWrite(Data(), to: journalURL) }
            var restored: URL?
            if restoring, let saved = try read(directory.appendingPathComponent(id + ".restore.json"),
                                               limit: Self.maximumBytes * 2, privateFile: true) {
                let archive = try JSONDecoder().decode(ShellHistoryArchive.self, from: saved.data)
                try Self.validate(archive)
                if archive.format == Self.format(for: command), !archive.content.isEmpty {
                    let file = base.appendingPathExtension("restore")
                    try TerminalRuntime.atomicWrite(archive.content, to: file)
                    restored = file
                }
            }
            let metadata = try JSONEncoder().encode(value)
            guard metadata.count <= 2 * 1_048_576 else { throw TerminalError.invalid("Shell launch metadata exceeds its limit") }
            try TerminalRuntime.atomicWrite(metadata, to: directory.appendingPathComponent(id + ".json"))
            if let previous {
                for suffix in ["history", "history.pending", "capability", "restore"] {
                    let file = directory.appendingPathComponent(id + "." + previous.token + "." + suffix)
                    if unlink(file.path) != 0, errno != ENOENT { throw TerminalError.runtime("Cannot retire old shell history") }
                }
            }
            return ShellHistoryFiles(journal: journalURL, capability: base.appendingPathExtension("capability"),
                                     restore: restored, token: value.token)
        }
    }

    public func capture(paneID: String, command: TerminalStartupCommand) throws -> ShellHistoryArchive {
        let id = try identifier(paneID), format = Self.format(for: command)
        if let directory = try directory(create: false) {
            if let archive: ShellHistoryArchive = try locked(directory, {
                guard let value = try journal(directory, id: id), value.command == command else { return nil }
                let base = directory.appendingPathComponent(id + "." + value.token)
                let pending = base.appendingPathExtension("history.pending")
                let interrupted = try pendingSnapshot(pending)
                guard let data = try read(base.appendingPathExtension("history"), limit: Self.maximumBytes + 1,
                                          tail: true, privateFile: true) else { return nil }
                let capability = try read(base.appendingPathExtension("capability"), limit: 64, privateFile: true)
                let interruptedAfterRead = try pendingSnapshot(pending)
                return ShellHistoryArchive(format: format, content: try Self.bounded(data.data, format: format, clipped: data.clipped),
                    provenance: .journal, capturesRunningCommand: !interrupted && !interruptedAfterRead && capability?.data == Data("preexec\n".utf8))
            }) { return archive }
        }
        guard format != .none else { return ShellHistoryArchive(format: format, content: Data(), provenance: .unavailable) }
        let source: URL
        if format != .fish, let path = environment["HISTFILE"], path.hasPrefix("/"), !path.contains("\0") {
            source = URL(fileURLWithPath: path)
        } else {
            switch format {
            case .zsh: source = home.appendingPathComponent(".zsh_history")
            case .bash: source = home.appendingPathComponent(".bash_history")
            case .fish:
                let base = environment["XDG_DATA_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
                    ?? home.appendingPathComponent(".local/share")
                let name = environment["fish_history"] ?? "fish"
                guard !name.isEmpty, name.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else {
                    return ShellHistoryArchive(format: format, content: Data(), provenance: .unavailable)
                }
                source = base.appendingPathComponent("fish/" + name + "_history")
            case .none: return ShellHistoryArchive(format: format, content: Data(), provenance: .unavailable)
            }
        }
        guard let value = try read(source, limit: Self.maximumBytes + 1, tail: true) else {
            return ShellHistoryArchive(format: format, content: Data(), provenance: .unavailable)
        }
        let data = format == .fish ? try Self.fishHistory(value.data, clipped: value.clipped) : value.data
        return ShellHistoryArchive(format: format, content: try Self.bounded(data, format: format,
            clipped: format == .fish ? false : value.clipped), provenance: .persistedFallback)
    }

    public func restore(_ archive: ShellHistoryArchive, paneID: String) throws {
        let id = try identifier(paneID)
        try Self.validate(archive)
        guard let directory = try directory(create: true) else { throw TerminalError.runtime("Cannot create shell history directory") }
        try locked(directory) {
            try TerminalRuntime.atomicWrite(JSONEncoder().encode(archive), to: directory.appendingPathComponent(id + ".restore.json"))
        }
    }

    private func pendingSnapshot(_ file: URL) throws -> Bool {
        guard let value = try read(file, limit: 64, privateFile: true) else { return false }
        guard let text = String(data: value.data, encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 1 else {
            throw TerminalError.invalid("Invalid shell history snapshot owner")
        }
        guard kill(pid, 0) != 0, errno == ESRCH else {
            throw TerminalError.runtime("Shell history snapshot is in progress; retry closing this terminal")
        }
        return true
    }

    private static func validate(_ archive: ShellHistoryArchive) throws {
        guard archive.content.count <= maximumBytes,
              (archive.format != .fish || String(data: archive.content, encoding: .utf8) != nil),
              (archive.format == .fish || !archive.content.contains(0)),
              (archive.format != .none || archive.content.isEmpty),
              try bounded(archive.content, format: archive.format, clipped: false) == archive.content else {
            throw TerminalError.invalid("Invalid shell history archive")
        }
    }

    private static func bounded(_ input: Data, format: ShellHistoryFormat, clipped: Bool) throws -> Data {
        var bytes = Array(input.suffix(maximumBytes))
        let truncated = clipped || input.count > maximumBytes
        if format == .none {
            guard bytes.isEmpty else { throw TerminalError.invalid("Unsupported shell history format") }
            return Data()
        }
        var starts = [0]
        if format == .fish {
            starts += bytes.indices.filter { bytes[$0] == 0 }.map { $0 + 1 }
        } else if format == .bash {
            let lines = [0] + bytes.indices.filter { bytes[$0] == 10 }.map { $0 + 1 }
            let timestamps = lines.filter { start in
                guard start < bytes.count, bytes[start] == 35 else { return false }
                let end = bytes[start...].firstIndex(of: 10) ?? bytes.count
                return end > start + 1 && bytes[(start + 1)..<end].allSatisfy { (48...57).contains($0) }
            }
            starts = timestamps.isEmpty ? lines : ([0] + timestamps.filter { $0 != 0 })
        } else {
            starts += bytes.indices.filter { bytes[$0] == 10 && ($0 == 0 || bytes[$0 - 1] != 92) }.map { $0 + 1 }
        }
        starts = starts.filter { $0 < bytes.count }
        if truncated, !starts.isEmpty { starts.removeFirst() }
        if starts.count > maximumEntries { starts = Array(starts.suffix(maximumEntries)) }
        guard let first = starts.first else { return Data() }
        bytes = Array(bytes[first...])
        guard format != .fish || String(bytes: bytes, encoding: .utf8) != nil,
              format == .fish || !bytes.contains(0),
              format != .fish || bytes.last == 0 else { throw TerminalError.invalid("Invalid shell history encoding") }
        return Data(bytes)
    }

    private static func fishHistory(_ data: Data, clipped: Bool) throws -> Data {
        var data = data
        if clipped, let newline = data.firstIndex(of: 10) { data = Data(data[(newline + 1)...]) }
        guard let text = String(data: data, encoding: .utf8) else { throw TerminalError.invalid("Invalid fish history encoding") }
        var result = Data()
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) where line.hasPrefix("- cmd: ") {
            let raw = Array(line.dropFirst(7).utf8)
            var decoded = [UInt8](), index = 0
            while index < raw.count {
                if raw[index] == 92, index + 1 < raw.count, [92, 110].contains(raw[index + 1]) {
                    decoded.append(raw[index + 1] == 110 ? 10 : 92); index += 2
                } else { decoded.append(raw[index]); index += 1 }
            }
            guard !decoded.contains(0) else { throw TerminalError.invalid("Invalid fish history entry") }
            result.append(contentsOf: decoded); result.append(0)
        }
        return result
    }
}
