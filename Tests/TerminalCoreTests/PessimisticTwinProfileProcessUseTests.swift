import Foundation
import XCTest
import Darwin
@testable import TerminalCore

final class PessimisticTwinProfileProcessUseTests: XCTestCase {
    // Implements: FR-TWIN-4, FR-TWIN-8, FR-TWIN-10
    func testCWDAndOpenVnodeUnderProfileBothHoldCleanup() {
        let cwd = TwinProfileUseTestProbe(); cwd.directory = "/profile/tmp"
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: cwd.probe))
        let descriptor = TwinProfileUseTestProbe(); descriptor.openFiles = [.init(descriptor: 3, path: "/profile/tmp/open", device: 1, inode: 1)]
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: descriptor.probe))
    }
    func testSiblingPrefixDoesNotHoldAndCleanSnapshotCanComplete() {
        let f = TwinProfileUseTestProbe(); f.directory = "/profile-other"; f.openFiles = [.init(descriptor: 3, path: "/profile-other/open", device: 1, inode: 1)]
        XCTAssertNoThrow(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: f.probe))
    }
    func testExactOwnKnownFDMayBeIgnoredButExtraOwnFDAndSelfCWDStillHold() {
        let f = TwinProfileUseTestProbe(); f.openFiles = [.init(descriptor: 3, path: "/profile/.trano-twin-profile", device: 1, inode: 1)]
        XCTAssertNoThrow(try TwinProfileProcessUse.validate(profileRoot: "/profile", ignoringOwnDescriptors: [3: "/profile/.trano-twin-profile"], probe: f.probe))
        f.openFiles.append(.init(descriptor: 4, path: "/profile/tmp/unowned-by-cleanup", device: 1, inode: 2))
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", ignoringOwnDescriptors: [3: "/profile/.trano-twin-profile"], probe: f.probe))
        f.openFiles.removeLast(); f.directory = "/profile"
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", ignoringOwnDescriptors: [3: "/profile/.trano-twin-profile"], probe: f.probe))
    }
    func testOwnFDExemptionsCannotApplyToOtherProcessOrDifferentFDPath() {
        let f = TwinProfileUseTestProbe(); f.openFiles = [.init(descriptor: 3, path: "/profile/another", device: 1, inode: 1)]
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", ignoringOwnDescriptors: [3: "/profile/.trano-twin-profile"], probe: f.probe))
        var probe = f.probe; probe.currentPID = 999
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", ignoringOwnDescriptors: [3: "/profile/another"], probe: probe))
        f.openFiles = []
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", ignoringOwnDescriptors: [3: "/profile/another"], probe: f.probe))
    }
    func testUnknownQueryFailurePIDReuseAndChangingPIDSetHold() {
        let f = TwinProfileUseTestProbe(); var unknown = f.probe
        unknown.cwd = { _ in throw TerminalError.invalid("incomplete") }
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: unknown))
        let reused = TwinProfileUseTestProbe(); reused.onFiles = { count in if count == 1 { reused.birthSeconds = 2 } }
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: reused.probe))
        let changed = TwinProfileUseTestProbe(); changed.onList = { count in if count >= 2 { changed.pids = [42, 43] } }
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: changed.probe))
    }
    func testCompleteOutsideFDChurnDoesNotHoldUnrelatedProfileCleanup() {
        let f = TwinProfileUseTestProbe(); f.openFiles = [.init(descriptor: 3, path: "/source/old-log", device: 1, inode: 1)]
        f.onFiles = { count in if count >= 2 { f.openFiles = [.init(descriptor: 4, path: "/source/new-log", device: 1, inode: 2)] } }
        XCTAssertNoThrow(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: f.probe))
    }
    func testExemptTargetFDIdentityOrCWDChangeDuringFinalSnapshotHolds() {
        let files = TwinProfileUseTestProbe(); files.openFiles = [.init(descriptor: 3, path: "/profile/marker", device: 1, inode: 1)]
        files.onFiles = { count in if count >= 2 { files.openFiles = [.init(descriptor: 3, path: "/profile/marker", device: 1, inode: 2)] } }
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", ignoringOwnDescriptors: [3: "/profile/marker"], probe: files.probe))
        let cwd = TwinProfileUseTestProbe(); cwd.onFiles = { count in if count == 1 { cwd.directory = "/profile/tmp" } }
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: cwd.probe))
    }
    func testVerifiedStableExitedProcessIsIgnoredWithoutCWDOrFDLookup() {
        let f = TwinProfileUseTestProbe(); f.exited = true
        var probe = f.probe; probe.cwd = { _ in XCTFail("Exited process has no cwd"); return "/" }; probe.files = { _, _, _ in XCTFail("Exited process has no descriptors"); return [] }
        XCTAssertNoThrow(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: probe))
    }
    func testBoundsDeadlineMalformedPathsAndIncompleteInventoriesHold() {
        let f = TwinProfileUseTestProbe()
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/", probe: f.probe))
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile/../source", probe: f.probe))
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: f.probe, maxProcesses: 0))
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: f.probe, maxDescriptors: 0))
        f.openFiles = [.init(descriptor: 3, path: "", device: 1, inode: 1)]
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: f.probe))
        f.openFiles = []; f.onFiles = { _ in f.time = 3 }
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: f.probe))
        let clock = TwinProfileUseTestProbe(); clock.time = .nan
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: "/profile", probe: clock.probe))
    }
    func testNativeOwnedWaitingProcessCWDAndOpenFileAreDetectedWithoutProvider() throws {
        let f = try TwinProfileUseRealFixture(); defer { f.remove() }
        for useFD in [false, true] {
            let child = Process(), output = Pipe(), input = Pipe()
            child.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
            child.currentDirectoryURL = useFD ? f.base : f.profile
            child.arguments = ["-I", "-S", "-B", "-u", "-c", "import sys;f=open(sys.argv[1], 'rb') if sys.argv[2]=='fd' else None;print('READY',flush=True);sys.stdin.buffer.read()", f.file.path, useFD ? "fd" : "cwd"]
            child.environment = ["PATH": "/usr/bin:/bin"]; child.standardOutput = output; child.standardError = Pipe(); child.standardInput = input
            try child.run(); defer { kill(child.processIdentifier, SIGKILL); child.waitUntilExit() }
            XCTAssertEqual(try output.fileHandleForReading.read(upToCount: 6), Data("READY\n".utf8))
            var probe = TwinProfileProcessUseProbe.native
            probe.processIDs = { _ in [child.processIdentifier] }
            XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: f.profile.path, probe: probe))
        }
    }
    func testNativeExactSelfFDExemptionDoesNotHideAnotherOpenFile() throws {
        let f = try TwinProfileUseRealFixture(); defer { f.remove() }
        let marker = open(f.file.path, O_RDONLY | O_CLOEXEC)
        guard marker >= 0 else { throw TerminalError.invalid("Fixture open failed") }; defer { close(marker) }
        var probe = TwinProfileProcessUseProbe.native; probe.processIDs = { _ in [getpid()] }
        XCTAssertNoThrow(try TwinProfileProcessUse.validate(profileRoot: f.profile.path, ignoringOwnDescriptors: [marker: f.file.path], probe: probe))
        let another = open(f.profile.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard another >= 0 else { throw TerminalError.invalid("Fixture directory open failed") }; defer { close(another) }
        XCTAssertThrowsError(try TwinProfileProcessUse.validate(profileRoot: f.profile.path, ignoringOwnDescriptors: [marker: f.file.path], probe: probe))
    }
}

