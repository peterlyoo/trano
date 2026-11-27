import Foundation
import Darwin

struct TwinProfileOpenFile: Equatable {
    let descriptor: Int32
    let path: String
    let device: UInt64
    let inode: UInt64
}
struct TwinProfileProcessUseIdentity: Equatable {
    let birth: SupervisorProcessIdentity
    let exited: Bool
}
struct TwinProfileProcessUseProbe {
    var userID: UInt32
    var currentPID: Int32
    var processIDs: (Int) throws -> [Int32]
    var identity: (Int32) throws -> TwinProfileProcessUseIdentity
    var cwd: (Int32) throws -> String
    var files: (Int32, Int, TimeInterval) throws -> [TwinProfileOpenFile]
    var now: () -> TimeInterval
    static var native: Self {
        .init(userID: getuid(), currentPID: getpid(), processIDs: TwinNativeProfileProcessUse.processIDs,
              identity: TwinNativeProfileProcessUse.identity, cwd: TwinNativeProfileProcessUse.cwd,
              files: TwinNativeProfileProcessUse.files, now: { ProcessInfo.processInfo.systemUptime })
    }
}

enum TwinProfileProcessUse {
    static func validate(profileRoot: String, ignoringOwnDescriptors: [Int32: String] = [:],
                         probe: TwinProfileProcessUseProbe = .native, maxProcesses: Int = 4096,
                         maxDescriptors: Int = 65_536, maxDescriptorsPerProcess: Int = 16_384,
                         timeout: TimeInterval = 2) throws {
        guard validPath(profileRoot), profileRoot != "/", (1...16_384).contains(maxProcesses),
              (1...262_144).contains(maxDescriptors), (1...65_536).contains(maxDescriptorsPerProcess),
              timeout.isFinite, timeout > 0, timeout <= 10,
              ignoringOwnDescriptors.count <= 1024,
              ignoringOwnDescriptors.allSatisfy({ $0.key >= 0 && validPath($0.value) && inside($0.value, root: profileRoot) }) else {
            throw TerminalError.invalid("Invalid private profile process-use bounds or exact descriptor exemptions")
        }
        let started = probe.now()
        guard started.isFinite else { throw TerminalError.invalid("Private profile process-use clock is unavailable") }
        let deadline = started + timeout
        guard deadline.isFinite else { throw TerminalError.invalid("Private profile process-use deadline is unavailable") }
        func checkTime() throws {
            let now = probe.now()
            guard now.isFinite, now >= started, now < deadline else { throw TerminalError.invalid("Private profile process-use inspection exceeded its deadline") }
        }
        func processes() throws -> [Int32] {
            try checkTime()
            let pids = try probe.processIDs(maxProcesses)
            guard pids.count <= maxProcesses, pids.allSatisfy({ $0 > 1 }), Set(pids).count == pids.count else {
                throw TerminalError.invalid("Private profile process inventory is incomplete")
            }
            try checkTime()
            return pids.sorted()
        }
        func inspect(_ pid: Int32, remaining: Int) throws -> TwinProfileUseSnapshot {
            try checkTime()
            let identity = try probe.identity(pid)
            guard identity.birth.pid == pid, identity.birth.ownerUID == probe.userID,
                  identity.birth.startedAtSeconds > 0, identity.birth.startedAtMicroseconds < 1_000_000 else {
                throw TerminalError.invalid("Private profile process identity is unavailable")
            }
            let directory: String?
            let files: [TwinProfileOpenFile]
            if identity.exited { directory = nil; files = [] }
            else {
                let path = try probe.cwd(pid)
                guard validPath(path) else { throw TerminalError.invalid("Private profile process cwd is incomplete") }
                guard !inside(path, root: profileRoot) else { throw TerminalError.invalid("A live process still uses the private twin profile as its cwd") }
                directory = path
                files = try probe.files(pid, min(maxDescriptorsPerProcess, remaining), deadline).sorted { $0.descriptor < $1.descriptor }
                guard files.count <= remaining, files.count <= maxDescriptorsPerProcess,
                      Set(files.map(\.descriptor)).count == files.count,
                      files.allSatisfy({ $0.descriptor >= 0 && validPath($0.path) }) else {
                    throw TerminalError.invalid("Private profile file-descriptor inventory is incomplete")
                }
                var seenExemptions = Set<Int32>()
                for file in files {
                    if pid == probe.currentPID, ignoringOwnDescriptors[file.descriptor] == file.path { seenExemptions.insert(file.descriptor); continue }
                    guard !inside(file.path, root: profileRoot) else { throw TerminalError.invalid("A live process still holds an open file in the private twin profile") }
                }
                if pid == probe.currentPID, seenExemptions != Set(ignoringOwnDescriptors.keys) {
                    throw TerminalError.invalid("The cleanup process no longer holds its exact descriptor exemptions")
                }
            }
            guard try probe.identity(pid) == identity else { throw TerminalError.invalid("A process changed identity during private profile inspection") }
            try checkTime()
            return .init(pid: pid, identity: identity, cwd: directory, files: files)
        }
        let pids = try processes()
        guard ignoringOwnDescriptors.isEmpty || pids.contains(probe.currentPID) else { throw TerminalError.invalid("The cleanup process is absent from its descriptor exemption inventory") }
        var snapshots: [TwinProfileUseSnapshot] = [], count = 0
        for pid in pids {
            let snapshot = try inspect(pid, remaining: maxDescriptors - count)
            count += snapshot.files.count; snapshots.append(snapshot)
        }
        guard try processes() == pids else { throw TerminalError.invalid("Processes changed during private twin profile inspection") }
        count = 0
        for snapshot in snapshots {
            let current = try inspect(snapshot.pid, remaining: maxDescriptors - count)
            guard current.pid == snapshot.pid, current.identity == snapshot.identity, current.cwd == snapshot.cwd,
                  current.files.filter({ inside($0.path, root: profileRoot) }) == snapshot.files.filter({ inside($0.path, root: profileRoot) }) else {
                throw TerminalError.invalid("A process changed cwd or owned-profile descriptors during private profile inspection")
            }
            count += current.files.count
        }
        guard try processes() == pids else { throw TerminalError.invalid("Processes changed before private twin profile cleanup") }
    }
    private static func validPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path.utf8.count <= 4096 && (path == "/" || !path.hasSuffix("/")) && !path.contains("//")
            && !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            && !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." })
    }
    private static func inside(_ path: String, root: String) -> Bool { path == root || path.hasPrefix(root + "/") }
}

