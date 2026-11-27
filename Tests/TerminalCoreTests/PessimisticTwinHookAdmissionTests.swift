import Foundation
import Darwin
import XCTest
import TranoSandboxBridge
@testable import TerminalCore

final class PessimisticTwinHookAdmissionTests: XCTestCase {
    // Implements: FR-TWIN-3, FR-TWIN-5, FR-TWIN-7, FR-TWIN-9.
    func testExactUnsandboxedRootHelperIsAdmitted() throws {
        let f = HookAdmissionFixture()
        XCTAssertNoThrow(try f.validate())
        XCTAssertEqual(f.queries, ["21:" + f.protected])
    }
    func testModelDescendantWithSameHelperAndRootAncestryCannotForgeHook() throws {
        let f = HookAdmissionFixture(); f.query = .init(result: 1, error: 0)
        XCTAssertThrowsError(try f.validate())
        XCTAssertEqual(f.queries.count, 1)
    }
    func testUnknownUnsupportedAndErrnoSandboxChecksFailClosed() throws {
        for result in [TranoTwinSandboxWriteResult(result: -1, error: ENOSYS), .init(result: -1, error: EINVAL), .init(result: 2, error: 0), .init(result: 0, error: EIO)] {
            let f = HookAdmissionFixture(); f.query = result
            XCTAssertThrowsError(try f.validate())
        }
    }
    func testPeerMustBeExactOwnedHelperExecutable() throws {
        for reason in ["copied-helper", "foreign-peer", "foreign-provider", "missing-peer", "missing-provider", "not-root"] {
            let f = HookAdmissionFixture()
            if reason == "copied-helper" { f.processes[21] = f.process(21, path: "/worktree/trano") }
            if reason == "foreign-peer" { f.processes[21] = f.process(21, owner: 502) }
            if reason == "foreign-provider" { f.processes[11] = f.process(11, owner: 502) }
            if reason == "missing-peer" { f.processes[21] = nil }
            if reason == "missing-provider" { f.processes[11] = nil }
            if reason == "not-root" { f.root = false }
            XCTAssertThrowsError(try f.validate(), reason)
            XCTAssertTrue(f.queries.isEmpty)
        }
    }
    func testPrivateProtectedFileAndExecutableOwnershipAreRequired() throws {
        for reason in ["missing", "foreign", "public", "symlink", "hardlink", "helper-writable", "helper-not-executable", "foreign-helper"] {
            let f = HookAdmissionFixture()
            if reason == "missing" { f.files[f.protected] = nil }
            if reason == "foreign" { f.files[f.protected] = f.file(f.protected, owner: 502, mode: 0o100600) }
            if reason == "public" { f.files[f.protected] = f.file(f.protected, mode: 0o100644) }
            if reason == "symlink" { f.files[f.protected] = f.file(f.protected, mode: 0o120600) }
            if reason == "hardlink" { f.files[f.protected] = f.file(f.protected, mode: 0o100600, links: 2) }
            if reason == "helper-writable" { f.files[f.helper] = f.file(f.helper, mode: 0o100775) }
            if reason == "helper-not-executable" { f.files[f.helper] = f.file(f.helper, mode: 0o100644) }
            if reason == "foreign-helper" { f.files[f.helper] = f.file(f.helper, owner: 502, mode: 0o100755) }
            XCTAssertThrowsError(try f.validate(), reason)
            XCTAssertTrue(f.queries.isEmpty)
        }
    }
    func testProtectedFileCannotBeAliasedToAllowedWorktreePath() throws {
        let f = HookAdmissionFixture(); f.files[f.protected] = f.file("/worktree/allowed.json", mode: 0o100600)
        XCTAssertThrowsError(try f.validate()); XCTAssertTrue(f.queries.isEmpty)
    }
    func testProcessBirthExecutableAndFileIdentityAreRecheckedAfterKernelQuery() throws {
        for reason in ["peer-birth", "provider-birth", "executable", "protected-file", "helper-file", "ancestry"] {
            let f = HookAdmissionFixture()
            f.onQuery = {
                if reason == "peer-birth" { f.processes[21] = f.process(21, seconds: 999) }
                if reason == "provider-birth" { f.processes[11] = f.process(11, seconds: 999) }
                if reason == "executable" { f.processes[21] = f.process(21, path: "/worktree/other") }
                if reason == "protected-file" { f.files[f.protected] = f.file(f.protected, inode: 999, mode: 0o100600) }
                if reason == "helper-file" { f.files[f.helper] = f.file(f.helper, inode: 999, mode: 0o100755) }
                if reason == "ancestry" { f.root = false }
            }
            XCTAssertThrowsError(try f.validate(), reason)
        }
    }
    func testInvalidIDsProviderAndPathsNeverReachKernelQuery() throws {
        let f = HookAdmissionFixture()
        for (origin, provider, kind, path) in [(Int32(0), Int32(11), AgentKind.claude, f.protected), (21, 21, .claude, f.protected), (21, 11, .shell, f.protected), (21, 11, .codex, "/runtime/../allowed"), (21, 11, .codex, "/runtime/a\0b"), (21, 11, .codex, "relative"), (21, 11, .claude, f.helper)] {
            XCTAssertThrowsError(try TwinHookAdmission.validate(originPID: origin, providerPID: provider, provider: kind, helperExecutable: f.helper, protectedPath: path, probe: f.probe))
        }
        XCTAssertTrue(f.queries.isEmpty)
    }
    func testRootOwnedReadOnlyHelperIsSupported() throws {
        let f = HookAdmissionFixture(); f.files[f.helper] = f.file(f.helper, owner: 0, mode: 0o100755)
        XCTAssertNoThrow(try f.validate())
    }
}

private final class HookAdmissionFixture {
    let helper = "/Applications/Trano.app/Contents/MacOS/trano"
    let protected = "/runtime/twins/run/round-1/launch.json"
    var files: [String: TwinHookFileWitness] = [:]
    var processes: [Int32: TwinHookProcessWitness] = [:]
    var root = true
    var query = TranoTwinSandboxWriteResult(result: 0, error: 0)
    var queries: [String] = []
    var onQuery: (() -> Void)?
    init() {
        files[helper] = file(helper, mode: 0o100755)
        files[protected] = file(protected, mode: 0o100600)
        processes[21] = process(21)
        processes[11] = process(11)
    }
    var probe: TwinHookAdmissionProbe {
        TwinHookAdmissionProbe(userID: 501, process: { self.processes[$0] }, file: { self.files[$0] }, rootHook: { _, _, _ in self.root }, sandboxWrite: { pid, path in self.queries.append("\(pid):" + path); self.onQuery?(); return self.query })
    }
    func validate() throws { try TwinHookAdmission.validate(originPID: 21, providerPID: 11, provider: .claude, helperExecutable: helper, protectedPath: protected, probe: probe) }
    func process(_ pid: Int32, owner: UInt32 = 501, seconds: UInt64 = 100, path: String? = nil) -> TwinHookProcessWitness {
        .init(birth: .init(pid: pid, ownerUID: owner, startedAtSeconds: seconds, startedAtMicroseconds: 1), executable: path ?? (pid == 21 ? helper : "/provider/claude"))
    }
    func file(_ path: String, inode: UInt64 = 1, owner: UInt32 = 501, mode: UInt32, links: UInt64 = 1) -> TwinHookFileWitness {
        .init(path: path, device: 1, inode: inode, owner: owner, mode: mode, links: links, size: 100, modifiedSeconds: 1, modifiedNanoseconds: 0, changedSeconds: 1, changedNanoseconds: 0)
    }
}
