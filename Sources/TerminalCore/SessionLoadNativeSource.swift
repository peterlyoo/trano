import Foundation
import Darwin

public struct SessionLoadPIDList {
    public let pids: [Int32]
    public let complete: Bool
    public init(pids: [Int32], complete: Bool = true) { self.pids = pids; self.complete = complete }
}

public struct SessionHookFileBinding: Codable, Equatable, Sendable {
    public let paneID: String
    public let ownershipToken: String
    public let providerSessionID: String
    public let configurationRoot: String
    public let relativePath: String
    public init(paneID: String, ownershipToken: String, providerSessionID: String, configurationRoot: String, relativePath: String) {
        self.paneID = paneID; self.ownershipToken = ownershipToken; self.providerSessionID = providerSessionID
        self.configurationRoot = configurationRoot; self.relativePath = relativePath
    }
}

struct SessionHookFairSelection {
    private struct Identity: Hashable {
        let paneID: String
        let backendPID: Int32
        let ownershipToken: String
        let providerSessionID: String?
        let providerPID: Int32?
        let hookBindingToken: String

        init(_ target: SessionLoadTarget) {
            paneID = target.paneID; backendPID = target.backendPID; ownershipToken = target.ownershipToken
            providerSessionID = target.providerSessionID; providerPID = target.providerPID
            hookBindingToken = target.hookBindingToken
        }
    }
    private var queue: [Identity] = []

    mutating func next(targets: [SessionLoadTarget]) -> [SessionLoadTarget] {
        let bounded = Array(targets.prefix(4096))
        let groups = Dictionary(grouping: bounded, by: \.paneID)
        let eligible = bounded.filter {
            $0.local && $0.alive && $0.provider == .claude && $0.providerSessionID?.isEmpty == false && groups[$0.paneID]?.count == 1
        }
        let current = Dictionary(uniqueKeysWithValues: eligible.map { (Identity($0), $0) })
        queue.removeAll { current[$0] == nil }
        var queued = Set(queue)
        for target in eligible {
            let identity = Identity(target)
            if queued.insert(identity).inserted { queue.append(identity) }
        }
        let selected = Array(queue.prefix(16))
        queue.removeFirst(selected.count)
        queue.append(contentsOf: selected)
        return selected.compactMap { current[$0] }
    }
}

public final class SessionLoadNativeSource: SessionLoadSource {
    public typealias ListPIDs = (Int) -> SessionLoadPIDList
    public typealias ReadProcess = (Int32) -> SessionLoadProcess?
    public typealias ReadHook = (SessionLoadTarget, SessionLoadMoment, Int) -> SessionHookTail?
    private let userID: UInt32
    private let listPIDs: ListPIDs
    private let readProcess: ReadProcess
    private let readHook: ReadHook?
    private var bindingProvider: (() -> [SessionHookFileBinding])?

    public init(userID: UInt32, listPIDs: @escaping ListPIDs, readProcess: @escaping ReadProcess,
                readHook: ReadHook? = nil) {
        self.userID = userID; self.listPIDs = listPIDs; self.readProcess = readProcess; self.readHook = readHook
    }
    public convenience init(bindings: @escaping () -> [SessionHookFileBinding] = { [] }) {
        self.init(userID: getuid(), listPIDs: Self.nativePIDs, readProcess: Self.nativeProcess)
        bindingProvider = bindings
    }
    public func processes(targets: [SessionLoadTarget], at moment: SessionLoadMoment) -> SessionLoadBatch {
        let list = listPIDs(16_384)
        var seen: Set<Int32> = []
        let pids = list.pids.prefix(16_384).filter { $0 > 1 && seen.insert($0).inserted }
        let records = pids.compactMap { pid -> SessionLoadProcess? in
            guard let process = readProcess(pid), process.pid == pid, process.userID == userID else { return nil }
            return process
        }
        return SessionLoadBatch(processes: records, userID: userID, observedAt: moment.date,
                                monotonicSeconds: moment.monotonicSeconds, complete: list.complete && list.pids.count <= 16_384)
    }
    public func hookTails(targets: [SessionLoadTarget], at moment: SessionLoadMoment) -> [SessionHookTail]? {
        let reader: ReadHook
        if let bindingProvider {
            let bindings = Array(bindingProvider().prefix(4096))
            reader = { target, moment, limit in
                guard let binding = bindings.first(where: {
                    $0.paneID == target.paneID && $0.ownershipToken == target.hookBindingToken &&
                    $0.providerSessionID == target.providerSessionID
                }) else { return nil }
                let current = SessionHookFileBinding(paneID: binding.paneID, ownershipToken: target.ownershipToken,
                    providerSessionID: binding.providerSessionID, configurationRoot: binding.configurationRoot, relativePath: binding.relativePath)
                return SessionHookFileReader.tail(binding: current, target: target, at: moment, limit: limit)
            }
        } else if let readHook { reader = readHook }
        else { return nil }
        return targets.lazy.filter { $0.local && $0.alive && $0.provider == .claude && $0.providerSessionID != nil }.prefix(16)
            .compactMap { target in
                guard let tail = reader(target, moment, 262_144), tail.paneID == target.paneID,
                      tail.ownershipToken == target.ownershipToken, tail.providerSessionID == target.providerSessionID else { return nil }
                return tail
            }
    }