private struct TwinProfileUseSnapshot: Equatable {
    let pid: Int32
    let identity: TwinProfileProcessUseIdentity
    let cwd: String?
    let files: [TwinProfileOpenFile]
}
private struct TwinProfileFDHandle: Equatable {
    let descriptor: Int32
    let kind: UInt32
}

private enum TwinNativeProfileProcessUse {
    static func processIDs(limit: Int) throws -> [Int32] {
        var pids = [Int32](repeating: 0, count: limit + 1)
        let size = Int32(pids.count * MemoryLayout<Int32>.size)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, size) }
        guard bytes > 0, bytes < size, bytes % Int32(MemoryLayout<Int32>.size) == 0 else { throw unavailable() }
        let values = pids.prefix(Int(bytes) / MemoryLayout<Int32>.size).filter { $0 > 0 }
        guard values.count <= limit, Set(values).count == values.count else { throw unavailable() }
        return values.sorted()
    }
    static func identity(_ pid: Int32) throws -> TwinProfileProcessUseIdentity {
        var value = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard pid > 1, proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &value, size) == size,
              value.pbi_pid == UInt32(pid), value.pbi_uid == getuid(), (1...5).contains(value.pbi_status),
              value.pbi_start_tvsec > 0, value.pbi_start_tvusec < 1_000_000 else { throw unavailable() }
        return .init(birth: .init(pid: pid, ownerUID: value.pbi_uid, startedAtSeconds: value.pbi_start_tvsec,
                                  startedAtMicroseconds: value.pbi_start_tvusec), exited: value.pbi_status == 5)
    }
    static func cwd(_ pid: Int32) throws -> String {
        var value = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &value, size) == size else { throw unavailable() }
        return try withUnsafeBytes(of: &value.pvi_cdir.vip_path) { try path($0) }
    }
    static func files(_ pid: Int32, limit: Int, deadline: TimeInterval) throws -> [TwinProfileOpenFile] {
        let before = try handles(pid, limit: limit)
        var files: [TwinProfileOpenFile] = []
        for handle in before where handle.kind == UInt32(PROX_FDTYPE_VNODE) {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw unavailable() }
            var value = vnode_fdinfowithpath()
            let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
            guard proc_pidfdinfo(pid, handle.descriptor, PROC_PIDFDVNODEPATHINFO, &value, size) == size else { throw unavailable() }
            let name = try withUnsafeBytes(of: &value.pvip.vip_path) { try path($0) }
            files.append(.init(descriptor: handle.descriptor, path: name, device: UInt64(value.pvip.vip_vi.vi_stat.vst_dev), inode: value.pvip.vip_vi.vi_stat.vst_ino))
        }
        let after = try handles(pid, limit: limit)
        guard before.filter({ $0.kind == UInt32(PROX_FDTYPE_VNODE) }) == after.filter({ $0.kind == UInt32(PROX_FDTYPE_VNODE) }) else { throw unavailable() }
        return files
    }
    private static func handles(_ pid: Int32, limit: Int) throws -> [TwinProfileFDHandle] {
        guard (0...65_536).contains(limit) else { throw unavailable() }
        var entries = [proc_fdinfo](repeating: proc_fdinfo(), count: limit + 1)
        let size = Int32(entries.count * MemoryLayout<proc_fdinfo>.stride)
        let bytes = entries.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, size) }
        guard bytes > 0, bytes < size, bytes % Int32(MemoryLayout<proc_fdinfo>.stride) == 0 else { throw unavailable() }
        let known: Set<UInt32> = [0, 1, 2, 3, 4, 5, 6, 7, 9, 10, 11]
        let handles = entries.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride).map { TwinProfileFDHandle(descriptor: $0.proc_fd, kind: $0.proc_fdtype) }.sorted { $0.descriptor < $1.descriptor }
        guard handles.count <= limit, handles.allSatisfy({ $0.descriptor >= 0 && known.contains($0.kind) }), Set(handles.map(\.descriptor)).count == handles.count else { throw unavailable() }
        return handles
    }
    private static func path(_ bytes: UnsafeRawBufferPointer) throws -> String {
        guard let end = bytes.firstIndex(of: 0), end > 0, end < bytes.count - 1,
              let path = String(data: Data(bytes.prefix(end)), encoding: .utf8), path.hasPrefix("/") else { throw unavailable() }
        return path
    }
    private static func unavailable() -> TerminalError { .invalid("Private profile process or vnode descriptor inspection is unavailable or incomplete") }
}
