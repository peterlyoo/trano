import Foundation
import Darwin
struct TwinPrivateProfileCleanup {
    static func remove(root: URL, runID: String, round: Int, provider: String, profilePath: String,
                       ticketPresent: Bool = true, userID: uid_t = getuid(), beforeRemove: () throws -> Void = {},
                       processAdmission: ([Int32: String]) throws -> Void = { _ in }) throws {
        let expected = root.path + "/twins/\(runID)/round-\(round)/profile"
        guard valid(root.path), valid(profilePath), UUID(uuidString: runID)?.uuidString.lowercased() == runID,
              (1...8).contains(round), ["claude", "codex"].contains(provider), profilePath == expected else {
            throw TerminalError.invalid("Private twin cleanup is not the exact owned profile path")
        }
        let first = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard first >= 0 else { throw TerminalError.invalid("Cannot inspect private twin profile ancestors") }
        var descriptors = [first], edges: [(Int32, String, Int32, stat)] = []
        defer { for descriptor in descriptors.reversed() { close(descriptor) } }
        let rootDepth = root.path.split(separator: "/").count
        for (index, part) in profilePath.split(separator: "/").enumerated() {
            let parent = descriptors.last!, name = String(part)
            let child = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if child < 0, errno == ENOENT, index >= rootDepth { return }
            guard child >= 0 else { throw TerminalError.invalid("Private twin profile ancestors must not be links") }
            descriptors.append(child)
            var info = stat()
            guard fstat(child, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == userID || index < rootDepth - 1 && info.st_uid == 0,
                  index < rootDepth - 1 || info.st_mode & 0o7777 == 0o700 else {
                throw TerminalError.invalid("Private twin profile ownership or permissions changed")
            }
            edges.append((parent, name, child, info))
        }
        guard ticketPresent, let directory = descriptors.last else {
            throw TerminalError.invalid("A private twin profile without its launch ticket is retained")
        }
        let marker = ".trano-twin-profile", bytes = Data("trano-pessimistic-twin-v1\n\(runID):\(round):\(provider)\n".utf8)
        let file = openat(directory, marker, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else { throw TerminalError.invalid("The private twin profile lacks its ownership marker") }
        defer { close(file) }
        var info = stat(), buffer = [UInt8](repeating: 0, count: 1024)
        guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_mode & 0o7777 == 0o600,
              info.st_uid == userID, info.st_nlink == 1, info.st_size == bytes.count else {
            throw TerminalError.invalid("The private twin profile marker is not private and owned")
        }
        var count: Int
        repeat { count = Darwin.read(file, &buffer, buffer.count) } while count < 0 && errno == EINTR
        guard count == bytes.count, Data(buffer.prefix(max(0, count))) == bytes else {
            throw TerminalError.invalid("The private twin profile marker belongs to another launch")
        }
        try beforeRemove()
        try processAdmission([directory: profilePath, file: profilePath + "/" + marker])
        for (parent, name, descriptor, original) in edges {
            var pathInfo = stat(), heldInfo = stat()
            guard fstatat(parent, name, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0, fstat(descriptor, &heldInfo) == 0,
                  same(original, pathInfo), same(original, heldInfo) else {
                throw TerminalError.invalid("Private twin profile identity changed before cleanup")
            }
        }
        var pathInfo = stat(), heldInfo = stat()
        guard fstatat(directory, marker, &pathInfo, AT_SYMLINK_NOFOLLOW) == 0, fstat(file, &heldInfo) == 0,
              same(info, pathInfo), same(info, heldInfo), info.st_size == heldInfo.st_size,
              info.st_mtimespec.tv_sec == heldInfo.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec == heldInfo.st_mtimespec.tv_nsec,
              info.st_ctimespec.tv_sec == heldInfo.st_ctimespec.tv_sec, info.st_ctimespec.tv_nsec == heldInfo.st_ctimespec.tv_nsec else {
            throw TerminalError.invalid("The private twin profile marker changed before cleanup")
        }
        try FileManager.default.removeItem(atPath: profilePath)
    }
    private static func same(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_uid == b.st_uid && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
    }
    private static func valid(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096 && !path.hasSuffix("/") && !path.contains("//")
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
}

extension TerminalRuntime {
    public func cleanupTwinPrivateProfile(run: TwinRun, round: TwinRound) throws {
        try assertOutsideSharedTransaction()
        let profilePath = root.appendingPathComponent("twins/\(run.id)/round-\(round.number)/profile").path
        if try TwinNativeGitFileSystem().info(profilePath) != nil {
            try TwinProfileProcessUse.validate(profileRoot: profilePath)
        }
        try transaction {
            let current = try requireTwin(run.id)
            guard current == run, current.phase == .cleaning, current.operation?.kind == .cleanup,
                  current.operation?.round == round.number, current.rounds.filter({ $0.number == round.number }) == [round], !round.cleaned else {
                throw TerminalError.invalid("Private twin cleanup lost its exact round claim")
            }
            let base = root.appendingPathComponent("twins/\(run.id)/round-\(round.number)")
            var info = stat()
            let exists = lstat(base.appendingPathComponent("launch-ticket.json").path, &info) == 0
            guard exists || errno == ENOENT else { throw TerminalError.invalid("Cannot verify the private twin launch ticket") }
            let ticket = exists ? try twinLaunchTicket(runID: run.id, round: round.number) : nil
            let profile = base.appendingPathComponent("profile").path
            guard ticket == nil || ticket?.source == run.source && ticket?.configurationRoot == profile,
                  round.pane == nil || ticket?.paneID == round.pane?.paneID else {
                throw TerminalError.invalid("Private twin cleanup ticket ownership changed")
            }
            let ownPanes = Set([round.pane?.paneID, ticket?.paneID].compactMap { $0 })
            let paths = [profile, round.snapshot?.worktreePath ?? base.appendingPathComponent("worktree").path]
            let inside: (String) -> Bool = { path in paths.contains { path == $0 || path.hasPrefix($0 + "/") } }
            let state = try state()
            guard !state.sessions.contains(where: { ownPanes.contains($0.id) || $0.alive && $0.remote == nil && inside($0.cwd) }),
                  !state.agentLaunches.contains(where: { $0.lifecycle == .active && (ownPanes.contains($0.paneID) || inside($0.cwd) || inside($0.configurationRoot)) }) else {
                throw TerminalError.invalid("A live pane or agent still uses the private twin profile")
            }
            try TwinPrivateProfileCleanup.remove(root: root, runID: run.id, round: round.number, provider: run.source.provider.rawValue,
                profilePath: ticket?.configurationRoot ?? profile, ticketPresent: ticket != nil, processAdmission: { descriptors in
                    try TwinProfileProcessUse.validate(profileRoot: profile, ignoringOwnDescriptors: descriptors)
                })
        }
    }
}
