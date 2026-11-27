import Foundation
import Darwin

public struct WorktreeNativeGitRunner: WorktreeGitCommandRunning {
    public init() {}
    public func run(arguments: [String], environment: [String: String], timeout: TimeInterval, limit: Int) throws -> WorktreeGitCommandResult {
        let result = try CommandRunner.run("/usr/bin/git", arguments, environment: environment, timeout: timeout, limit: limit)
        return WorktreeGitCommandResult(status: result.status, stdout: result.stdout, stderr: result.stderr)
    }
}

public struct WorktreeNativeGitFileSystem: WorktreeGitFileSystem {
    public init() {}

    public func canonicalPath(_ path: String) throws -> String {
        try validate(path)
        guard let pointer = realpath(path, nil) else { throw WorktreeGitError.unsafe("Cannot resolve filesystem path") }
        defer { free(pointer) }
        guard let result = String(validatingUTF8: pointer) else { throw WorktreeGitError.unsafe("Invalid UTF-8 filesystem path") }
        return result
    }

    public func info(_ path: String) throws -> WorktreeGitFileInfo? {
        try validate(path)
        var value = stat()
        guard lstat(path, &value) == 0 else {
            if errno == ENOENT { return nil }
            throw WorktreeGitError.unsafe("Cannot inspect filesystem metadata")
        }
        let kind: WorktreeGitFileKind
        switch value.st_mode & S_IFMT {
        case S_IFDIR: kind = .directory
        case S_IFREG: kind = .regular
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return .init(identity: .init(device: UInt64(UInt32(bitPattern: value.st_dev)), inode: value.st_ino),
                     ownerUID: value.st_uid, kind: kind, size: UInt64(max(0, value.st_size)))
    }

    public func read(_ path: String, limit: Int) throws -> Data {
        try validate(path)
        guard limit >= 0, limit <= 1_048_576 else { throw WorktreeGitError.unsafe("Invalid filesystem read bound") }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw WorktreeGitError.unsafe("Cannot open worktree metadata") }
        defer { close(fd) }
        var before = stat(), after = stat()
        guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
              before.st_size >= 0, before.st_size <= limit else { throw WorktreeGitError.unsafe("Invalid worktree metadata file") }
        var data = Data(), buffer = [UInt8](repeating: 0, count: min(16_384, limit + 1))
        while true {
            let count = Darwin.read(fd, &buffer, min(buffer.count, limit + 1 - data.count))
            if count < 0 && errno == EINTR { continue }
            guard count >= 0 else { throw WorktreeGitError.unsafe("Cannot read worktree metadata") }
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= limit else { throw WorktreeGitError.unsafe("Worktree metadata exceeds bound") }
        }
        guard fstat(fd, &after) == 0, sameFile(before, after), after.st_size == data.count,
              before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec, before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
              before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec else {
            throw WorktreeGitError.unsafe("Worktree metadata changed during read")
        }
        return data
    }

    public func children(_ path: String, limit: Int) throws -> [String] {
        try validate(path)
        guard (0...16_384).contains(limit) else { throw WorktreeGitError.unsafe("Invalid directory enumeration bound") }
        let fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_DIRECTORY)
        guard fd >= 0 else { throw WorktreeGitError.unsafe("Cannot open metadata directory") }
        guard let directory = fdopendir(fd) else { close(fd); throw WorktreeGitError.unsafe("Cannot enumerate metadata directory") }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else { throw WorktreeGitError.unsafe("Metadata directory enumeration failed") }
                break
            }
            let name: String? = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(validatingUTF8: $0) }
            }
            guard let name else { throw WorktreeGitError.unsafe("Invalid UTF-8 metadata directory name") }
            if name == "." || name == ".." { continue }
            result.append(name)
            guard result.count <= limit else { throw WorktreeGitError.unsafe("Metadata directory exceeds bound") }
        }
        return result
    }

    private func validate(_ path: String) throws {
        guard path.hasPrefix("/"), !path.utf8.contains(0), path.utf8.count <= 16_384 else {
            throw WorktreeGitError.unsafe("Invalid filesystem path")
        }
    }

    private func sameFile(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode == rhs.st_mode && lhs.st_uid == rhs.st_uid
    }
}

public struct WorktreeNativeGitProcessProbe: WorktreeGitProcessProbing {
    public init() {}

    static func isVerifiedExited(pid: Int32, sample: kinfo_proc, returnedBytes: Int, querySucceeded: Bool) -> Bool {
        exitedIdentity(pid: pid, sample: sample, returnedBytes: returnedBytes, querySucceeded: querySucceeded) != nil
    }

