import Darwin
import XCTest
@testable import TerminalCore

final class WorktreeExitedProcessTests: XCTestCase {
    // Implements: FR-WT-3, FR-WT-7
    func testOnlyAnExactOwnedKernelZombieMayBeExcludedFromActiveDirectoryUse() {
        var sample = kinfo_proc()
        sample.kp_proc.p_pid = 42
        sample.kp_proc.p_stat = 5
        sample.kp_proc.p_un.__p_starttime.tv_sec = 10
        sample.kp_proc.p_un.__p_starttime.tv_usec = 20
        sample.kp_eproc.e_pcred.p_ruid = getuid()
        sample.kp_eproc.e_ucred.cr_uid = getuid()
        func allowed(_ value: kinfo_proc, pid: Int32 = 42, bytes: Int = MemoryLayout<kinfo_proc>.size, succeeded: Bool = true) -> Bool {
            WorktreeNativeGitProcessProbe.isVerifiedExited(pid: pid, sample: value, returnedBytes: bytes, querySucceeded: succeeded)
        }
        XCTAssertTrue(allowed(sample))
        for state: Int8 in [0, 1, 2, 3, 4, 6, 7] {
            var active = sample; active.kp_proc.p_stat = state
            XCTAssertFalse(allowed(active))
        }
        XCTAssertFalse(allowed(sample, pid: 43))
        XCTAssertFalse(allowed(sample, pid: 0))
        XCTAssertFalse(allowed(sample, bytes: 0))
        XCTAssertFalse(allowed(sample, bytes: MemoryLayout<kinfo_proc>.size - 1))
        XCTAssertFalse(allowed(sample, succeeded: false))
        var other = sample; other.kp_eproc.e_pcred.p_ruid = getuid() + 1
        XCTAssertFalse(allowed(other))
        other = sample; other.kp_eproc.e_ucred.cr_uid = getuid() + 1
        XCTAssertFalse(allowed(other))
        for seconds in [-1, 0] {
            var invalid = sample; invalid.kp_proc.p_un.__p_starttime.tv_sec = seconds
            XCTAssertFalse(allowed(invalid))
        }
        for micros: Int32 in [-1, 1_000_000] {
            var invalid = sample; invalid.kp_proc.p_un.__p_starttime.tv_usec = micros
            XCTAssertFalse(allowed(invalid))
        }
    }

    func testExitedWitnessRetainsBirthIdentityToRejectReusedPIDs() throws {
        var sample = kinfo_proc()
        sample.kp_proc.p_pid = 42; sample.kp_proc.p_stat = 5
        sample.kp_eproc.e_pcred.p_ruid = getuid(); sample.kp_eproc.e_ucred.cr_uid = getuid()
        sample.kp_proc.p_un.__p_starttime.tv_sec = 10; sample.kp_proc.p_un.__p_starttime.tv_usec = 20
        let original = try XCTUnwrap(WorktreeNativeGitProcessProbe.exitedIdentity(pid: 42, sample: sample, returnedBytes: MemoryLayout<kinfo_proc>.size, querySucceeded: true))
        XCTAssertEqual(original.startedAtSeconds, 10); XCTAssertEqual(original.startedAtMicroseconds, 20)
        sample.kp_proc.p_un.__p_starttime.tv_usec = 21
        XCTAssertNotEqual(original, WorktreeNativeGitProcessProbe.exitedIdentity(pid: 42, sample: sample, returnedBytes: MemoryLayout<kinfo_proc>.size, querySucceeded: true))
    }
}
