import Foundation
import CryptoKit
import Darwin

public struct ClaudeAuthenticationContext: Codable, Equatable, Sendable {
    public let cwd: String
    public init(cwd: String) throws {
        guard cwd.hasPrefix("/"), cwd.utf8.count <= 4096,
              cwd.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }),
              !cwd.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
              !cwd.contains("//"), cwd == "/" || !cwd.hasSuffix("/") else {
            throw TerminalError.invalid("Claude authentication context requires an absolute normalized working directory")
        }
        self.cwd = cwd
    }
    private enum CodingKeys: String, CodingKey { case cwd }
    public init(from decoder: Decoder) throws {
        try self.init(cwd: decoder.container(keyedBy: CodingKeys.self).decode(String.self, forKey: .cwd))
    }
}

struct ClaudeAuthenticationContextReader {
    private let managedCandidates: [URL]
    private let managedDropInDirectories: [URL]
    private let ancestorBoundary: URL?
    init(managedCandidates: [URL], managedDropInDirectories: [URL] = [], ancestorBoundary: URL? = nil) {
        self.managedCandidates = managedCandidates
        self.managedDropInDirectories = managedDropInDirectories
        self.ancestorBoundary = ancestorBoundary
    }
    static func native(_ context: ClaudeAuthenticationContext, _ accountRoot: URL) throws -> String {
        let policy = URL(fileURLWithPath: "/Library/Application Support/ClaudeCode")
        let preferences = URL(fileURLWithPath: "/Library/Managed Preferences")
        let user = NSUserName()
        guard !user.isEmpty, !user.contains("/"), user != ".", user != ".." else { throw unavailable() }
        return try Self(managedCandidates: [policy.appendingPathComponent("managed-settings.json"),
            preferences.appendingPathComponent("com.anthropic.claudecode.plist"),
            preferences.appendingPathComponent(user).appendingPathComponent("com.anthropic.claudecode.plist")],
            managedDropInDirectories: [policy.appendingPathComponent("managed-settings.d")]).capture(context, accountRoot: accountRoot)
    }
    func capture(_ context: ClaudeAuthenticationContext, accountRoot: URL) throws -> String {
        let context = try ClaudeAuthenticationContext(cwd: context.cwd)
        if let boundary = ancestorBoundary?.path {
            guard context.cwd == boundary || context.cwd.hasPrefix(boundary + "/") else { throw Self.unavailable() }
        }
        guard managedCandidates.count <= 16, managedDropInDirectories.count <= 8 else { throw Self.unavailable() }
        let cwd = try Self.directory(context.cwd, ownedLeaf: true)
        close(cwd.fd)
        var witnesses: [[String: Any]] = [["cwd": context.cwd, "identity": cwd.identity]]
        var total = 0, cursor = URL(fileURLWithPath: context.cwd), depth = 0
        while true {
            guard depth < 64 else { throw Self.unavailable() }
            for name in ["settings.json", "settings.local.json"] {
                let path = cursor.appendingPathComponent(".claude").appendingPathComponent(name).path
                witnesses.append(try Self.settings(path, total: &total))
            }
            witnesses.append(try Self.gitMarker(cursor.appendingPathComponent(".git").path))
            if cursor.path == (ancestorBoundary?.path ?? "/") { break }
            cursor.deleteLastPathComponent(); depth += 1
        }
        for candidate in managedCandidates + [accountRoot.appendingPathComponent("remote-settings.json")] {
            witnesses.append(try Self.absent(candidate.path))
        }
        for directory in managedDropInDirectories { witnesses.append(try Self.absent(directory.path)) }
        let finalCwd = try Self.directory(context.cwd, ownedLeaf: true)
        close(finalCwd.fd)
        guard finalCwd.identity == cwd.identity else { throw Self.unavailable() }
        return try Self.hash(witnesses)
    }
    private static func settings(_ path: String, total: inout Int) throws -> [String: Any] {
        let opened = try pathParent(path)
        guard let parent = opened.fd else { return ["path": path, "missing": opened.missing!] }
        defer { close(parent) }
        let name = URL(fileURLWithPath: path).lastPathComponent
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if fd < 0 {
            guard errno == ENOENT else { throw unavailable() }
            return ["path": path, "missing": opened.identity]
        }
        defer { close(fd) }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_uid == getuid(), before.st_nlink == 1, before.st_size >= 0, before.st_size <= 1_048_576 else { throw unavailable() }
        var data = Data(), buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count < 0 && errno == EINTR { continue }
            guard count >= 0, data.count + max(0, count) <= 1_048_576 else { throw unavailable() }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        total += data.count
        guard total <= 4 * 1_048_576 else { throw unavailable() }
        var after = stat(), current = stat()
        guard fstat(fd, &after) == 0, fstatat(parent, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
              fileIdentity(before) == fileIdentity(after), fileIdentity(before) == fileIdentity(current), data.count == before.st_size else { throw unavailable() }
        let object: [String: Any]
        do {
            guard let decoded = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw unavailable() }
            object = decoded
        } catch { throw unavailable() }
        for key in ["policyHelper", "policyHelpers", "managedSettings"] where object[key] != nil && !(object[key] is NSNull) { throw unavailable() }
        return ["path": path, "parent": opened.identity, "auth": try ClaudeAuthenticationIdentityReader.authProjection(object, credentials: false)]
    }
    private static func absent(_ path: String) throws -> [String: Any] {
        let opened = try pathParent(path)
        guard let parent = opened.fd else { return ["path": path, "missing": opened.missing!] }
        defer { close(parent) }
        var info = stat()
        if fstatat(parent, URL(fileURLWithPath: path).lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 { throw unavailable() }
        guard errno == ENOENT else { throw unavailable() }
        return ["path": path, "missing": opened.identity]
    }
    private static func gitMarker(_ path: String) throws -> [String: Any] {
        let opened = try pathParent(path)
        guard let parent = opened.fd else { return ["path": path, "missing": opened.missing!] }
        defer { close(parent) }
        var info = stat()
        guard fstatat(parent, ".git", &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            guard errno == ENOENT else { throw unavailable() }
            return ["path": path, "missing": opened.identity]
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid() else { throw unavailable() }
        return ["path": path, "directory": directoryIdentity(info)]
    }
    private static func pathParent(_ path: String) throws -> (fd: Int32?, identity: String, missing: String?) {
        guard path.hasPrefix("/"), path.utf8.count <= 8192 else { throw unavailable() }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent().path
        let parts = parent.split(separator: "/").map(String.init)
        guard parts.count <= 64 else { throw unavailable() }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw unavailable() }
        var current = "/", info = stat()
        guard fstat(fd, &info) == 0 else { close(fd); throw unavailable() }
        for part in parts {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if next < 0 {
                let failure = errno, identity = directoryIdentity(info)
                close(fd)
                guard failure == ENOENT else { throw unavailable() }
                return (nil, "", current + ":" + identity + ":" + part)
            }
            close(fd); fd = next
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == getuid() || info.st_uid == 0 else { close(fd); throw unavailable() }
            current = URL(fileURLWithPath: current).appendingPathComponent(part).path
        }
        return (fd, directoryIdentity(info), nil)
    }
    private static func directory(_ path: String, ownedLeaf: Bool) throws -> (fd: Int32, identity: String) {
        let opened = try pathParent(URL(fileURLWithPath: path).appendingPathComponent(".context-witness").path)
        guard let fd = opened.fd else { throw unavailable() }
        var info = stat()
        guard fstat(fd, &info) == 0, !ownedLeaf || info.st_uid == getuid() else { close(fd); throw unavailable() }
        return (fd, opened.identity)
    }
    private static func directoryIdentity(_ value: stat) -> String { "\(value.st_dev):\(value.st_ino):\(value.st_mode):\(value.st_uid)" }
    private static func fileIdentity(_ value: stat) -> String { "\(directoryIdentity(value)):\(value.st_nlink):\(value.st_size):\(value.st_mtimespec.tv_sec):\(value.st_mtimespec.tv_nsec):\(value.st_ctimespec.tv_sec):\(value.st_ctimespec.tv_nsec)" }
    private static func hash(_ value: Any) throws -> String {
        SHA256.hash(data: try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
    }
    private static func unavailable() -> TerminalError { .invalid("Claude project or managed authentication settings are unavailable or changed; verify this launch context again") }
}
