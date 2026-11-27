import Foundation
import Darwin
import XCTest
@testable import TerminalCore

final class PessimisticTwinGitPlumbingTests: XCTestCase {
    // Implements: FR-TWIN-2, FR-TWIN-10
    func testProductionSnapshotPlumbingPreservesSourceAndIncludesUntrackedBeforeInterceptedWorktreeCreation() throws {
        let fs = TwinNativeGitFileSystem()
        let temporary = URL(fileURLWithPath: try fs.canonicalPath(FileManager.default.temporaryDirectory.path)).appendingPathComponent("twin-plumbing-unit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let source = temporary.appendingPathComponent("source"), runtime = temporary.appendingPathComponent("runtime")
        for value in [source, runtime] { try FileManager.default.createDirectory(at: value, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
        let environment = ["PATH": "/usr/bin:/bin", "HOME": temporary.path, "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_AUTHOR_NAME": "Trano", "GIT_AUTHOR_EMAIL": "trano@localhost", "GIT_COMMITTER_NAME": "Trano", "GIT_COMMITTER_EMAIL": "trano@localhost"]
        func git(_ arguments: [String]) throws -> Data {
            let result = try CommandRunner.run("/usr/bin/git", ["-C", source.path, "-c", "core.hooksPath=/dev/null"] + arguments, environment: environment)
            guard result.status == 0 else { throw TwinGitError.unsafe("Isolated fixture setup failed") }; return result.stdout
        }
        _ = try git(["init", "-q"])
        let file = source.appendingPathComponent("tracked.txt")
        try Data("committed\n".utf8).write(to: file)
        _ = try git(["add", "--all"]); _ = try git(["commit", "-qm", "fixture"])
        try Data("staged\n".utf8).write(to: file); _ = try git(["add", "tracked.txt"])
        try Data("latest unstaged\n".utf8).write(to: file)
        let untracked = source.appendingPathComponent("한글\nnew.bin"), binary = Data([0, 255, 10])
        try binary.write(to: untracked)
        let index = try Data(contentsOf: source.appendingPathComponent(".git/index")), head = try git(["rev-parse", "HEAD"])
        let runner = InterceptWorktreeRunner(), service = TwinGitService(root: runtime, runner: runner, fileSystem: fs, inspector: NeverWorktreeInspector())
        let identity = SupervisorProcessIdentity(pid: 42, ownerUID: getuid(), startedAtSeconds: 1, startedAtMicroseconds: 1)
        let binding = TwinSourceBinding(paneID: UUID().uuidString.lowercased(), generation: UUID().uuidString.lowercased(), conversationID: UUID().uuidString.lowercased(), cwd: source.path, configurationRoot: temporary.path, provider: .codex, backendPID: 42, providerPID: 43, backendIdentity: identity, providerIdentity: identity)
        XCTAssertThrowsError(try service.snapshot(source: binding, runID: "d53161fb-54d8-4cee-9f02-71f71a1ea675", round: 1)) { error in XCTAssertTrue(error is InterceptWorktreeRunner.Intercept, String(describing: error) + " last=" + runner.lastCommand) }
        XCTAssertTrue(runner.creationIntercepted)
        XCTAssertEqual(try git(["rev-parse", "HEAD"]), head)
        XCTAssertEqual(try Data(contentsOf: source.appendingPathComponent(".git/index")), index)
        XCTAssertEqual(try Data(contentsOf: file), Data("latest unstaged\n".utf8))
        XCTAssertEqual(try Data(contentsOf: untracked), binary)
        let snapshot = try XCTUnwrap(runner.snapshotOID)
        XCTAssertEqual(try git(["show", snapshot + ":한글\nnew.bin"]), binary)
        XCTAssertEqual(try git(["show", snapshot + ":tracked.txt"]), Data("latest unstaged\n".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.appendingPathComponent("twins/d53161fb-54d8-4cee-9f02-71f71a1ea675/round-1/worktree").path))
    }
}
private final class InterceptWorktreeRunner: TwinGitCommandRunning {
    enum Intercept: Error { case creation }
    var creationIntercepted = false
    var snapshotOID: String?
    var lastCommand = ""
    func run(arguments: [String], input: Data?, environment: [String: String], timeout: TimeInterval, limit: Int) throws -> WorktreeGitCommandResult {
        if arguments.contains("worktree") && arguments.contains("add") { creationIntercepted = true; throw Intercept.creation }
        lastCommand = arguments.suffix(8).joined(separator: " ")
        let result = try TwinNativeGitRunner().run(arguments: arguments, input: input, environment: environment, timeout: timeout, limit: limit)
        if arguments.contains("worktree") && arguments.contains("list") { lastCommand += " response=" + String(decoding: result.stdout, as: UTF8.self).replacingOccurrences(of: "\0", with: "|") }
        if arguments.contains("commit-tree"), result.status == 0 { snapshotOID = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines) }
        return result
    }
}
private final class NeverWorktreeInspector: WorktreeGitInspecting {
    func creationInvocation(cwd: String, gitArguments: [String]) throws -> WorktreeCreationInvocation? { nil }
    func snapshot(cwd: String, gitArguments: [String]) throws -> WorktreeRepositorySnapshot { throw TwinGitError.unsafe("No real worktree should be inspected") }
    func inspect(_ identity: WorktreeIdentity) throws -> WorktreeInspection { throw TwinGitError.unsafe("No real worktree should be inspected") }
    func remove(_ identity: WorktreeIdentity) throws { throw TwinGitError.unsafe("No real worktree may be removed") }
    func processUse(path: String) throws -> WorktreeProcessUse { .uncertain }
}
