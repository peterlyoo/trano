import Darwin
import Foundation

final class ForegroundProgramProbe {
    private struct Process: Hashable {
        let pid: Int32
        let parent: Int32
        let group: Int32
        let foreground: Int32
        let terminal: UInt32
        let seconds: UInt64
        let microseconds: UInt64
        let executable: String

        var identity: Identity { Identity(pid: pid, seconds: seconds, microseconds: microseconds, executable: executable) }
        var paneIdentity: PaneIdentity { PaneIdentity(pid: pid, seconds: seconds, microseconds: microseconds, terminal: terminal) }

        static func read(_ pid: Int32) -> Process? {
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != 5 else { return nil }
            var path = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return nil }
            return Process(pid: pid, parent: Int32(info.pbi_ppid), group: Int32(info.pbi_pgid),
                           foreground: Int32(bitPattern: info.e_tpgid), terminal: info.e_tdev,
                           seconds: info.pbi_start_tvsec, microseconds: info.pbi_start_tvusec,
                           executable: String(cString: path))
        }
    }

    private struct Identity: Hashable {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64
        let executable: String
    }

    private struct PaneIdentity: Equatable {
        let pid: Int32
        let seconds: UInt64
        let microseconds: UInt64
        let terminal: UInt32
    }

    private struct CachedProgram { let value: TerminalProgram? }
    private let lock = NSLock()
    private var bindings: [String: PaneIdentity] = [:]
    private var cache: [Identity: CachedProgram] = [:]
    private static let maximumArgumentBytes = 65_536

    static func shellOwnsForeground(pid: Int32) -> Bool {
        guard let pane = Process.read(pid), pane.terminal != UInt32.max, pane.terminal != 0,
              pane.group == pane.pid, pane.group == pane.foreground,
              ["zsh", "bash", "fish", "dash", "sh", "ksh"].contains(URL(fileURLWithPath: pane.executable).lastPathComponent),
              let current = Process.read(pid) else { return false }
        return current == pane
    }

    static func shellInputIdentity(pid: Int32, expected: SupervisorProcessIdentity) -> String? {
        guard expected.ownerUID == getuid(), let pane = Process.read(pid), pane.pid == expected.pid,
              pane.seconds == expected.startedAtSeconds, pane.microseconds == expected.startedAtMicroseconds,
              pane.seconds > 0, pane.terminal != UInt32.max, pane.terminal != 0, pane.group == pane.pid, pane.group == pane.foreground,
              ["zsh", "bash", "fish", "dash", "sh", "ksh"].contains(URL(fileURLWithPath: pane.executable).lastPathComponent),
              let current = Process.read(pid), current == pane else { return nil }
        return "\(pid):\(pane.seconds):\(pane.microseconds):\(pane.terminal):\(pane.group)"
    }

    func programs(for sessions: [TerminalSession], refreshIdentity: Bool = false) -> [String: TerminalProgram] {
        lock.lock()
        defer { lock.unlock() }
        let local = sessions.filter { $0.alive && $0.remote == nil }
        let paneIDs = Set(local.map(\.id))
        bindings = bindings.filter { paneIDs.contains($0.key) }
        var visited: Set<Identity> = []
        var result: [String: TerminalProgram] = [:]
        for session in local {
            guard let pane = Process.read(session.pid), pane.foreground > 1, pane.terminal != UInt32.max else { continue }
            if refreshIdentity || bindings[session.id] == nil || bindings[session.id]?.pid != pane.pid {
                bindings[session.id] = pane.paneIdentity
            }
            guard bindings[session.id] == pane.paneIdentity else { continue }
            let leader = pane.foreground == pane.pid ? pane : Process.read(pane.foreground)
            var program: TerminalProgram?
            if let leader, belongs(leader, to: pane) {
                program = classify(leader, visited: &visited)
            }
            if program == nil {
                for pid in groupMembers(pane.foreground) where pid != leader?.pid {
                    guard let process = Process.read(pid), belongs(process, to: pane) else { continue }
                    if let known = classify(process, visited: &visited) { program = known; break }
                }
            }
            guard let current = Process.read(pane.pid), current.paneIdentity == pane.paneIdentity,
                  current.foreground == pane.foreground else { continue }
            if let program { result[session.id] = program }
        }
        cache = cache.filter { visited.contains($0.key) }
        if cache.count > 512 { cache.removeAll(keepingCapacity: true) }
        return result
    }

    private func classify(_ process: Process, visited: inout Set<Identity>) -> TerminalProgram? {
        let key = process.identity
        visited.insert(key)
        if let cached = cache[key] { return cached.value }
        let arguments: [String]
        if process.executable.split(separator: "/").last == "kubectl" {
            guard let value = Self.arguments(pid: process.pid) else { return nil }
            arguments = value
        } else { arguments = [] }
        let program = TerminalProgram.classify(executable: process.executable, arguments: arguments)
        guard let current = Process.read(process.pid), current.identity == key,
              current.group == process.group, current.foreground == process.foreground,
              current.terminal == process.terminal else { return nil }
        cache[key] = CachedProgram(value: program)
        return program
    }

    private func belongs(_ process: Process, to pane: Process) -> Bool {
        guard process.group == pane.foreground, process.foreground == pane.foreground,
              process.terminal == pane.terminal else { return false }
        var current = process.pid
        var visited: Set<Int32> = []
        for _ in 0..<32 {
            if current == pane.pid { return true }
            guard visited.insert(current).inserted, let parent = Process.read(current) else { return false }
            current = parent.parent
        }
        return false
    }

    private func groupMembers(_ group: Int32) -> [Int32] {
        var pids = [Int32](repeating: 0, count: 64)
        let capacity = Int32(pids.count * MemoryLayout<Int32>.size)
        let bytes = pids.withUnsafeMutableBytes { raw in
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), raw.baseAddress, capacity)
        }
        guard bytes > 0 else { return [] }
        return pids.prefix(min(Int(bytes) / MemoryLayout<Int32>.size, pids.count)).filter { $0 > 1 }.sorted()
    }

    private static func arguments(pid: Int32) -> [String]? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var bytes = [UInt8](repeating: 0, count: maximumArgumentBytes)
        var size = bytes.count
        let count = UInt32(mib.count)
        let status = bytes.withUnsafeMutableBytes { raw in sysctl(&mib, count, raw.baseAddress, &size, nil, 0) }
        guard status == 0, size <= maximumArgumentBytes else { return nil }
        return decodeArguments(Data(bytes.prefix(size)))
    }

    static func decodeArguments(_ data: Data) -> [String]? {
        guard data.count >= MemoryLayout<Int32>.size, data.count <= maximumArgumentBytes else { return nil }
        let argc = data.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) }
        guard (1...4096).contains(argc), let pathEnd = data[4...].firstIndex(of: 0), pathEnd > 4 else { return nil }
        var cursor = pathEnd
        while cursor < data.count && data[cursor] == 0 { cursor += 1 }
        var result: [String] = []
        result.reserveCapacity(Int(argc))
        for _ in 0..<argc {
            guard cursor < data.count, let end = data[cursor...].firstIndex(of: 0),
                  let argument = String(data: data[cursor..<end], encoding: .utf8) else { return nil }
            result.append(argument)
            cursor = end + 1
        }
        return result
    }
}