private final class TwinProfileUseRealFixture {
    let base: URL; let profile: URL; let file: URL
    init() throws {
        base = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("twin-profile-use-" + UUID().uuidString)
        profile = base.appendingPathComponent("profile"); file = profile.appendingPathComponent("marker")
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]); try Data("FRESH_FIXTURE_ONLY\n".utf8).write(to: file)
    }
    func remove() { try? FileManager.default.removeItem(at: base) }
}
private final class TwinProfileUseTestProbe {
    var pids: [Int32] = [42], birthSeconds: UInt64 = 1, directory = "/outside", exited = false, time: TimeInterval = 0
    var openFiles: [TwinProfileOpenFile] = [], listCalls = 0, fileCalls = 0
    var onList: ((Int) -> Void)?, onFiles: ((Int) -> Void)?
    var probe: TwinProfileProcessUseProbe {
        .init(userID: getuid(), currentPID: 42, processIDs: { _ in self.listCalls += 1; self.onList?(self.listCalls); return self.pids },
            identity: { pid in .init(birth: .init(pid: pid, ownerUID: getuid(), startedAtSeconds: self.birthSeconds, startedAtMicroseconds: 0), exited: self.exited) },
            cwd: { _ in self.directory }, files: { _, _, _ in self.fileCalls += 1; self.onFiles?(self.fileCalls); return self.openFiles }, now: { self.time })
    }
}
