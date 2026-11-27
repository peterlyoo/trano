import Foundation
import XCTest
@testable import TerminalCore

final class GitTrackingShellTests: XCTestCase {
    // Implements: FR-WT-1, FR-WT-6
    func testShimPassesOrdinaryGitAndNestedGitThroughWithoutCapture() throws {
        let fixture = try fixture()
        XCTAssertFalse(GitTrackingShell.isInstalled(root: fixture.root))
        let path = try GitTrackingShell.install(root: fixture.root, helperExecutable: fixture.helper.path)
        XCTAssertTrue(GitTrackingShell.isInstalled(root: fixture.root))
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fixture.bin.path + ":/usr/bin:/bin"
        environment["CAPTURE_RECEIPT"] = fixture.receipt.path
        environment["FAKE_GIT_EXIT"] = "7"
        let result = try CommandRunner.run(path, ["status", "literal path with spaces"], input: Data("stdin\n".utf8), environment: environment)
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "stdin\nstatus\nliteral path with spaces\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
        environment["TRANO_WORKTREE_CAPTURE"] = "nested"
        let nested = try CommandRunner.run(path, ["worktree", "add", "한글 경로"], environment: environment)
        XCTAssertEqual(nested.status, 7)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.receipt.path))
    }

    func testWorktreeInvocationPreservesArgvAndCompatibilityPaths() throws {
        let fixture = try fixture()
        let path = try GitTrackingShell.install(root: fixture.root, helperExecutable: fixture.helper.path)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fixture.bin.path + ":/usr/bin:/bin"
        environment["CAPTURE_RECEIPT"] = fixture.receipt.path
        let result = try CommandRunner.run(path, ["-C", "/repo with spaces", "worktree", "add", "--", "한글 경로"], environment: environment)
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(try String(contentsOf: fixture.receipt, encoding: .utf8), "tracked-git\n")
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "-C\n/repo with spaces\nworktree\nadd\n--\n한글 경로\n")
        for file in [fixture.root.appendingPathComponent("bin/git"), fixture.root.appendingPathComponent("shell/bin/git")] {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: file.path))
            XCTAssertEqual(try Data(contentsOf: file), try Data(contentsOf: URL(fileURLWithPath: path)))
        }
        let first = try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber
        _ = try GitTrackingShell.install(root: fixture.root, helperExecutable: fixture.helper.path)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: path)[.systemFileNumber] as? NSNumber, first)
    }

    func testEnvironmentPreservesSeparateGitShimAndRefusesUnmanagedReplacement() throws {
        let fixture = try fixture()
        let environment = try GitTrackingShell.environment(["PATH": fixture.bin.path + ":/usr/bin"], root: fixture.root, helperExecutable: fixture.helper.path)
        XCTAssertEqual(environment["PATH"]?.components(separatedBy: ":").first, fixture.root.appendingPathComponent("git-bin").path)
        let conflict = try self.fixture()
        let bin = conflict.root.appendingPathComponent("git-bin")
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let file = bin.appendingPathComponent("git")
        try Data("user owned\n".utf8).write(to: file)
        XCTAssertThrowsError(try GitTrackingShell.install(root: conflict.root, helperExecutable: conflict.helper.path))
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "user owned\n")
    }

    func testMissingTrackingHelperStillRunsOriginalGit() throws {
        let fixture = try fixture()
        let path = try GitTrackingShell.install(root: fixture.root, helperExecutable: fixture.helper.path)
        try FileManager.default.removeItem(at: fixture.helper)
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = fixture.bin.path + ":/usr/bin:/bin"
        environment["FAKE_GIT_EXIT"] = "9"
        let result = try CommandRunner.run(path, ["worktree", "add", "path"], environment: environment)
        XCTAssertEqual(result.status, 9)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "worktree\nadd\npath\n")
    }

    private func fixture() throws -> (root: URL, bin: URL, helper: URL, receipt: URL) {
        let base = URL(fileURLWithPath: "/tmp").appendingPathComponent("trano git unit " + UUID().uuidString.prefix(8))
        let root = base.appendingPathComponent("runtime"), bin = base.appendingPathComponent("real bin")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        let git = bin.appendingPathComponent("git"), helper = base.appendingPathComponent("trano helper")
        try Data("#!/bin/sh\n/bin/cat\nfor arg do printf '%s\\n' \"$arg\"; done\nexit \"${FAKE_GIT_EXIT:-0}\"\n".utf8).write(to: git)
        try Data("#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$CAPTURE_RECEIPT\"\nshift\nexec \"$@\"\n".utf8).write(to: helper)
        for path in [git, helper] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path.path) }
        return (root, bin, helper, base.appendingPathComponent("receipt"))
    }
}
