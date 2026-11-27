import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct WorktreeCleanupState: Codable, Equatable {
    public var schemaVersion = 1
    public var captures: [WorktreeCapture]
    public var records: [WorktreeCleanupRecord]
    public init(captures: [WorktreeCapture] = [], records: [WorktreeCleanupRecord] = []) {
        self.captures = captures; self.records = records
    }
}

public final class WorktreeCleanupStore {
    public let root: URL
    private let maximumBytes = 1_048_576
    public init(root: URL) { self.root = root }

    public func load() throws -> WorktreeCleanupState {
        let directory = try openRoot(); defer { close(directory) }
        guard let data = try readData(in: directory) else { return WorktreeCleanupState() }
        let state: WorktreeCleanupState
        do { state = try JSONDecoder().decode(WorktreeCleanupState.self, from: data) }
        catch { throw TerminalError.invalid("Worktree cleanup state is invalid.") }
        try validate(state)
        return state
    }

    public func transaction<T>(_ body: (inout WorktreeCleanupState) throws -> T) throws -> T {
        let directory = try openRoot(); defer { close(directory) }
        let lease = try openLease("worktree-cleanup.lock", directory: directory); defer { close(lease) }
        while flock(lease, LOCK_EX) != 0 {
            guard errno == EINTR else { throw TerminalError.runtime("Cannot lock worktree cleanup state.") }
        }
        var state = try load()
        let previous = state
        let result = try body(&state)
        if state != previous { try save(state, directory: directory) }
        return result
    }

    public func withCleanupLease<T>(_ body: () throws -> T) throws -> T? {
        let directory = try openRoot(); defer { close(directory) }
        let lease = try openLease("worktree-cleanup-operation.lock", directory: directory); defer { close(lease) }
        guard flock(lease, LOCK_EX | LOCK_NB) == 0 else {
            if errno == EWOULDBLOCK || errno == EAGAIN { return nil }
            throw TerminalError.runtime("Cannot acquire worktree cleanup operation ownership.")
        }
        return try body()
    }

    private func openLease(_ name: String, directory: Int32) throws -> Int32 {
        let descriptor = openat(directory, name, O_CREAT | O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TerminalError.invalid("Cannot open worktree cleanup lease.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            close(descriptor); throw TerminalError.invalid("Worktree cleanup lease must be private and owned.")
        }
        return descriptor
    }

    private func openRoot() throws -> Int32 {
        let descriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TerminalError.invalid("Worktree cleanup requires a private runtime directory.") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
            close(descriptor); throw TerminalError.invalid("Worktree cleanup requires a private owned runtime directory.")
        }
        return descriptor
    }

    private func readData(in directory: Int32) throws -> Data? {
        let descriptor = openat(directory, "worktree-cleanup.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw TerminalError.invalid("Cannot open worktree cleanup state.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == getuid(),
              info.st_nlink == 1, info.st_mode & 0o077 == 0, info.st_size >= 0, info.st_size <= maximumBytes else {
            throw TerminalError.invalid("Worktree cleanup state must be a private owned regular file of at most 1 MiB.")
        }
        var result = Data(), buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw TerminalError.runtime("Cannot read worktree cleanup state.") }
            if count == 0 { return result }
            guard result.count + count <= maximumBytes else { throw TerminalError.invalid("Worktree cleanup state exceeds 1 MiB.") }
            result.append(contentsOf: buffer.prefix(count))
        }
    }

    private func save(_ state: WorktreeCleanupState, directory: Int32) throws {
        try validate(state)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var data = try encoder.encode(state); data.append(10)
        guard data.count <= maximumBytes else { throw TerminalError.invalid("Worktree cleanup state exceeds 1 MiB.") }
        let temporary = ".worktree-cleanup-write-" + UUID().uuidString.lowercased()
        let descriptor = openat(directory, temporary, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw TerminalError.runtime("Cannot create worktree cleanup state.") }
        defer { close(descriptor); _ = unlinkat(directory, temporary, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw TerminalError.runtime("Cannot write worktree cleanup state.") }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, renameat(directory, temporary, directory, "worktree-cleanup.json") == 0 else {
            throw TerminalError.runtime("Cannot replace worktree cleanup state.")
        }
    }

    private func validate(_ state: WorktreeCleanupState) throws {
        guard state.schemaVersion == 1, state.captures.count <= 32, state.records.count <= 256,
              Set(state.captures.map(\.id)).count == state.captures.count,
              Set(state.records.map(\.id)).count == state.records.count else { throw TerminalError.invalid("Invalid worktree cleanup state bounds.") }
        func path(_ value: String) -> Bool { value.hasPrefix("/") && !value.contains("\0") && value.utf8.count <= 4096 }
        func owner(_ value: WorktreeOwner) -> Bool {
            UUID(uuidString: value.paneID) != nil && !value.generation.isEmpty && !value.generation.contains("\0") && value.generation.utf8.count <= 256
                && value.backendPID > 1 && value.processIdentity.pid == value.backendPID && value.processIdentity.ownerUID == getuid()
                && value.processIdentity.startedAtSeconds > 0 && value.processIdentity.startedAtMicroseconds < 1_000_000
        }
        for capture in state.captures {
            guard UUID(uuidString: capture.id) != nil, UUID(uuidString: capture.nonce) != nil, owner(capture.owner),
                  path(capture.invocation.cwd), path(capture.invocation.targetPath), capture.invocation.gitArguments.count <= 64,
                  capture.invocation.gitArguments.reduce(0, { $0 + $1.utf8.count }) <= 16_384,
                  capture.invocation.gitArguments.allSatisfy({ !$0.contains("\0") }), capture.startedAt.timeIntervalSince1970.isFinite,
                  capture.before.map({ $0.worktrees.count <= 512 }) ?? true else { throw TerminalError.invalid("Invalid worktree creation capture.") }
        }
        for record in state.records {
            guard UUID(uuidString: record.id) != nil, owner(record.owner), path(record.identity.path),
                  path(record.identity.commonDirectory), path(record.identity.adminDirectory),
                  record.createdAt.timeIntervalSince1970.isFinite, record.updatedAt.timeIntervalSince1970.isFinite,
                  record.message.map({ $0.utf8.count <= 2048 }) ?? true else { throw TerminalError.invalid("Invalid tracked worktree identity.") }
            if record.status == .pending, record.completion == nil || record.eligibleAt == nil {
                throw TerminalError.invalid("Pending worktree cleanup lacks completion eligibility.")
            }
            if let eligible = record.eligibleAt {
                guard eligible.timeIntervalSince1970.isFinite, let proof = record.completion,
                      eligible >= proof.completedAt.addingTimeInterval(30) else {
                    throw TerminalError.invalid("Worktree cleanup cannot shorten the completion grace.")
                }
            }
            if let proof = record.completion {
                guard proof.owner == record.owner, !proof.completionID.isEmpty, proof.completionID.utf8.count <= 256,
                      !proof.turnID.isEmpty, proof.turnID.utf8.count <= 256, proof.completedAt.timeIntervalSince1970.isFinite else {
                    throw TerminalError.invalid("Invalid worktree completion proof.")
                }
            }
        }
    }
}
