import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public struct SupervisorProcessIdentity: Codable, Equatable {
    public let pid: Int32
    public let ownerUID: UInt32
    public let startedAtSeconds: UInt64
    public let startedAtMicroseconds: UInt64

    public init(pid: Int32, ownerUID: UInt32, startedAtSeconds: UInt64, startedAtMicroseconds: UInt64) {
        self.pid = pid
        self.ownerUID = ownerUID
        self.startedAtSeconds = startedAtSeconds
        self.startedAtMicroseconds = startedAtMicroseconds
    }

    public static func read(_ pid: Int32) -> SupervisorProcessIdentity? {
        #if canImport(Darwin)
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
              info.pbi_pid == UInt32(pid), info.pbi_uid == getuid(), info.pbi_status != 5 else { return nil }
        return SupervisorProcessIdentity(pid: pid, ownerUID: info.pbi_uid,
            startedAtSeconds: info.pbi_start_tvsec, startedAtMicroseconds: info.pbi_start_tvusec)
        #else
        return nil
        #endif
    }
}