    static func exitedIdentity(pid: Int32, sample: kinfo_proc, returnedBytes: Int, querySucceeded: Bool) -> SupervisorProcessIdentity? {
        let birth = sample.kp_proc.p_un.__p_starttime
        guard querySucceeded, returnedBytes == MemoryLayout<kinfo_proc>.size, pid > 1,
              sample.kp_proc.p_pid == pid, sample.kp_proc.p_stat == 5,
              sample.kp_eproc.e_pcred.p_ruid == getuid(), sample.kp_eproc.e_ucred.cr_uid == getuid(),
              birth.tv_sec > 0, birth.tv_usec >= 0, birth.tv_usec < 1_000_000 else { return nil }
        return SupervisorProcessIdentity(pid: pid, ownerUID: getuid(), startedAtSeconds: UInt64(birth.tv_sec), startedAtMicroseconds: UInt64(birth.tv_usec))
    }

    public func snapshot(limit: Int) throws -> WorktreeGitProcessSnapshot {
        guard (1...16_384).contains(limit) else { return .init(records: [], complete: false) }
        let deadline = ProcessInfo.processInfo.systemUptime + 2
        guard let before = ownedPIDs(limit: limit) else { return .init(records: [], complete: false) }
        var records: [WorktreeGitProcessRecord] = []
        var exited: [SupervisorProcessIdentity] = []
        var complete = true
        for pid in before {
            guard ProcessInfo.processInfo.systemUptime < deadline else { return .init(records: records, complete: false) }
            guard let first = identity(pid) else {
                if let witness = exitedIdentity(pid) { exited.append(witness); continue }
                complete = false; records.append(.init(pid: pid, ownerUID: getuid(), cwd: nil)); continue
            }
            var vnode = proc_vnodepathinfo()
            let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
            let count = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &vnode, size)
            let cwd: String? = withUnsafeBytes(of: &vnode.pvi_cdir.vip_path) { bytes in
                guard count == size, let end = bytes.firstIndex(of: 0), end > 0 else { return nil }
                return String(data: Data(bytes.prefix(end)), encoding: .utf8)
            }
            guard let after = identity(pid), first == after, let cwd, cwd.hasPrefix("/") else {
                complete = false; records.append(.init(pid: pid, ownerUID: first.ownerUID, cwd: nil)); continue
            }
            records.append(.init(pid: pid, ownerUID: first.ownerUID, cwd: cwd))
        }
        guard ProcessInfo.processInfo.systemUptime < deadline, let after = ownedPIDs(limit: limit), before == after else {
            return .init(records: records, complete: false)
        }
        for witness in exited {
            guard ProcessInfo.processInfo.systemUptime < deadline, exitedIdentity(witness.pid) == witness else {
                return .init(records: records, complete: false)
            }
        }
        return .init(records: records, complete: complete)
    }

    private func exitedIdentity(_ pid: Int32) -> SupervisorProcessIdentity? {
        var keys: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var sample = kinfo_proc(), bytes = MemoryLayout<kinfo_proc>.size
        let result = keys.withUnsafeMutableBufferPointer { sysctl($0.baseAddress, UInt32($0.count), &sample, &bytes, nil, 0) }
        return Self.exitedIdentity(pid: pid, sample: sample, returnedBytes: bytes, querySucceeded: result == 0)
    }

    private func ownedPIDs(limit: Int) -> [Int32]? {
        var pids = [Int32](repeating: 0, count: limit + 1)
        let size = Int32(pids.count * MemoryLayout<Int32>.size)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, size) }
        guard bytes > 0, bytes < size, bytes % Int32(MemoryLayout<Int32>.size) == 0 else { return nil }
        let result = Array(pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).filter { $0 > 0 }.sorted())
        guard result.count <= limit, Set(result).count == result.count else { return nil }
        return result
    }

    private func identity(_ pid: Int32) -> SupervisorProcessIdentity? {
        guard pid > 0 else { return nil }
        var value = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size, value.pbi_pid == UInt32(pid),
              value.pbi_uid == getuid(), value.pbi_status != 5, value.pbi_start_tvusec < 1_000_000 else { return nil }
        return .init(pid: pid, ownerUID: value.pbi_uid, startedAtSeconds: value.pbi_start_tvsec,
                     startedAtMicroseconds: value.pbi_start_tvusec)
    }
}
