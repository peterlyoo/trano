import Foundation
import Darwin

public protocol TwinGitCommandRunning {
    func run(arguments: [String], input: Data?, environment: [String: String], timeout: TimeInterval, limit: Int) throws -> WorktreeGitCommandResult
}

public struct TwinNativeGitRunner: TwinGitCommandRunning {
    public init() {}
    public func run(arguments: [String], input: Data?, environment: [String: String], timeout: TimeInterval, limit: Int) throws -> WorktreeGitCommandResult {
        let result = try CommandRunner.run("/usr/bin/git", arguments, input: input, environment: environment, timeout: timeout, limit: limit)
        return .init(status: result.status, stdout: result.stdout, stderr: result.stderr)
    }
}

public struct TwinGitNode: Equatable {
    public enum Kind: String { case directory, regular, symlink, other }
    public let identity: WorktreeFileIdentity
    public let ownerUID: UInt32
    public let kind: Kind
    public let mode: UInt32
    public let size: Int64
    public let modifiedSeconds: Int64
    public let modifiedNanoseconds: Int64
    public let changedSeconds: Int64
    public let changedNanoseconds: Int64
    public init(identity: WorktreeFileIdentity, ownerUID: UInt32, kind: Kind, mode: UInt32 = 0o100644, size: Int64 = 0,
                modifiedSeconds: Int64 = 0, modifiedNanoseconds: Int64 = 0, changedSeconds: Int64 = 0, changedNanoseconds: Int64 = 0) {
        self.identity = identity; self.ownerUID = ownerUID; self.kind = kind; self.mode = mode; self.size = size
        self.modifiedSeconds = modifiedSeconds; self.modifiedNanoseconds = modifiedNanoseconds
        self.changedSeconds = changedSeconds; self.changedNanoseconds = changedNanoseconds
    }
}

public protocol TwinGitFileSystem {
    func canonicalPath(_ path: String) throws -> String
    func info(_ path: String) throws -> TwinGitNode?
    func read(_ path: String, limit: Int) throws -> Data
    func readLink(_ path: String, limit: Int) throws -> Data
    func ensurePrivateDirectory(_ path: String) throws
    func writePrivate(_ data: Data, path: String) throws
    func removePrivateFile(_ path: String) throws
}

public struct TwinNativeGitFileSystem: TwinGitFileSystem {
    public init() {}
    public func canonicalPath(_ path: String) throws -> String { try WorktreeNativeGitFileSystem().canonicalPath(path) }
    public func info(_ path: String) throws -> TwinGitNode? {
        try validate(path)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let descriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else {
            if errno == ENOENT { return nil }
            throw TwinGitError.unsafe("Twin filesystem parent is unavailable or traverses a symbolic link")
        }
        defer { close(descriptor) }
        var value = stat()
        guard fstatat(descriptor, URL(fileURLWithPath: path).lastPathComponent, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }
            throw TwinGitError.unsafe("Cannot inspect twin filesystem metadata")
        }
        return node(value)
    }
    public func read(_ path: String, limit: Int) throws -> Data {
        try validate(path)
        guard (0...67_108_864).contains(limit) else { throw TwinGitError.unsafe("Invalid twin read limit") }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { throw TwinGitError.unsafe("Cannot open twin snapshot file") }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG, before.st_uid == getuid(),
              before.st_size >= 0, before.st_size <= limit else { throw TwinGitError.unsafe("Snapshot file is unavailable or exceeds its bound") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(65_536, limit + 1))
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw TwinGitError.unsafe("Cannot read snapshot file") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw TwinGitError.unsafe("Snapshot file exceeds its bound") }
        }
        guard fstat(fd, &after) == 0, node(before) == node(after), data.count == after.st_size,
              try info(path) == node(after) else { throw TwinGitError.unsafe("Snapshot file changed while reading") }
        return data
    }
    public func readLink(_ path: String, limit: Int) throws -> Data {
        guard (1...16_384).contains(limit), let before = try info(path), before.kind == .symlink, before.ownerUID == getuid() else {
            throw TwinGitError.unsafe("Invalid snapshot symbolic link")
        }
        var bytes = [UInt8](repeating: 0, count: limit + 1)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let descriptor = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard descriptor >= 0 else { throw TwinGitError.unsafe("Symbolic link parent changed") }
        defer { close(descriptor) }
        let count = readlinkat(descriptor, URL(fileURLWithPath: path).lastPathComponent, &bytes, bytes.count)
        guard count >= 0, count <= limit, try info(path) == before else { throw TwinGitError.unsafe("Snapshot symbolic link changed or exceeds its bound") }
        return Data(bytes.prefix(count))
    }
    public func ensurePrivateDirectory(_ path: String) throws {
        try validate(path)
        if let existing = try info(path) {
            guard existing.kind == .directory, existing.ownerUID == getuid(), existing.mode & 0o077 == 0,
                  try canonicalPath(path) == path else { throw TwinGitError.unsafe("Twin directory must be private, owned and canonical") }
            return
        }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        guard let owner = try info(parent), owner.kind == .directory, owner.ownerUID == getuid(), owner.mode & 0o077 == 0,
              try canonicalPath(parent) == parent, mkdir(path, 0o700) == 0 else { throw TwinGitError.unsafe("Cannot create private twin directory") }
    }
    public func writePrivate(_ data: Data, path: String) throws {
        try validate(path)
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        try ensurePrivateDirectory(parent)
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW_ANY, 0o600)
        guard fd >= 0 else { throw TwinGitError.unsafe("Twin journal path already exists or is unavailable") }
        defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(fd, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw TwinGitError.unsafe("Cannot write twin snapshot journal") }
                offset += count
            }
        }
        guard fsync(fd) == 0 else { throw TwinGitError.unsafe("Cannot persist twin snapshot journal") }
    }
    public func removePrivateFile(_ path: String) throws {
        try validate(path)
        guard let current = try info(path) else { return }
        guard current.kind == .regular, current.ownerUID == getuid(), unlink(path) == 0 else {
            throw TwinGitError.unsafe("Cannot remove private twin index")
        }
    }
    private func validate(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 16_384 else { throw TwinGitError.unsafe("Invalid twin filesystem path") }
    }
    private func node(_ value: stat) -> TwinGitNode {
        let kind: TwinGitNode.Kind
        switch value.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .regular
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return .init(identity: .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: value.st_ino), ownerUID: value.st_uid,
                     kind: kind, mode: UInt32(value.st_mode), size: value.st_size,
                     modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                     changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec))
    }
}
