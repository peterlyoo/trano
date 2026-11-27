import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public final class UnisessionStateStore {
    public let root: URL
    private let maximumBytes = 65_536
    public init(root: URL) { self.root = root }

    public func load() throws -> UnisessionRecord? {
        let directory = try openRoot(); defer { close(directory) }
        guard let data = try readData(in: directory) else { return nil }
        let record: UnisessionRecord
        do { record = try JSONDecoder().decode(UnisessionRecord.self, from: data) }
        catch { throw TerminalError.invalid("Unisession state is not valid JSON.") }
        try validate(record)
        return record
    }

    public func reservation() -> DetachedPaneReservation {
        do { return .known(try load()?.reservedPaneIDs ?? []) }
        catch { return .unavailable }
    }

    public func save(_ record: UnisessionRecord) throws {
        try validate(record)
        let directory = try openRoot(); defer { close(directory) }
        _ = try readData(in: directory)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(record); data.append(10)
        guard data.count <= maximumBytes else { throw TerminalError.invalid("Unisession state exceeds 64 KiB.") }
        let temporary = ".unisession-write-" + UUID().uuidString.lowercased()
        let descriptor = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TerminalError.runtime("Cannot create private Unisession state.") }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = write(descriptor, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TerminalError.runtime("Cannot write Unisession state.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, renameat(directory, temporary, directory, "unisession.json") == 0 else {
            throw TerminalError.runtime("Cannot replace Unisession state.")
        }
    }

    private func validate(_ record: UnisessionRecord) throws {
        guard record.schemaVersion == 1, record.reservedPaneIDs.count <= 512,
              record.reservedPaneIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
              record.pendingPaneID.map({ record.reservedPaneIDs.contains($0) }) ?? true else {
            throw TerminalError.invalid("Invalid Unisession ownership state or unsupported schema.")
        }
        if let binding = record.binding {
            let identity = binding.processIdentity
            guard record.reservedPaneIDs.contains(binding.paneID), binding.backendPID > 1,
                  identity.pid == binding.backendPID, identity.ownerUID == getuid(), identity.startedAtSeconds > 0,
                  identity.startedAtMicroseconds < 1_000_000 else {
                throw TerminalError.invalid("Invalid Unisession process birth identity.")
            }
        }
    }

    private func openRoot() throws -> Int32 {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TerminalError.invalid("Unisession requires a private owned runtime directory.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor); throw TerminalError.invalid("Unisession requires a private owned runtime directory.")
        }
        return descriptor
    }

    private func readData(in directory: Int32) throws -> Data? {
        let descriptor = openat(directory, "unisession.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw TerminalError.invalid("Cannot open private Unisession state.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size >= 0, info.st_size <= maximumBytes else {
            throw TerminalError.invalid("Unisession state must be a private owned regular file of at most 64 KiB.")
        }
        var data = Data(), bytes = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &bytes, bytes.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.runtime("Cannot read Unisession state.") }
            if count == 0 { return data }
            guard data.count + count <= maximumBytes else { throw TerminalError.invalid("Unisession state exceeds 64 KiB.") }
            data.append(contentsOf: bytes.prefix(count))
        }
    }
}
