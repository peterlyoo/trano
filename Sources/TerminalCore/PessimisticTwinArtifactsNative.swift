import Foundation
import CryptoKit
import Darwin

extension TwinNativeGitFileSystem: TwinArtifactFileSystem {
    func artifactInfo(_ path: String) throws -> TwinArtifactNode? {
        let (parent, name) = try artifactParent(path)
        let fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { if errno == ENOENT { return nil }; throw TwinGitError.unsafe("Artifact parent is unavailable or linked") }
        defer { close(fd) }
        var value = stat()
        guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return nil }; throw TwinGitError.unsafe("Cannot inspect artifact metadata")
        }
        return artifactNode(value)
    }
    func artifactChildren(_ path: String, limit: Int) throws -> [String] {
        guard limit >= 0, limit <= 100_000 else { throw TwinGitError.unsafe("Invalid artifact entry bound") }
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw TwinGitError.unsafe("Artifact directory is unavailable or linked") }
        guard let directory = fdopendir(fd) else { close(fd); throw TwinGitError.unsafe("Cannot read artifact directory") }
        defer { closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw TwinGitError.unsafe("Artifact directory enumeration failed") }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(validatingCString: $0) }
            }
            guard let name else { throw TwinGitError.unsafe("Artifact names must be valid UTF-8") }
            if name == "." || name == ".." { continue }
            guard names.count < limit else { throw TwinGitError.unsafe("Artifact directory exceeds its entry bound") }
            names.append(name)
        }
        return names.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    }
    func artifactDigest(_ path: String, expected: TwinArtifactNode, limit: UInt64) throws -> String {
        guard expected.metadata.size >= 0, UInt64(expected.metadata.size) <= limit,
              try artifactInfo(path) == expected else { throw TwinGitError.unsafe("Artifact changed before hashing") }
        if expected.metadata.kind == .symlink {
            let bytes = try readLink(path, limit: 16_384)
            guard try artifactInfo(path) == expected else { throw TwinGitError.unsafe("Artifact link changed while hashing") }
            return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        }
        guard expected.metadata.kind == .regular, expected.links == 1 else { throw TwinGitError.unsafe("Unsupported artifact content") }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW_ANY | O_NONBLOCK)
        guard fd >= 0 else { throw TwinGitError.unsafe("Artifact content is unavailable or linked") }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, artifactNode(before) == expected else { throw TwinGitError.unsafe("Artifact identity changed before hashing") }
        var hash = SHA256(), count: UInt64 = 0, buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let size = Darwin.read(fd, &buffer, buffer.count)
            if size < 0 && errno == EINTR { continue }
            guard size >= 0 else { throw TwinGitError.unsafe("Artifact content read failed") }
            if size == 0 { break }
            guard UInt64(size) <= limit - count else { throw TwinGitError.unsafe("Artifact content exceeds its bound") }
            count += UInt64(size); hash.update(data: Data(buffer.prefix(size)))
        }
        guard fstat(fd, &after) == 0, artifactNode(after) == expected,
              count == UInt64(expected.metadata.size), try artifactInfo(path) == expected else { throw TwinGitError.unsafe("Artifact changed while hashing") }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func artifactMove(_ source: String, _ destination: String, expected: TwinArtifactNode) throws {
        let (sourceParent, sourceName) = try artifactParent(source), (targetParent, targetName) = try artifactParent(destination)
        let from = open(sourceParent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard from >= 0 else { throw TwinGitError.unsafe("Artifact source parent changed") }
        defer { close(from) }
        let to = open(targetParent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard to >= 0 else { throw TwinGitError.unsafe("Artifact quarantine parent changed") }
        defer { close(to) }
        var before = stat(), target = stat()
        guard fstatat(from, sourceName, &before, AT_SYMLINK_NOFOLLOW) == 0, artifactNode(before) == expected,
              fstatat(to, targetName, &target, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT,
              renameatx_np(from, sourceName, to, targetName, UInt32(RENAME_EXCL)) == 0 else {
            throw TwinGitError.unsafe("Artifact identity changed, destination exists, or exclusive atomic rename is unavailable")
        }
        guard fsync(from) == 0, fsync(to) == 0 else { throw TwinGitError.unsafe("Artifact was retained but its move needs durability inspection") }
    }
    func artifactCreatePrivateDirectory(_ path: String) throws {
        let (parent, name) = try artifactParent(path)
        let fd = open(parent, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw TwinGitError.unsafe("Private artifact parent is unavailable or linked") }
        defer { close(fd) }
        var owner = stat()
        guard fstat(fd, &owner) == 0, owner.st_uid == getuid(), owner.st_mode & 0o077 == 0,
              mkdirat(fd, name, 0o700) == 0, fsync(fd) == 0 else {
            throw TwinGitError.unsafe("Refusing to adopt or replace an existing artifact quarantine directory")
        }
    }
    func artifactSyncDirectory(_ path: String) throws {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW_ANY)
        guard fd >= 0 else { throw TwinGitError.unsafe("Cannot sync artifact directory") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw TwinGitError.unsafe("Cannot persist artifact directory") }
    }
    private func artifactParent(_ path: String) throws -> (String, String) {
        guard path.hasPrefix("/"), path.utf8.count <= 16_384, !path.utf8.contains(0),
              !path.hasSuffix("/"), !path.contains("//"),
              !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }), let slash = path.lastIndex(of: "/") else {
            throw TwinGitError.unsafe("Invalid artifact filesystem path")
        }
        return (slash == path.startIndex ? "/" : String(path[..<slash]), String(path[path.index(after: slash)...]))
    }
    private func artifactNode(_ value: stat) -> TwinArtifactNode {
        let kind: TwinGitNode.Kind
        switch value.st_mode & S_IFMT { case S_IFREG: kind = .regular; case S_IFDIR: kind = .directory; case S_IFLNK: kind = .symlink; default: kind = .other }
        return .init(metadata: .init(identity: .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: value.st_ino), ownerUID: value.st_uid,
            kind: kind, mode: UInt32(value.st_mode), size: value.st_size, modifiedSeconds: Int64(value.st_mtimespec.tv_sec),
            modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec), changedSeconds: Int64(value.st_ctimespec.tv_sec),
            changedNanoseconds: Int64(value.st_ctimespec.tv_nsec)), links: UInt64(value.st_nlink))
    }
}