    private static func nativePIDs(limit: Int) -> SessionLoadPIDList {
        let capacity = min(max(limit, 1), 16_384) + 1
        var pids = [Int32](repeating: 0, count: capacity)
        let size = Int32(capacity * MemoryLayout<Int32>.size)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_UID_ONLY), getuid(), $0.baseAddress, size) }
        guard bytes >= 0 else { return SessionLoadPIDList(pids: [], complete: false) }
        let count = min(Int(bytes) / MemoryLayout<Int32>.size, capacity)
        return SessionLoadPIDList(pids: Array(pids.prefix(min(count, limit))), complete: count <= limit && bytes < size)
    }

    private struct KernelIdentity: Equatable {
        let pid: Int32
        let parent: Int32
        let userID: UInt32
        let started: UInt64
    }

    private static func kernelIdentity(_ pid: Int32) -> KernelIdentity? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != 5,
              info.pbi_start_tvusec < 1_000_000 else { return nil }
        let seconds = info.pbi_start_tvsec.multipliedReportingOverflow(by: 1_000_000)
        let start = seconds.partialValue.addingReportingOverflow(info.pbi_start_tvusec)
        guard !seconds.overflow, !start.overflow, start.partialValue > 0 else { return nil }
        return KernelIdentity(pid: pid, parent: Int32(bitPattern: info.pbi_ppid), userID: info.pbi_uid, started: start.partialValue)
    }

    private static let timebase: mach_timebase_info_data_t? = {
        var info = mach_timebase_info_data_t()
        return mach_timebase_info(&info) == KERN_SUCCESS && info.numer > 0 && info.denom > 0 ? info : nil
    }()

    private static func nativeProcess(_ pid: Int32) -> SessionLoadProcess? {
        guard let before = kernelIdentity(pid), let timebase else { return nil }
        var usage = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard status == 0, let after = kernelIdentity(pid), before == after,
              let cpu = SessionLoadClockUnits.nanoseconds(userTicks: usage.ri_user_time, systemTicks: usage.ri_system_time,
                                                        numerator: timebase.numer, denominator: timebase.denom) else { return nil }
        return SessionLoadProcess(pid: pid, parentPID: before.parent, userID: before.userID,
                                  startedAtMicroseconds: before.started, cpuNanoseconds: cpu, residentBytes: usage.ri_resident_size)
    }
}

public enum SessionHookFileReader {
    public static func tail(binding: SessionHookFileBinding, target: SessionLoadTarget,
                            at moment: SessionLoadMoment, limit: Int = 262_144) -> SessionHookTail? {
        guard target.local, target.alive, target.provider == .claude,
              binding.paneID == target.paneID, binding.ownershipToken == target.ownershipToken,
              binding.providerSessionID == target.providerSessionID, UUID(uuidString: binding.providerSessionID) != nil,
              binding.configurationRoot.hasPrefix("/"), !binding.configurationRoot.contains("\0"),
              binding.relativePath.utf8.count <= 4096 else { return nil }
        let parts = binding.relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard (1...64).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\0") }),
              parts.last == binding.providerSessionID + ".jsonl" else { return nil }
        var directory = open(binding.configurationRoot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { return nil }
        defer { close(directory) }
        guard owned(directory, type: S_IFDIR) else { return nil }
        for part in parts.dropLast() {
            let child = openat(directory, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard child >= 0 else { return nil }
            guard owned(child, type: S_IFDIR) else { close(child); return nil }
            close(directory); directory = child
        }
        guard let filename = parts.last else { return nil }
        let file = openat(directory, filename, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard file >= 0 else { return nil }
        defer { close(file) }
        var info = stat()
        guard fstat(file, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, info.st_size >= 0 else { return nil }
        let count = min(max(limit, 1), 262_144, Int(min(info.st_size, Int64(Int.max))))
        let offset = info.st_size - Int64(count)
        var bytes = [UInt8](repeating: 0, count: count)
        let received = bytes.withUnsafeMutableBytes { pread(file, $0.baseAddress, count, offset) }
        guard received >= 0 else { return nil }
        var after = stat()
        guard fstat(file, &after) == 0, after.st_ino == info.st_ino, after.st_dev == info.st_dev,
              after.st_size >= info.st_size else { return nil }
        return SessionHookTail(paneID: target.paneID, ownershipToken: target.ownershipToken,
                               providerSessionID: binding.providerSessionID, collectedAt: moment.date,
                               fileOffset: UInt64(offset), bytes: Data(bytes.prefix(received)))
    }

    private static func owned(_ fd: Int32, type: mode_t) -> Bool {
        var info = stat()
        return fstat(fd, &info) == 0 && info.st_uid == getuid() && info.st_mode & S_IFMT == type
    }
}
